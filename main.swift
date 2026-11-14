// 分刻 · Countmin — macOS 悬浮小窗版 v2
// 功能：Liquid Glass 界面 / 设置页(月薪+工作日自动计算) / 金币进度条(图标吸色)
//       明细芯片 / 迷你模式 / 状态栏常驻(含状态栏迷你金额显示)
//       关闭默认收纳到状态栏(设置可选直接退出) / 校正工时
// 纯逻辑(节假日/费率/吸色)在 Logic.swift，测试在 test_logic.swift

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WidgetKit
import Network
import ServiceManagement
import CryptoKit

// MARK: - 小组件数据桥（本机回环 HTTP）
// 沙盒扩展既读不到真实家目录、也读不到别的 App 的偏好（ad-hoc 签名下临时豁免不生效），
// 但 outbound 网络是标准沙盒能力 —— 所以在 127.0.0.1 起一个极简 HTTP 服务把快照喂给扩展。
// 只绑回环地址，不暴露到局域网。
final class WidgetBridge {
    static let shared = WidgetBridge()
    static let port: UInt16 = 47821
    private var listener: NWListener?
    private var payload = Data("{}".utf8)

    func update(_ data: Data) { payload = data }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .utility))
            self?.serve(conn)
        }
        l.start(queue: .global(qos: .utility))
        listener = l
    }

    private func serve(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] _, _, _, _ in
            guard let self else { conn.cancel(); return }
            let body = self.payload
            var out = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(body)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

struct Gain: Identifiable { let id = UUID(); let xOffset: CGFloat }

// 流水明细行（设置页查询结果）
struct DayLogRow: Identifiable {
    let key: String       // yyyy-MM-dd
    let earned: Double
    let otSeconds: Double
    var id: String { key }
}

// 处理 xiaoxinxin:// URL（小组件点击唤起主窗口）
final class URLOpener: NSObject {
    static let shared = URLOpener()
    var onOpen: (() -> Void)?
    /// 2.5：小组件点进来带页面（xiaoxinxin://days → 倒计时页，://money → 首页）
    var onOpenPage: ((String) -> Void)?
    @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        let raw = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue ?? ""
        onOpen?()
        if let url = URL(string: raw), let host = url.host, !host.isEmpty { onOpenPage?(host) }
    }
}

// MARK: - 开发者信息 / 版本 / 版权 / 主题迭代记录
let DEV_NAME = "逍狗屁屁"
// 副标题随 2.7 品牌焕新换成理念式 slogan（不堆关键词，规避商店关键词垃圾审核）
let DEV_TAGLINE = "记录每一段值得的时光"
// 版本号单一来源 = Info.plist 的 CFBundleShortVersionString / CFBundleVersion（plutil 改一处，界面全跟）
// 裸二进制（脱离 bundle 跑自检）读不到 Info.plist 时用下面的兜底值
let APP_VERSION = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    ?? ProcessInfo.processInfo.environment["XINXIN_VERSION"] ?? "2.7.1"
let APP_BUILD = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
    ?? ProcessInfo.processInfo.environment["XINXIN_BUILD"] ?? "49"

/// 发版日期单一来源：Info.plist 的 XinXinReleaseDate（每次升版本一起改）。
/// 脱离 bundle 跑自检时依次退回 Info.plist 文件修改日 → 当天，保证「跟随版本迭代」不会写死。
let APP_RELEASE_DATE: String = {
    if let s = Bundle.main.infoDictionary?["XinXinReleaseDate"] as? String, !s.isEmpty { return s }
    let p = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist").path
    if let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
}()
let APP_COPYRIGHT_YEAR = String(Calendar.current.component(.year, from: Date()))
let APP_COPYRIGHT_LINE = "© \(APP_COPYRIGHT_YEAR) \(DEV_NAME). 保留所有权利。"
let SONY_COPYRIGHT_NOTICE =
    "Sony 30th 主题为致敬初代 PlayStation 30 周年的非官方配色。PlayStation 及 Sony 相关标识为 Sony Interactive Entertainment Inc. 等权利人的商标，版权归各自所有者；本应用与 Sony Interactive Entertainment 无任何关联或授权关系。"

/// 主题与版权声明的迭代记录：关于面板、设置页「版本与版权」、README 共用这一张表
struct ReleaseRecord: Identifiable {
    var id: String { version }
    let version: String
    let build: String
    let date: String
    let theme: String
    let copyright: String
}
let RELEASE_HISTORY: [ReleaseRecord] = [
    .init(version: "2.7.1", build: "49", date: "2026-11-14",
          theme: "修复非工作日仍会自动打卡：自动上班前先按班次开始日判工作日，周末与自定义休息日不再到点就计费",
          copyright: "autoClockInIfNeeded() 原先只判断是否在 [计划上班, 计划下班) 时间窗内，从未查工作日规则；现补 isWorkDate(start, rule:)，判班次开始日以兼顾跨零点夜班。自动下班不拦——周末手动打卡加班仍可正常结束；开着「叠加法定节假日」时调休补班日照常打卡"),
    .init(version: "2.7.0", build: "48", date: "2026-11-12",
          theme: "改名「分刻 · Countmin」：去金钱词，回归「每一分钟都值得记录」的时间内核；副标题改为「记录每一段值得的时光」",
          copyright: "原名「小薪薪」带金钱词，限制了商店上架与功能延展。改名只动展示层：Bundle ID（com.haofan.xiaoxinxin）、数据目录、小组件扩展标识全部保持原样，老用户的打卡记录与设置无需迁移即可继承"),
    .init(version: "2.6.6", build: "47", date: "2026-11-10",
          theme: "小组件也扣午休了：主窗口 83%、小组件 95% 的口径差补平，休息时段进度冻结不再往上爬",
          copyright: "2.6.5 只把主程序的工时口径改成可计费秒数，扩展那一路仍按墙钟累加：午休期间小组件百分比照涨，下班还会顶到 112%。现在主程序把本班次休息区间写进快照，扩展按重叠秒数扣除，停表烘焙同样剔休息"),
    .init(version: "2.6.5", build: "46", date: "2026-11-09",
          theme: "午休不再算工时：9:00–18:00 休 60 分钟，16:38 从 95% 回到 83%，18:00 正好 100%",
          copyright: "分母按 8 小时、分子按墙钟 9 小时，两边口径不一致，午休还在进钱；现按「休息从几点开始」定位休息区间，金额 / 工时 / 月度累计 / 锁屏全部剔除。另修改月薪会清零当天累计、改工时直接重置起点导致已跑时长被抹掉"),
    .init(version: "2.6.4", build: "45", date: "2026-11-09",
          theme: "倒计时与纪念日支持修改已添加的事件；事件列表可按 ≡ 手柄拖动排序，或用 ⇅ 菜单上移 / 下移 / 置顶 / 置底",
          copyright: "修掉编辑时 createdKey 被重置成今天（一次性倒计时进度起点被改）、纪念日编辑丢失 mode 与 targetDays 两个字段；编辑状态从全局 evEditing 拆成按类隔离的 evEditingKind，避免改倒计时把纪念日表单串掉"),
    .init(version: "2.6.3", build: "44", date: "2026-11-09",
          theme: "修中尺寸小组件反复变灰骨架：强刷时间线从每 5 分钟降到每小时，不再烧穿系统刷新预算",
          copyright: "WidgetKit 每天只给约 40-50 次刷新额度，旧版 5 分钟一刷一天 288 次，额度烧完时间线过期就被系统打回占位图；现改为事件驱动刷新 + 每小时兜底"),
    .init(version: "2.6.2", build: "43", date: "2026-11-08",
          theme: "拖窗口跟手了：不再逐帧搬窗口，改由系统拖窗循环处理；顶部 / 底部各一条固定拖拽带，窗口在后台点哪儿都不会再沉下去",
          copyright: "拖拽改走 performDrag（实测拖 +120,-80 窗口就走 +120,-80；旧版只走一半）。空白处点击也补上兜底"),
    .init(version: "2.6.1", build: "42", date: "2026-11-08",
          theme: "修拖拽发飘：去掉 SwiftUI DragGesture 搬窗口的自研方案",
          copyright: "SwiftUI 手势用 .local 坐标系，窗口跟着鼠标动，位移被自身抵消一半；改由 AppKit 背景拖 / performDrag 接管"),
    .init(version: "2.6.0", build: "41", date: "2026-11-07",
          theme: "顶栏重做：不再有留白，整条都是按钮（标题=关于、MONEY/DAYS 模块切换、打卡状态菜单）；图标改成「一半人民币、一半沙漏」",
          copyright: "点击顶栏任何位置都会被窗口接住并重新置前；Dock 图标缓存强制刷新"),
    .init(version: "2.5.2", build: "40", date: "2026-11-07",
          theme: "顶栏留白彻底不掉层：首次点击即激活，空白区域也能拖窗；换扁平天蓝新图标",
          copyright: "宿主视图在 acceptsFirstMouse 阶段激活并置前，hitTest 兜底覆盖整个窗口矩形"),
    .init(version: "2.5.1", build: "39", date: "2026-11-07",
          theme: "点窗口顶部留白不再掉层：后台时首次点击也能激活窗口并置前",
          copyright: "宿主视图改为接受首次点击的 NSHostingView 子类，配合同步激活 + 置前"),
    .init(version: "2.5.0", build: "38", date: "2026-11-07",
          theme: "小组件按 MONEY / DAYS 拆成两个：工资组件显示今日到账与本月，日子组件显示倒计时剩余天数与纪念日累计",
          copyright: "小组件配色跟随 App 主题（Liquid Glass / 薄荷 / 天蓝 / Sony 30th 四色进度条），不再是固定深蓝金"),
    .init(version: "2.4.1", build: "37", date: "2026-11-07",
          theme: "点顶栏留白不再把窗口沉到最底层（窗口接管点击并置前）；顶栏圆形按钮命中区收敛到圆内",
          copyright: "贴边收纳改为「拖拽 ≥40pt 松手」才触发，顶部边缘不再收纳；沿用 Sony 30th 商标归属声明"),
    .init(version: "2.4.0", build: "36", date: "2026-11-07",
          theme: "「记录日」正式更名「纪念日」；倒计时与纪念日二级页内置事件管理（新增 / 改名 / 删除 / 切换）；设置页与首页等高、页内滚动",
          copyright: "修复无边框窗口无法拖动的问题；沿用 Sony 30th 商标归属声明"),
    .init(version: "2.3.0", build: "35", date: "2026-11-07",
          theme: "默认主题改为「白 + 天蓝」；菜单栏可按 MONEY / DAYS 自选显示项并滚动轮播，有内容时不显示图标",
          copyright: "窗口外观跟随主题明暗，修复系统深色模式下浅色主题文字发白；沿用 Sony 30th 商标归属声明"),
    .init(version: "2.2.1", build: "34", date: "2026-11-07",
          theme: "四款主题保留；界面去 emoji、改用字重与重点色建立层级；修复首页与二级页窗口变形",
          copyright: "补充 Sony 30th 非官方致敬与商标归属声明；关于页加入版本 / Build / 发版日期与迭代记录"),
    .init(version: "2.2.0", build: "33", date: "2026-11-07",
          theme: "新增 Sony 30th、白+薄荷绿、白+天蓝，连同初始 Liquid Glass 共四款；色卡无极调色 + 背景透明度",
          copyright: "Sony 30th 依据初代 PlayStation 30 周年公开配色实现，当时未附商标声明"),
    .init(version: "2.1.0", build: "32", date: "2026-11-07",
          theme: "初始 Liquid Glass 透明风格；首页拆为 Your Money / Your Days 三张独立进度卡",
          copyright: "沿用 v1.x 开发者版权声明"),
    .init(version: "2.0.0", build: "31", date: "2026-11-07",
          theme: "初始 Liquid Glass 透明风格；进度条统计内容可切换",
          copyright: "沿用 v1.x 开发者版权声明"),
]

/// 关于面板正文（自检也读它，保证版本 / 日期 / 版权 / Sony 声明一处不漏）
func aboutCreditsText() -> String {
    let lines = RELEASE_HISTORY.prefix(2).map { "v\($0.version) · \($0.date) · \($0.theme)" }
    return """
    开发者　\(DEV_NAME)
    \(DEV_TAGLINE)
    v\(APP_VERSION) · Build \(APP_BUILD) · \(APP_RELEASE_DATE)
    \(APP_COPYRIGHT_LINE)

    \(SONY_COPYRIGHT_NOTICE)

    主题与版权声明迭代（完整记录见 设置 → 版本与版权）
    \(lines.joined(separator: "\n"))
    """
}

/// 标准「关于」面板：开发者署名 + 版本/Build/日期 + 版权 + Sony 声明 + 迭代摘要
@MainActor
func showAboutPanel() {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.lineSpacing = 3
    let text = aboutCreditsText()
    let credits = NSMutableAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: para,
    ])
    if let r = text.range(of: DEV_NAME) {
        credits.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 12),
                             range: NSRange(r, in: text))
    }
    NSApp.orderFrontStandardAboutPanel(options: [
        .applicationName: "分刻 · Countmin",
        .applicationVersion: APP_VERSION,
        .version: "Build \(APP_BUILD) · \(APP_RELEASE_DATE)",
        .credits: credits,
    ] as [NSApplication.AboutPanelOptionKey: Any])
    NSApp.activate()
}

// MARK: - 计薪模型

enum Page { case home, salary, countdown, recordDay, settings, mini

    var heightKey: String {
        switch self {
        case .home: return "home"
        case .salary: return "salary"
        case .countdown: return "countdown"
        case .recordDay: return "recordDay"
        case .settings: return "settings"
        case .mini: return "mini"
        }
    }
}

// 2.1：Your Money / Your Days 两大模块，下面三个模式各自独立成二级页，不共用模块
enum DetailMode: String, CaseIterable {
    case salary, countdown, recordDay

    /// 所属模块名（用户指定）
    var module: String {
        switch self { case .salary: return "Your Money"; default: return "Your Days" }
    }
    var title: String {
        switch self {
        case .salary:    return "薪酬进度"
        case .countdown: return "倒计时"
        case .recordDay: return "纪念日"
        }
    }
    var icon: String {
        switch self {
        case .salary:    return ""
        case .countdown: return ""
        case .recordDay: return ""
        }
    }
    var page: Page {
        switch self {
        case .salary: return .salary
        case .countdown: return .countdown
        case .recordDay: return .recordDay
        }
    }
    var card: HomeCard {
        switch self {
        case .salary: return .money
        case .countdown: return .countdown
        case .recordDay: return .recordDay
        }
    }
}

// 首页三张进度卡可单独隐藏
enum HomeCard: String, CaseIterable {
    case money, countdown, recordDay

    var title: String {
        switch self {
        case .money:     return "Your Money · 薪酬"
        case .countdown: return "Your Days · 倒计时"
        case .recordDay: return "Your Days · 纪念日"
        }
    }
    var detail: String {
        switch self {
        case .money:     return "薪酬/工时进度、当日与本月摘要，点击进入薪酬详情页"
        case .countdown: return "目标日剩余天数或完成百分比，点击进入倒计时详情页"
        case .recordDay: return "从纪念日起累计的天数与里程碑进度，点击进入纪念日详情页"
        }
    }
}

// MARK: - 菜单栏显示项（2.3）
// 菜单栏（状态栏）能显示的内容：MONEY 系 4 种、DAYS 系 2 种，可多选 + 轮播。
// 左侧统一加一枚小字标签（MONEY / DAYS），一眼分得清是钱还是天数。
enum BarGroup {
    case money, days
    var tag: String { self == .money ? "MONEY" : "DAYS" }
}

enum StatusBarKind: String, CaseIterable, Identifiable {
    case moneyToday, moneyMonth, moneyTodayPct, moneyMonthPct, daysCountdown, daysRecord

    var id: String { rawValue }

    var group: BarGroup {
        switch self {
        case .moneyToday, .moneyMonth, .moneyTodayPct, .moneyMonthPct: return .money
        case .daysCountdown, .daysRecord:                              return .days
        }
    }

    var title: String {
        switch self {
        case .moneyToday:     return "今日已赚"
        case .moneyMonth:     return "本月累计"
        case .moneyTodayPct:  return "今日进度"
        case .moneyMonthPct:  return "本月进度"
        case .daysCountdown:  return "倒计时剩余"
        case .daysRecord:     return "纪念日累计"
        }
    }

    var detail: String {
        switch self {
        case .moneyToday:    return "今日已到账金额（隐私模式自动显示百分比）"
        case .moneyMonth:    return "本月累计进账（隐私模式自动显示百分比）"
        case .moneyTodayPct: return "今日工时进度，计划 8h = 100%"
        case .moneyMonthPct: return "本月工时进度"
        case .daysCountdown: return "当前倒计时还剩几天，过期显示「已到」"
        case .daysRecord:    return "当前纪念日已经累计几天"
        }
    }

    /// 预览 / 轮播提示用的短名
    var short: String {
        switch self {
        case .moneyToday:     return "今日已赚"
        case .moneyMonth:     return "本月累计"
        case .moneyTodayPct:  return "今日%"
        case .moneyMonthPct:  return "本月%"
        case .daysCountdown:  return "倒计时"
        case .daysRecord:     return "纪念日"
        }
    }

    /// 进度条只在「钱」的进度类里有意义
    var showsProgress: Bool { group == .money }
}

// 纪念日二级页的 6 个模块，显隐与另外两页完全独立
// 2.4：不再走「进度条 / 里程碑」口径，改为围绕「累计时长」给信息
enum RecordDayChip: String, CaseIterable {
    case elapsed, duration, start, months, years, name

    var title: String {
        switch self {
        case .elapsed:  return "累计天数"
        case .duration: return "累计时长"
        case .start:    return "起始日期"
        case .months:   return "累计月数"
        case .years:    return "累计年数"
        case .name:     return "纪念日名称"
        }
    }
    var detail: String {
        switch self {
        case .elapsed:  return "从起始日到今天一共多少天"
        case .duration: return "拆成「X 年 Y 个月 Z 天」的累计时长"
        case .start:    return "纪念日从哪一天开始算"
        case .months:   return "从起始日到今天累计几个月"
        case .years:    return "从起始日到今天累计几年"
        case .name:     return "名称与显示方式"
        }
    }
}

// 薪酬二级页的 8 个模块（显隐与倒计时模块完全独立）
enum MoneyChip: String, CaseIterable {
    case salary, workdays, dayRate, hourRate, perSec, worked, monthEarned, monthOT

    var title: String {
        switch self {
        case .salary:      return "月薪"
        case .workdays:    return "工作日/月"
        case .dayRate:     return "日薪"
        case .hourRate:    return "时薪"
        case .perSec:      return "每秒进账"
        case .worked:      return "今日已工作"
        case .monthEarned: return "本月累计进账"
        case .monthOT:     return "本月加班时长"
        }
    }
    var detail: String {
        switch self {
        case .salary:      return "每月税后工资（隐私模式下显示 --）"
        case .workdays:    return "按自定义周几 + 法定节假日实时算"
        case .dayRate:     return "月薪 ÷ 当月工作日"
        case .hourRate:    return "日薪 ÷ 每日计划工时"
        case .perSec:      return "时薪 ÷ 3600"
        case .worked:      return "今日已工作时长 / 隐私模式改显示今日进度"
        case .monthEarned: return "本月累计 / 隐私模式改显示月度进度"
        case .monthOT:     return "本月加班 / 隐私模式改显示超出 100% 部分"
        }
    }
}

// 首页可显隐的按钮（设置页逐项开关）
enum HomeButton: String, CaseIterable {
    case clockIn, clockOut, overtime, mini, collapse, settings, close, metric

    var title: String {
        switch self {
        case .clockIn:   return "打卡上班"
        case .clockOut:  return "打卡下班"
        case .overtime:  return "加班打卡"
        case .mini:     return "缩小为迷你条"
        case .collapse: return "收纳到状态栏"
        case .settings: return "设置"
        case .close:    return "关闭窗口"
        case .metric:   return "切换统计内容"
        }
    }

    var detail: String {
        switch self {
        case .clockIn, .clockOut: return "隐藏后仍可从状态栏菜单打卡，不会丢失入口"
        case .overtime:           return "只在 Your Money 薪酬页出现；首页与 Your Days 两页不显示"
        case .settings:           return "隐藏后仍可从状态栏菜单进入设置"
        case .close:              return "隐藏后可用 ⌘Q 退出"
        default:                  return "首页顶部 / 底部的小按钮"
        }
    }
}

// 倒计时模式下首页芯片区专用模块（设置页逐项开关显隐）
enum CountdownChip: String, CaseIterable {
    case elapsed, remaining, target, percent, span, name

    var title: String {
        switch self {
        case .elapsed:   return "累计天数"
        case .remaining: return "剩余天数"
        case .target:    return "目标日期"
        case .percent:   return "完成进度"
        case .span:      return "总跨度"
        case .name:      return "倒计时名称"
        }
    }

    var detail: String {
        switch self {
        case .elapsed:   return "从起点到今天已走过的自然日"
        case .remaining: return "距目标日还剩几天，到期后显示「已到期」"
        case .target:    return "下一个目标日（年度重复会自动顺延）"
        case .percent:   return "已走天数 ÷ 总跨度"
        case .span:      return "起点到目标日的总天数"
        case .name:      return "名称与重复方式（每年 / 仅一次）"
        }
    }
}

// 进度条统一数据源：所有统计口径都算出这一份，首页 / 迷你条 / 状态栏 / 小组件共用
struct ProgressInfo {
    var ratio: Double = 0          // 原值，加班可 > 1
    var fill: Double = 0           // 条内填充 0...1
    var overflow: Double = 0       // 超出 100% 的部分（0...1，画第二段）
    var leading: String = "¥0.00"  // 首页大字主段
    var trailing: String = "00"    // 首页大字小字段
    var caption: String = "今日已到账"
    var footer: String = ""
    var isMoney: Bool = true
    var privacy: Bool = false
    var metric: ProgressMetric = .todaySalary
    var mode: DetailMode = .salary     // 2.1：这份进度属于哪个独立页面
}

// 薪酬二级页允许的 4 种口径（倒计时不再混进薪酬的统计内容里）
extension ProgressMetric {
    static var salaryCases: [ProgressMetric] { [.todaySalary, .monthSalary, .todayHours, .monthHours] }
}

@MainActor
final class EarnModel: ObservableObject {
    @Published var page: Page = .home
    @Published var salaryText: String
    @Published var workDaysText: String      // 空 = 自动按节假日
    @Published var workStartText: String     // 上班时间 HH:mm
    @Published var workEndText: String       // 下班时间 HH:mm
    @Published var breakMinText: String      // 每日休息时长（分钟）
    @Published var breakStartText: String    // 午休开始时刻 HH:mm（休息要真从工时里扣，光有时长扣不准）
    @Published var manualHoursText: String = ""  // 手动补录已上班小时数
    @Published var working = false
    @Published var displayEarned: Double = 0
    @Published var gains: [Gain] = []
    @Published var logText: String = ""
    // 2.2：主色由主题调色板统一供给（图标染色不再反向覆盖用户选的颜色）
    var accentA: Color { AppPalette.accent }
    var accentB: Color { AppPalette.accentDeep }
    /// Sony 30th 用初代四色按键做进度条渐变，其余主题仍是主色双色渐变
    var barColors: [Color] {
        let four = Array(AppPalette.highlights.dropFirst().prefix(4))
        return four.count >= 4 ? four : [accentA, accentB]
    }
    @Published var iconImage: NSImage?
    @Published var statusBarMode = false     // 缩小至状态栏：状态栏图标直接显示金额+进度
    @Published var closeBehavior: String     // 点击关闭按钮时："hide"=收纳到状态栏，"quit"=直接退出
    @Published var barSymbol: String         // 状态栏金额前缀符号/emoji，可自定义（空=只显示数字）
    // 2.3 菜单栏显示：选哪几项（MONEY / DAYS 可混选）、是否轮播、是否带迷你进度条
    @Published var statusBarShowData = true      // 菜单栏常显数据（关掉只在「收缩至状态栏」时显示）
    @Published var statusBarKinds: Set<String> = [StatusBarKind.moneyToday.rawValue]
    @Published var statusBarRotate = false       // 多选时按顺序轮播
    @Published var statusBarRotateSeconds: Double = 5
    @Published var statusBarShowBar = false      // 数值前带迷你进度条（默认关：有内容就纯文字，不显示任何图标）
    @Published var statusBarGuard: String?       // 至少保留一项的提示
    @Published var autoOutEnabled: Bool      // 到点自动下班：到计划下班时刻自动打卡下班
    @Published var autoInEnabled: Bool       // 到点自动上班：到计划上班时刻自动打卡上班
    @Published var launchAtLogin: Bool       // 开机自动启动（登录项）
    @Published var launchAtLoginError: String?
    @Published var overtimeSeconds: Double = 0   // 今日加班累计秒数（自动下班后/过了下班时间再打卡的时段）
    @Published var dayLogRevision = 0        // 流水增删计数：驱动本月累计芯片刷新

    // MARK: - 2.0 配置（全部落本机 UserDefaults，不联网）
    @Published var customWeekdays: Set<Int>       // 每周计薪日：1=周日 … 7=周六
    @Published var useLegalHolidays: Bool         // 自定义周几之上是否叠加法定节假日 / 调休
    @Published var hiddenButtons: Set<String>     // 首页隐藏的按钮 id
    @Published var hiddenCountdownChips: Set<String>  // 倒计时二级页隐藏的模块 id
    @Published var hiddenMoneyChips: Set<String>      // 薪酬二级页隐藏的模块 id（与倒计时独立）
    @Published var hiddenRecordDayChips: Set<String>  // 纪念日二级页隐藏的模块 id
    @Published var hiddenHomeCards: Set<String>       // 首页隐藏的进度卡 id
    @Published var progressMetric: ProgressMetric // 薪酬二级页的进度条统计内容
    @Published var countdowns: [CountdownItem]    // 自定义日期倒计时
    @Published var activeCountdownId: String      // 首页显示的那条
    @Published var recordDays: [RecordDayItem]    // 纪念日
    @Published var activeRecordDayId: String      // 当前显示的纪念日
    @Published var privacyEnabled: Bool           // 隐私模式开关
    @Published var privacyUnlockedUntil: Date?    // 临时解锁看真实数字
    @Published var showOnboarding: Bool           // 首次进入 2.0 的统计内容引导

    // MARK: - 2.2 主题与调色（全部落本机 UserDefaults）
    @Published var themeId: String                // 当前预设 id
    @Published var themeBg: [Double]              // 背景色 RGB
    @Published var themeText: [Double]            // 文本色 RGB
    @Published var themeAccent: [Double]          // 重点 / 开关色 RGB
    @Published var themeAlpha: Double             // 背景不透明度（独立于颜色）
    @Published var homeCardGuard: String?         // 首页至少保留一张卡的提示
    @Published var manualOvertime = false         // 手动加班段：独立计时、单独计入加班时长

    var currentTheme: AppTheme { AppTheme(rawValue: themeId) ?? .liquidGlass }

    private var pinHash: String                   // 只存加盐哈希，绝不存明文
    private var pinSalt: String
    var hasPIN: Bool { !pinHash.isEmpty }

    private var dayKey = ""                  // 当前计费日 yyyy-MM-dd，用于跨天自动重置
    private var autoInKey = ""               // 已自动打过卡的班次标识，同一班次只自动打一次
    private var dayLog: [String: [String: Double]] = [:]   // 历史流水：dateKey -> ["earned": 当日到账, "ot": 当日加班秒]

    var onResize: (() -> Void)?
    var onHidePanel: (() -> Void)?           // 关闭收纳：由入口注入隐藏面板的实现

    private var baseEarned: Double = 0
    private var clockInAt: Date?
    private var lastGainMark: Double = 0
    private var workedBeforeSession: Double = 0   // 今日此前已完成计费段的累计秒数
    /// 上一次的班次配置：改工时时要用旧参数把已跑的段结算掉
    private var lastSchedule: (start: String, end: String, breakStart: String, breakMin: Double)?
    private var timer: Timer?
    private let ud: UserDefaults
    private var tickCount = 0
    private var snapTimer: DispatchSourceTimer?   // 快照心跳：不依赖界面存活
    private var snapBeat = 0
    private var napToken: NSObjectProtocol?

    // WidgetKit 数据快照：主 App（未沙盒）写出，小组件扩展（沙盒）经临时豁免授权读取
    // 注意：路径里的「小薪薪」是 2.x 的历史目录名。2.7 改名为「分刻」后这里必须保持原样，
    // 否则老用户的打卡记录、设置和小组件快照全部读不到——数据目录不做迁移是有意为之。
    static let widgetSnapURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/小薪薪", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget-snapshot.json")
    }()

    // 沙盒豁免对含中文的路径匹配不可靠，额外写一份纯 ASCII 路径，扩展优先读它
    static let widgetSnapURLAscii: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Xiaoxinxin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget-snapshot.json")
    }()

    // 快照字段只放「计算输入」，小组件在渲染时刻自己算实时金额，时间线无需高频刷新
    // 小组件沙盒容器内的副本：扩展在沙盒里直接读自己的 Application Support，无需任何豁免
    // 只在容器已被系统创建后写入（手工造容器会缺元数据，导致扩展起不来）
    static var widgetContainerSnapURL: URL? {
        let dataDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.haofan.xiaoxinxin.widget/Data", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dataDir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        // 同上：「小薪薪」是历史目录名，随 2.7 改名保留，不做迁移
        let dir = dataDir.appendingPathComponent("Library/Application Support/小薪薪", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget-snapshot.json")
    }

    // 2.5：小组件同步 Your Days 模块（倒计时 / 纪念日）。
    // 日期一律给时间戳，天数由小组件按当前时刻自己算，App 关一天也不会把「剩余 55 天」写死。
    var daysSnapshot: [String: Any] {
        var out: [String: Any] = [:]
        if let cd = activeCountdown, let p = countdownProgress(cd) {
            var d: [String: Any] = [
                "name": cd.name.isEmpty ? "倒计时" : cd.name,
                "mode": cd.mode,
                "targetKey": p.targetKey,
                "totalDays": p.totalDays,
                "ratio": p.ratio,
                "yearly": cd.isYearly,
                "expired": p.expired,
            ]
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "Asia/Shanghai")
            if let day = f.date(from: p.targetKey) {
                let cal = Calendar.current
                let ts = cal.date(bySettingHour: cd.targetHour ?? 0, minute: cd.targetMinute ?? 0,
                                  second: 0, of: day) ?? day
                d["targetTS"] = ts.timeIntervalSince1970
            }
            out["countdown"] = d
        }
        if let rd = activeRecordDay, let p = activeRecordDayProgress {
            out["record"] = [
                "name": rd.name.isEmpty ? "纪念日" : rd.name,
                "startKey": p.startKey,
                "elapsed": p.elapsedDays,
                "years": p.span.years, "months": p.span.months, "days": p.span.days,
                "ratio": p.ratio,
            ]
        }
        return out
    }

    func writeWidgetSnapshot(reload: Bool = false, alive: Bool = true) {
        var dict: [String: Any] = [
            "baseEarned": baseEarned,
            "clockInAt": clockInAt?.timeIntervalSince1970 ?? 0,
            "working": working,
            "ratePerSec": ratePerSec,
            "ratePerDay": ratePerDay,
            "workedBeforeSession": workedBeforeSession,
            "salary": salary,
            "savedAt": Date.now.timeIntervalSince1970,
            "alive": alive,   // 主 App 是否还活着：false 表示已退出，小组件据此停表
            // 2.0：隐私模式下小组件必须同步收起所有金额，只留百分比
            "privacy": privacyActive,
            "plannedHours": effectiveHours,     // 小组件按工时实时算隐私百分比
            "progressRatio": progressInfo.ratio,
            "progressText": percentText(progressInfo.ratio, dec: 0),
            "metric": progressMetric.rawValue,
            "monthRatio": privacyActive ? monthHoursRatio : monthMoneyRatio,
        ]
        // 2.6.4：小组件按工时算的进度也得剔掉午休。
        // 主程序走 billableSeconds() 扣休息，小组件原来只有墙钟时长，午休那 1 小时照跑，
        // 9:00–18:00 休 60 分在 16:38 会显示 95%（实际约 83%）。这里把本班次休息区间一并下发，
        // 扩展自己按重叠秒数扣（它编不到 Logic.swift，只能拿数据说话）。
        if let s0 = shiftStartTime(now: .now, startStr: workStartText, endStr: workEndText),
           let s1 = shiftEndTime(now: .now, startStr: workStartText, endStr: workEndText) {
            let win = breakWindow(shiftStart: s0, shiftEnd: s1,
                                  breakStartStr: breakStartText,
                                  breakMinutes: Double(Int(breakMinText) ?? 60))
            dict["breakStartTS"] = win.start.timeIntervalSince1970
            dict["breakEndTS"] = win.end.timeIntervalSince1970
        } else {
            dict["breakStartTS"] = 0
            dict["breakEndTS"] = 0
        }
        // 2.5：主题配色 + Your Days，小组件跟着 App 一起变色、一起显示日子
        dict["theme"] = [
            "id": themeId,
            "bg": themeBg,
            "text": themeText,
            "accent": themeAccent,
            "alpha": themeAlpha,
        ]
        dict["days"] = daysSnapshot
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            WidgetBridge.shared.update(data)
            try? data.write(to: Self.widgetSnapURL, options: .atomic)
            try? data.write(to: Self.widgetSnapURLAscii, options: .atomic)
            if let c = Self.widgetContainerSnapURL { try? data.write(to: c, options: .atomic) }
        }
        // 偏好域镜像：沙盒扩展读文件可能被拦，读别的 App 的偏好则通常允许，作为独立通道
        ud.set(baseEarned, forKey: "wBaseEarned")
        ud.set(clockInAt?.timeIntervalSince1970 ?? 0, forKey: "wClockInAt")
        ud.set(working, forKey: "wWorking")
        ud.set(ratePerSec, forKey: "wRatePerSec")
        ud.set(ratePerDay, forKey: "wRatePerDay")
        ud.set(workedBeforeSession, forKey: "wWorkedBefore")
        ud.set(salary, forKey: "wSalary")
        ud.set(Date.now.timeIntervalSince1970, forKey: "wSavedAt")
        ud.set(alive, forKey: "wAlive")
        ud.set(privacyActive, forKey: "wPrivacy")
        ud.set(effectiveHours, forKey: "wPlannedHours")
        ud.set(progressInfo.ratio, forKey: "wProgressRatio")
        // 2.5：主题与 Days 用 JSON 字符串镜像，避免为每个字段开一个偏好键
        if let t = try? JSONSerialization.data(withJSONObject: dict["theme"] ?? [:]),
           let s = String(data: t, encoding: .utf8) { ud.set(s, forKey: "wThemeJSON") }
        if let d = try? JSONSerialization.data(withJSONObject: dict["days"] ?? [:]),
           let s = String(data: d, encoding: .utf8) { ud.set(s, forKey: "wDaysJSON") }
        ud.set(dict["monthRatio"] as? Double ?? 0, forKey: "wMonthRatio")
        // 2.6.4：偏好域镜像也要带午休区间，否则走 PR 通道时又会退回墙钟口径
        ud.set(dict["breakStartTS"] as? Double ?? 0, forKey: "wBreakStart")
        ud.set(dict["breakEndTS"] as? Double ?? 0, forKey: "wBreakEnd")
        ud.synchronize()
        if reload {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    var salary: Double { Double(salaryText) ?? 0 }

    // 2.0：工作日规则改为「按月实时算」，不再在启动时冻结一次（修跨月不重算的 bug）
    var workdayRule: WorkdayRule {
        WorkdayRule(weekdays: customWeekdays,
                    useLegalHolidays: useLegalHolidays,
                    manualDays: Int(workDaysText))
    }
    var autoDays: Int {
        monthWorkDays(Date.now, rule: WorkdayRule(weekdays: customWeekdays,
                                                  useLegalHolidays: useLegalHolidays,
                                                  manualDays: nil))
    }
    var workDays: Int { monthWorkDays(Date.now, rule: workdayRule) }
    // 只看是否手填，不再用「手填值恰好等于自动值」判断（1.x 会误判成自动）
    var isAutoDays: Bool { workDaysText.trimmingCharacters(in: .whitespaces).isEmpty }
    var effectiveWorkDays: Int { max(1, workDays) }   // 一个都不勾时兜底，避免费率除零
    var effectiveHours: Double {
        effectiveWorkHours(startStr: workStartText, endStr: workEndText,
                           breakMinutes: Double(Int(breakMinText) ?? 60))
    }
    var ratePerSec: Double { salary / Double(effectiveWorkDays) / effectiveHours / 3600 }
    var ratePerHour: Double { salary / Double(effectiveWorkDays) / effectiveHours }
    var ratePerDay: Double { salary / Double(effectiveWorkDays) }

    // MARK: - 2.0 统一进度数据源
    var activeCountdown: CountdownItem? {
        countdowns.first { $0.id == activeCountdownId } ?? countdowns.first
    }
    var activeCountdownProgress: CountdownProgress? {
        guard let item = activeCountdown else { return nil }
        return countdownProgress(item)
    }
    var activeRecordDay: RecordDayItem? {
        recordDays.first { $0.id == activeRecordDayId } ?? recordDays.first
    }
    var activeRecordDayProgress: RecordDayProgress? {
        guard let item = activeRecordDay else { return nil }
        return recordDayProgress(item)
    }
    var privacyActive: Bool {
        privacyEnabled && !(privacyUnlockedUntil.map { $0 > Date.now } ?? false)
    }
    var todayHoursRatio: Double {
        hoursProgress(workedSeconds: workedSeconds, plannedHours: effectiveHours)
    }
    var monthHoursRatio: Double {
        hoursProgress(workedSeconds: monthWorkedSeconds,
                      plannedHours: Double(effectiveWorkDays) * effectiveHours)
    }
    var todayMoneyRatio: Double { ratePerDay > 0 ? displayEarned / ratePerDay : 0 }
    var monthMoneyRatio: Double { salary > 0 ? monthEarned / salary : 0 }

    /// 旧接口：条内填充比例（封顶 1），供迷你条 / 状态栏 / 小组件沿用
    var progress: Double { clampedProgress(progressInfo.ratio) }
    var progressRatio: Double { progressInfo.ratio }

    /// 薪酬口径：首页薪酬卡 / 薪酬二级页 / 迷你条 / 状态栏 / 小组件共用
    var progressInfo: ProgressInfo { progressInfo(mode: .salary) }
    /// 倒计时口径：首页倒计时卡 / 倒计时二级页共用，绝不被隐私分支覆盖
    var countdownInfo: ProgressInfo { progressInfo(mode: .countdown) }
    /// 纪念日口径：首页纪念日卡 / 纪念日二级页共用
    var recordDayInfo: ProgressInfo { progressInfo(mode: .recordDay) }

    /// 2.1 核心：按模式分别出一份进度，两套数据互不串线。
    /// 修复的 bug：旧版 `if privacyActive` 把整个 `switch progressMetric` 盖掉，
    /// 隐私 + 倒计时时大字是薪酬口径、芯片却是倒计时口径，两半数据对不上。
    func progressInfo(mode: DetailMode) -> ProgressInfo {
        var info = ProgressInfo(privacy: mode == .salary ? privacyActive : false,
                                metric: progressMetric, mode: mode)
        let money = "¥" + fmt(floor(displayEarned * 100) / 100)
        let cents = String(format: "%02d", Int(floor(displayEarned * 10000)) % 100)
        let todayPct = percentText(todayHoursRatio)

        switch mode {
        case .salary:
            if privacyActive {
                // 隐私模式：明确的工资数字一律换成百分比进度；8h=100%，加班 4h=+50% → 150%
                info.ratio = todayHoursRatio
                info.isMoney = false
                info.leading = todayPct
                info.trailing = ""
                info.caption = "今日进度 · 隐私模式"
                info.footer = "今日 \(todayPct) · 本月 \(percentText(monthHoursRatio))"
                    + "（加班计入超出 100% 的部分）"
            } else {
                switch progressMetric {
                case .monthSalary:
                    info.ratio = monthMoneyRatio
                    info.leading = money; info.trailing = cents
                    info.caption = "今日已到账 · 本月累计 ¥\(fmt(monthEarned))"
                    info.footer = "本月进度 \(percentText(info.ratio)) · 距月薪还差 ¥\(fmt(max(0, salary - monthEarned)))"
                case .todayHours:
                    info.ratio = todayHoursRatio
                    info.isMoney = false
                    info.leading = percentText(info.ratio); info.trailing = ""
                    info.caption = "今日工时进度"
                    info.footer = "今日已到账 ¥\(fmt(displayEarned)) · 计划 \(String(format: "%.1f", effectiveHours)) 小时"
                        + (info.ratio > 1 ? " · 加班部分已超出 100%" : "")
                case .monthHours:
                    info.ratio = monthHoursRatio
                    info.isMoney = false
                    info.leading = percentText(info.ratio); info.trailing = ""
                    info.caption = "本月工时进度"
                    info.footer = "本月累计 ¥\(fmt(monthEarned)) · 应出勤 \(effectiveWorkDays) 天 × \(String(format: "%.1f", effectiveHours)) 小时"
                case .todaySalary, .countdown:
                    // .countdown 是旧存档遗留值，拆页后一律回落为今日工资
                    info.ratio = todayMoneyRatio
                    info.leading = money; info.trailing = cents
                    info.caption = overtimeNow ? "加班计费中 · 今日已到账"
                        : (working ? "正在进账 · 今日已到账" : "今日已到账")
                    info.footer = salary <= 0 ? "在 设置中填写月薪后开始累计进度"
                        : (displayEarned >= ratePerDay && ratePerDay > 0
                           ? "今日进度 \(percentText(info.ratio)) · 已超出全天 ¥\(fmt(displayEarned - ratePerDay))"
                           : "今日进度 \(percentText(info.ratio)) · 距离全天还差 ¥\(fmt(max(0, ratePerDay - displayEarned)))")
                }
            }

        case .countdown:
            // 倒计时页与隐私模式无关：本身不含任何工资金额，也不显示薪酬进度
            info.isMoney = false
            if let item = activeCountdown, let p = countdownProgress(item) {
                info.ratio = p.ratio
                if item.mode == "percent" {
                    info.leading = percentText(p.ratio); info.trailing = ""
                } else {
                    info.leading = "\(p.daysLeft)"; info.trailing = " 天"
                }
                let targetText = item.hasCustomTime ? "\(p.targetKey) \(item.targetTimeText)" : p.targetKey
                let startText = item.startKeyText ?? "自动"
                info.caption = p.expired ? "\(item.name) · 已到期" : "距离 \(item.name) · \(targetText)"
                info.footer = p.expired
                    ? "倒计时已结束 · 累计 \(p.elapsedDays) 天 / 总跨度 \(p.totalDays) 天"
                    : String(format: "还有 %d 天 · 已走 %.1f%% · 起点 %@",
                             p.daysLeft, p.ratio * 100, startText)
            } else {
                info.ratio = 0
                info.leading = "--"; info.trailing = ""
                info.caption = "还没有倒计时"
                info.footer = "点卡片进本页 → 事件管理 → 新增，建一个即可"
            }

        case .recordDay:
            // 纪念日同样与隐私模式、薪酬数据完全无关；2.4 起主口径是「累计时长」，不再是里程碑进度
            info.isMoney = false
            if let item = activeRecordDay, let p = recordDayProgress(item) {
                info.ratio = 0
                info.leading = "\(p.elapsedDays)"; info.trailing = " 天"
                info.caption = p.started ? "\(item.name) · 已相伴" : "\(item.name) · 尚未开始"
                info.footer = p.started
                    ? "从 \(p.startKey) 起 · 累计 \(p.span.shortText)"
                    : "起始日 \(p.startKey) 还没到，到那天开始累计"
            } else {
                info.ratio = 0
                info.leading = "--"; info.trailing = ""
                info.caption = "还没有纪念日"
                info.footer = "点卡片进本页 → 事件管理 → 新增，建一个即可"
            }
        }

        info.fill = clampedProgress(info.ratio)
        info.overflow = min(1, max(0, info.ratio - 1))
        return info
    }

    /// 隐私模式下所有金额露出点统一走这里
    func displayMoney(_ v: Double, dec: Int = 2, prefix: String = "¥") -> String {
        privacyActive ? "--" : prefix + fmt(v, dec)
    }
    // 今日已工作秒数 = 已结束段 + 正在进行的计费段（重启后也不会漏算）
    // 口径：墙钟时长去掉落在午休里的部分，否则分母扣了休息、分子没扣，下班会跑到 112%
    var workedSeconds: Double {
        guard working, let start = clockInAt else { return workedBeforeSession }
        return workedBeforeSession + billableElapsed(from: start)
    }

    /// [from, now] 内真正计入工作的秒数（剔除午休时段）
    func billableElapsed(from start: Date, to now: Date = .now) -> Double {
        billableSeconds(from: start, to: now,
                        startStr: workStartText, endStr: workEndText,
                        breakStartStr: breakStartText,
                        breakMinutes: Double(Int(breakMinText) ?? 60))
    }
    var workedMinutes: Int { Int(workedSeconds / 60) }
    var totalWorkedHours: Double { workedSeconds / 3600 }

    // 当前班次的计划下班时刻（跨零点班次自动落到次日）
    var scheduledEnd: Date? {
        shiftEndTime(now: Date.now, startStr: workStartText, endStr: workEndText)
    }
    // 当前班次的计划上班时刻（跨零点班次的凌晨时段落到前一天）
    var scheduledStart: Date? {
        shiftStartTime(now: Date.now, startStr: workStartText, endStr: workEndText)
    }
    // 加班中：手动开的加班段，或当前计费段是在计划下班之后打卡的
    var overtimeNow: Bool {
        if manualOvertime { return working }
        guard working, let s = clockInAt, let end = scheduledEnd else { return false }
        return s >= end
    }
    var overtimeMinutes: Int { Int(overtimeSeconds / 60) }

    // 本月累计进账 = 今日实时 + 历史流水（日切时落账）
    var monthEarned: Double {
        _ = dayLogRevision   // 供 SwiftUI 感知流水增删
        let today = dateKey(Date.now)
        var sum = displayEarned
        for (k, v) in dayLog where k.hasPrefix(today.prefix(7)) && k != today { sum += v["earned"] ?? 0 }
        return sum
    }
    // 本月累计加班秒数 = 今日加班 + 历史流水
    var monthOTSeconds: Double {
        _ = dayLogRevision
        let today = dateKey(Date.now)
        var sum = overtimeSeconds
        for (k, v) in dayLog where k.hasPrefix(today.prefix(7)) && k != today { sum += v["ot"] ?? 0 }
        return sum
    }
    // 2.0 本月工时进度：2.0 起流水里直接记工时；旧数据按金额反推，费率变了也不丢口径
    var monthWorkedSeconds: Double {
        _ = dayLogRevision
        let today = dateKey(Date.now)
        let rate = ratePerSec > 0 ? ratePerSec : 1
        var sum = workedSeconds
        for (k, v) in dayLog where k.hasPrefix(today.prefix(7)) && k != today {
            sum += v["worked"] ?? ((v["earned"] ?? 0) / rate)
        }
        return sum
    }

    init(ud: UserDefaults = .standard) {
        self.ud = ud
        salaryText = ud.string(forKey: "salary") ?? ""
        workDaysText = ud.string(forKey: "workDaysText") ?? ""
        workStartText = ud.string(forKey: "workStart") ?? "09:00"
        workEndText = ud.string(forKey: "workEnd") ?? "18:00"
        breakMinText = ud.string(forKey: "breakMin") ?? "60"
        breakStartText = ud.string(forKey: "breakStart") ?? "12:00"

        // 2.0 配置读取（旧版本没有这些键 → 全部给兼容默认，升级不丢原有行为）
        customWeekdays = Set((ud.array(forKey: "customWeekdays") as? [Int]) ?? [2, 3, 4, 5, 6])
        useLegalHolidays = ud.object(forKey: "useLegalHolidays") == nil ? true : ud.bool(forKey: "useLegalHolidays")
        hiddenButtons = Set(ud.stringArray(forKey: "hiddenButtons") ?? [])
        hiddenCountdownChips = Set(ud.stringArray(forKey: "hiddenCountdownChips") ?? [])
        hiddenMoneyChips = Set(ud.stringArray(forKey: "hiddenMoneyChips") ?? [])
        hiddenRecordDayChips = Set(ud.stringArray(forKey: "hiddenRecordDayChips") ?? [])
        // 2.2 首页至少保留一张模块卡：旧存档 / 手工写坏数据时兜回来（init 里只用局部变量，别读 self）
        let savedHiddenCards = Set(ud.stringArray(forKey: "hiddenHomeCards") ?? [])
        hiddenHomeCards = savedHiddenCards.count >= HomeCard.allCases.count
            ? Set(HomeCard.allCases.dropFirst().map { $0.rawValue }) : savedHiddenCards
        // 2.2 主题：主题 id + 四路颜色 / 透明度分别落盘，选预设后仍可继续微调
        // 2.3 默认主题换成「白 + 天蓝」（比原先的 Liquid Glass 更中性）：只迁移没动过色卡的旧存档
        var savedThemeId = ud.string(forKey: "themeId") ?? AppTheme.sky.rawValue
        if AppTheme(rawValue: savedThemeId) == nil { savedThemeId = AppTheme.sky.rawValue }
        func nearPreset(_ key: String, _ target: [Double]) -> Bool {
            guard let a = ud.array(forKey: key) as? [NSNumber], a.count >= 3 else { return true }
            return zip(a.prefix(3).map { $0.doubleValue }, target).allSatisfy { abs($0 - $1) < 0.03 }
        }
        if ud.bool(forKey: "themeDefaultSky23") == false {
            ud.set(true, forKey: "themeDefaultSky23")
            if savedThemeId != AppTheme.sky.rawValue, let cur = AppTheme(rawValue: savedThemeId),
               nearPreset("themeBg", cur.preset.bg),
               nearPreset("themeText", cur.preset.text),
               nearPreset("themeAccent", cur.preset.accent),
               ud.object(forKey: "themeAlpha") == nil
                   || abs(ud.double(forKey: "themeAlpha") - cur.preset.alpha) < 0.02 {
                savedThemeId = AppTheme.sky.rawValue
                ud.set(savedThemeId, forKey: "themeId")
                ud.removeObject(forKey: "themeBg")
                ud.removeObject(forKey: "themeText")
                ud.removeObject(forKey: "themeAccent")
                ud.removeObject(forKey: "themeAlpha")
            }
        }
        themeId = savedThemeId
        let preset = (AppTheme(rawValue: savedThemeId) ?? .sky).preset
        func doubles(_ key: String, _ fallback: [Double]) -> [Double] {
            guard let a = ud.array(forKey: key) as? [NSNumber], a.count >= 3 else { return fallback }
            return Array(a.prefix(3)).map { $0.doubleValue }
        }
        themeBg = doubles("themeBg", preset.bg)
        themeText = doubles("themeText", preset.text)
        themeAccent = doubles("themeAccent", preset.accent)
        themeAlpha = ud.object(forKey: "themeAlpha") == nil ? preset.alpha : ud.double(forKey: "themeAlpha")
        homeCardGuard = nil
        manualOvertime = ud.bool(forKey: "manualOvertime")
        // 2.1 迁移：旧存档把「倒计时」当成一种薪酬统计口径，拆页后回落为今日工资
        let savedMetric = ProgressMetric(rawValue: ud.string(forKey: "progressMetric") ?? "") ?? .todaySalary
        progressMetric = savedMetric == .countdown ? .todaySalary : savedMetric
        if let data = ud.data(forKey: "countdowns"),
           let list = try? JSONDecoder().decode([CountdownItem].self, from: data) {
            countdowns = list
        } else {
            countdowns = []
        }
        activeCountdownId = ud.string(forKey: "activeCountdownId") ?? ""
        if let data = ud.data(forKey: "recordDays"),
           let list = try? JSONDecoder().decode([RecordDayItem].self, from: data) {
            recordDays = list
        } else {
            recordDays = []
        }
        activeRecordDayId = ud.string(forKey: "activeRecordDayId") ?? ""
        privacyEnabled = ud.bool(forKey: "privacyEnabled")
        pinHash = ud.string(forKey: "pinHash") ?? ""
        pinSalt = ud.string(forKey: "pinSalt") ?? ""
        showOnboarding = ud.object(forKey: "v2Onboarded") == nil
        privacyUnlockedUntil = nil

        closeBehavior = ud.string(forKey: "closeBehavior") ?? "hide"
        barSymbol = ud.string(forKey: "barSymbol") ?? ""
        // 2.3 菜单栏显示项：只保留合法 id，空集合回落默认
        if let arr = ud.array(forKey: "statusBarKinds") as? [String] {
            let valid = arr.filter { StatusBarKind(rawValue: $0) != nil }
            statusBarKinds = valid.isEmpty ? [StatusBarKind.moneyToday.rawValue] : Set(valid)
        }
        statusBarShowData = ud.object(forKey: "statusBarShowData") == nil
            ? true : ud.bool(forKey: "statusBarShowData")
        statusBarRotate = ud.bool(forKey: "statusBarRotate")
        statusBarRotateSeconds = ud.object(forKey: "statusBarRotateSecs") == nil
            ? 5 : ud.double(forKey: "statusBarRotateSecs")
        statusBarShowBar = ud.object(forKey: "statusBarShowBar") == nil
            ? false : ud.bool(forKey: "statusBarShowBar")
        baseEarned = ud.double(forKey: "baseEarned")
        displayEarned = baseEarned
        lastGainMark = baseEarned
        working = ud.bool(forKey: "working")
        if ud.object(forKey: "workedBeforeSession") != nil {
            workedBeforeSession = ud.double(forKey: "workedBeforeSession")
        } else {
            workedBeforeSession = ud.double(forKey: "workedSeconds")   // 旧字段迁移
        }
        if let saved = ud.object(forKey: "clockInAt") as? Date { clockInAt = saved }
        autoOutEnabled = ud.object(forKey: "autoOut") == nil ? true : ud.bool(forKey: "autoOut")
        autoInEnabled = ud.object(forKey: "autoIn") == nil ? true : ud.bool(forKey: "autoIn")
        launchAtLogin = LaunchAtLogin.isEnabled
        // 截图/自检专用：裸二进制拿不到 SMAppService 真实状态，按环境变量假设已开启（不影响生产）
        if ProcessInfo.processInfo.environment["XINXIN_SHOT_FORCE_LOGIN"] == "1" { launchAtLogin = true }
        autoInKey = ud.string(forKey: "autoInKey") ?? ""
        overtimeSeconds = ud.double(forKey: "overtimeSeconds")
        if let raw = ud.dictionary(forKey: "dayLog") as? [String: [String: NSNumber]] {
            dayLog = raw.mapValues { ["earned": $0["earned"]?.doubleValue ?? 0, "ot": $0["ot"]?.doubleValue ?? 0] }
        }
        dayKey = ud.string(forKey: "dayKey") ?? ""
        // 跨天重置：上次使用不是今天 → 清零昨日累计；若打卡计费中则从现在重新起算新的一天
        let today = dateKey(Date.now)
        if dayKey != today && (baseEarned > 0 || workedBeforeSession > 0 || working) {
            flushDayLog(dayKey)              // 昨日账目落流水，供本月累计
            baseEarned = 0
            workedBeforeSession = 0
            overtimeSeconds = 0
            displayEarned = 0
            lastGainMark = 0
            if working { clockInAt = Date.now }
        }
        dayKey = today
        if working && clockInAt != nil {
            logText = "\(timeStr(clockInAt!)) 打卡上班，继续计费中"
        }
        loadIcon()
        syncThemeGlobals()                  // 2.2：主题色写进全局调色板，首帧就按用户配色渲染
        WidgetBridge.shared.start()          // 本机回环数据桥：沙盒扩展唯一稳定的取数通道
        writeWidgetSnapshot(reload: true)   // 启动即落快照并叫醒小组件
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }

        // 快照心跳必须独立于界面：窗口收起 / 切到后台时，界面计时器可能被系统降频甚至挂起，
        // 小组件就会读到过期快照。这里用独立 GCD 定时器 + 阻止 App Nap。
        napToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "保持打卡计时与小组件快照准确")
        let beat = DispatchSource.makeTimerSource(queue: .main)
        beat.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(2))
        beat.setEventHandler { [weak self] in
            guard let self else { return }
            self.snapBeat += 1
            // 快照每 15 秒落一次（供扩展的停表冻结逻辑），但强刷时间线改为每小时一次：
            // WidgetKit 的刷新预算每天只有约 40-50 次，旧版 5 分钟一刷（288 次/天）把额度
            // 烧穿后，时间线过期就续不上，实例被系统打回灰色占位图且不再自愈。
            // 打卡/改薪/换主题等关键事件各自已有 reload: true，这里只做低频兜底。
            self.writeWidgetSnapshot(reload: self.snapBeat % 240 == 0)   // 每 60 分钟兜底强刷
        }
        beat.resume()
        snapTimer = beat

        // 退出前写一份 alive=false，让小组件立刻停表，而不是按旧 clockInAt 继续虚增
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.writeWidgetSnapshot(reload: true, alive: false)
        }
    }

    func loadIcon() {
        if let data = ud.data(forKey: "customIconData"), let img = NSImage(data: data) {
            iconImage = img
        } else if let url = Bundle.main.url(forResource: "coin", withExtension: "png"),
                  let img = NSImage(contentsOf: url) {
            iconImage = img
        }
    }

    func setCustomIcon(_ data: Data?) {
        if let data { ud.set(data, forKey: "customIconData") } else { ud.removeObject(forKey: "customIconData") }
        loadIcon()
    }

    // MARK: - 2.2 主题与调色
    func syncThemeGlobals() {
        AppPalette.apply(bg: themeBg, text: themeText, accent: themeAccent,
                         alpha: themeAlpha, glass: currentTheme.glass,
                         highlights: currentTheme.swatches)
        onAppearanceSync?(AppPalette.isDark)   // 窗口外观跟主题，不跟系统深色模式
    }
    private func persistTheme() {
        ud.set(themeId, forKey: "themeId")
        ud.set(themeBg, forKey: "themeBg")
        ud.set(themeText, forKey: "themeText")
        ud.set(themeAccent, forKey: "themeAccent")
        ud.set(themeAlpha, forKey: "themeAlpha")
        syncThemeGlobals()
    }
    /// 选预设 = 填入一套默认色；之后色卡 / 透明度仍可继续改
    func selectTheme(_ t: AppTheme) {
        themeId = t.rawValue
        let p = t.preset
        themeBg = p.bg; themeText = p.text; themeAccent = p.accent; themeAlpha = p.alpha
        persistTheme()
    }
    func resetTheme() { selectTheme(currentTheme) }
    func setThemeAlpha(_ v: Double) { themeAlpha = min(1, max(0.15, v)); persistTheme() }
    /// 0 背景 / 1 文本 / 2 重点开关色：ColorPicker 用的无极调节绑定
    func themeColorBinding(_ which: Int) -> Binding<Color> {
        Binding(get: {
            switch which {
            case 0: return AppPalette.color(self.themeBg)
            case 1: return AppPalette.color(self.themeText)
            default: return AppPalette.color(self.themeAccent)
            }
        }, set: { c in
            let v = AppPalette.rgb(c)
            switch which {
            case 0: self.themeBg = v
            case 1: self.themeText = v
            default: self.themeAccent = v
            }
            self.persistTheme()
        })
    }
    /// 老功能保留：把自定义图标主色写进「重点色」，与主题系统统一
    func useIconAccent() {
        guard let img = iconImage, let (a, _) = extractPalette(img) else { return }
        themeAccent = AppPalette.rgb(Color(nsColor: a))
        persistTheme()
    }

    func tick() {
        checkDayRollover()
        // 隐私模式临时查看真实数字：到点自动收回
        if let until = privacyUnlockedUntil, until <= Date.now {
            privacyUnlockedUntil = nil
            writeWidgetSnapshot(reload: true)
        }
        autoClockInIfNeeded()
        autoClockOutIfNeeded()
        guard working, let start = clockInAt else { return }
        displayEarned = baseEarned + billableElapsed(from: start) * ratePerSec
        if displayEarned - lastGainMark >= 0.01 {
            lastGainMark = displayEarned
            spawnGain()
        }
        tickCount += 1
        if tickCount % 900 == 0 { writeWidgetSnapshot() }   // 30fps 计时 → 约每 30 秒落一次快照
        // 计费中每小时兜底强刷一次（时间线已预生成 75 分钟条目，见 Widget/SalaryWidget.swift）；
        // 每 5 分钟强刷会烧穿 WidgetKit 日刷新预算，导致组件过期后被打回占位图（2.6.3 修）
        if tickCount % 108000 == 0 { writeWidgetSnapshot(reload: true) }
    }

    private func spawnGain() {
        let g = Gain(xOffset: CGFloat.random(in: -90...90))
        withAnimation(.easeOut(duration: 0.15)) { gains.append(g) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeIn(duration: 0.2)) { self?.gains.removeAll { $0.id == g.id } }
        }
    }

    func clockIn(at when: Date = .now) {
        clockInAt = when
        lastGainMark = baseEarned
        working = true
        // 手动打卡同样占掉本班次的自动打坑位：手动打过又手动下班后，不会到点又被自动打开
        if let s = shiftStartTime(now: when, startStr: workStartText, endStr: workEndText) {
            autoInKey = shiftKey(s)
            ud.set(autoInKey, forKey: "autoInKey")
        }
        if overtimeNow {
            logText = "\(timeStr(clockInAt!)) 加班打卡，已过下班时间，按原费率继续计费"
        } else {
            logText = "\(timeStr(clockInAt!)) 打卡上班，金币开始滚动"
        }
        persist()
    }

    // 2.2：手动加班段——先结算正在跑的正常段，再从当前时刻开一段独立计费
    func startOvertime() {
        guard salary > 0 else { return }
        let now = Date.now
        if working, let start = clockInAt {
            let billable = billableElapsed(from: start, to: now)
            baseEarned += billable * ratePerSec
            workedBeforeSession += billable
            displayEarned = baseEarned
            clockInAt = now
            lastGainMark = baseEarned
        } else {
            clockIn(at: now)
        }
        manualOvertime = true
        ud.set(true, forKey: "manualOvertime")
        logText = privacyActive ? "\(timeStr(now)) 开始加班，进度已隐藏"
                                : "\(timeStr(now)) 开始加班，本段单独计入加班时长"
        persist()
    }

    func endOvertime() { if working { clockOut() } }

    func clockOut(auto: Bool = false) {
        guard working, let start = clockInAt else { return }
        let elapsed = max(0, Date.now.timeIntervalSince(start))     // 墙钟：加班时长按实际待在公司的时间算
        let billable = billableElapsed(from: start)                  // 计费：扣掉午休
        baseEarned += billable * ratePerSec
        workedBeforeSession += billable
        // 手动加班段 / 本段开始于计划下班之后 → 计入加班时长
        var wasOvertime = manualOvertime
        if !wasOvertime, let end = scheduledEnd, start >= end { wasOvertime = true }
        if wasOvertime { overtimeSeconds += elapsed }
        displayEarned = baseEarned
        working = false
        clockInAt = nil
        manualOvertime = false
        ud.set(false, forKey: "manualOvertime")
        if privacyActive {
            // 隐私模式：日志行也不能漏出金额 / 加班时长
            logText = auto ? "\(timeStr(Date.now)) 已到下班时间，自动打卡下班"
                           : "\(timeStr(Date.now)) 下班打卡，进度已更新"
        } else if auto {
            logText = "\(timeStr(Date.now)) 已到下班时间，自动打卡下班，今日共到账 ¥\(fmt(baseEarned))"
        } else {
            logText = "\(timeStr(Date.now)) 下班打卡，今日共到账 ¥\(fmt(baseEarned))"
                + (overtimeMinutes > 0 ? "（含加班 \(overtimeMinutes) 分钟）" : "")
        }
        persist()
    }

    // 昨日账目落流水；只保留最近两个月，防止无限增长
    private func flushDayLog(_ key: String) {
        guard baseEarned > 0 || overtimeSeconds > 0 else { return }
        dayLog[key] = ["earned": baseEarned, "ot": overtimeSeconds,
                       "worked": workedBeforeSession]   // 2.0 月度工时进度用
        let nowPrefix = String(dateKey(Date.now).prefix(7))
        let prevPrefix = String(dateKey(Calendar.current.date(byAdding: .month, value: -1, to: Date.now)!).prefix(7))
        dayLog = dayLog.filter { $0.key.hasPrefix(nowPrefix) || $0.key.hasPrefix(prevPrefix) }
        dayLogRevision += 1
    }

    // —— 流水明细：设置页查询 / 删除 / 手动添加 ——

    var dayLogTotal: Int {
        _ = dayLogRevision
        return dayLog.count
    }

    // 按日期闭区间查询（yyyy-MM-dd 字符串序即日期序；空串=不限制），降序返回；今日实时数据不在流水
    func dayLogRows(start: String, end: String) -> [DayLogRow] {
        _ = dayLogRevision
        return dayLog
            .filter { (start.isEmpty || $0.key >= start) && (end.isEmpty || $0.key <= end) }
            .filter { $0.key != dateKey(Date.now) }
            .sorted { $0.key > $1.key }
            .map { DayLogRow(key: $0.key, earned: $0.value["earned"] ?? 0, otSeconds: $0.value["ot"] ?? 0) }
    }

    @discardableResult
    func removeDayLog(_ key: String) -> Bool {
        guard dayLog.removeValue(forKey: key) != nil else { return false }
        dayLogRevision += 1
        persist()
        return true
    }

    // 手动新增/覆盖某天流水；返回 nil=成功，否则为错误提示
    func insertDayLog(key: String, earned: Double, otMinutes: Double) -> String? {
        guard isValidDayKey(key) else { return "日期格式应为 yyyy-MM-dd" }
        if key == dateKey(Date.now) { return "今日金额以实时打卡为准，请选其他日期" }
        guard earned >= 0, earned < 1_000_000 else { return "进账金额需在 0–999999 之间" }
        guard otMinutes >= 0, otMinutes < 1440 else { return "加班分钟需在 0–1439 之间" }
        dayLog[key] = ["earned": earned, "ot": otMinutes * 60]
        dayLogRevision += 1
        persist()
        return nil
    }

    // 跨天自动重置：日期变化时清零今日累计与加班；仍在计费则从当前时刻重新起算新的一天
    private func checkDayRollover() {
        let today = dateKey(Date.now)
        guard today != dayKey else { return }
        let wasWorking = working
        flushDayLog(dayKey)                  // 昨日账目落流水，供本月累计
        baseEarned = 0
        workedBeforeSession = 0
        overtimeSeconds = 0
        dayKey = today
        displayEarned = 0
        lastGainMark = 0
        if wasWorking { clockInAt = Date.now }
        logText = wasWorking ? "跨入新的一天，今日累计已重置，继续计费"
                             : "新的一天，今日累计已重置"
        persist()
        writeWidgetSnapshot(reload: true)   // 跨天必须立刻叫醒小组件，否则最多 1 小时显示昨天的累计
    }

    // 到点自动下班：本段计费开始于计划下班之前、现在已过下班时刻 → 自动打卡下班
    private func autoClockOutIfNeeded() {
        guard autoOutEnabled, working, let s = clockInAt, let end = scheduledEnd else { return }
        if s < end && Date.now >= end { clockOut(auto: true) }
    }

    // 到点自动上班：进入班次窗口且本班次还没自动打过卡 → 自动打卡上班。
    // 判据比自动下班严格一层——必须在 [计划上班, 计划下班) 之内，下班之后不会被自动打开。
    private func autoClockInIfNeeded() {
        guard autoInEnabled, !working,
              let start = scheduledStart, let end = scheduledEnd else { return }
        let now = Date.now
        guard now >= start, now < end else { return }        // 未到上班时间 / 已过下班时间
        // 修复：非工作日（自定义周几 / 叠加的法定节假日）不再自动打卡。
        // 判「班次开始日」而不是 Date.now——跨零点夜班的凌晨属于前一天的班，按前一天规则算。
        // 工作日规则此前只用于算每月天数与日薪，自动打卡一直没引用，导致周六照打。
        guard isWorkDate(start, rule: workdayRule) else { return }
        let key = shiftKey(start)
        guard autoInKey != key else { return }               // 本班次已自动打过（含跨零点前后半夜）
        autoInKey = key
        ud.set(autoInKey, forKey: "autoInKey")
        // 刚好到点（2 分钟内）从上班时刻起算；开机晚了则从当前时刻起算，不白送工时
        let lateBy = now.timeIntervalSince(start)
        let origin = lateBy <= 120 ? start : now
        clockIn(at: origin)
        logText = lateBy <= 120
            ? "\(timeStr(origin)) 已到上班时间，自动打卡上班"
            : "\(timeStr(origin)) 自动打卡上班（已过上班时间，从中途起算）"
    }

    // —— 以下仅供 --sim-autoout 自检使用，不影响正常功能 ——
    func debugStartSession(at date: Date) {
        clockInAt = date
        working = true
        lastGainMark = baseEarned
    }

    func debugSimulateNewDay() {
        dayKey = "2000-01-01"
        checkDayRollover()
    }

    func debugSeedDayLog(key: String, earned: Double, ot: Double) {
        dayLog[key] = ["earned": earned, "ot": ot]
    }

    func onSalaryChanged() {
        // 旧月薪要先从存盘读出来：salary 已经跟着输入框变了，
        // 结算当前段必须用旧费率。旧版这里直接 baseEarned = 0 / workedBeforeSession = 0，
        // 改一次月薪就把今天已经赚到的钱和工时全抹掉了。
        let oldSalary = Double(ud.string(forKey: "salary") ?? "") ?? salary
        if working, let start = clockInAt {
            let billable = billableElapsed(from: start)
            let oldRate = oldSalary / Double(effectiveWorkDays) / effectiveHours / 3600
            baseEarned += billable * oldRate
            workedBeforeSession += billable
            displayEarned = baseEarned
            lastGainMark = baseEarned
            clockInAt = Date.now
            logText = "↻ 月薪已更新，此前工时已按旧费率结算"
        }
        ud.set(salaryText, forKey: "salary")
        persist()
    }

    func onWorkDaysChanged() {
        ud.set(workDaysText, forKey: "workDaysText")
        rebaseCurrentSession("工作日天数已更新")
    }

    // 费率相关的设置变化：先把已跑的段结掉，再从这一刻按新费率起算
    private func rebaseCurrentSession(_ what: String) {
        if working, let start = clockInAt {
            let billable = billableElapsed(from: start)
            baseEarned += billable * ratePerSec
            workedBeforeSession += billable
            displayEarned = baseEarned
            lastGainMark = baseEarned
            clockInAt = Date.now
            logText = "↻ \(what)，已跑工时会先结算，从现在按新费率计费"
        }
        persist()
    }

    func onScheduleChanged() {
        // 工时变化会改变费率：先把已跑的这段按「旧配置」结掉，再从这一刻按新费率起算。
        // 旧版直接 clockInAt = now，既不结算也不累计，改一次工时就把已经赚到的时长抹掉了。
        if working, let start = clockInAt, let p = lastSchedule {
            let oldHours = effectiveWorkHours(startStr: p.start, endStr: p.end, breakMinutes: p.breakMin)
            let oldRate = oldHours > 0 ? ratePerDay / oldHours / 3600 : ratePerSec
            let billable = billableSeconds(from: start, to: .now,
                                           startStr: p.start, endStr: p.end,
                                           breakStartStr: p.breakStart, breakMinutes: p.breakMin)
            baseEarned += billable * oldRate
            workedBeforeSession += billable
            displayEarned = baseEarned
            clockInAt = Date.now
            lastGainMark = baseEarned
            logText = "↻ 工作时长已更新，此前工时已结算，从现在按新费率计费"
        }
        lastSchedule = (workStartText, workEndText, breakStartText, Double(Int(breakMinText) ?? 60))
        ud.set(workStartText, forKey: "workStart")
        ud.set(workEndText, forKey: "workEnd")
        ud.set(breakMinText, forKey: "breakMin")
        ud.set(breakStartText, forKey: "breakStart")
    }

    // 校正工时：把今天实际工作的总时长设为指定值（多记/少记均可），
    // 与当前已计工时的差额按费率折算，直接反映到今日累计与进度条
    func correctWork(hours: Double) {
        guard hours >= 0, hours <= 24 else { return }
        let current = totalWorkedHours
        let delta = hours - current
        guard abs(delta) > 0.001 else {
            logText = "工时无需校正，当前已是 \(fmt(current, 1)) 小时"
            return
        }
        baseEarned += delta * 3600 * ratePerSec
        if baseEarned < 0 { baseEarned = 0 }
        displayEarned = baseEarned
        workedBeforeSession = max(0, workedBeforeSession + delta * 3600)
        lastGainMark = baseEarned
        let verb = delta > 0 ? "补记" : "核减"
        logText = privacyActive
            ? "工时已校正，进度已更新"
            : "校正为 \(fmt(hours, 1)) 小时（\(verb) \(fmt(abs(delta), 1))h），今日累计 ¥\(fmt(baseEarned))"
        if abs(totalWorkedHours - hours) > 0.05 {
            logText = privacyActive
                ? "计费中，工时已按最低段校正"
                : "计费中，工时最低为本段 \(fmt(totalWorkedHours, 1)) 小时"
        }
        persist()
    }

    // 点击关闭按钮：默认收纳到状态栏（窗口隐藏、继续计费），设置里可选直接退出
    func requestClose() {
        if closeBehavior == "quit" {
            NSApp.terminate(nil)
        } else {
            onHidePanel?()
        }
    }

    // 收缩至状态栏：始终收纳（不受「关闭=退出」设置影响），窗口隐藏、菜单栏继续走数
    func collapseToStatusBar() {
        statusBarMode = true
        onHidePanel?()
    }

    // 大小窗口切换（完整 ↔ 迷你条）
    func toggleMini() {
        withAnimation { page = (page == .mini) ? .home : .mini }
    }

    func onCloseBehaviorChanged() {
        ud.set(closeBehavior, forKey: "closeBehavior")
    }

    // 状态栏符号变更：限长并立即落盘（收纳模式下 0.5s 刷新定时器会自动套用）
    func onBarSymbolChanged() {
        if barSymbol.count > 4 { barSymbol = String(barSymbol.prefix(4)) }
        ud.set(barSymbol, forKey: "barSymbol")
    }

    // MARK: - 2.3 菜单栏显示项

    /// 按枚举顺序返回当前选中项：顺序固定，轮播可预期
    var selectedStatusBarKinds: [StatusBarKind] {
        StatusBarKind.allCases.filter { statusBarKinds.contains($0.rawValue) }
    }

    /// 菜单栏显示的值：返回（主数值, 后缀单位）。隐私模式下金额一律换百分比。
    func statusBarValue(_ k: StatusBarKind) -> (text: String, unit: String) {
        let prefix = barSymbol.isEmpty ? "" : barSymbol + " "
        switch k {
        case .moneyToday:
            return privacyActive ? (percentText(todayHoursRatio), "")
                                 : (prefix + fmt(displayEarned, 2), "")
        case .moneyMonth:
            return privacyActive ? (percentText(monthHoursRatio), "")
                                 : (prefix + fmt(monthEarned, 2), "")
        case .moneyTodayPct:
            return (percentText(todayHoursRatio), "")
        case .moneyMonthPct:
            return (percentText(monthHoursRatio), "")
        case .daysCountdown:
            guard let p = activeCountdownProgress else { return ("未设置", "") }
            return p.expired ? ("已到", "") : ("\(p.daysLeft)", "天")
        case .daysRecord:
            guard let p = activeRecordDayProgress, p.started else { return ("未开始", "") }
            return ("\(p.elapsedDays)", "天")
        }
    }

    func isStatusBarKindOn(_ k: StatusBarKind) -> Bool { statusBarKinds.contains(k.rawValue) }

    /// 至少保留一项：全关会让菜单栏变成空白胶囊
    func toggleStatusBarKind(_ k: StatusBarKind) {
        if statusBarKinds.contains(k.rawValue) {
            guard statusBarKinds.count > 1 else {
                statusBarGuard = "菜单栏至少要保留一项，最后一项不能取消"
                return
            }
            statusBarKinds.remove(k.rawValue)
        } else {
            statusBarKinds.insert(k.rawValue)
        }
        statusBarGuard = nil
        ud.set(Array(statusBarKinds).sorted(), forKey: "statusBarKinds")
    }

    func onStatusBarDisplayChanged() {
        ud.set(statusBarShowData, forKey: "statusBarShowData")
        ud.set(statusBarRotate, forKey: "statusBarRotate")
        ud.set(statusBarRotateSeconds, forKey: "statusBarRotateSecs")
        ud.set(statusBarShowBar, forKey: "statusBarShowBar")
    }

    private func persist() {
        ud.set(salaryText, forKey: "salary")
        ud.set(baseEarned, forKey: "baseEarned")
        ud.set(working, forKey: "working")
        ud.set(workedBeforeSession, forKey: "workedBeforeSession")
        ud.set(overtimeSeconds, forKey: "overtimeSeconds")
        ud.set(dayKey, forKey: "dayKey")
        ud.set(dayLog, forKey: "dayLog")
        if let c = clockInAt { ud.set(c, forKey: "clockInAt") } else { ud.removeObject(forKey: "clockInAt") }
        writeWidgetSnapshot(reload: true)   // 打卡/校正/改薪等关键事件 → 通知小组件刷新
    }

    func onAutoOutChanged() {
        ud.set(autoOutEnabled, forKey: "autoOut")
    }

    func onAutoInChanged() {
        ud.set(autoInEnabled, forKey: "autoIn")
    }

    // 开机自启动：开关状态以系统真实状态为准，写失败时回滚 UI 并给出提示
    @discardableResult
    func onLaunchAtLoginChanged() -> String? {
        let want = launchAtLogin
        let err = LaunchAtLogin.setEnabled(want)
        launchAtLogin = LaunchAtLogin.isEnabled
        ud.set(launchAtLogin, forKey: "launchAtLoginWanted")   // 只作为「用户意愿」记录
        return err
    }

    // MARK: - 2.0 设置项写入

    func onWorkdayRuleChanged() {
        ud.set(Array(customWeekdays).sorted(), forKey: "customWeekdays")
        ud.set(useLegalHolidays, forKey: "useLegalHolidays")
        rebaseCurrentSession("每周工作日规则已更新")
    }

    func isButtonHidden(_ b: HomeButton) -> Bool { hiddenButtons.contains(b.rawValue) }

    func toggleButton(_ b: HomeButton) {
        if hiddenButtons.contains(b.rawValue) { hiddenButtons.remove(b.rawValue) }
        else { hiddenButtons.insert(b.rawValue) }
        ud.set(Array(hiddenButtons).sorted(), forKey: "hiddenButtons")
    }

    func isCountdownChipHidden(_ c: CountdownChip) -> Bool {
        hiddenCountdownChips.contains(c.rawValue)
    }

    func toggleCountdownChip(_ c: CountdownChip) {
        if hiddenCountdownChips.contains(c.rawValue) { hiddenCountdownChips.remove(c.rawValue) }
        else { hiddenCountdownChips.insert(c.rawValue) }
        ud.set(Array(hiddenCountdownChips).sorted(), forKey: "hiddenCountdownChips")
    }

    // 薪酬页模块：与倒计时模块用两套独立 key，改一边不会影响另一边
    func isMoneyChipHidden(_ c: MoneyChip) -> Bool { hiddenMoneyChips.contains(c.rawValue) }

    func toggleMoneyChip(_ c: MoneyChip) {
        if hiddenMoneyChips.contains(c.rawValue) { hiddenMoneyChips.remove(c.rawValue) }
        else { hiddenMoneyChips.insert(c.rawValue) }
        ud.set(Array(hiddenMoneyChips).sorted(), forKey: "hiddenMoneyChips")
    }

    func isHomeCardHidden(_ c: HomeCard) -> Bool { hiddenHomeCards.contains(c.rawValue) }

    /// 2.2：首页至少保留一张模块卡，全关会得到一个空白首页
    func toggleHomeCard(_ c: HomeCard) {
        if hiddenHomeCards.contains(c.rawValue) {
            hiddenHomeCards.remove(c.rawValue)
            homeCardGuard = nil
        } else {
            let visible = HomeCard.allCases.count - hiddenHomeCards.count
            if visible <= 1 {
                homeCardGuard = "首页至少要保留一个模块，最后一张不能隐藏"
                return
            }
            hiddenHomeCards.insert(c.rawValue)
            homeCardGuard = nil
        }
        ud.set(Array(hiddenHomeCards).sorted(), forKey: "hiddenHomeCards")
    }

    func onMetricChanged() {
        // 只允许薪酬口径落盘，避免旧值 countdown 又被写回去
        if progressMetric == .countdown { progressMetric = .todaySalary }
        ud.set(progressMetric.rawValue, forKey: "progressMetric")
        writeWidgetSnapshot(reload: true)
    }

    func finishOnboarding(_ mode: DetailMode? = nil) {
        // 2.1：引导改成「想先逛哪个模块」，口径选择留在薪酬二级页里
        page = mode?.page ?? .home
        ud.set(true, forKey: "v2Onboarded")
        showOnboarding = false
        onMetricChanged()
    }

    func onCountdownsChanged() {
        if let data = try? JSONEncoder().encode(countdowns) { ud.set(data, forKey: "countdowns") }
        if !countdowns.contains(where: { $0.id == activeCountdownId }) {
            activeCountdownId = countdowns.first?.id ?? ""
        }
        ud.set(activeCountdownId, forKey: "activeCountdownId")
        writeWidgetSnapshot(reload: true)
    }

    @discardableResult
    func addCountdown(_ item: CountdownItem) -> String? {
        guard !item.name.trimmingCharacters(in: .whitespaces).isEmpty else { return "请填写名称" }
        guard item.valid else { return "日期不合法（月 1–12、日 1–31、时 0–23、分 0–59）" }
        if let e = countdownRangeError(item) { return e }
        guard countdowns.count < 12 else { return "最多添加 12 条倒计时" }
        countdowns.append(item)
        if activeCountdownId.isEmpty { activeCountdownId = item.id }
        onCountdownsChanged()
        return nil
    }

    /// 2.4：二级页里改日期 / 时刻 / 模式
    @discardableResult
    func updateCountdown(id: String, with item: CountdownItem) -> String? {
        guard !item.name.trimmingCharacters(in: .whitespaces).isEmpty else { return "请填写名称" }
        guard item.valid else { return "日期不合法（月 1–12、日 1–31、时 0–23、分 0–59）" }
        if let e = countdownRangeError(item) { return e }
        guard let i = countdowns.firstIndex(where: { $0.id == id }) else { return "这条倒计时已经不在了" }
        var copy = item
        copy.id = id
        countdowns[i] = copy
        onCountdownsChanged()
        return nil
    }

    func removeCountdown(id: String) {
        countdowns.removeAll { $0.id == id }
        onCountdownsChanged()
    }

    // MARK: 顺序调整（拖动 / 菜单，改完立刻写回本机存盘）
    func placeCountdown(id: String, before targetID: String) {
        if EventOrder.place(&countdowns, id: id, before: targetID) { onCountdownsChanged() }
    }
    func shiftCountdown(id: String, by delta: Int) {
        if EventOrder.shift(&countdowns, id: id, by: delta) { onCountdownsChanged() }
    }
    func placeCountdown(id: String, at index: Int) {
        if EventOrder.place(&countdowns, id: id, at: index) { onCountdownsChanged() }
    }

    func setActiveCountdown(id: String) {
        activeCountdownId = id
        onCountdownsChanged()
    }

    /// 2.4：二级页内直接改名（空名回退成「未命名」，长度截到 16 字）
    func renameCountdown(id: String, to raw: String) {
        guard let i = countdowns.firstIndex(where: { $0.id == id }) else { return }
        var name = String(raw.prefix(16))
        if name.trimmingCharacters(in: .whitespaces).isEmpty && !raw.isEmpty { name = "" }
        guard countdowns[i].name != name else { return }
        countdowns[i].name = name
        if let data = try? JSONEncoder().encode(countdowns) { ud.set(data, forKey: "countdowns") }
        writeWidgetSnapshot(reload: false)
    }

    func commitCountdownName(id: String) {
        guard let i = countdowns.firstIndex(where: { $0.id == id }) else { return }
        if countdowns[i].name.trimmingCharacters(in: .whitespaces).isEmpty {
            countdowns[i].name = "未命名"
            onCountdownsChanged()
        }
    }

    // MARK: - 2.1 纪念日任务（与倒计时任务两套独立数据）

    func isRecordDayChipHidden(_ c: RecordDayChip) -> Bool {
        hiddenRecordDayChips.contains(c.rawValue)
    }

    func toggleRecordDayChip(_ c: RecordDayChip) {
        if hiddenRecordDayChips.contains(c.rawValue) { hiddenRecordDayChips.remove(c.rawValue) }
        else { hiddenRecordDayChips.insert(c.rawValue) }
        ud.set(Array(hiddenRecordDayChips).sorted(), forKey: "hiddenRecordDayChips")
    }

    func onRecordDaysChanged() {
        if let data = try? JSONEncoder().encode(recordDays) { ud.set(data, forKey: "recordDays") }
        if !recordDays.contains(where: { $0.id == activeRecordDayId }) {
            activeRecordDayId = recordDays.first?.id ?? ""
        }
        ud.set(activeRecordDayId, forKey: "activeRecordDayId")
        writeWidgetSnapshot(reload: true)
    }

    @discardableResult
    func addRecordDay(_ item: RecordDayItem) -> String? {
        guard !item.name.trimmingCharacters(in: .whitespaces).isEmpty else { return "请填写名称" }
        guard item.valid else { return "日期不合法（年 1970–2100、月 1–12、日 1–31）" }
        guard recordDays.count < 12 else { return "最多添加 12 条纪念日" }
        recordDays.append(item)
        if activeRecordDayId.isEmpty { activeRecordDayId = item.id }
        onRecordDaysChanged()
        return nil
    }

    func removeRecordDay(id: String) {
        recordDays.removeAll { $0.id == id }
        onRecordDaysChanged()
    }

    // MARK: 顺序调整（拖动 / 菜单，改完立刻写回本机存盘）
    func placeRecordDay(id: String, before targetID: String) {
        if EventOrder.place(&recordDays, id: id, before: targetID) { onRecordDaysChanged() }
    }
    func shiftRecordDay(id: String, by delta: Int) {
        if EventOrder.shift(&recordDays, id: id, by: delta) { onRecordDaysChanged() }
    }
    func placeRecordDay(id: String, at index: Int) {
        if EventOrder.place(&recordDays, id: id, at: index) { onRecordDaysChanged() }
    }

    /// 2.4：二级页里改纪念日的名称 / 起始日期
    @discardableResult
    func updateRecordDay(id: String, with item: RecordDayItem) -> String? {
        guard !item.name.trimmingCharacters(in: .whitespaces).isEmpty else { return "请填写名称" }
        guard item.valid else { return "日期不合法（年 1970–2100、月 1–12、日 1–31）" }
        guard let i = recordDays.firstIndex(where: { $0.id == id }) else { return "这条纪念日已经不在了" }
        var copy = item
        copy.id = id
        recordDays[i] = copy
        onRecordDaysChanged()
        return nil
    }

    func setActiveRecordDay(id: String) {
        activeRecordDayId = id
        onRecordDaysChanged()
    }

    /// 2.4：二级页内直接改名
    func renameRecordDay(id: String, to raw: String) {
        guard let i = recordDays.firstIndex(where: { $0.id == id }) else { return }
        let name = String(raw.prefix(16))
        guard recordDays[i].name != name else { return }
        recordDays[i].name = name
        if let data = try? JSONEncoder().encode(recordDays) { ud.set(data, forKey: "recordDays") }
        writeWidgetSnapshot(reload: false)
    }

    func commitRecordDayName(id: String) {
        guard let i = recordDays.firstIndex(where: { $0.id == id }) else { return }
        if recordDays[i].name.trimmingCharacters(in: .whitespaces).isEmpty {
            recordDays[i].name = "未命名"
            onRecordDaysChanged()
        }
    }

    // MARK: - 2.0 隐私模式 PIN（只存加盐 SHA-256，绝不存明文）

    static func pinDigest(_ pin: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + ":" + pin).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func setPIN(_ pin: String) -> String? {
        guard pin.count == 4, pin.allSatisfy({ $0.isNumber }) else { return "密码需为 4 位数字" }
        let salt = UUID().uuidString
        pinSalt = salt
        pinHash = Self.pinDigest(pin, salt: salt)
        ud.set(salt, forKey: "pinSalt")
        ud.set(pinHash, forKey: "pinHash")
        return nil
    }

    func verifyPIN(_ pin: String) -> Bool {
        guard hasPIN else { return true }
        return Self.pinDigest(pin, salt: pinSalt) == pinHash
    }

    func enablePrivacy(pin: String) -> String? {
        if let err = setPIN(pin) { return err }
        privacyEnabled = true
        onPrivacyChanged()
        return nil
    }

    func disablePrivacy() {
        privacyEnabled = false
        privacyUnlockedUntil = nil
        onPrivacyChanged()
    }

    /// 临时看一眼真实数字（默认 60 秒后自动恢复隐私展示）
    func unlockTemporarily(seconds: TimeInterval = 60) {
        privacyUnlockedUntil = Date.now.addingTimeInterval(seconds)
        writeWidgetSnapshot(reload: true)
    }

    func onPrivacyChanged() {
        ud.set(privacyEnabled, forKey: "privacyEnabled")
        logText = privacyEnabled
            ? "隐私模式已开启：工资数字改为百分比进度"
            : "隐私模式已关闭，金额恢复显示"
        writeWidgetSnapshot(reload: true)
    }
}

// MARK: - 开机自启动
//
// 优先用 macOS 13+ 的 SMAppService（正规登录项，用户能在「系统设置 → 通用 → 登录项」里看到并管理）。
// 本机是自签名证书（非 Developer ID），系统可能拒绝注册，失败则回退到 LaunchAgents plist。
// 两条路的实际效果一致：登录后静默启动，带 --autostart 参数直接进状态栏，不弹主窗。
enum LaunchAtLogin {
    static let label = "com.haofan.xiaoxinxin.autostart"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// 已注册但用户还没在系统设置里允许
    static var needsApproval: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .requiresApproval }
        return false
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 返回 nil 表示成功，否则为给用户看的错误文案
    static func setEnabled(_ on: Bool) -> String? {
        if #available(macOS 13.0, *) {
            do {
                if on {
                    if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                } else {
                    if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                }
                removeLegacyPlist()          // 清掉历史残留，避免两套机制同时生效
                return nil
            } catch {
                // 自签名 App 被系统拒绝时走 LaunchAgent，功能等价
                return legacySetEnabled(on)
            }
        }
        return legacySetEnabled(on)
    }

    private static func legacySetEnabled(_ on: Bool) -> String? {
        if on {
            let dir = plistURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dict: [String: Any] = [
                "Label": label,
                // 用 open 拉起完整 bundle，等价于用户双击；-g 表示不抢前台，登录后不打断用户
                "ProgramArguments": ["/usr/bin/open", "-g", "-a", Bundle.main.bundlePath, "--args", "--autostart"],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
            ]
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: dict, format: .xml, options: 0) else {
                return "生成登录项配置失败"
            }
            do {
                try data.write(to: plistURL)
            } catch {
                return "写入登录项失败：\(error.localizedDescription)"
            }
            _ = launchctl(["bootout", "gui/\(getuid())", plistURL.path])   // 先卸旧的，报错忽略
            let code = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
            // 5 = 已在加载中，属于正常情况
            return (code == 0 || code == 5) ? nil : "注册登录项失败（launchctl \(code)）"
        } else {
            _ = launchctl(["bootout", "gui/\(getuid())", plistURL.path])
            try? FileManager.default.removeItem(at: plistURL)
            return nil
        }
    }

    private static func removeLegacyPlist() {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        _ = launchctl(["bootout", "gui/\(getuid())", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - Liquid Glass 背景

struct GlassPanel: NSViewRepresentable {
    var cornerRadius: CGFloat
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let v = NSGlassEffectView()
            v.cornerRadius = cornerRadius
            return v
        } else {
            let v = NSVisualEffectView()
            // 浅色/深色都由系统材质自适应（旧系统回退用，新系统走 NSGlassEffectView）
            v.material = .underWindowBackground
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = cornerRadius
            v.layer?.masksToBounds = true
            return v
        }
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *), let v = nsView as? NSGlassEffectView {
            v.cornerRadius = cornerRadius
        } else if let v = nsView as? NSVisualEffectView {
            v.layer?.cornerRadius = cornerRadius
        }
    }
}

// MARK: - 组件

// MARK: - 明暗双模式配色（跟随系统外观，无需手动切换）

/// 浅色/深色两个值合成一条动态色，系统切换外观时自动生效
func dynColor(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

// MARK: - 2.2 主题与调色（四款预设 + 色卡无极调节 + 背景透明度）

enum AppTheme: String, CaseIterable, Identifiable {
    case liquidGlass, mint, sky, sony30

    var id: String { rawValue }
    var title: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .mint:        return "白 + 薄荷绿"
        case .sky:         return "白 + 天蓝"
        case .sony30:      return "Sony 30th"
        }
    }
    var detail: String {
        switch self {
        case .liquidGlass: return "初始透明玻璃：跟随桌面光影，背景透明度可单独调"
        case .mint:        return "纯白底 + 薄荷绿强调色，清爽不刺眼"
        case .sky:         return "纯白底 + 天蓝强调色，冷静通透"
        case .sony30:      return "初代 PlayStation 30 周年：浅灰机身 + 深灰字 + 四色按键点缀"
        }
    }
    var icon: String {
        switch self {
        case .liquidGlass: return ""
        case .mint:        return ""
        case .sky:         return ""
        case .sony30:      return ""
        }
    }
    var glass: Bool { self == .liquidGlass }

    /// 预设色值：背景 / 文本 / 重点色（RGB 0...1）+ 背景不透明度
    var preset: (bg: [Double], text: [Double], accent: [Double], alpha: Double) {
        switch self {
        case .liquidGlass: return ([1, 1, 1], [0.12, 0.13, 0.15], [0.84, 0.00, 0.08], 0.58)
        case .mint:        return ([1, 1, 1], [0.08, 0.20, 0.17], [0.10, 0.68, 0.50], 1.00)
        case .sky:         return ([1, 1, 1], [0.07, 0.16, 0.27], [0.16, 0.52, 0.90], 1.00)
        case .sony30:      return ([0.82, 0.83, 0.84], [0.15, 0.16, 0.18], [0.28, 0.31, 0.36], 1.00)
        }
    }
    /// 主题预览的小色块（Sony 30th 用初代四色按键）
    var swatches: [Color] {
        switch self {
        case .liquidGlass:
            return [Color(white: 0.95), Color(white: 0.72), Color(red: 0.84, green: 0, blue: 0.08)]
        case .mint:
            return [.white, Color(red: 0.10, green: 0.68, blue: 0.50), Color(red: 0.62, green: 0.92, blue: 0.82)]
        case .sky:
            return [.white, Color(red: 0.16, green: 0.52, blue: 0.90), Color(red: 0.66, green: 0.84, blue: 0.98)]
        case .sony30:
            return [Color(red: 0.82, green: 0.83, blue: 0.84),
                    Color(red: 0.20, green: 0.70, blue: 0.35),
                    Color(red: 0.88, green: 0.20, blue: 0.24),
                    Color(red: 0.20, green: 0.45, blue: 0.85),
                    Color(red: 0.85, green: 0.45, blue: 0.75)]
        }
    }
}

/// 全局当前调色板：EarnModel 每次改主题都会同步，视图重绘时读取。
/// 这样 Glass.fill / redDeep 的上百处调用点无需逐个改成环境变量。
enum AppPalette {
    static var bg = Color.white
    static var text = Color(white: 0.12)
    static var accent = Color(red: 0.84, green: 0, blue: 0.08)
    static var accentDeep = Color(red: 0.60, green: 0, blue: 0.06)
    static var alpha: Double = 0.58
    static var glass = true
    static var highlights: [Color] = []

    /// 主题本身是深色还是浅色：窗口外观要跟主题走，不能让系统深色模式把
    /// Color.primary / TextField 占位符 / 开关底纹全刷成白色（浅色主题下会整片糊掉）
    static var isDark: Bool {
        let v = rgb(bg)
        let l = 0.299 * v[0] + 0.587 * v[1] + 0.114 * v[2]
        return l < 0.5
    }

    static func rgb(_ c: Color) -> [Double] {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return [Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent)]
    }
    static func color(_ v: [Double]) -> Color {
        guard v.count >= 3 else { return .white }
        return Color(red: v[0], green: v[1], blue: v[2])
    }
    /// 主色太浅时按钮文字自动转深色，保证对比度
    static var onAccent: Color {
        let v = rgb(accent)
        let l = 0.299 * v[0] + 0.587 * v[1] + 0.114 * v[2]
        return l > 0.62 ? Color(white: 0.12) : .white
    }
    static func apply(bg b: [Double], text t: [Double], accent a: [Double],
                      alpha al: Double, glass g: Bool, highlights h: [Color]) {
        guard b.count >= 3, t.count >= 3, a.count >= 3 else { return }
        bg = color(b); text = color(t); accent = color(a)
        accentDeep = Color(red: a[0] * 0.72, green: a[1] * 0.72, blue: a[2] * 0.72)
        alpha = min(1, max(0.15, al)); glass = g; highlights = h
    }
}

enum Glass {
    /// 玻璃填充：Liquid Glass 走白雾 / 深灰雾；实色主题走「底色 + 文本色」混合出的层级色块
    static func fill(_ a: Double) -> Color {
        if AppPalette.glass {
            return dynColor(NSColor(white: 1, alpha: a),
                            NSColor(white: 0.11, alpha: min(0.94, 0.26 + a * 1.15)))
        }
        return surface(min(0.34, 0.035 + a * 0.30))
    }
    static func line(_ a: Double) -> Color {
        if AppPalette.glass {
            return dynColor(NSColor(white: 1, alpha: a),
                            NSColor(white: 1, alpha: max(0.055, a * 0.24)))
        }
        return AppPalette.text.opacity(min(0.42, 0.06 + a * 0.24))
    }
    /// 实色主题：底色混入少量文本色，f 越大色块越深
    static func surface(_ f: Double) -> Color {
        let base = NSColor(AppPalette.bg).usingColorSpace(.sRGB) ?? .white
        let ink = NSColor(AppPalette.text).usingColorSpace(.sRGB) ?? .black
        let mixed = base.blended(withFraction: min(0.5, max(0, f)), of: ink) ?? base
        return Color(nsColor: mixed)
    }
    /// 2.2 设置页色块深度：1 分区容器（最浅）/ 2 分组卡 / 3 分区标题（最深）/ 4 组内行
    static func level(_ n: Int) -> Color {
        let i = min(4, max(1, n))
        if AppPalette.glass { return fill([0, 0.10, 0.20, 0.30, 0.14][i]) }
        return surface([0, 0.035, 0.075, 0.17, 0.055][i])
    }
}

// 重点色：改成动态读取全局调色板，主题切换即全站生效（原有调用点保持不变）
var redDeep: Color { AppPalette.accent }

/// 主题变化 → 同步窗口外观（浅色主题用 aqua，深色主题用 darkAqua）。
/// 入口建好窗口后注册；否则系统深色模式会把 Color.primary、TextField 占位符、
/// 开关底纹按深色渲染，而主题底色是浅色 → 整片文字发白看不清。
var onAppearanceSync: ((Bool) -> Void)?

struct IconChip: View {
    let icon: String
    let value: String
    let label: String
    var highlight = false

    var body: some View {
        // 2.2.1 极简版式：去掉装饰图标，数值用主题重点色 + 更大更粗字号撑起层级
        VStack(spacing: 5) {
            if !icon.isEmpty { Text(icon).font(.system(size: 13, weight: .medium)) }
            Text(value)
                .font(.system(size: highlight ? 16 : 15, weight: .heavy, design: .rounded))
                .foregroundStyle(redDeep)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Glass.fill(0.32))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Glass.line(0.55), lineWidth: 1))
        )
    }
}

struct GlassIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Glass.fill(0.35)))
                .overlay(Circle().strokeBorder(Glass.line(0.55), lineWidth: 1))
                // 2.4.1：命中区收敛到圆形本体。顶着窗口圆角那四个方角原本也能点，
                // 在顶栏右上角抬手很容易误触关闭
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 2.0 密码输入（AppKit 原生弹窗，避开本机 swiftc 的 SwiftUI @State 宏限制）

@MainActor
func askPIN(title: String, message: String, confirm: String = "确定") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: confirm)
    alert.addButton(withTitle: "取消")
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    field.placeholderString = "4 位数字密码"
    alert.accessoryView = field
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue
}

/// 需要验密的动作统一走这里；返回 false 表示取消或密码错误
@MainActor
func requirePIN(model: EarnModel, title: String, message: String) -> Bool {
    guard model.hasPIN else { return true }
    guard let pin = askPIN(title: title, message: message) else { return false }
    if model.verifyPIN(pin) { return true }
    let alert = NSAlert()
    alert.messageText = "密码不对"
    alert.informativeText = "请重试。密码只在本机保存加盐哈希，无法找回；忘记可在设置页关闭隐私模式后重设。"
    alert.runModal()
    return false
}

// MARK: - 首页

// MARK: - 2.1 共享组件：顶部工具条 / 打卡按钮 / 日志行

/// 三个页面共用一套工具条：首页显示完整入口，二级页换成「返回 + 模式名」，不再多塞按钮
struct AppHeader: View {
    @ObservedObject var model: EarnModel
    var mode: DetailMode? = nil
    var onBack: () -> Void = {}

    private var isDetail: Bool { mode != nil }

    var body: some View {
        HStack(spacing: 5) {
            if isDetail {
                GlassIconButton(symbol: "chevron.left", help: "返回首页") { onBack() }
                Text(mode!.title)
                    .font(.system(size: 13.5, weight: .heavy))
                    .lineLimit(1).minimumScaleFactor(0.8).fixedSize()
            } else {
                // 2.6：顶栏不再有「只是文字」的区域 —— 标题本身就是一个按钮（点开关于）
                titleButton
            }
            moduleSwitch
            // 2.2：打卡状态只属于 Your Money；Your Days 两页不显示「加班中 / 计费中 / 未打卡」
            // 2.6：二级页正文里本来就有打卡 / 加班按钮，顶栏只留首页这一处，避免挤爆工具条
            if !isDetail { punchMenu }
            // 隐私锁只属于 Your Money；Your Days 两页没有任何金额，不挂这把锁
            if model.privacyEnabled && (!isDetail || mode == .salary) {
                GlassIconButton(symbol: model.privacyActive ? "lock.fill" : "lock.open.fill",
                                help: model.privacyActive ? "临时查看真实数字（需密码）" : "立即恢复隐私显示") {
                    if model.privacyActive {
                        if requirePIN(model: model, title: "临时查看",
                                      message: "输入 4 位密码，60 秒后自动恢复百分比显示") {
                            model.unlockTemporarily()
                        }
                    } else {
                        model.privacyUnlockedUntil = nil
                    }
                }
            }
            if !isDetail {
                if !model.isButtonHidden(.mini) {
                    GlassIconButton(symbol: "rectangle.compress.vertical", help: "缩小为迷你条") {
                        withAnimation { model.page = .mini }
                    }
                }
                if !model.isButtonHidden(.collapse) {
                    GlassIconButton(symbol: "menubar.rectangle", help: "收缩至状态栏") {
                        model.collapseToStatusBar()
                    }
                }
            }
            if !model.isButtonHidden(.settings) {
                GlassIconButton(symbol: "gearshape", help: "设置") { withAnimation { model.page = .settings } }
            }
            if !model.isButtonHidden(.close) {
                GlassIconButton(symbol: "xmark", help: model.closeBehavior == "quit" ? "退出分刻" : "收纳到状态栏") {
                    model.requestClose()
                }
            }
        }
        // 2.6：整条顶栏做成一块圆角矩形工具条，并向上 / 左右「出血」铺到窗口边缘。
        // 关键：底色必须不透明。窗口本身是半透明的（背景 58%），macOS 会把半透明像素上的
        // 点击判给下层窗口 —— 这正是「点顶栏留白，窗口沉到别的 App 后面」的根因。
        // 这块不透明的圆角矩形把顶部整片遮住，条内任何缝隙都变成真能点住的表面。
        .padding(.horizontal, 7)
        .padding(.vertical, 8)
        .background(barBackground)
    }

    /// 顶部工具条的底：上两角跟随窗口圆角（32），下两角 15；负 padding 让它越过页面边距
    /// 直接铺到窗口顶边和左右边（页面统一 padding 是 14 / 6）
    private var barBackground: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 32, bottomLeadingRadius: 15,
                                           bottomTrailingRadius: 15, topTrailingRadius: 32,
                                           style: .continuous)
        return ZStack {
            shape.fill(AppPalette.bg)
            shape.fill(Glass.fill(0.26))
            shape.strokeBorder(Glass.line(0.45), lineWidth: 1)
        }
        // 底色只负责好看：整块不参与命中测试。条内的缝隙（按钮之间、两头留白）
        // 于是直接漏到根层的原生拖拽面上 —— 点得住、也拖得动
        .allowsHitTesting(false)
        .padding(.horizontal, -21)   // 14（页面边距）+ 7（条内边距）
        .padding(.top, -14)          // 6（页面上边距）+ 8（条上下边距）
    }

    /// 标题 = 按钮：点开「关于」（版本 / Build / 发版日期 / 版权与迭代记录都在那）
    private var titleButton: some View {
        Button { showAboutPanel() } label: {
            Text("分刻")
                .font(.system(size: 14.5, weight: .heavy))
                .foregroundStyle(AppPalette.text)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Capsule().fill(Glass.fill(0.30)))
                .overlay(Capsule().strokeBorder(Glass.line(0.45), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("关于 分刻 · Countmin v\(APP_VERSION)（Build \(APP_BUILD)）")
    }

    /// MONEY / DAYS 模块切换：整条弹性铺满中间，顶栏不留任何不可点的空白
    private var moduleSwitch: some View {
        HStack(spacing: 2) {
            moduleTab("MONEY", active: model.page == .salary) {
                if model.page != .salary { withAnimation { model.page = .salary } }
            }
            // 中缝竖线：两段是独立单元格，宽一点也不会看成分散的标签
            Rectangle().fill(Glass.line(0.42)).frame(width: 1, height: 11)
            moduleTab("DAYS", active: model.page == .countdown || model.page == .recordDay) {
                if model.page != .countdown && model.page != .recordDay {
                    withAnimation { model.page = .countdown }
                }
            }
        }
        .padding(2)
        // 胶囊底只做视觉：不参与命中测试。否则胶囊里那圈 2pt 留白会把点击吞掉，
        // 既不激活窗口也拖不动 —— 让它漏到下层拖拽面去
        .background(Capsule().fill(Glass.fill(0.22)).allowsHitTesting(false))
        .overlay(Capsule().strokeBorder(Glass.line(0.40), lineWidth: 1).allowsHitTesting(false))
        .frame(maxWidth: .infinity)
    }

    private func moduleTab(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(active ? AppPalette.onAccent : Color.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(active
                    ? AnyShapeStyle(LinearGradient(colors: [model.accentA, model.accentB],
                                                   startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(Color.clear)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label == "MONEY" ? "打开薪酬进度页" : "打开天数页（倒计时）")
    }

    /// 打卡状态胶囊也是按钮：点开就能打卡 / 上下班 / 加班，不再只是指示灯
    private var punchMenu: some View {
        Menu {
            Button(model.working ? "打卡下班" : "打卡上班") {
                if model.working { model.clockOut() } else { model.clockIn() }
            }
            if model.working {
                Button(model.overtimeNow ? "结束加班" : "开始加班") {
                    if model.overtimeNow { model.endOvertime() } else { model.startOvertime() }
                }
            }
            Divider()
            Button("打开薪酬页") { withAnimation { model.page = .salary } }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(model.overtimeNow ? Color.orange : (model.working ? Color.red : Color.gray.opacity(0.6)))
                    .frame(width: 7, height: 7)
                Text(model.overtimeNow ? "加班中" : (model.working ? "计费中" : "未打卡"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 7).padding(.vertical, 4.5)
            .background(Capsule().fill(Glass.fill(0.32)))
            .overlay(Capsule().strokeBorder(Glass.line(0.5), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("打卡状态：点开可上班 / 下班 / 加班")
    }
}

struct PunchButtons: View {
    @ObservedObject var model: EarnModel
    /// 加班按钮只属于 Your Money 薪酬页；首页保留两个快捷，Your Days 两页不加载本组件
    var includeOvertime = false

    private var showIn: Bool { !model.isButtonHidden(.clockIn) }
    private var showOut: Bool { !model.isButtonHidden(.clockOut) }
    private var showOT: Bool { includeOvertime && !model.isButtonHidden(.overtime) }

    var body: some View {
        Group {
            if showIn || showOut || showOT {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        if showIn { clockInButton }
                        if showOut { clockOutButton }
                    }
                    if showOT { overtimeButton }
                }
            }
        }
        .padding(.top, 14)
    }

    private var clockInButton: some View {
        Button { withAnimation { model.clockIn() } } label: {
            Text("打卡上班").font(.system(size: 16.5, weight: .heavy))
                .foregroundStyle(AppPalette.onAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                // 按钮始终用主色双色渐变：Sony 四色渐变只给进度条，浅色段会让白字看不清
                .background(Capsule().fill(LinearGradient(colors: [model.accentA, model.accentB],
                                                           startPoint: .top, endPoint: .bottom)))
                .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.02)],
                                                       startPoint: .top, endPoint: .center))
                    .blendMode(.plusLighter).allowsHitTesting(false))
                .overlay(Capsule().strokeBorder(Glass.line(0.5), lineWidth: 1))
                .shadow(color: model.accentB.opacity(0.38), radius: 9, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(model.salary <= 0 || model.working)
        .opacity(model.salary > 0 && !model.working ? 1 : 0.45)
    }

    private var clockOutButton: some View {
        Button { withAnimation { model.clockOut() } } label: {
            Text("打卡下班").font(.system(size: 16.5, weight: .heavy))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Capsule().fill(Glass.fill(0.42)))
                .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!model.working || model.manualOvertime)
        .opacity(model.working && !model.manualOvertime ? 1 : 0.45)
    }

    /// 2.2 加班段：开始 = 独立开一段计费；结束 = 结算并下班。本段计入加班时长
    private var overtimeButton: some View {
        Button {
            withAnimation { model.manualOvertime ? model.endOvertime() : model.startOvertime() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.manualOvertime ? "moon.fill" : "moon.stars.fill")
                Text(model.manualOvertime ? "结束加班并下班" : "开始加班")
            }
            .font(.system(size: 14, weight: .heavy))
            .foregroundStyle(model.manualOvertime ? AppPalette.onAccent : redDeep)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(Capsule().fill(model.manualOvertime
                                       ? Color.orange.opacity(0.92) : Glass.fill(0.36)))
            .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.salary <= 0)
        .opacity(model.salary > 0 ? 1 : 0.45)
    }
}

struct LogLine: View {
    @ObservedObject var model: EarnModel
    var body: some View {
        Text(model.logText).font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary).lineLimit(1)
            .frame(maxWidth: .infinity).padding(.top, 10)
    }
}

/// Your Days 两页不参与打卡：底部只留一句模块说明，避免出现「打卡上班」按钮和薪酬日志
struct DaysPageFooter: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
    }
}

// MARK: - 2.1 新首页：两张互相独立的进度卡，点击才进对应二级页

struct HomeProgressCard: View {
    @ObservedObject var model: EarnModel
    let mode: DetailMode

    /// 2.2.1：轨道颜色跟随主题文本色，不用 colorScheme。
    /// 无边框透明窗口的 colorScheme 跟系统外观走（系统深色时返回 .dark），
    /// 但主题本身可能是浅色，按 colorScheme 取色会把轨道画成半透明白，叠在浅卡片上等于隐形。
    private var track: Color { AppPalette.text.opacity(0.18) }
    private var trackEdge: Color { AppPalette.text.opacity(0.14) }

    private var info: ProgressInfo {
        switch mode {
        case .salary: return model.progressInfo
        case .countdown: return model.countdownInfo
        case .recordDay: return model.recordDayInfo
        }
    }
    private var hasTask: Bool {
        switch mode {
        case .salary: return true
        case .countdown: return model.activeCountdown != nil
        case .recordDay: return model.activeRecordDay != nil
        }
    }
    private var settingsGroup: String {
        switch mode {
        case .salary: return "salary"
        case .countdown: return "countdown"
        case .recordDay: return "recordDay"
        }
    }

    private var cardTitle: String {
        let name: String?
        switch mode {
        case .salary:    name = nil
        case .countdown: name = model.activeCountdown?.name
        case .recordDay: name = model.activeRecordDay?.name
        }
        return name.map { "\(mode.module) · \(mode.title) · \($0)" } ?? "\(mode.module) · \(mode.title)"
    }
    private var subTag: String {
        switch mode {
        case .salary:    return model.progressMetric.title
        case .countdown: return model.activeCountdown?.mode == "percent" ? "按百分比" : "按天数"
        case .recordDay: return "累计时长"
        }
    }

    var body: some View {
        Button {
            if !hasTask {
                // 2.4：倒计时 / 纪念日没有内容时直接进自己的二级页并展开事件管理，
                // 新增操作就近完成，不用再跳到设置页
                switch mode {
                case .salary:
                    SettingsUIState.shared.openGroups.insert(settingsGroup)
                    withAnimation { model.page = .settings }
                case .countdown:
                    SettingsUIState.shared.openEventManager(.countdown)
                    withAnimation { model.page = .countdown }
                case .recordDay:
                    SettingsUIState.shared.openEventManager(.anniversary)
                    withAnimation { model.page = .recordDay }
                }
            } else {
                withAnimation { model.page = mode.page }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(cardTitle).font(.system(size: 14, weight: .heavy)).lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
                    Text(subTag).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(info.leading)
                        .font(.system(size: info.isMoney ? 37 : 36, weight: .heavy, design: .rounded))
                        .foregroundStyle(redDeep).lineLimit(1).minimumScaleFactor(0.6)
                    if !info.trailing.isEmpty {
                        Text(info.trailing).font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(redDeep.opacity(0.75))
                    }
                    Spacer(minLength: 4)
                    if info.overflow > 0 {
                        Text("+" + percentText(info.overflow))
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.16))).fixedSize()
                    }
                }
                if mode == .recordDay {
                    // 2.4：纪念日不再画进度条，改成「累计时长」——X 年 Y 个月 Z 天
                    durationStrip
                } else {
                    GeometryReader { g in
                        let w = g.size.width
                        ZStack(alignment: .leading) {
                            // 2.2.1 根因修复：Shape 在 ZStack 里只按 ideal size 布局，
                            // 轨道原来没给宽度 → 被压成 0（或只跟填充一样宽），真机上整条消失。
                            // 显式铺满宽度后，浅色/深色主题都能看到完整轨道。
                            Capsule()
                                .fill(track)
                                .overlay(Capsule().strokeBorder(trackEdge, lineWidth: 0.8))
                                .frame(width: w, height: 8)
                            Capsule()
                                .fill(LinearGradient(colors: model.barColors,
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(0, w * info.fill), height: 8)
                        }
                        .frame(width: w, height: 8, alignment: .leading)
                    }
                    .frame(height: 8)
                }
                Text(info.footer).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Glass.fill(0.26)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Glass.line(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("点击进入\(mode.title)详情")
    }

    /// 纪念日累计时长：年 / 个月 / 天 三段，替代进度条
    private var durationStrip: some View {
        let span = model.activeRecordDayProgress?.span ?? ElapsedSpan()
        return HStack(spacing: 5) {
            durationUnit(span.years, "年")
            durationUnit(span.months, "个月")
            durationUnit(span.days, "天")
            Spacer(minLength: 0)
        }
        .frame(height: 16)
    }

    private func durationUnit(_ v: Int, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(v)")
                .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                .foregroundStyle(redDeep)
            Text(unit)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(Capsule().fill(Glass.fill(0.30)))
        .fixedSize()
    }
}

struct HomeView: View {
    @ObservedObject var model: EarnModel

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(model: model)
            VStack(spacing: 9) {
                if !model.isHomeCardHidden(.money) { HomeProgressCard(model: model, mode: .salary) }
                if !model.isHomeCardHidden(.countdown) { HomeProgressCard(model: model, mode: .countdown) }
                if !model.isHomeCardHidden(.recordDay) { HomeProgressCard(model: model, mode: .recordDay) }
            }
            .padding(.top, 10)
            if model.hiddenHomeCards.count >= HomeCard.allCases.count {
                Text("进度卡全被隐藏了：设置 → 首页布局可重新打开")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
            }
            PunchButtons(model: model)
            LogLine(model: model)
        }
        // 2.6：顶部留白压到 12pt，且整条顶栏都是控件 —— 原本「标题 + Your Money/Your Days 装饰行」
        // 那两行空白已取消，MONEY 卡片直接上移
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 18)
    }
}

// MARK: - 2.1 倒计时二级页（独立数据、独立模块，和薪酬页零共享）

struct CountdownDetailView: View {
    @ObservedObject var model: EarnModel
    private var info: ProgressInfo { model.countdownInfo }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(model: model, mode: .countdown) { withAnimation { model.page = .home } }
            amountView
            progressZone
            countdownChips
            DaysEventManager(model: model, kind: .countdown)
            DaysPageFooter(text: "Your Days · 倒计时不参与打卡与计薪")
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 20)
    }

    private var amountView: some View {
        VStack(spacing: 4) {
            Text(info.caption).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(info.leading).font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(redDeep).lineLimit(1).minimumScaleFactor(0.6)
                if !info.trailing.isEmpty {
                    Text(info.trailing).font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(redDeep.opacity(0.75))
                }
            }
            .frame(height: 52, alignment: .center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
    }

    private var progressZone: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Glass.fill(0.38)).frame(width: w, height: 12)
                        .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
                    Capsule()
                        .fill(LinearGradient(colors: model.barColors,
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, w * info.fill), height: 12)
                }
                .frame(width: w, height: 12, alignment: .leading)
            }
            .frame(height: 14)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(info.footer).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !model.isButtonHidden(.metric) { taskMenu }
            }
        }
        .padding(.bottom, 12)
    }

    private var taskMenu: some View {
        Menu {
            ForEach(model.countdowns) { c in
                Button {
                    model.setActiveCountdown(id: c.id)
                } label: { Text(model.activeCountdownId == c.id ? "✓ \(c.name)" : c.name) }
            }
            Divider()
            Button("管理倒计时任务…") {
                SettingsUIState.shared.openGroups.insert("countdown")
                withAnimation { model.page = .settings }
            }
        } label: {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Glass.fill(0.35)))
                .overlay(Circle().strokeBorder(Glass.line(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain).fixedSize()
        .help("切换倒计时任务（当前：\(model.activeCountdown?.name ?? "无")）")
    }

    private var countdownChips: some View {
        let items = CountdownChip.allCases.filter { !model.isCountdownChipHidden($0) }
        let rows = stride(from: 0, to: items.count, by: 3)
            .map { Array(items[$0..<min($0 + 3, items.count)]) }
        return VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    ForEach(rows[i], id: \.self) { c in countdownChip(c) }
                    ForEach(0..<(3 - rows[i].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
            if items.isEmpty {
                Text("倒计时模块全被隐藏了：设置 → 倒计时 → 倒计时页模块可重新打开")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 10)
            }
        }
        .padding(.bottom, 14)
    }

    private func countdownChip(_ c: CountdownChip) -> some View {
        let p = model.activeCountdownProgress
        let item = model.activeCountdown
        let targetShort: String = {
            guard let key = p?.targetKey else { return "--" }
            let md = String(key.dropFirst(5)).replacingOccurrences(of: "-", with: "/")
            return item?.isYearly == true ? md : String(key.prefix(4)) + "/" + md
        }()
        return Group {
            switch c {
            case .elapsed:   IconChip(icon: "", value: "\(p?.elapsedDays ?? 0) 天", label: "累计天数")
            case .remaining: IconChip(icon: "", value: p?.expired == true ? "已到期" : "\(p?.daysLeft ?? 0) 天",
                                      label: "剩余天数", highlight: true)
            case .target:    IconChip(icon: "", value: targetShort, label: "目标日期")
            case .percent:   IconChip(icon: "", value: percentText(p?.ratio ?? 0), label: "完成进度")
            case .span:      IconChip(icon: "", value: "\(p?.totalDays ?? 0) 天", label: "总跨度")
            case .name:      IconChip(icon: "", value: item?.name ?? "--",
                                      label: item?.isYearly == true ? "每年重复" : "仅一次", highlight: true)
            }
        }
    }
}

// MARK: - 2.1 纪念日二级页（Your Days 下第二个独立模式）

struct RecordDayDetailView: View {
    @ObservedObject var model: EarnModel
    private var info: ProgressInfo { model.recordDayInfo }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(model: model, mode: .recordDay) { withAnimation { model.page = .home } }
            amountView
            durationZone
            recordChips
            DaysEventManager(model: model, kind: .anniversary)
            DaysPageFooter(text: "Your Days · 纪念日不参与打卡与计薪")
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 20)
    }

    private var amountView: some View {
        VStack(spacing: 4) {
            Text(info.caption).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(info.leading).font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(redDeep).lineLimit(1).minimumScaleFactor(0.6)
                if !info.trailing.isEmpty {
                    Text(info.trailing).font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(redDeep.opacity(0.75))
                }
            }
            .frame(height: 52, alignment: .center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
    }

    /// 2.4：纪念日不做进度条，主展示改成「累计时长」：年 / 个月 / 天 + 总天数
    private var durationZone: some View {
        let p = model.activeRecordDayProgress
        let span = p?.span ?? ElapsedSpan()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                durationBlock(span.years, "年")
                durationBlock(span.months, "个月")
                durationBlock(span.days, "天")
                Spacer(minLength: 0)
                if !model.isButtonHidden(.metric) { taskMenu }
            }
            Text(p?.started == true
                 ? "累计 \(span.totalDays) 天 · \(span.shortText)"
                 : "起始日还没到，到那天开始累计时长")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.bottom, 12)
    }

    private func durationBlock(_ v: Int, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(v)")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(redDeep)
            Text(unit)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Glass.fill(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Glass.line(0.45), lineWidth: 1))
        .fixedSize()
    }

    private var taskMenu: some View {
        Menu {
            ForEach(model.recordDays) { c in
                Button { model.setActiveRecordDay(id: c.id) } label: {
                    Text(model.activeRecordDayId == c.id ? "✓ \(c.name)" : c.name)
                }
            }
            Divider()
            Button("管理纪念日任务…") {
                SettingsUIState.shared.openGroups.insert("recordDay")
                withAnimation { model.page = .settings }
            }
        } label: {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Glass.fill(0.35)))
                .overlay(Circle().strokeBorder(Glass.line(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain).fixedSize()
        .help("切换纪念日任务（当前：\(model.activeRecordDay?.name ?? "无")）")
    }

    private var recordChips: some View {
        let items = RecordDayChip.allCases.filter { !model.isRecordDayChipHidden($0) }
        let rows = stride(from: 0, to: items.count, by: 3)
            .map { Array(items[$0..<min($0 + 3, items.count)]) }
        return VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    ForEach(rows[i], id: \.self) { c in recordChip(c) }
                    ForEach(0..<(3 - rows[i].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
            if items.isEmpty {
                Text("纪念日模块全被隐藏了：设置 → Your Days → 纪念日页模块")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 10)
            }
        }
        .padding(.bottom, 14)
    }

    private func recordChip(_ c: RecordDayChip) -> some View {
        let p = model.activeRecordDayProgress
        let item = model.activeRecordDay
        let startShort: String = {
            guard let k = p?.startKey else { return "--" }
            return String(k.dropFirst(5)).replacingOccurrences(of: "-", with: "/")
        }()
        return Group {
            switch c {
            case .elapsed:
                IconChip(icon: "", value: "\(p?.elapsedDays ?? 0) 天", label: "累计天数", highlight: true)
            case .duration:
                // 芯片宽度有限，用紧凑写法 2年5月18天，避免被挤出卡片
                if let s = p?.span {
                    IconChip(icon: "", value: "\(s.years)年\(s.months)月\(s.days)天", label: "累计时长", highlight: true)
                } else {
                    IconChip(icon: "", value: "--", label: "累计时长", highlight: true)
                }
            case .start:
                IconChip(icon: "", value: startShort, label: "起始日期")
            case .months:
                IconChip(icon: "", value: "\(((p?.span.years ?? 0) * 12) + (p?.span.months ?? 0)) 个月", label: "累计月数")
            case .years:
                IconChip(icon: "", value: "\(p?.span.years ?? 0) 年", label: "累计年数")
            case .name:
                IconChip(icon: "", value: item?.name ?? "--", label: "纪念日", highlight: true)
            }
        }
    }
}

// MARK: - 2.4 Your Days 事件管理（倒计时 / 纪念日 二级页共用，风格完全一致）

enum DaysEventKind: String {
    case countdown, anniversary

    /// 表单里「年」的占位文案：倒计时可留空表示每年重复
    var yearPlaceholder: String { self == .countdown ? "年选填" : "年" }
    var emptyHint: String {
        self == .countdown
            ? "还没有倒计时事件。填名称 + 目标月/日（年留空=每年重复），可另设起始日与目标时刻。"
            : "还没有纪念日。填名称 + 起始年月日，从那天起累计时长。"
    }
}

// MARK: - 事件排序控件（设置页 / DAYS 二级页共用）

/// 拖放落点：进入某一行时，把拖动源实时插到这一行之前。
struct EventReorderDropDelegate: DropDelegate {
    @Binding var draggingID: String?
    let targetID: String
    let onPlaceBefore: (String, String) -> Void

    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropEntered(info: DropInfo) {
        guard let src = draggingID, src != targetID else { return }
        withAnimation(.easeInOut(duration: 0.12)) { onPlaceBefore(src, targetID) }
    }
    func performDrop(info: DropInfo) -> Bool { draggingID = nil; return true }
}

/// 一行两个控件：长按 ≡ 拖动排序；点 ⇅ 用菜单做等价调整（不依赖手势，保证一定可用）。
struct EventSortControls: View {
    let id: String
    let index: Int
    let count: Int
    @Binding var draggingID: String?
    let onShift: (Int) -> Void
    let onPlaceAt: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppPalette.text.opacity(0.4))
                .frame(width: 15, height: 20)
                .contentShape(Rectangle())
                .onDrag {
                    draggingID = id
                    return NSItemProvider(object: id as NSString)
                }
                .help("按住拖动，调整事件顺序")
            Menu {
                Button("上移") { onShift(-1) }.disabled(index == 0)
                Button("下移") { onShift(1) }.disabled(index >= count - 1)
                Divider()
                Button("置顶") { onPlaceAt(0) }.disabled(index == 0)
                Button("置底") { onPlaceAt(count - 1) }.disabled(index >= count - 1)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppPalette.text.opacity(0.4))
                    .frame(width: 15, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(count < 2)
            .help("上移 / 下移 / 置顶 / 置底")
        }
        .fixedSize()
    }
}

struct DaysEventManager: View {
    @ObservedObject var model: EarnModel
    @ObservedObject private var ui = SettingsUIState.shared
    let kind: DaysEventKind
    @State private var draggingID: String? = nil

    private var count: Int {
        kind == .countdown ? model.countdowns.count : model.recordDays.count
    }
    private var open: Bool { ui.isEventManagerOpen(kind) }
    private var editingName: String? {
        guard ui.isEditing(kind) else { return nil }
        if kind == .countdown { return model.activeCountdown?.name }
        return model.activeRecordDay?.name
    }

    private var editing: Bool { ui.isEditing(kind) }

    var body: some View {
        VStack(spacing: 0) {
            head
            if open {
                if count == 0 { emptyHint.padding(.top, 6) } else { list.padding(.top, 6) }
                form.padding(.top, 8)
            }
        }
        .onAppear { ui.ensureFormMatches(kind) }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Glass.fill(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Glass.line(0.5), lineWidth: 1))
    }

    // MARK: 头部

    private var head: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { ui.toggleEventManager(kind) }
            } label: {
                HStack(spacing: 6) {
                    Text("事件管理")
                        .font(.system(size: 12.5, weight: .heavy))
                        .foregroundStyle(AppPalette.text)
                    Text("\(count) 项")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppPalette.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "收起事件管理" : "展开事件管理：新增 / 编辑已有事件 / 改名 / 改日期 / 删除")

            Spacer(minLength: 0)

            if open {
                Button { startNew() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                        Text(editing ? "新建" : "新增").font(.system(size: 10, weight: .heavy))
                    }
                    .foregroundStyle(AppPalette.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(AppPalette.accent.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(AppPalette.accent.opacity(0.38), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(editing ? "切回新增模式" : "清空表单，准备新增")
            }
        }
    }

    private var emptyHint: some View {
        Text(kind.emptyHint)
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 列表

    private var list: some View {
        ScrollView(.vertical, showsIndicators: count > 3) {
            VStack(spacing: 4) {
                if kind == .countdown {
                    ForEach(model.countdowns) { item in countdownRow(item) }
                } else {
                    ForEach(model.recordDays) { item in recordRow(item) }
                }
                if count > 1 {
                    Text("按住 ≡ 手柄拖动排序，或点 ⇅ 菜单上移 / 下移 / 置顶 / 置底")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 7)
                }
            }
            .padding(.vertical, 1)
        }
        .frame(height: min(CGFloat(count) * 38 + (count > 1 ? 14 : 2), 130))
        .clipped()
    }

    private func row(active: Bool,
                     onSelect: @escaping () -> Void,
                     name: Binding<String>,
                     onSubmit: @escaping () -> Void,
                     detail: String,
                     onDelete: @escaping () -> Void,
                     sort: EventSortControls? = nil) -> some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                Image(systemName: active ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(active ? AppPalette.accent : AppPalette.text.opacity(0.32))
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设为当前显示，并把这项载入下方编辑区")

            VStack(alignment: .leading, spacing: 1) {
                TextField("未命名", text: name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppPalette.text)
                    .onSubmit(onSubmit)
                Text(detail)
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let sort { sort }
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppPalette.text.opacity(0.42))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("删除这一项")
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(active ? Glass.fill(0.34) : Glass.fill(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(active ? AppPalette.accent.opacity(0.32) : Color.clear, lineWidth: 1))
    }

    private func countdownRow(_ item: CountdownItem) -> some View {
        let p = countdownProgress(item)
        let targetYear = item.year.map { "\($0)/" } ?? ""
        let timeText = item.hasCustomTime ? " " + item.targetTimeText : ""
        let stateText = p?.expired == true ? "已到期" : "还剩 \(p?.daysLeft ?? 0) 天"
        let idx = model.countdowns.firstIndex(where: { $0.id == item.id }) ?? 0
        return row(active: model.activeCountdownId == item.id,
                   onSelect: { selectCountdown(item) },
                   name: Binding(get: { item.name },
                                 set: { model.renameCountdown(id: item.id, to: $0) }),
                   onSubmit: { model.commitCountdownName(id: item.id) },
                   detail: "\(targetYear)\(item.month)/\(item.day)\(timeText) · \(stateText) · \(item.modeTitle)",
                   onDelete: { withAnimation { model.removeCountdown(id: item.id) } },
                   sort: EventSortControls(id: item.id, index: idx, count: model.countdowns.count,
                                           draggingID: $draggingID,
                                           onShift: { model.shiftCountdown(id: item.id, by: $0) },
                                           onPlaceAt: { model.placeCountdown(id: item.id, at: $0) }))
            .onDrop(of: [UTType.text],
                    delegate: EventReorderDropDelegate(
                        draggingID: $draggingID, targetID: item.id,
                        onPlaceBefore: { src, target in model.placeCountdown(id: src, before: target) }))
    }

    private func recordRow(_ item: RecordDayItem) -> some View {
        let p = recordDayProgress(item)
        let dateText = String(format: "%04d/%d/%d", item.year, item.month, item.day)
        let stateText = p?.started == true ? "累计 \(p?.span.shortText ?? "")" : "未开始"
        let idx = model.recordDays.firstIndex(where: { $0.id == item.id }) ?? 0
        return row(active: model.activeRecordDayId == item.id,
                   onSelect: { selectRecordDay(item) },
                   name: Binding(get: { item.name },
                                 set: { model.renameRecordDay(id: item.id, to: $0) }),
                   onSubmit: { model.commitRecordDayName(id: item.id) },
                   detail: "\(dateText) 起 · \(stateText)",
                   onDelete: { withAnimation { model.removeRecordDay(id: item.id) } },
                   sort: EventSortControls(id: item.id, index: idx, count: model.recordDays.count,
                                           draggingID: $draggingID,
                                           onShift: { model.shiftRecordDay(id: item.id, by: $0) },
                                           onPlaceAt: { model.placeRecordDay(id: item.id, at: $0) }))
            .onDrop(of: [UTType.text],
                    delegate: EventReorderDropDelegate(
                        draggingID: $draggingID, targetID: item.id,
                        onPlaceBefore: { src, target in model.placeRecordDay(id: src, before: target) }))
    }

    // MARK: 表单（新增 / 编辑同一套）

    private var form: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(editing ? "编辑" : "新增")
                    .font(.system(size: 9.5, weight: .heavy))
                    .foregroundStyle(editing ? AppPalette.accent : .secondary)
                    .frame(width: 24, alignment: .leading)
                TextField(kind == .countdown ? "名称，如 春节 / 项目上线" : "名称，如 在一起 / 入职", text: $ui.evName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppPalette.text)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Glass.fill(0.26)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Glass.line(0.45), lineWidth: 1))
            }
            if kind == .countdown {
                HStack(spacing: 5) {
                    tag("目标")
                    field("年选填", text: $ui.evYear, width: 52)
                    field("月", text: $ui.evMonth, width: 28)
                    field("日", text: $ui.evDay, width: 28)
                    field("时:分", text: $ui.evTime, width: 50)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    tag("起始")
                    field("年", text: $ui.evStartYear, width: 44)
                    field("月", text: $ui.evStartMonth, width: 28)
                    field("日", text: $ui.evStartDay, width: 28)
                    Text("留空 = 创建日")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 5) {
                    tag("起始")
                    field("年", text: $ui.evStartYear, width: 44)
                    field("月", text: $ui.evStartMonth, width: 28)
                    field("日", text: $ui.evStartDay, width: 28)
                    Text("累计到今天的时长")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    tag("节点")
                    field("每 N 天", text: $ui.evTarget, width: 50)
                    Text("留空 = 每 100 天一个里程碑")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 6) {
                chip("按天数", on: !ui.evPercent) { ui.evPercent = false }
                chip("按百分比", on: ui.evPercent) { ui.evPercent = true }
                Spacer(minLength: 0)
                Button { submit() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: editing ? "checkmark" : "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text(editing ? "保存" : "添加").font(.system(size: 11, weight: .heavy))
                    }
                    .foregroundStyle(AppPalette.onAccent)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(AppPalette.accent))
                }
                .buttonStyle(.plain)
            }
            if let err = ui.evError {
                Text(err)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let n = editingName {
                Text("正在编辑「\(n)」，改完点保存；点右上「新建」可切回新增。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func tag(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 9.5, weight: .heavy))
            .foregroundStyle(.secondary)
            .frame(width: 24, alignment: .trailing)
    }

    private func field(_ placeholder: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .multilineTextAlignment(.center)
            .foregroundStyle(AppPalette.text)
            .frame(width: width)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Glass.fill(0.26)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Glass.line(0.45), lineWidth: 1))
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(on ? AppPalette.onAccent : AppPalette.text.opacity(0.7))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(on
                    ? AnyShapeStyle(AppPalette.accent)
                    : AnyShapeStyle(Glass.fill(0.28))))
                .overlay(Capsule().strokeBorder(Glass.line(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: 选择 / 提交

    private func startNew() {
        ui.resetEventForm()
    }

    private func selectCountdown(_ item: CountdownItem) {
        model.setActiveCountdown(id: item.id)
        ui.loadCountdownForEditing(item)
    }

    private func selectRecordDay(_ item: RecordDayItem) {
        model.setActiveRecordDay(id: item.id)
        ui.loadRecordDayForEditing(item)
    }

    private func submit() {
        let name = ui.evName.trimmingCharacters(in: .whitespaces)
        let sy = Int(ui.evStartYear.trimmingCharacters(in: .whitespaces))
        let sm = Int(ui.evStartMonth.trimmingCharacters(in: .whitespaces))
        let sd = Int(ui.evStartDay.trimmingCharacters(in: .whitespaces))

        if kind == .countdown {
            let yText = ui.evYear.trimmingCharacters(in: .whitespaces)
            let m = Int(ui.evMonth.trimmingCharacters(in: .whitespaces)) ?? 0
            let d = Int(ui.evDay.trimmingCharacters(in: .whitespaces)) ?? 0
            let (hh, mm) = parseClock(ui.evTime)
            // 编辑已有事件时沿用原创建日，否则一次性倒计时的进度起点会被重置成今天
            let existing = editing ? model.activeCountdown : nil
            var item = CountdownItem(name: name, month: m, day: d,
                                     year: yText.isEmpty ? nil : Int(yText),
                                     mode: ui.evPercent ? "percent" : "days",
                                     createdKey: existing?.createdKey ?? dateKey(Date.now))
            item.startYear = sy; item.startMonth = sm; item.startDay = sd
            item.targetHour = hh; item.targetMinute = mm
            if editing, let id = model.activeCountdownId.isEmpty ? nil : model.activeCountdownId {
                if let err = model.updateCountdown(id: id, with: item) { ui.evError = err; return }
            } else {
                if let err = model.addCountdown(item) { ui.evError = err; return }
                if let last = model.countdowns.last { model.setActiveCountdown(id: last.id) }
            }
        } else {
            guard let y = sy, let m = sm, let d = sd else { ui.evError = "请填完整的起始年月日"; return }
            let targetText = ui.evTarget.trimmingCharacters(in: .whitespaces)
            let targetDays = targetText.isEmpty ? 0 : (Int(targetText) ?? -1)
            guard (0...100000).contains(targetDays) else {
                ui.evError = "里程碑天数请填 1–100000，留空按 100 天"; return
            }
            let item = RecordDayItem(name: name, year: y, month: m, day: d,
                                     targetDays: targetDays,
                                     mode: ui.evPercent ? "percent" : "days")
            if editing, !model.activeRecordDayId.isEmpty {
                if let err = model.updateRecordDay(id: model.activeRecordDayId, with: item) { ui.evError = err; return }
            } else {
                if let err = model.addRecordDay(item) { ui.evError = err; return }
                if let last = model.recordDays.last { model.setActiveRecordDay(id: last.id) }
            }
        }
        startNew()
    }

    private func parseClock(_ s: String) -> (Int?, Int?) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return (nil, nil) }
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return (nil, nil) }
        return (h, m)
    }
}


// MARK: - 薪酬二级页（原首页，2.1 起只服务薪酬口径）

struct SalaryDetailView: View {
    @ObservedObject var model: EarnModel

    private var info: ProgressInfo { model.progressInfo }

    var body: some View {
        VStack(spacing: 0) {
            header
            amountView
            progressZone
            if model.salary <= 0 && !model.privacyActive { goToSettingsHint }
            chips
            PunchButtons(model: model, includeOvertime: true)
            logLine
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 20)
    }

    // 2.1：工具条统一走共享组件，二级页多一个「返回首页」
    private var header: some View {
        AppHeader(model: model, mode: .salary) { withAnimation { model.page = .home } }
    }

    private var gainLayer: some View {
        ZStack {
            ForEach(model.gains) { g in
                Text("+¥0.01")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(redDeep)
                    .offset(x: g.xOffset, y: -18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var amountView: some View {
        VStack(spacing: 4) {
            Text(info.caption)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(info.leading)
                    .font(.system(size: info.isMoney ? 46 : 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(model.working || model.displayEarned > 0 || !info.isMoney
                                     ? redDeep : Color.secondary.opacity(0.4))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !info.trailing.isEmpty {
                    Text(info.trailing)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(model.working || model.displayEarned > 0 || !info.isMoney
                                         ? redDeep.opacity(0.75) : Color.secondary.opacity(0.4))
                }
            }
            .frame(height: 52, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { if !model.privacyActive { gainLayer } }
        .clipped()
    }

    // 金币进度条（2.0：统计内容可切换；超出 100% 的加班部分单独画第二段细条）
    private var progressZone: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Glass.fill(0.38))
                        .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
                        .frame(width: w, height: 12)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                    Capsule()
                        .fill(LinearGradient(colors: model.barColors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, w * info.fill), height: 12)
                        .shadow(color: model.accentB.opacity(0.45), radius: 6)
                }
                .frame(width: w, height: 12, alignment: .leading)
            }
            .frame(height: 14)
            // 加班 / 超额部分：不与主条重叠，另起一条橙色细进度，直观表达「超出 100% 的进度」
            if info.overflow > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.orange.opacity(0.16)).frame(height: 5)
                        Capsule()
                            .fill(LinearGradient(colors: [Color.orange.opacity(0.6), Color.orange],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, g.size.width * info.overflow), height: 5)
                    }
                }
                .frame(height: 5)
                .padding(.top, -3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(info.footer)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if info.overflow > 0 {
                    Text("+" + percentText(info.overflow))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.16)))
                        .fixedSize()
                }
                if !model.isButtonHidden(.metric) { metricMenu }
            }
        }
        .padding(.bottom, 12)
    }

    // 2.1：薪酬页只切 4 种薪酬/工时口径，倒计时任务不在这里出现
    private var metricMenu: some View {
        Menu {
            ForEach(ProgressMetric.salaryCases, id: \.self) { m in
                Button {
                    model.progressMetric = m
                    model.onMetricChanged()
                } label: {
                    Text(model.progressMetric == m ? "✓ \(m.title)" : m.title)
                }
            }
            Divider()
            Button("去日期倒计时") { withAnimation { model.page = .countdown } }
        } label: {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Glass.fill(0.35)))
                .overlay(Circle().strokeBorder(Glass.line(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("切换薪酬进度口径（当前：\(model.progressMetric.title)）")
    }

    private var chipOTText: String {
        // 隐私模式：加班时长不外露，只显示「超出 100% 的月度进度」
        if model.privacyActive {
            return "+" + percentText(max(0, model.monthHoursRatio - 1))
        }
        let m = Int(model.monthOTSeconds / 60)
        return m >= 60 ? "\(m/60)时\(m%60)分" : "\(m)分"
    }

    private var workedChipText: String {
        if model.privacyActive { return percentText(model.todayHoursRatio) }
        return model.workedMinutes >= 60
            ? "\(model.workedMinutes/60)时\(model.workedMinutes%60)分" : "\(model.workedMinutes)分"
    }

    // 未填月薪时引导去设置页
    private var goToSettingsHint: some View {
        Button(action: { withAnimation { model.page = .settings } }) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.fill").font(.system(size: 11))
                Text("去设置填写月薪，开始计费").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(redDeep)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(Glass.fill(0.4)))
            .overlay(Capsule().strokeBorder(redDeep.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 12)
    }

    // 2.1：薪酬页模块按自己的开关显隐，与倒计时页模块用两套独立配置
    private var chips: some View {
        let items = MoneyChip.allCases.filter { !model.isMoneyChipHidden($0) }
        let rows = stride(from: 0, to: items.count, by: 3)
            .map { Array(items[$0..<min($0 + 3, items.count)]) }
        return VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    ForEach(rows[i], id: \.self) { c in moneyChip(c) }
                    ForEach(0..<(3 - rows[i].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
            if items.isEmpty {
                Text("薪酬模块全被隐藏了：设置 → 薪酬进度 → 薪酬页模块可重新打开")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 10)
            }
        }
        .padding(.bottom, 14)
    }

    private func moneyChip(_ c: MoneyChip) -> some View {
        let hidden = model.privacyActive
        return Group {
            switch c {
            case .salary:
                IconChip(icon: "", value: model.salary > 0 ? model.displayMoney(model.salary, dec: 0) : "--", label: "月薪")
            case .workdays:
                IconChip(icon: "", value: "\(model.workDays) 天\(model.isAutoDays ? "" : "·手动")", label: "工作日/月")
            case .dayRate:
                IconChip(icon: "", value: model.salary > 0 ? model.displayMoney(model.ratePerDay) : "--", label: "日薪", highlight: true)
            case .hourRate:
                IconChip(icon: "", value: model.salary > 0 ? model.displayMoney(model.ratePerHour) : "--", label: "时薪")
            case .perSec:
                IconChip(icon: "", value: model.salary > 0 ? model.displayMoney(model.ratePerSec, dec: 4) : "--", label: "每秒进账", highlight: true)
            case .worked:
                IconChip(icon: "", value: workedChipText, label: hidden ? "今日进度" : "今日已工作")
            case .monthEarned:
                Button {
                    model.logText = hidden
                        ? "本月进度 \(percentText(model.monthHoursRatio))（含加班超出部分）"
                        : "本月累计进账 ¥\(fmt(model.monthEarned))，其中今日实时 ¥\(fmt(model.displayEarned))"
                } label: {
                    IconChip(icon: "",
                             value: hidden ? percentText(model.monthHoursRatio)
                                           : (model.salary > 0 ? "¥" + fmt(model.monthEarned) : "--"),
                             label: hidden ? "本月进度" : "本月累计进账", highlight: true)
                }
                .buttonStyle(.plain)
            case .monthOT:
                Button {
                    let m = model.monthOTSeconds / 60
                    model.logText = hidden
                        ? "加班已折算为超出 100% 的进度"
                        : (m >= 60
                           ? String(format: "本月累计加班 %d 小时 %d 分钟", Int(m) / 60, Int(m) % 60)
                           : "本月累计加班 \(Int(m)) 分钟")
                } label: {
                    IconChip(icon: "", value: chipOTText,
                             label: hidden ? "超出 100% 部分" : "本月加班时长")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // 2.2：打卡按钮统一走共享组件 PunchButtons；薪酬页多一个加班段按钮，
    // 首页只留两个快捷，Your Days 两页完全不加载打卡组件。
    private var logLine: some View {
        Text(model.logText)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
    }
}

// MARK: - 设置页

// 设置页内容高度测量（用于窗口高度自适应）
struct PageContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// 设置页内容高度测量（用于窗口高度自适应）
struct SettingsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// 设置页 UI 状态（折叠分组 / 流水查询输入）
// 用 ObservableObject 而非 @State：本机 swiftc 的 SwiftUI 宏插件在嵌套沙箱里起不来
final class SettingsUIState: ObservableObject {
    static let shared = SettingsUIState()
    @Published var openGroups: Set<String> = SettingsUIState.initialOpenGroups()
    @Published var queryStart = ""
    @Published var queryEnd = ""
    @Published var rows: [DayLogRow] = []
    @Published var addDate = ""
    @Published var addEarned = ""
    @Published var addOTMin = ""
    @Published var logError: String?
    // 2.0 设置页表单状态（同样避开 @State 宏）
    @Published var cdName = ""
    @Published var cdMonth = ""
    @Published var cdDay = ""
    @Published var cdYear = ""          // 空 = 每年重复
    @Published var cdPercent = false    // false = 按天数，true = 按百分比
    @Published var cdError: String?
    // 2.1 纪念日表单状态
    @Published var rdName = ""
    @Published var rdYear = ""
    @Published var rdMonth = ""
    @Published var rdDay = ""
    @Published var rdTarget = ""        // 空 = 自动 100 天里程碑
    @Published var rdPercent = false
    @Published var rdError: String?
    // 2.4 Your Days 事件管理：倒计时 / 纪念日共用一套表单字段。
    // evEditingKind 标记当前编辑的是哪一类；切到另一页时必须清掉，否则会把上一页的
    // 「正在编辑」状态串过去，提交时误改到另一类的当前选中项。
    @Published var eventManagerOpen: Set<String> = []
    @Published var evName = ""
    @Published var evYear = ""
    @Published var evMonth = ""
    @Published var evDay = ""
    @Published var evStartYear = ""
    @Published var evStartMonth = ""
    @Published var evStartDay = ""
    @Published var evTime = ""          // 目标时刻 HH:mm，留空 = 00:00
    @Published var evTarget = ""        // 纪念日里程碑天数，空 = 100 天
    @Published var evPercent = false
    @Published var evEditing = false    // true = 表单正在编辑当前选中项
    @Published var evEditingKind: String? = nil
    @Published var evError: String?
    @Published var privacyError: String?
    @Published var workdayError: String?
    @Published var contentHeight: CGFloat = 0   // 内容实际高度（折叠状态不同）→ 窗口自适应
    @Published var viewportHeight: CGFloat = 0  // SwiftUI 视口高度：始终等于窗口高度，避免溢出绘制
    @Published var pageHeights: [String: CGFloat] = [:]   // 首页/迷你条的内容自然高度（关掉 sizingOptions 后只能自己量）
    var forceHeight: CGFloat?                   // 导出截图时的高度上限
    var exportMode = false                      // 导出截图：按内容高度贴合，避免滚动裁切/居中留白

    // 2.1：按 Your Money / Your Days / 通用 三大分区组织，两个模块的配置互不串线
    static let allGroups = ["salary", "workdays", "time", "metric", "moneyChips", "correct", "ledger",
                            "countdown", "chips", "recordDay", "recordChips",
                            "theme", "layout", "buttons", "statusbar", "privacy", "look", "window", "about"]

    /// 设置页高度上限：2.4 起固定与首页等高，内容超出后在页内滚动，不再把窗口拉到近满屏
    static func maxViewport() -> CGFloat {
        if let f = shared.forceHeight { return f }
        if let s = ProcessInfo.processInfo.environment["XINXIN_SETTINGS_H"], let v = Double(s), v >= 400 {
            return CGFloat(v)
        }
        let screenCap = (NSScreen.main?.visibleFrame.height ?? 900) - 40
        let homeH = shared.pageHeights[Page.home.heightKey] ?? 0
        return min(screenCap, max(420, homeH >= 420 ? homeH : 620))
    }

    /// 目标视口高度（窗口与 SwiftUI 用同一个值，避免两者不一致导致内容溢出重叠）
    static func viewport(contentHeight h: CGFloat) -> CGFloat {
        let maxH = maxViewport()
        guard h > 1 else { return maxH * 0.6 }
        return min(maxH, max(376, h))
    }

    // 展开状态与真实数据同域存取（截图/演示可用 XINXIN_DEFAULTS_SUITE 隔离）
    static func store() -> UserDefaults {
        if let s = ProcessInfo.processInfo.environment["XINXIN_DEFAULTS_SUITE"],
           let u = UserDefaults(suiteName: s) { return u }
        return .standard
    }

    static func initialOpenGroups() -> Set<String> {
        if let saved = store().stringArray(forKey: "settingsOpenGroups") { return Set(saved) }
        return ["salary", "time"]
    }

    func toggleGroup(_ id: String) {
        if openGroups.contains(id) { openGroups.remove(id) } else { openGroups.insert(id) }
        Self.store().set(Array(openGroups), forKey: "settingsOpenGroups")
    }

    func toggleAllGroups() {
        openGroups = openGroups.count == Self.allGroups.count ? [] : Set(Self.allGroups)
        Self.store().set(Array(openGroups), forKey: "settingsOpenGroups")
    }

    // MARK: - 2.4 Your Days 事件管理

    func isEventManagerOpen(_ kind: DaysEventKind) -> Bool { eventManagerOpen.contains(kind.rawValue) }

    func toggleEventManager(_ kind: DaysEventKind) {
        if eventManagerOpen.contains(kind.rawValue) { eventManagerOpen.remove(kind.rawValue) }
        else { eventManagerOpen.insert(kind.rawValue) }
        evError = nil
    }

    func openEventManager(_ kind: DaysEventKind) {
        eventManagerOpen.insert(kind.rawValue)
    }

    func resetEventForm() {
        evName = ""; evYear = ""; evMonth = ""; evDay = ""
        evStartYear = ""; evStartMonth = ""; evStartDay = ""
        evTime = ""; evTarget = ""; evError = nil
        evPercent = false
        evEditing = false
        evEditingKind = nil
    }

    func isEditing(_ kind: DaysEventKind) -> Bool {
        evEditing && evEditingKind == kind.rawValue
    }

    /// 二级页出现时调用：表单若属于另一类事件，就退回干净的新增态
    func ensureFormMatches(_ kind: DaysEventKind) {
        if let k = evEditingKind, k != kind.rawValue { resetEventForm() }
    }

    /// 把已有倒计时载入编辑表单（设置页与二级页事件管理共用）
    func loadCountdownForEditing(_ item: CountdownItem) {
        evName = item.name
        evYear = item.year.map(String.init) ?? ""
        evMonth = "\(item.month)"
        evDay = "\(item.day)"
        evStartYear = item.startYear.map(String.init) ?? ""
        evStartMonth = item.startMonth.map(String.init) ?? ""
        evStartDay = item.startDay.map(String.init) ?? ""
        evTime = item.hasCustomTime ? item.targetTimeText : ""
        evTarget = ""
        evPercent = item.mode == "percent"
        evEditing = true
        evEditingKind = DaysEventKind.countdown.rawValue
        evError = nil
    }

    /// 把已有纪念日载入编辑表单；显示方式与里程碑步长也要回填，编辑保存才不会被重置
    func loadRecordDayForEditing(_ item: RecordDayItem) {
        evName = item.name
        evYear = ""; evMonth = ""; evDay = ""; evTime = ""
        evStartYear = "\(item.year)"
        evStartMonth = "\(item.month)"
        evStartDay = "\(item.day)"
        evTarget = item.targetDays > 0 ? "\(item.targetDays)" : ""
        evPercent = item.mode == "percent"
        evEditing = true
        evEditingKind = DaysEventKind.anniversary.rawValue
        evError = nil
    }
}

struct SettingsView: View {
    @ObservedObject var model: EarnModel
    @ObservedObject private var ui = SettingsUIState.shared
    @State private var draggingCountdownID: String? = nil
    @State private var draggingRecordID: String? = nil

    var body: some View {
        Group {
            if ui.exportMode {
                settingsScroll.frame(maxHeight: settingsMaxHeight)
            } else {
                settingsScroll.frame(height: ui.viewportHeight > 1
                                    ? ui.viewportHeight
                                    : SettingsUIState.viewport(contentHeight: ui.contentHeight))
            }
        }
        .clipped()   // 动画中间帧兜底：溢出内容裁在滚动区内，绝不画到别的卡片上
    }

    private var settingsScroll: some View {
        ScrollView {
            VStack(spacing: 8) {
                // 标题栏 + 全部展开/折叠
                HStack(spacing: 6) {
                    Text("设置").font(.system(size: 19, weight: .heavy))
                    Spacer()
                    GlassIconButton(symbol: ui.openGroups.count == SettingsUIState.allGroups.count
                                    ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                                    help: ui.openGroups.count == SettingsUIState.allGroups.count ? "全部折叠" : "全部展开") {
                        toggleAllGroups()
                    }
                    GlassIconButton(symbol: "chevron.left", help: "返回") { withAnimation { model.page = .home } }
                }
                .padding(.bottom, 2)

                sectionLabel("Your Money", trailing: "薪酬进度 · 只作用于薪酬卡与薪酬页")

                // MARK: 薪酬与工作天数
                group("salary", icon: "", title: "薪酬与工作天数",
                      summary: model.privacyActive ? "已隐藏"
                        : (model.salary > 0 ? "¥\(fmt(model.salary, 0))/月 · \(model.workDays) 天" : "未设置"),
                      locked: true) {
                    fieldLabel("每月税后工资")
                    HStack(spacing: 6) {
                        Text("¥").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                        TextField("输入每月税后工资", text: $model.salaryText).textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .semibold))
                        Text("/月").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Glass.fill(0.3)))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Glass.line(0.55), lineWidth: 1))

                    fieldLabel("每月工作天数", trailing: "自动 \(model.autoDays) 天")
                    HStack(spacing: 6) {
                        TextField("自动 \(model.autoDays) 天（按法定节假日）", text: $model.workDaysText)
                            .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold))
                        Text("天").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Glass.fill(0.3)))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Glass.line(0.55), lineWidth: 1))

                    caption("留空则按「每周工作日」规则自动算（当前 \(model.autoDays) 天）；填数字则直接按该天数计薪。2.0 起跨月自动重算。")
                }

                // MARK: 每周工作日（2.0）
                group("workdays", icon: "", title: "每周工作日",
                      summary: "\(model.workDays) 天/月" + (model.isAutoDays ? " · 自动" : " · 手动")) {
                    fieldLabel("哪些天算工作日", trailing: "本月自动 \(model.autoDays) 天")
                    weekdayChips()
                    if let err = ui.workdayError { warnLine(err) }

                    fieldLabel("法定节假日口径",
                               trailing: model.useLegalHolidays ? "叠加节假日" : "只看勾选")
                    switchRow(icon: model.useLegalHolidays ? "calendar.badge.checkmark" : "calendar",
                              on: model.useLegalHolidays,
                              title: "叠加国办法定节假日 / 调休补班",
                              detail: "开启：按勾选的周几算，再扣法定节假日、加调休补班；关闭：完全按勾选的周几算，适合轮班 / 单双休",
                              binding: Binding(get: { model.useLegalHolidays },
                                               set: { model.useLegalHolidays = $0 })) {
                        model.onWorkdayRuleChanged()
                    }
                    caption("1.x 只在启动时算一次工作日，跨月会一直用旧值；2.0 起按月实时重算，改规则后费率立即跟着更新。上面「每月工作天数」手填的数字优先级更高。")
                }

                // MARK: 工作时间 · 自动打卡
                group("time", icon: "", title: "工作时间 · 自动打卡",
                      summary: "\(model.workStartText)–\(model.workEndText) · \(String(format: "%.1f", model.effectiveHours))h") {
                    fieldLabel("每日工作时长", trailing: String(format: "= %.1f 小时/天", model.effectiveHours))
                    // 两行排布：一行放三个输入框会超出卡片内宽，被压缩后看着就是“变形”
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            scheduleField(label: "上班", text: $model.workStartText, placeholder: "09:00", width: 58)
                            scheduleField(label: "下班", text: $model.workEndText, placeholder: "18:00", width: 58)
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 8) {
                            scheduleField(label: "休息", text: $model.breakMinText, placeholder: "60", width: 46, unit: "分钟")
                            scheduleField(label: "从", text: $model.breakStartText, placeholder: "12:00", width: 50)
                            Spacer(minLength: 0)
                        }
                    }

                    caption("实际计费工时 = 下班 − 上班 − 休息，默认 09:00–18:00 休 60 分钟即 8 小时。费率 = 月薪 ÷ 工作日 ÷ 实际工时。支持跨零点（如 22:00–06:00）。")

                    fieldLabel("自动打卡", trailing: model.autoInEnabled && model.autoOutEnabled ? "上下班都自动"
                                                    : (model.autoInEnabled ? "仅自动上班"
                                                       : (model.autoOutEnabled ? "仅自动下班" : "均已关闭")))
                    VStack(spacing: 6) {
                        switchRow(icon: model.autoInEnabled ? "sunrise.fill" : "sunrise",
                                  on: model.autoInEnabled,
                                  title: "到上班时间自动打卡",
                                  detail: "进入工作时间后自动开始计费；错过整点启动则从中途起算，不白送工时",
                                  binding: $model.autoInEnabled) {
                            model.onAutoInChanged()
                        }
                        switchRow(icon: model.autoOutEnabled ? "alarm.waves.left.and.right.fill" : "moon.zzz",
                                  on: model.autoOutEnabled,
                                  title: "到下班时间自动打卡",
                                  detail: "自动下班后再打卡计为加班，首页显示「加班中」",
                                  binding: $model.autoOutEnabled) {
                            model.onAutoOutChanged()
                        }
                    }
                }

                // MARK: 薪酬进度口径（只作用于 Your Money）
                group("metric", icon: "", title: "薪酬进度口径",
                      summary: model.progressMetric.title) {
                    ForEach(ProgressMetric.salaryCases, id: \.self) { m in
                        Button {
                            model.progressMetric = m
                            model.onMetricChanged()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: model.progressMetric == m ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(model.progressMetric == m ? redDeep : .secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.title).font(.system(size: 12, weight: .semibold))
                                    Text(m.detail)
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                        .lineLimit(1).minimumScaleFactor(0.7)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Glass.fill(model.progressMetric == m ? 0.45 : 0.2)))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Glass.line(model.progressMetric == m ? 0.7 : 0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    caption("只影响 Your Money 的进度条（首页薪酬卡 + 薪酬二级页）。Your Days 的倒计时 / 纪念日在下面单独配置，两边互不干扰。")
                }

                // MARK: 薪酬页模块（Your Money 专属开关）
                group("moneyChips", icon: "", title: "薪酬页模块",
                      summary: "\(MoneyChip.allCases.count - model.hiddenMoneyChips.count)/\(MoneyChip.allCases.count) 个显示") {
                    ForEach(MoneyChip.allCases, id: \.self) { c in
                        switchRow(icon: model.isMoneyChipHidden(c) ? "square.dashed" : "checkmark.square.fill",
                                  on: !model.isMoneyChipHidden(c),
                                  title: c.title, detail: c.detail,
                                  binding: Binding(get: { !model.isMoneyChipHidden(c) },
                                                   set: { _ in model.toggleMoneyChip(c) })) { }
                    }
                    caption("只控制薪酬二级页的芯片。倒计时页、纪念日页各有自己独立的模块开关，改这里不会影响它们。")
                }

                // MARK: 工时校正
                group("correct", icon: "", title: "工时校正",
                      summary: model.privacyActive ? "已隐藏"
                        : String(format: "今日已计 %.1f 小时", model.totalWorkedHours),
                      locked: true) {
                    HStack(spacing: 8) {
                        TextField("如 5.5", text: $model.manualHoursText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .frame(width: 60)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Glass.fill(0.3)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Glass.line(0.5), lineWidth: 1))
                        Text("小时").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button {
                            model.correctWork(hours: Double(model.manualHoursText) ?? -1)
                            model.manualHoursText = ""
                        } label: {
                            Text("✓ 校正")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .background(Capsule().fill(Glass.fill(0.42)))
                        .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
                        .disabled((Double(model.manualHoursText) ?? -1) < 0)
                        .opacity((Double(model.manualHoursText) ?? -1) >= 0 ? 1 : 0.62)
                        Spacer()
                        Text("当前已计 \(String(format: "%.1f", model.totalWorkedHours)) 小时")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Glass.fill(0.24)))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Glass.line(0.5), lineWidth: 1))

                    caption("填今天实际工作的总小时数（0–24，多了少了都行），App 会与已计工时求差额并按当前费率补记或核减。适合忘打卡、中途外出、加班补差。")
                }

                // MARK: 流水明细
                group("ledger", icon: "", title: "流水明细",
                      summary: "共 \(model.dayLogTotal) 天 · 可查询/增删",
                      locked: true) {
                    fieldLabel("按日期范围查询")
                    HStack(spacing: 6) {
                        logField("开始 2026-11-01", text: $ui.queryStart, width: 96)
                        Text("至").font(.system(size: 11)).foregroundStyle(.secondary)
                        logField("结束 2026-11-30", text: $ui.queryEnd, width: 96)
                        Button { runLogQuery() } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 30, height: 26)
                        }
                        .buttonStyle(.plain)
                        .background(Capsule().fill(Glass.fill(0.42)))
                        .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
                        .help("按日期范围查询")
                    }
                    if let msg = ui.logError {
                        Text(msg)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(redDeep)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    if ui.rows.isEmpty {
                        Text("暂无流水记录（每天下班 / 跨天时自动落账）")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Glass.fill(0.18)))
                            .padding(.top, 6)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(ui.rows) { r in
                                HStack(spacing: 8) {
                                    Text(String(r.key.dropFirst(5)).replacingOccurrences(of: "-", with: "/"))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 40, alignment: .leading)
                                    Text(r.key).font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary.opacity(0.7))
                                    Spacer(minLength: 0)
                                    Text("¥" + fmt(r.earned))
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundStyle(redDeep)
                                    Text(r.otSeconds >= 60 ? "加班 \(Int(r.otSeconds / 60)) 分" : "—")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 50, alignment: .trailing)
                                    Button { model.removeDayLog(r.key); runLogQuery() } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 22, height: 22)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("删除 \(r.key) 的记录")
                                }
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Glass.fill(0.2)))
                            }
                        }
                        .padding(.top, 6)
                    }
                    fieldLabel("手动补记 / 新增")
                    HStack(spacing: 6) {
                        logField("日期 2026-11-03", text: $ui.addDate, width: 100)
                        logField("进账 ¥", text: $ui.addEarned, width: 56)
                        logField("加班分", text: $ui.addOTMin, width: 42)
                        Button { addLogRow() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 30, height: 26)
                        }
                        .buttonStyle(.plain)
                        .background(Capsule().fill(Glass.fill(0.42)))
                        .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
                        .help("手动添加该日流水")
                    }
                    caption("补记忘记打卡的日子，或删除错误的记录；进账留 0 表示只记加班。今日金额以实时打卡为准。")
                }

                sectionLabel("Your Days", trailing: "倒计时 + 纪念日 · 两个独立二级页")

                // MARK: 倒计时任务（Your Days）
                group("countdown", icon: "", title: "日期倒计时",
                      summary: "\(model.countdowns.count) 条 · 按天走数") {
                    if model.countdowns.isEmpty {
                        Text("还没有倒计时。加一个新年 / 生日 / 纪念日，进度条就能按天走数。")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Glass.fill(0.18)))
                    } else {
                        VStack(spacing: 4) {
                            ForEach(model.countdowns) { c in countdownRow(c) }
                            if model.countdowns.count > 1 {
                                Text("按住 ≡ 手柄拖动排序，或点 ⇅ 菜单上移 / 下移 / 置顶 / 置底")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                            }
                        }
                        .padding(.top, 4)
                    }

                    fieldLabel("新增倒计时", trailing: "年份留空 = 每年重复")
                    HStack(spacing: 5) {
                        logField("名称", text: $ui.cdName, width: 84)
                        logField("月", text: $ui.cdMonth, width: 30)
                        logField("日", text: $ui.cdDay, width: 30)
                        logField("年选填", text: $ui.cdYear, width: 58)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        modeOption("按天数", on: !ui.cdPercent) { ui.cdPercent = false }
                        modeOption("按百分比", on: ui.cdPercent) { ui.cdPercent = true }
                        Spacer(minLength: 0)
                        Button { addCountdownTapped() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                                Text("添加").font(.system(size: 11, weight: .semibold))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .background(Capsule().fill(redDeep.opacity(0.16)))
                        .overlay(Capsule().strokeBorder(redDeep.opacity(0.42), lineWidth: 1))
                    }
                    .padding(.top, 6)
                    if let err = ui.cdError { warnLine(err) }
                    caption("按天维度走数：天数模式大字显示「还剩 N 天」，百分比模式显示「已走 X%」，进度条都按起点→目标日的自然日推进。年度重复起点是上一次同月同日，一次性目标起点是添加当天。")
                }

                // MARK: 倒计时页模块（Your Days 专属开关）
                group("chips", icon: "", title: "倒计时页模块",
                      summary: "\(CountdownChip.allCases.count - model.hiddenCountdownChips.count)/\(CountdownChip.allCases.count) 个显示") {
                    ForEach(CountdownChip.allCases, id: \.self) { c in
                        switchRow(icon: model.isCountdownChipHidden(c) ? "square.dashed" : "checkmark.square.fill",
                                  on: !model.isCountdownChipHidden(c),
                                  title: c.title, detail: c.detail,
                                  binding: Binding(get: { !model.isCountdownChipHidden(c) },
                                                   set: { _ in model.toggleCountdownChip(c) })) { }
                    }
                    caption("只控制倒计时二级页的 6 个模块，和薪酬页、纪念日页的模块开关完全独立。")
                }

                // MARK: 纪念日任务（Your Days）
                group("recordDay", icon: "", title: "纪念日",
                      summary: "\(model.recordDays.count) 条 · 按天累计") {
                    if model.recordDays.isEmpty {
                        Text("还没有纪念日。加一个起始日期，就能看到「已经一起走过 N 天」。")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Glass.fill(0.18)))
                    } else {
                        VStack(spacing: 4) {
                            ForEach(model.recordDays) { c in recordDayRow(c) }
                            if model.recordDays.count > 1 {
                                Text("按住 ≡ 手柄拖动排序，或点 ⇅ 菜单上移 / 下移 / 置顶 / 置底")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                            }
                        }
                        .padding(.top, 4)
                    }
                    fieldLabel("新增纪念日", trailing: "起始日 → 今天的累计时长")
                    HStack(spacing: 5) {
                        logField("名称", text: $ui.rdName, width: 76)
                        logField("年", text: $ui.rdYear, width: 44)
                        logField("月", text: $ui.rdMonth, width: 28)
                        logField("日", text: $ui.rdDay, width: 28)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Button { addRecordDayTapped() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                                Text("添加").font(.system(size: 11, weight: .semibold))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .background(Capsule().fill(redDeep.opacity(0.16)))
                        .overlay(Capsule().strokeBorder(redDeep.opacity(0.42), lineWidth: 1))
                    }
                    .padding(.top, 6)
                    if let err = ui.rdError { warnLine(err) }
                    caption("与倒计时方向相反：倒计时看「还剩几天」，纪念日看「已经过了几天」。进度条按当前 100 天里程碑走数，也可以自定义目标天数。")
                }

                // MARK: 纪念日页模块（Your Days 专属开关）
                group("recordChips", icon: "", title: "纪念日页模块",
                      summary: "\(RecordDayChip.allCases.count - model.hiddenRecordDayChips.count)/\(RecordDayChip.allCases.count) 个显示") {
                    ForEach(RecordDayChip.allCases, id: \.self) { c in
                        switchRow(icon: model.isRecordDayChipHidden(c) ? "square.dashed" : "checkmark.square.fill",
                                  on: !model.isRecordDayChipHidden(c),
                                  title: c.title, detail: c.detail,
                                  binding: Binding(get: { !model.isRecordDayChipHidden(c) },
                                                   set: { _ in model.toggleRecordDayChip(c) })) { }
                    }
                    caption("只控制纪念日二级页的 6 个模块，和倒计时页、薪酬页的模块开关完全独立。")
                }

                sectionLabel("通用与外观", trailing: "主题 / 布局 / 按钮 / 隐私 / 图标")

                // MARK: 主题与配色（2.2）
                group("theme", icon: "", title: "主题与配色",
                      summary: model.currentTheme.title) {
                    fieldLabel("预设主题", trailing: "选完仍可继续调色")
                    ForEach(AppTheme.allCases, id: \.self) { t in
                        Button { model.selectTheme(t) } label: {
                            HStack(spacing: 8) {
                                Text(t.icon).font(.system(size: 15))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).font(.system(size: 11.5, weight: .bold))
                                    Text(t.detail).font(.system(size: 9.5))
                                        .foregroundStyle(.secondary).lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 4)
                                HStack(spacing: 3) {
                                    ForEach(t.swatches.indices, id: \.self) { i in
                                        Circle().fill(t.swatches[i]).frame(width: 9, height: 9)
                                            .overlay(Circle().strokeBorder(Glass.line(0.8), lineWidth: 1))
                                    }
                                }
                                Image(systemName: model.currentTheme == t ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(model.currentTheme == t ? redDeep : .secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Glass.level(model.currentTheme == t ? 4 : 1)))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(model.currentTheme == t ? redDeep.opacity(0.55) : Glass.line(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    fieldLabel("色卡微调", trailing: "无极调节 · 立即生效")
                    themeColorRow("背景颜色", model.themeColorBinding(0))
                    themeColorRow("文本颜色", model.themeColorBinding(1))
                    themeColorRow("重点 / 开关颜色", model.themeColorBinding(2))

                    fieldLabel("背景透明度", trailing: "\(Int(model.themeAlpha * 100))%")
                    Slider(value: Binding(get: { model.themeAlpha },
                                          set: { model.setThemeAlpha($0) }), in: 0.15...1.0)
                        .controlSize(.small).tint(redDeep)
                    HStack(spacing: 8) {
                        Button { model.resetTheme() } label: {
                            Text("恢复当前主题默认").font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 11).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .background(Capsule().fill(Glass.fill(0.4)))
                        .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
                        Button { model.useIconAccent() } label: {
                            Text("吸取图标主色").font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 11).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .background(Capsule().fill(Glass.fill(0.4)))
                        .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                    caption("四款预设只是起点：选完仍可用色卡连续调背景 / 文本 / 重点开关色，透明度单独一个滑块。Liquid Glass 是透明玻璃（可调透出桌面的程度），其余三款为实色主题。改动立即生效，只保存在本机。")
                }

                // MARK: 首页布局（三张独立进度卡）
                group("layout", icon: "", title: "首页布局",
                      summary: "\(HomeCard.allCases.count - model.hiddenHomeCards.count)/\(HomeCard.allCases.count) 张显示") {
                    ForEach(HomeCard.allCases, id: \.self) { c in
                        switchRow(icon: model.isHomeCardHidden(c) ? "square.dashed" : "checkmark.square.fill",
                                  on: !model.isHomeCardHidden(c),
                                  title: c.title, detail: c.detail,
                                  binding: Binding(get: { !model.isHomeCardHidden(c) },
                                                   set: { _ in model.toggleHomeCard(c) })) { }
                    }
                    if let g = model.homeCardGuard { warnLine(g) }
                    caption("首页至少要保留一个模块，关到最后一张会被自动拦下，避免出现空白首页。每张卡只显示自己那条进度，点进去才是对应模式的详情页；隐藏卡片不会删除任何数据。")
                }

                // MARK: 首页按钮（2.0）
                group("buttons", icon: "", title: "首页按钮",
                      summary: "已隐藏 \(model.hiddenButtons.count) 个") {
                    ForEach(HomeButton.allCases, id: \.self) { b in
                        switchRow(icon: model.isButtonHidden(b) ? "eye.slash" : "eye",
                                  on: !model.isButtonHidden(b),
                                  title: b.title, detail: b.detail,
                                  binding: Binding(get: { !model.isButtonHidden(b) },
                                                   set: { _ in model.toggleButton(b) })) { }
                    }
                    caption("关掉只是从首页隐藏，不是停用：打卡仍可从状态栏菜单操作，设置也能从状态栏菜单进入，窗口用 ⌘Q 退出。")
                }

                // MARK: 隐私模式（2.0）
                group("privacy", icon: "", title: "隐私模式",
                      summary: model.privacyEnabled
                        ? (model.privacyActive ? "已开启 · 只显示百分比" : "临时查看中") : "未开启") {
                    switchRow(icon: model.privacyEnabled ? "lock.fill" : "lock.open",
                              on: model.privacyEnabled,
                              title: "隐藏工资数字，改用百分比进度",
                              detail: "首页 / 芯片 / 迷你条 / 状态栏 / 小组件的金额全部改为进度：8 小时=100%，加班 4 小时=额外 50% → 150%；月度同理",
                              binding: Binding(get: { model.privacyEnabled },
                                               set: { want in
                                                   if want { enablePrivacyTapped() }
                                                   else { disablePrivacyTapped() }
                                               })) { }
                    if model.privacyEnabled {
                        HStack(spacing: 8) {
                            Button { changePINTapped() } label: {
                                Text("修改密码").font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .background(Capsule().fill(Glass.fill(0.4)))
                            .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))

                            Button {
                                if requirePIN(model: model, title: "临时查看",
                                              message: "输入 4 位密码，60 秒后自动恢复百分比显示") {
                                    model.unlockTemporarily()
                                }
                            } label: {
                                Text("临时查看 60 秒").font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .background(Capsule().fill(Glass.fill(0.4)))
                            .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 8)
                    }
                    if let err = ui.privacyError { warnLine(err) }
                    caption("密码为 4 位数字，只在本机保存加盐 SHA-256 哈希，不存明文、不联网。关闭隐私 / 临时查看 / 改密码都要验密码。忘记密码无法找回：退出 App 后执行 defaults delete com.haofan.xiaoxinxin pinHash 再启动即可重置隐私设置（不影响工资数据）。")
                }

                // MARK: 菜单栏（状态栏）显示（2.3）
                group("statusbar", icon: "", title: "菜单栏显示",
                      summary: model.statusBarShowData
                        ? model.selectedStatusBarKinds.map { $0.short }.joined(separator: " · ")
                        : "只显示图标") {
                    barPreview()

                    switchRow(icon: "menubar.rectangle",
                              on: model.statusBarShowData,
                              title: "菜单栏常显数据",
                              detail: "关闭后只在「收缩至状态栏」时显示，平时只留一个小图标",
                              binding: $model.statusBarShowData) {
                        model.onStatusBarDisplayChanged()
                    }

                    fieldLabel("显示内容", trailing: "可多选 · 至少保留一项")
                    HStack(spacing: 7) {
                        barKindChip(.moneyToday)
                        barKindChip(.moneyMonth)
                    }
                    HStack(spacing: 7) {
                        barKindChip(.moneyTodayPct)
                        barKindChip(.moneyMonthPct)
                    }
                    HStack(spacing: 7) {
                        barKindChip(.daysCountdown)
                        barKindChip(.daysRecord)
                    }
                    if let g = model.statusBarGuard { warnLine(g) }

                    switchRow(icon: "arrow.triangle.2.circlepath",
                              on: model.statusBarRotate,
                              title: "滚动显示",
                              detail: model.selectedStatusBarKinds.count > 1
                                  ? "在所选项之间轮流切换，不用点开就能看全"
                                  : "先多选几项再开；只选一项时不需要滚动",
                              binding: $model.statusBarRotate) {
                        model.onStatusBarDisplayChanged()
                    }

                    if model.selectedStatusBarKinds.count > 1 && model.statusBarRotate {
                        fieldLabel("切换间隔", trailing: "每 \(Int(model.statusBarRotateSeconds)) 秒")
                        HStack(spacing: 7) {
                            ForEach([3.0, 5.0, 8.0, 12.0], id: \.self) { s in
                                Button {
                                    model.statusBarRotateSeconds = s
                                    model.onStatusBarDisplayChanged()
                                } label: {
                                    Text("\(Int(s))s")
                                        .font(.system(size: 11, weight: .heavy))
                                        .frame(width: 42, height: 26)
                                }
                                .buttonStyle(.plain)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Glass.fill(model.statusBarRotateSeconds == s ? 0.6 : 0.24)))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Glass.line(model.statusBarRotateSeconds == s ? 0.75 : 0.45),
                                                  lineWidth: 1))
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    switchRow(icon: "chart.bar.fill",
                              on: model.statusBarShowBar,
                              title: "数值前带迷你进度条",
                              detail: "MONEY 类显示今日进度条；DAYS 类只有数字，不画条",
                              binding: $model.statusBarShowBar) {
                        model.onStatusBarDisplayChanged()
                    }

                    fieldLabel("金额前缀符号", trailing: model.barSymbol.isEmpty ? "当前：仅数字" : "当前：\(model.barSymbol)")
                    HStack(spacing: 8) {
                        TextField("留空=仅数字", text: $model.barSymbol)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .frame(width: 78)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Glass.fill(0.3)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Glass.line(0.5), lineWidth: 1))
                            .onChange(of: model.barSymbol) { _ in model.onBarSymbolChanged() }
                        ForEach(["¥", "%", "·", "•", ""], id: \.self) { e in
                            Button { model.barSymbol = e; model.onBarSymbolChanged() } label: {
                                Text(e.isEmpty ? "空" : e).font(.system(size: e.isEmpty ? 12 : 15))
                                    .frame(width: 30, height: 28)
                            }
                            .buttonStyle(.plain)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Glass.fill(model.barSymbol == e ? 0.6 : 0.24)))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Glass.line(model.barSymbol == e ? 0.75 : 0.45), lineWidth: 1))
                        }
                    }
                    caption("有内容在菜单栏显示时不显示图标（纯文字更干净）；全部关掉后会自动改回 App 图标。左侧小字 MONEY / DAYS 标明这一项属于薪酬还是天数；隐私模式下金额自动换成百分比，天数类不受影响。改完立刻生效，右键点菜单栏也能快速切换。")
                }

                // MARK: 外观与图标
                group("look", icon: "", title: "外观与图标",
                      summary: model.iconImage != nil ? "自定义图标" : "默认金币") {
                    fieldLabel("进度条图标")
                    HStack(spacing: 12) {
                        if let img = model.iconImage {
                            Image(nsImage: img).resizable().scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                                .overlay(Circle().strokeBorder(Glass.line(0.9), lineWidth: 2.5))
                                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        }
                        VStack(spacing: 6) {
                            Button { uploadIcon() } label: {
                                Text("上传自定义图标")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .background(Capsule().fill(Glass.fill(0.42)))
                            .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))

                            Button { model.setCustomIcon(nil) } label: {
                                Text("恢复默认金币")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .background(Capsule().fill(Glass.fill(0.42)))
                            .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
                        }
                    }
                    caption("图标自动裁圆。想把图标主色用作进度条与开关色，去「主题与配色」点「吸取图标主色」。金额前缀符号在「菜单栏显示」里设置。")
                }

                // MARK: 窗口行为
                group("window", icon: "", title: "窗口与启动",
                      summary: (model.closeBehavior == "quit" ? "关闭=退出" : "关闭=收纳状态栏")
                               + (model.launchAtLogin ? " · 开机启动" : "")) {
                    fieldLabel("点击关闭按钮时")
                    HStack(spacing: 8) {
                        closeOption("收纳到状态栏", value: "hide", icon: "dock.rectangle")
                        closeOption("直接退出", value: "quit", icon: "power")
                    }
                    caption("收纳到状态栏：小窗隐藏，状态栏图标继续显示金额与进度，点击随时恢复。直接退出：结束 App，今日累计会保留到下次打开。")

                    fieldLabel("开机自启动", trailing: model.launchAtLogin ? "已开启" : "已关闭")
                    switchRow(icon: model.launchAtLogin ? "power.circle.fill" : "power.circle",
                              on: model.launchAtLogin,
                              title: "登录后自动启动",
                              detail: "开机登录时静默启动并停在状态栏，不弹主窗；关掉不影响当前这次运行",
                              binding: $model.launchAtLogin) {
                        model.launchAtLoginError = model.onLaunchAtLoginChanged()
                    }
                    if let err = model.launchAtLoginError {
                        warnLine(err)
                    } else if LaunchAtLogin.needsApproval {
                        warnLine("登录项已登记，还需到「系统设置 → 通用 → 登录项」允许分刻。")
                    }
                    caption("配合「工作时间 · 自动打卡」可实现开机后到点自动开始计费，不用每天手动点打卡。")
                }


                // 2.2.1 版本与版权：作者信息 + Sony 30th 声明 + 主题/版权迭代记录
                group("about", icon: "", title: "版本与版权",
                      summary: "v\(APP_VERSION) · \(APP_RELEASE_DATE)") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("开发者")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Text(DEV_NAME)
                            .font(.system(size: 16, weight: .heavy)).foregroundStyle(redDeep)
                        Spacer(minLength: 0)
                        Button("关于面板") { showAboutPanel() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(redDeep)
                    }
                    Text(DEV_TAGLINE).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Divider().padding(.vertical, 6)
                    Text("v\(APP_VERSION) · Build \(APP_BUILD) · \(APP_RELEASE_DATE)")
                        .font(.system(size: 11.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(redDeep)
                    Text(APP_COPYRIGHT_LINE).font(.system(size: 10.5, weight: .medium))
                        .padding(.top, 3)
                    caption(SONY_COPYRIGHT_NOTICE)
                    Divider().padding(.vertical, 6)
                    fieldLabel("主题与版权声明迭代记录")
                    ForEach(RELEASE_HISTORY) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("v\(r.version) · Build \(r.build) · \(r.date)")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(redDeep)
                            Text(r.theme).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(r.copyright).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.top, 8)

                // 开发者署名（点击查看关于）
                Button { showAboutPanel() } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(redDeep.opacity(0.42))
                            .frame(width: 5, height: 5)
                        Text(DEV_NAME)
                            .font(.system(size: 11, weight: .bold)).tracking(2.4)
                            .foregroundStyle(Color.primary.opacity(0.42))
                        Text("DEVELOPER")
                            .font(.system(size: 8, weight: .bold)).tracking(1.1)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Glass.fill(0.3)))
                    .overlay(Capsule().strokeBorder(Glass.line(0.62), lineWidth: 1))
                    .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
                }
                .buttonStyle(.plain)
                .help("关于 分刻 · Countmin · 开发者 \(DEV_NAME)")
                .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(GeometryReader { g in
                Color.clear.preference(key: SettingsContentHeightKey.self, value: g.size.height)
            })
        }
        .onPreferenceChange(SettingsContentHeightKey.self) { h in
            if abs(h - ui.contentHeight) > 1 {
                ui.contentHeight = h
                // 内容高度变了（折叠/展开）→ 同一时刻贴合窗口，避免中间帧内容溢出到别的卡片上
                DispatchQueue.main.async { model.onResize?() }
            }
        }
        .onAppear { runLogQuery() }
    }

    // 折叠分组卡片
    private func group<C: View>(_ id: String, icon: String, title: String, summary: String,
                                locked: Bool = false,
                                @ViewBuilder content: () -> C) -> some View {
        let open = ui.openGroups.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button { toggleGroup(id) } label: {
                HStack(spacing: 7) {
                    if !icon.isEmpty { Text(icon).font(.system(size: 12)) }
                    Text(title).font(.system(size: 13.5, weight: .heavy))
                    Spacer(minLength: 6)
                    Text(summary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    // 隐私模式：薪酬 / 校正 / 流水这三组会露出金额或加班时长，整组锁住
                    if locked && model.privacyActive { privacyLockedCard() }
                    else { content() }
                }
                    .padding(.horizontal, 13)
                    .padding(.bottom, 12)
            }
        }
        // 2.2 层级：分区标题（深）> 分组卡（中）> 组内行（浅），色块深度逐级递减
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Glass.level(2)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .strokeBorder(Glass.line(open ? 0.85 : 0.5), lineWidth: 1))
    }

    // 折叠/展开不做图层过渡动画：SwiftUI 的插入动画会在布局更新前就把内容画出来，
    // 那几帧内容会压到下面的卡片上（用户看到的就是“窗口变形”）。一次性切换最稳。
    private func toggleGroup(_ id: String) {
        ui.toggleGroup(id)
    }

    private func toggleAllGroups() {
        ui.toggleAllGroups()
    }

    // 隐私模式锁卡片：薪酬 / 校正 / 流水三组统一用它，避免逐个文本漏改
    private func privacyLockedCard() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(redDeep)
                Text("隐私模式：这里的金额与加班已隐藏")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 0)
            }
            Text("需要查看或编辑时输密码临时解锁 60 秒，到点自动恢复隐藏。状态栏、迷你条、桌面小组件同样只显示百分比。")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if requirePIN(model: model, title: "临时查看",
                              message: "输入 4 位密码，60 秒后自动恢复隐藏") {
                    model.unlockTemporarily()
                }
            } label: {
                Text("临时解锁 60 秒")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(Glass.fill(0.42)))
            .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Glass.fill(0.22)))
        .padding(.top, 6)
    }

    // 组内小标题
    private func fieldLabel(_ s: String, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(s).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 9).padding(.bottom, 5)
    }

    // 组内说明文字：允许按可用宽度换行（不加 fixedSize(vertical:) 会被压成单行截断）
    private func caption(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }

    // 组内警示行：开关写入失败 / 需要用户去系统设置放行
    private func warnLine(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(redDeep)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }

    // 开关行：图标 + 标题 + 说明 + 右侧小开关（自动上班/自动下班/开机自启动共用）
    private func switchRow(icon: String, on: Bool, title: String, detail: String,
                           binding: Binding<Bool>, onChange: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? redDeep : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .tint(redDeep)     // 2.2 重点 / 开关色跟随主题，不再用系统蓝
                .onChange(of: binding.wrappedValue) { _ in onChange() }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Glass.level(4)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Glass.line(0.55), lineWidth: 1))
    }


    // MARK: - 菜单栏显示（2.3）
    /// 菜单栏预览：与真实菜单栏同一套排版（小字标签 + 等宽数值）
    private func barPreview() -> some View {
        let kinds = model.selectedStatusBarKinds
        let k = kinds.first ?? .moneyToday
        let v = model.statusBarValue(k)
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(k.group.tag)
                    .font(.system(size: 8, weight: .heavy)).tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(v.text)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppPalette.text)
                if !v.unit.isEmpty {
                    Text(v.unit).font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary).baselineOffset(0.6)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(AppPalette.text.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Glass.line(0.5), lineWidth: 1))
            Spacer(minLength: 4)
            Text(model.statusBarShowData
                 ? (kinds.count > 1
                    ? "共 \(kinds.count) 项 · \(model.statusBarRotate ? "每 \(Int(model.statusBarRotateSeconds)) 秒轮播" : "只显示第一项")"
                    : "菜单栏预览")
                 : "已关闭 · 只留图标")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.top, 2)
    }

    /// 菜单栏显示项开关卡（MONEY / DAYS 共用）
    private func barKindChip(_ k: StatusBarKind) -> some View {
        let on = model.isStatusBarKindOn(k)
        return Button { model.toggleStatusBarKind(k) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(k.group.tag)
                        .font(.system(size: 7.5, weight: .heavy)).tracking(0.6)
                        .foregroundStyle(on ? redDeep : Color.secondary.opacity(0.8))
                    Spacer(minLength: 0)
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 9))
                        .foregroundStyle(on ? redDeep : Color.secondary.opacity(0.55))
                }
                Text(k.title)
                    .font(.system(size: 11, weight: on ? .heavy : .semibold))
                    .foregroundStyle(on ? AppPalette.text : AppPalette.text.opacity(0.55))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Glass.level(on ? 5 : 2)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? redDeep.opacity(0.6) : Glass.line(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(k.detail)
    }

    private var settingsMaxHeight: CGFloat { SettingsUIState.maxViewport() }

    /// 2.2 分区标题：最深的一级色块 + 左侧重点色竖条，和下层分组卡明确分层
    private func sectionLabel(_ s: String, trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(redDeep).frame(width: 3, height: 19)
            Text(s).font(.system(size: 14.5, weight: .heavy)).foregroundStyle(redDeep)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Glass.level(3)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(redDeep.opacity(0.24), lineWidth: 1))
        .padding(.top, 15).padding(.bottom, 7)
    }

    // 2.2 色卡行：系统颜色面板，连续调节、即时生效
    private func themeColorRow(_ title: String, _ binding: Binding<Color>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden().frame(width: 46, height: 24)
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Glass.level(4)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Glass.line(0.5), lineWidth: 1))
    }

    // 流水明细小输入框
    private func logField(_ placeholder: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .multilineTextAlignment(.center)
            .frame(width: width)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Glass.fill(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Glass.line(0.5), lineWidth: 1))
    }

    // MARK: - 2.0 设置页交互

    // 周一~周天七个开关（Calendar.weekday：1=周日 … 7=周六）
    private func weekdayChips() -> some View {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        return HStack(spacing: 5) {
            ForEach(1...7, id: \.self) { wd in
                let on = model.customWeekdays.contains(wd)
                Button {
                    if on {
                        guard model.customWeekdays.count > 1 else {
                            ui.workdayError = "至少要留一个工作日，否则无法计薪"
                            return
                        }
                        model.customWeekdays.remove(wd)
                    } else {
                        model.customWeekdays.insert(wd)
                    }
                    ui.workdayError = nil
                    model.onWorkdayRuleChanged()
                } label: {
                    Text(names[wd - 1])
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(on ? .white : Color.primary.opacity(0.65))
                        .frame(width: 34, height: 30)
                        .background(Capsule().fill(on
                            ? AnyShapeStyle(redDeep.opacity(0.9))
                            : AnyShapeStyle(Glass.fill(0.3))))
                        .overlay(Capsule().strokeBorder(Glass.line(on ? 0.7 : 0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func modeOption(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? .white : Color.primary.opacity(0.7))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(on
                    ? AnyShapeStyle(redDeep.opacity(0.9))
                    : AnyShapeStyle(Glass.fill(0.3))))
                .overlay(Capsule().strokeBorder(Glass.line(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func countdownRow(_ c: CountdownItem) -> some View {
        let p = countdownProgress(c)
        let active = model.activeCountdownId == c.id
        return HStack(spacing: 6) {
            Button {
                model.setActiveCountdown(id: c.id)
            } label: {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(active ? redDeep : .secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设为首页当前倒计时")

            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text("\(c.month)/\(c.day)" + (c.isYearly ? " · 每年" : " · \(c.year ?? 0)"))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(p?.expired == true ? "已到期" : "\(p?.daysLeft ?? 0) 天")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(redDeep)
                .fixedSize()
            Button {
                guard let i = model.countdowns.firstIndex(where: { $0.id == c.id }) else { return }
                model.countdowns[i].mode = model.countdowns[i].mode == "days" ? "percent" : "days"
                model.onCountdownsChanged()
            } label: {
                Text(c.modeTitle)
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Glass.fill(0.4)))
            }
            .buttonStyle(.plain)
            .help("切换天数 / 百分比显示")
            EventSortControls(id: c.id,
                              index: model.countdowns.firstIndex(where: { $0.id == c.id }) ?? 0,
                              count: model.countdowns.count,
                              draggingID: $draggingCountdownID,
                              onShift: { model.shiftCountdown(id: c.id, by: $0) },
                              onPlaceAt: { model.placeCountdown(id: c.id, at: $0) })
            Button { editCountdownFromSettings(c) } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("编辑「\(c.name)」的名称 / 日期 / 时刻 / 重复方式")
            Button { model.removeCountdown(id: c.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("删除 \(c.name)")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Glass.fill(0.2)))
        .onDrop(of: [UTType.text],
                delegate: EventReorderDropDelegate(
                    draggingID: $draggingCountdownID, targetID: c.id,
                    onPlaceBefore: { src, target in model.placeCountdown(id: src, before: target) }))
    }

    /// 设置页列表的「编辑」：跳到对应二级页，并把这一项载入事件管理的编辑表单
    private func editCountdownFromSettings(_ c: CountdownItem) {
        model.setActiveCountdown(id: c.id)
        ui.loadCountdownForEditing(c)
        ui.openEventManager(.countdown)
        model.page = .countdown
    }

    private func editRecordDayFromSettings(_ c: RecordDayItem) {
        model.setActiveRecordDay(id: c.id)
        ui.loadRecordDayForEditing(c)
        ui.openEventManager(.anniversary)
        model.page = .recordDay
    }

    private func addCountdownTapped() {
        let m = Int(ui.cdMonth.trimmingCharacters(in: .whitespaces)) ?? 0
        let d = Int(ui.cdDay.trimmingCharacters(in: .whitespaces)) ?? 0
        let y = Int(ui.cdYear.trimmingCharacters(in: .whitespaces))
        let item = CountdownItem(name: ui.cdName.trimmingCharacters(in: .whitespaces),
                                 month: m, day: d, year: y,
                                 mode: ui.cdPercent ? "percent" : "days",
                                 createdKey: dateKey(Date.now))
        if let err = model.addCountdown(item) { ui.cdError = err; return }
        ui.cdName = ""; ui.cdMonth = ""; ui.cdDay = ""; ui.cdYear = ""
        ui.cdError = nil
    }

    private func recordDayRow(_ c: RecordDayItem) -> some View {
        let p = recordDayProgress(c)
        let active = model.activeRecordDayId == c.id
        return HStack(spacing: 6) {
            Button { model.setActiveRecordDay(id: c.id) } label: {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(active ? redDeep : .secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设为当前纪念日")

            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(verbatim: "\(String(c.year))/\(c.month)/\(c.day) · \(c.targetDays > 0 ? "目标 \(c.targetDays) 天" : "百天里程碑")")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(verbatim: "\(p?.elapsedDays ?? 0) 天")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(redDeep).fixedSize()
            Button {
                guard let i = model.recordDays.firstIndex(where: { $0.id == c.id }) else { return }
                model.recordDays[i].mode = model.recordDays[i].mode == "days" ? "percent" : "days"
                model.onRecordDaysChanged()
            } label: {
                Text(c.modeTitle)
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Glass.fill(0.4)))
            }
            .buttonStyle(.plain)
            .help("切换天数 / 百分比显示")
            EventSortControls(id: c.id,
                              index: model.recordDays.firstIndex(where: { $0.id == c.id }) ?? 0,
                              count: model.recordDays.count,
                              draggingID: $draggingRecordID,
                              onShift: { model.shiftRecordDay(id: c.id, by: $0) },
                              onPlaceAt: { model.placeRecordDay(id: c.id, at: $0) })
            Button { editRecordDayFromSettings(c) } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("编辑「\(c.name)」的名称 / 起始日 / 显示方式 / 里程碑")
            Button { model.removeRecordDay(id: c.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("删除 \(c.name)")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Glass.fill(0.2)))
        .onDrop(of: [UTType.text],
                delegate: EventReorderDropDelegate(
                    draggingID: $draggingRecordID, targetID: c.id,
                    onPlaceBefore: { src, target in model.placeRecordDay(id: src, before: target) }))
    }

    private func addRecordDayTapped() {
        let y = Int(ui.rdYear.trimmingCharacters(in: .whitespaces)) ?? 0
        let m = Int(ui.rdMonth.trimmingCharacters(in: .whitespaces)) ?? 0
        let d = Int(ui.rdDay.trimmingCharacters(in: .whitespaces)) ?? 0
        let item = RecordDayItem(name: ui.rdName.trimmingCharacters(in: .whitespaces),
                                 year: y, month: m, day: d, targetDays: 0, mode: "days")
        if let err = model.addRecordDay(item) { ui.rdError = err; return }
        ui.rdName = ""; ui.rdYear = ""; ui.rdMonth = ""; ui.rdDay = ""; ui.rdTarget = ""
        ui.rdError = nil
    }

    private func enablePrivacyTapped() {
        guard let pin = askPIN(title: "设置隐私密码", message: "输入 4 位数字密码。开启后所有工资金额改为百分比进度。"),
              let pin2 = askPIN(title: "再输一次", message: "确认刚才的 4 位密码", confirm: "确认") else { return }
        guard pin == pin2 else { ui.privacyError = "两次输入的密码不一致"; return }
        ui.privacyError = model.enablePrivacy(pin: pin)
    }

    private func disablePrivacyTapped() {
        guard requirePIN(model: model, title: "关闭隐私模式",
                         message: "输入 4 位密码以恢复金额显示") else { return }
        model.disablePrivacy()
        ui.privacyError = nil
    }

    private func changePINTapped() {
        guard requirePIN(model: model, title: "验证旧密码",
                         message: "先输入当前 4 位密码") else { return }
        guard let pin = askPIN(title: "新密码", message: "输入新的 4 位数字密码"),
              let pin2 = askPIN(title: "再输一次", message: "确认新密码", confirm: "确认") else { return }
        guard pin == pin2 else { ui.privacyError = "两次输入不一致"; return }
        ui.privacyError = model.setPIN(pin)
        if ui.privacyError == nil { model.logText = "隐私密码已更新" }
    }

    private func runLogQuery() {
        let s = ui.queryStart.trimmingCharacters(in: .whitespaces)
        let e = ui.queryEnd.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty && !isValidDayKey(s) { ui.logError = "开始日期格式应为 yyyy-MM-dd"; return }
        if !e.isEmpty && !isValidDayKey(e) { ui.logError = "结束日期格式应为 yyyy-MM-dd"; return }
        ui.logError = nil
        ui.rows = model.dayLogRows(start: s, end: e)
    }

    private func addLogRow() {
        let key = ui.addDate.trimmingCharacters(in: .whitespaces)
        let earned = Double(ui.addEarned.trimmingCharacters(in: .whitespaces)) ?? -1
        let ot = Double(ui.addOTMin.trimmingCharacters(in: .whitespaces)) ?? 0
        if let err = model.insertDayLog(key: key, earned: earned, otMinutes: ot) {
            ui.logError = err
            return
        }
        ui.logError = nil
        ui.addDate = ""; ui.addEarned = ""; ui.addOTMin = ""
        runLogQuery()
    }

    // 玻璃风格的二选一（替代系统蓝色分段控件）
    private func closeOption(_ title: String, value: String, icon: String) -> some View {
        let on = model.closeBehavior == value
        return Button {
            model.closeBehavior = value
            model.onCloseBehaviorChanged()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.68))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(on
                    ? AnyShapeStyle(LinearGradient(colors: [redDeep.opacity(0.9), redDeep],
                                                   startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Glass.fill(0.32)))
            )
            .overlay(Capsule().strokeBorder(Glass.line(on ? 0.5 : 0.55), lineWidth: 1))
            .shadow(color: on ? redDeep.opacity(0.35) : .clear, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func scheduleField(label: String, text: Binding<String>, placeholder: String, width: CGFloat, unit: String? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(width: width)
                .onChange(of: text.wrappedValue) { _ in model.onScheduleChanged() }
            if let unit {
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Glass.fill(0.3)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Glass.line(0.55), lineWidth: 1))
    }

    private func uploadIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.message = "选择一张图片作为进度条图标（自动裁圆、吸取主色）"
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            model.setCustomIcon(data)
        }
    }
}

// MARK: - 迷你模式

struct MiniView: View {
    @ObservedObject var model: EarnModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                if let img = model.iconImage {
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Glass.line(0.9), lineWidth: 2))
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Glass.fill(0.4))
                            .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
                        Capsule()
                            .fill(LinearGradient(colors: model.barColors, startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, geo.size.width * model.progress))
                    }
                }
                .frame(height: 9)
                Text(model.privacyActive ? percentText(model.progressRatio, dec: 0)
                                        : "¥" + fmt(model.displayEarned, 4))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(redDeep)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // 大小窗口切换键（迷你 → 完整）
                Button(action: { withAnimation { model.page = .home } }) {
                    Image(systemName: "rectangle.expand.vertical")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("展回大窗")
            }
            Text(model.privacyActive ? "隐私模式 · 点击展开"
                 : (model.overtimeNow ? "加班中 · 点击展开" : (model.working ? "计费中 · 点击展开" : "点击展开")))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { model.page = .home } }
    }
}

// MARK: - 2.0 首次启动引导：选进度条统计内容

struct OnboardingView: View {
    @ObservedObject var model: EarnModel

    var body: some View {
        VStack(spacing: 10) {
            Text("先逛哪个模块？")
                .font(.system(size: 19, weight: .heavy))
            Text("首页会同时显示 Your Money 和 Your Days 的进度卡，点哪张进哪个详情页。三个模式互不共用模块，先挑一个看看。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)

            ForEach(DetailMode.allCases, id: \.self) { m in
                Button { model.finishOnboarding(m) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(m.module) · \(m.title)").font(.system(size: 14, weight: .heavy))
                            Text(m == .salary ? "薪酬/工时进度、月薪日薪、本月累计"
                                 : (m == .countdown ? "距目标日还剩几天、完成百分比" : "从纪念日起已记录多少天、百天里程碑"))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            Button { model.finishOnboarding(nil) } label: {
                Text("直接看首页（推荐）")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 372)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(AppPalette.bg)
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Glass.line(0.7), lineWidth: 1)))
    }
}

// MARK: - 根视图

struct ContentView: View {
    @ObservedObject var model: EarnModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // 2.2：只有 Liquid Glass 主题挂玻璃层；实色主题直接铺纯色底，不再采样桌面壁纸
            if AppPalette.glass { GlassPanel(cornerRadius: 32).ignoresSafeArea() }
            // 背景色 × 独立透明度：四款主题共用同一套 color / alpha 控件
            Rectangle()
                .fill(AppPalette.bg.opacity(AppPalette.alpha))
                .ignoresSafeArea().allowsHitTesting(false)
            // 主色晕染：玻璃主题稍强，实色主题只留极淡一层，避免盖住干净底色
            RadialGradient(colors: [model.accentA.opacity(AppPalette.glass ? (scheme == .dark ? 0.30 : 0.18) : 0.09), .clear],
                           center: UnitPoint(x: 0.1, y: 0.0), startRadius: 0, endRadius: 420)
                .ignoresSafeArea().allowsHitTesting(false)
            RadialGradient(colors: [model.accentB.opacity(AppPalette.glass ? (scheme == .dark ? 0.26 : 0.14) : 0.06), .clear],
                           center: UnitPoint(x: 0.9, y: 1.0), startRadius: 0, endRadius: 420)
                .ignoresSafeArea().allowsHitTesting(false)

            // 只量「页面内容」的自然高度：ZStack 会被背景渐变撑满，量它等于量窗口
            Group {
                switch model.page {
                case .home: HomeView(model: model).fixedSize(horizontal: false, vertical: true)
                case .salary: SalaryDetailView(model: model).fixedSize(horizontal: false, vertical: true)
                case .countdown: CountdownDetailView(model: model).fixedSize(horizontal: false, vertical: true)
                case .recordDay: RecordDayDetailView(model: model).fixedSize(horizontal: false, vertical: true)
                case .settings: SettingsView(model: model)
                case .mini: MiniView(model: model).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(AppPalette.text)
            .background(GeometryReader { g in
                Color.clear.preference(key: PageContentHeightKey.self, value: g.size.height)
            })
            // 2.0 首次启动引导覆盖层（不参与首页内容高度测量）
            if model.showOnboarding {
                // 半透明遮罩顺带吞掉点击，避免引导时误触下层首页按钮
                Rectangle()
                    .fill(Color.black.opacity(0.2))
                    .contentShape(Rectangle())
                    .onTapGesture { }
                OnboardingView(model: model)
                    .foregroundStyle(AppPalette.text)
                    .transition(.opacity)
            }
        }
        .onPreferenceChange(PageContentHeightKey.self) { h in
            // 关闭 sizingOptions 后 hosting 的 fittingSize 恒为 0，只能自己量内容高度
            guard h > 40 else { return }
            let key = model.page.heightKey
            if abs((SettingsUIState.shared.pageHeights[key] ?? 0) - h) > 0.5 {
                SettingsUIState.shared.pageHeights[key] = h
                if model.page != .settings { DispatchQueue.main.async { model.onResize?() } }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .frame(width: model.page == .mini ? 330 : 372)
        .onChange(of: model.page) { model.onResize?() }
    }
}

// MARK: - 状态栏常驻（菜单 + 迷你金额/进度显示）

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let statusMenu = NSMenu()
    private let panel: NSPanel
    private let model: EarnModel
    private var barModeActive = false
    // 2.3 菜单栏轮播状态
    private var rotateIndex = 0
    private var lastRotateAt = Date()
    private var lastRenderKey = ""
    private var iconOnly = true
    private var refreshTimer: Timer?
    var barTitle: String? { statusItem.button?.title }   // 自检用

    init(panel: NSPanel, model: EarnModel) {
        self.panel = panel
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusMenu.delegate = self

        applyDefaultIcon()
        statusItem.button?.toolTip = "分刻（左键：显示/隐藏小窗，双指点按：菜单）"
        // 菜单永久挂在图标上：触控板双指点按（右键）由系统直接弹出，事件层 100% 可靠；
        // 左键点击在 menuNeedsUpdate 里拦截，转为显示/隐藏小窗
        statusItem.menu = statusMenu
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshBar() }
        }
    }

    private func applyDefaultIcon() {
        // 菜单栏没有内容可显示时，退回 App 图标（彩色）；取不到图标再退回钞票符号
        if let appIcon = NSApp.applicationIconImage, appIcon.size.width > 1 {
            let img = (appIcon.copy() as? NSImage) ?? appIcon
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = false
            statusItem.button?.image = img
        } else {
            let img = NSImage(systemSymbolName: "banknote.fill", accessibilityDescription: "分刻")
            img?.isTemplate = true
            statusItem.button?.image = img
        }
        statusItem.button?.title = ""
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
    }

    // 状态栏迷你进度条（模板图，自动适配深浅色）
    private func progressImage(_ p: Double, active: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 30, height: 14))
        img.lockFocus()
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 3, width: 30, height: 8), xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(active ? 1.0 : 0.7).setFill()
        let w = max(3, CGFloat(p) * 30)
        NSBezierPath(roundedRect: NSRect(x: 0, y: 3, width: w, height: 8), xRadius: 4, yRadius: 4).fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    /// 轮播游标：只在开启滚动且选中多项时推进，间隔取用户设置
    private func currentKind() -> StatusBarKind? {
        let kinds = model.selectedStatusBarKinds
        guard let first = kinds.first else { return nil }
        guard model.statusBarRotate, kinds.count > 1 else {
            rotateIndex = 0
            lastRotateAt = Date()
            return first
        }
        let interval = max(1.5, model.statusBarRotateSeconds)
        if Date().timeIntervalSince(lastRotateAt) >= interval {
            lastRotateAt = Date()
            rotateIndex = (rotateIndex + 1) % kinds.count
        }
        return kinds[min(rotateIndex, kinds.count - 1)]
    }

    /// 菜单栏文字：小字 MONEY/DAYS 标签 + 等宽数值 +（天数后缀）
    private func barTitle(kind: StatusBarKind, value: String, unit: String) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: kind.group.tag, attributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .heavy),
            .foregroundColor: NSColor.secondaryLabelColor,
            .baselineOffset: 1.2,
            .kern: 0.8,
        ]))
        s.append(NSAttributedString(string: " " + value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]))
        if !unit.isEmpty {
            s.append(NSAttributedString(string: unit, attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .baselineOffset: 0.6,
            ]))
        }
        return s
    }

    private func refreshBar() {
        // 「菜单栏显示数据」默认开：菜单栏常显所选内容；关掉后退回只为「收缩至状态栏」显示
        let wantData = model.statusBarShowData || model.statusBarMode
        guard wantData, let kind = currentKind() else {
            if !iconOnly {
                iconOnly = true
                lastRenderKey = ""
                applyDefaultIcon()
                statusItem.button?.toolTip = "分刻（左键：显示/隐藏小窗，双指点按：菜单）"
            }
            barModeActive = model.statusBarMode
            return
        }

        let v = model.statusBarValue(kind)
        let kinds = model.selectedStatusBarKinds
        let bar = model.statusBarShowBar && kind.showsProgress
        let key = "\(kind.rawValue)|\(v.text)|\(v.unit)|\(bar)|\(model.progress)"
        if key != lastRenderKey || iconOnly {
            iconOnly = false
            lastRenderKey = key
            statusItem.button?.image = bar ? progressImage(model.progress, active: model.working) : nil
            statusItem.button?.title = ""
            statusItem.button?.attributedTitle = barTitle(kind: kind, value: v.text, unit: v.unit)
        }

        var tip = "\(kind.group.tag == "MONEY" ? "Your Money" : "Your Days") · \(kind.title)：\(v.text)\(v.unit)"
        tip += "\n今日进度 \(percentText(model.todayHoursRatio)) · 已工作 \(model.workedMinutes) 分钟"
        if model.statusBarRotate && kinds.count > 1 {
            let i = (kinds.firstIndex(of: kind) ?? 0) + 1
            tip += "\n轮播中 \(i)/\(kinds.count) · 每 \(Int(model.statusBarRotateSeconds)) 秒切换"
        }
        tip += "\n左键点击恢复小窗"
        statusItem.button?.toolTip = tip
        barModeActive = model.statusBarMode
    }

    /// 自检用：打印菜单栏条目的实际尺寸与标题，并把按钮渲染成 PNG 供目视检查
    func dumpStatus(_ pngPath: String?) {
        guard let btn = statusItem.button else {
            print("BAR| 无按钮（状态栏条目未创建）")
            return
        }
        let f = btn.frame, wf = btn.window?.frame ?? .zero
        print("BAR| visible=\(statusItem.isVisible) btnFrame=\(Int(f.width))x\(Int(f.height)) winFrame=\(Int(wf.width))x\(Int(wf.height))@\(Int(wf.origin.x)),\(Int(wf.origin.y))")
        let iconDesc = btn.image.map { "有图标 \(Int($0.size.width))x\(Int($0.size.height))" } ?? "无图标（纯文字）"
        print("BAR| title=[\(btn.attributedTitle.string)] \(iconDesc) 项=\(model.selectedStatusBarKinds.map { $0.rawValue }) 轮播=\(model.statusBarRotate) 常显=\(model.statusBarShowData)")
        guard let pngPath else { return }
        let fit = btn.fittingSize
        print("BAR| fittingSize=\(Int(fit.width))x\(Int(fit.height))")
        let size = NSSize(width: max(60, fit.width + 12), height: 22)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(white: 0.98, alpha: 1).setFill()          // 浅色菜单栏底
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let copy = btn.attributedTitle.copy() as? NSAttributedString ?? NSAttributedString()
        let m = NSMutableAttributedString(attributedString: copy)
        // 浅底上把动态色换算成固定深色，PNG 才看得出排版
        m.addAttribute(.foregroundColor, value: NSColor(white: 0.15, alpha: 1),
                       range: NSRange(location: 0, length: m.length))
        m.draw(at: NSPoint(x: 6, y: 5))
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let d = rep.representation(using: .png, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: pngPath))
            print("BAR-PNG| \(pngPath)")
        }
    }

    // 每次菜单即将弹出时动态重建条目（状态随时变化）
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu()
        // 左键点击也会走菜单通道——拦截下来转为显示/隐藏小窗，不弹菜单
        if let event = NSApp.currentEvent,
           event.type == .leftMouseUp || event.type == .leftMouseDown {
            DispatchQueue.main.async {
                self.statusItem.menu = nil      // 置空取消菜单跟踪
                self.handleLeftClick()
                self.statusItem.menu = self.statusMenu  // 恢复，供下次右键使用
            }
        }
    }

    private func handleLeftClick() {        if model.statusBarMode {
            model.statusBarMode = false
            bringPanelFront()
        } else if panel.isVisible {
            panel.orderOut(nil)
        } else {
            bringPanelFront()
        }
    }

    /// 窗口是普通层级了：唤出时必须主动激活 App，否则会被前台窗口压住
    private func bringPanelFront() {
        forcePanelFront(panel)
    }

    private func populateMenu() {
        statusMenu.removeAllItems()

        let salaryItem = NSMenuItem(title: model.privacyActive ? "薪酬：已隐藏"
            : (model.salary > 0 ? "薪酬：¥\(fmt(model.salary, 0)) /月"
                                : "薪酬：未设置（点击设置）"),
            action: #selector(openSettings), keyEquivalent: "")
        salaryItem.target = self
        statusMenu.addItem(salaryItem)

        let daysItem = NSMenuItem(title: "工作日：\(model.workDays) 天/月（\(model.isAutoDays ? "自动" : "手动")）",
                                  action: #selector(openSettings), keyEquivalent: "")
        daysItem.target = self
        statusMenu.addItem(daysItem)

        statusMenu.addItem(.separator())

        // 2.1：三个模式各有独立入口；薪酬口径子菜单只列 Your Money 的 4 种
        let homeItem = NSMenuItem(title: "首页（Your Money / Your Days）",
                                  action: #selector(showFull), keyEquivalent: "")
        homeItem.target = self
        statusMenu.addItem(homeItem)

        let salaryItem2 = NSMenuItem(title: "Your Money · 薪酬进度",
                                     action: #selector(openSalaryDetail), keyEquivalent: "")
        salaryItem2.target = self
        statusMenu.addItem(salaryItem2)

        let daysSub = NSMenu()
        let cdItem = NSMenuItem(title: "倒计时详情", action: #selector(openCountdownDetail), keyEquivalent: "")
        cdItem.target = self
        daysSub.addItem(cdItem)
        let rdItem = NSMenuItem(title: "纪念日详情", action: #selector(openRecordDayDetail), keyEquivalent: "")
        rdItem.target = self
        daysSub.addItem(rdItem)
        if !model.countdowns.isEmpty {
            daysSub.addItem(.separator())
            for c in model.countdowns {
                let on = model.activeCountdownId == c.id
                let it = NSMenuItem(title: (on ? "✓ " : "　") + c.name,
                                    action: #selector(switchCountdown(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = c.id
                daysSub.addItem(it)
            }
        }
        if !model.recordDays.isEmpty {
            daysSub.addItem(.separator())
            for c in model.recordDays {
                let on = model.activeRecordDayId == c.id
                let it = NSMenuItem(title: (on ? "✓ " : "　") + c.name,
                                    action: #selector(switchRecordDay(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = c.id
                daysSub.addItem(it)
            }
        }
        let daysMenuItem = NSMenuItem(title: "Your Days · 倒计时 / 纪念日", action: nil, keyEquivalent: "")
        daysMenuItem.submenu = daysSub
        statusMenu.addItem(daysMenuItem)

        let metricSub = NSMenu()
        for m in ProgressMetric.salaryCases {
            let it = NSMenuItem(title: (model.progressMetric == m ? "✓ " : "") + m.title,
                                action: #selector(switchMetric(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.rawValue
            metricSub.addItem(it)
        }
        let metricItem = NSMenuItem(title: "Your Money · 薪酬进度口径", action: nil, keyEquivalent: "")
        metricItem.submenu = metricSub
        statusMenu.addItem(metricItem)
        statusMenu.addItem(.separator())

        let punch = NSMenuItem(title: model.working ? "打卡下班" : "打卡上班",
                               action: #selector(punchFromMenu), keyEquivalent: "")
        punch.target = self
        statusMenu.addItem(punch)

        // 2.2：加班按钮即使从首页隐藏，状态栏也留一个入口
        let ot = NSMenuItem(title: model.manualOvertime ? "结束加班并下班" : "开始加班（独立计时）",
                            action: #selector(overtimeFromMenu), keyEquivalent: "")
        ot.target = self
        statusMenu.addItem(ot)

        let full = NSMenuItem(title: "完整界面（大窗）", action: #selector(showFull), keyEquivalent: "")
        full.target = self
        statusMenu.addItem(full)

        let mini = NSMenuItem(title: "▫ 迷你条（小窗，可展回大窗）", action: #selector(showMini), keyEquivalent: "")
        mini.target = self
        statusMenu.addItem(mini)

        let bar = NSMenuItem(title: model.statusBarMode ? "恢复小窗显示" : "收缩至状态栏（菜单栏走数）",
                             action: #selector(toggleStatusBarMode), keyEquivalent: "")
        bar.target = self
        statusMenu.addItem(bar)

        // 2.3 菜单栏显示内容：MONEY / DAYS 自选 + 滚动
        let barSub = NSMenu()
        let dataItem = NSMenuItem(title: "菜单栏显示数据",
                                  action: #selector(toggleBarData), keyEquivalent: "")
        dataItem.target = self
        dataItem.state = model.statusBarShowData ? .on : .off
        barSub.addItem(dataItem)
        barSub.addItem(.separator())
        for k in StatusBarKind.allCases {
            let it = NSMenuItem(title: "\(k.group.tag) · \(k.title)",
                                action: #selector(toggleBarKind(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = k.rawValue
            it.state = model.isStatusBarKindOn(k) ? .on : .off
            barSub.addItem(it)
        }
        barSub.addItem(.separator())
        let rot = NSMenuItem(title: "滚动显示（每 \(Int(model.statusBarRotateSeconds)) 秒）",
                             action: #selector(toggleBarRotate), keyEquivalent: "")
        rot.target = self
        rot.state = model.statusBarRotate ? .on : .off
        barSub.addItem(rot)
        let barDisplay = NSMenuItem(title: "菜单栏显示内容", action: nil, keyEquivalent: "")
        barDisplay.submenu = barSub
        statusMenu.addItem(barDisplay)

        let toggle = NSMenuItem(title: panel.isVisible ? "隐藏小窗" : "显示小窗",
                                action: #selector(togglePanel), keyEquivalent: "h")
        toggle.target = self
        statusMenu.addItem(toggle)

        statusMenu.addItem(.separator())
        let about = NSMenuItem(title: "ⓘ 关于 分刻 · Countmin v\(APP_VERSION)（开发者 \(DEV_NAME)）",
                               action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        statusMenu.addItem(about)

        let quit = NSMenuItem(title: "退出分刻", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        statusMenu.addItem(quit)
    }

    private func showPanel(as page: Page) {
        model.statusBarMode = false
        withAnimation { model.page = page }
        forcePanelFront(panel)
    }

    @objc private func openSettings() { showPanel(as: .settings) }
    @objc private func showFull() { showPanel(as: .home) }
    @objc private func openSalaryDetail() { showPanel(as: .salary) }
    @objc private func openCountdownDetail() { showPanel(as: .countdown) }
    @objc private func openRecordDayDetail() { showPanel(as: .recordDay) }
    @objc private func showMini() { showPanel(as: .mini) }
    @objc private func toggleStatusBarMode() {
        if model.statusBarMode {
            model.statusBarMode = false
            forcePanelFront(panel)
        } else {
            model.statusBarMode = true
            panel.orderOut(nil)
        }
    }
    @objc private func punchFromMenu() {
        if model.working { model.clockOut() } else { model.clockIn() }
    }

    @objc private func overtimeFromMenu() {
        if model.manualOvertime { model.endOvertime() } else { model.startOvertime() }
    }

    // 2.3 菜单栏显示项
    @objc private func toggleBarData() {
        model.statusBarShowData.toggle()
        model.onStatusBarDisplayChanged()
    }

    @objc private func toggleBarRotate() {
        model.statusBarRotate.toggle()
        model.onStatusBarDisplayChanged()
    }

    @objc private func toggleBarKind(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let k = StatusBarKind(rawValue: raw) else { return }
        model.toggleStatusBarKind(k)
    }

    @objc private func switchMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let m = ProgressMetric(rawValue: raw) else { return }
        model.progressMetric = m
        model.onMetricChanged()
    }

    @objc private func switchCountdown(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.setActiveCountdown(id: id)
        showPanel(as: .countdown)
    }

    @objc private func switchRecordDay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.setActiveRecordDay(id: id)
        showPanel(as: .recordDay)
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { forcePanelFront(panel) }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func openAbout() { showAboutPanel() }
}

// MARK: - 贴边自动收纳

// 判断窗口是否贴近所在屏幕边缘（上边按整屏算，可贴到菜单栏）
@MainActor
func nearScreenEdge(_ frame: NSRect, threshold: CGFloat = 12) -> Bool {
    guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else { return false }
    let v = screen.visibleFrame
    // 2.4.1：顶部不参与贴边收纳 —— 把窗口往上推到标题栏下方是最常见的摆放方式，
    // 一贴上去就被收进菜单栏，观感就是「点了一下顶部，窗口没了」
    return frame.minX <= v.minX + threshold || frame.maxX >= v.maxX - threshold
        || frame.minY <= v.minY + threshold
}

// 恢复小窗时若还停在边缘，往内挪一截，避免一恢复又立刻触发贴边缩小
@MainActor
func unpinPanelFromEdge(_ panel: NSPanel) {
    guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) ?? NSScreen.main else { return }
    let v = screen.visibleFrame
    let margin: CGFloat = 48
    var f = panel.frame
    if f.minX < v.minX + margin { f.origin.x = v.minX + margin }
    if f.maxX > v.maxX - margin { f.origin.x = v.maxX - margin - f.width }
    if f.minY < v.minY + margin { f.origin.y = v.minY + margin }
    // 顶部不再往回推：贴顶不是收纳条件，没必要把窗口从菜单栏下面拽下来
    panel.setFrameOrigin(f.origin)
}

// 把面板可靠地提到最前。
// 只调 makeKeyAndOrderFront 并不够：应用没被激活时，窗口只会排到「本 App 窗口栈」的顶，
// 别的 App 的普通层级窗口照样压在它上面——用户看到的就是「点了小薪薪，窗口没出来」。
// 顺序很关键：先激活自己，再前置，再在下一拍复查兜底。
@MainActor
func forcePanelFront(_ panel: NSPanel) {
    unpinPanelFromEdge(panel)
    if !panel.isVisible { panel.orderFront(nil) }
    panel.makeKeyAndOrderFront(nil)
    if !NSApp.isActive { NSApp.activate() }
    // 激活有可能被系统忽略（比如从后台被唤起），这时直接把窗口提到本层级最前，
    // 至少不会出现「窗口存在但被别的 App 盖住」的观感
    DispatchQueue.main.async {
        guard panel.isVisible else { return }
        if !NSApp.isActive || !panel.isKeyWindow {
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }
}

// MARK: - 界面图导出（产品手册用：--export-shots <目录>）

final class BackdropView: NSView {
    var colors: [NSColor] = []
    var baseColor: NSColor = .white
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 32, yRadius: 32)
        baseColor.setFill()
        path.fill()
        if colors.count >= 2 {
            ctx.saveGState()
            path.addClip()
            let cs = CGColorSpaceCreateDeviceRGB()
            let grad = CGGradient(colorsSpace: cs, colors: colors.map { $0.cgColor } as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: bounds.height),
                                   end: CGPoint(x: bounds.width, y: 0), options: [])
            ctx.restoreGState()
        }
    }
}

@MainActor
func exportShots(to dir: String, model: EarnModel, dark: Bool = false) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let pages: [(String, Page, CGFloat, CGFloat)] = [
        ("home", .home, 372, 620),
        ("salary", .salary, 372, 470),
        ("countdown", .countdown, 372, 470),
        ("recordDay", .recordDay, 372, 470),
        ("settings", .settings, 372, 420),
        ("mini", .mini, 330, 120),
    ]
    for (name, page, width, minHeight) in pages {
        model.page = page
        model.tick()   // 导出时先把金额算到当下（不跑 runloop，否则截图里永远是 0.00）
        SettingsUIState.shared.exportMode = page == .settings
        SettingsUIState.shared.forceHeight = page == .settings ? 1500 : nil
        let hosting = NSHostingView(rootView: ContentView(model: model))
        hosting.appearance = appearance
        var h = max(minHeight, hosting.fittingSize.height)
        if page == .settings { h = max(h, hosting.fittingSize.height) }
        let pad: CGFloat = 46
        let box = NSSize(width: width + pad * 2, height: h + pad * 2)
        let container = BackdropView(frame: NSRect(origin: .zero, size: box))
        container.appearance = appearance
        container.wantsLayer = true
        container.baseColor = dark ? NSColor(white: 0.09, alpha: 1) : .white
        container.colors = [
            NSColor(model.accentA).withAlphaComponent(dark ? 0.42 : 0.35),
            NSColor(model.accentB).withAlphaComponent(dark ? 0.34 : 0.25)
        ]
        hosting.frame = NSRect(x: pad, y: pad, width: width, height: h)
        container.addSubview(hosting)
        container.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(box.width * scale), pixelsHigh: Int(box.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        rep.size = box
        container.cacheDisplay(in: container.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: dir + "/\(name)\(dark ? "-dark" : "").png"))
        }
        SettingsUIState.shared.forceHeight = nil
        SettingsUIState.shared.exportMode = false
        model.page = .home
    }
    print("导出完成：\(dir)")
}

// MARK: - 入口

// 无边框面板默认不能成为 key window（键盘输入进不来）——必须子类化放行
// canBecomeMain 同样是 false：NSPanel 默认不做主窗口，于是「激活 App 时抬起主窗口」
// 这一步没有窗口可抬，面板就一直留在别的 App 窗口后面（点 Dock 图标看不到窗口的真正原因）
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // 2.4.1：点顶栏空白/窗口边缘时窗口会「沉到最底层，像被隐藏」
    // 根因：面板开着 becomesKeyOnlyIfNeeded，点在不需要键盘的区域（顶栏留白、圆角外沿）
    // 时面板不接管这次点击，系统就把「没人接收」的点击转给下层 App，
    // 我们的小窗随即掉到所有窗口后面。这里保证任何鼠标按下都先把自己捞到最前。
    override func mouseDown(with event: NSEvent) {
        if !NSApp.isActive { NSApp.activate() }
        if !isKeyWindow { makeKeyAndOrderFront(nil) }
        super.mouseDown(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !NSApp.isActive { NSApp.activate() }
            if !isVisible { orderFront(nil) }
            if !isKeyWindow { makeKey() }
            if event.type == .leftMouseDown { WindowDragCenter.shared.noteMouseDown(at: frame.origin) }
        default:
            break
        }
        super.sendEvent(event)
    }
}

// 2.5.1：点窗口顶部空白（YOUR MONEY 上方的标题行 / 面包屑行留白）时，
// 如果 App 当时在后台，这次点击根本不会被送达窗口——AppKit 询问命中视图
// 「要不要接受首次点击」，NSHostingView 默认答 false，于是系统把点击吞掉用于
// 「激活 App」，而无边框面板连激活都做不到，结果就是窗口原地留在最底层，
// 观感上像被缩放隐藏。子类化后明确回答 true，并顺手把自己激活 + 置前。
final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    /// 2.5.2：把「这一下点击属于我」在最早的时机确认掉。
    /// 无边框面板处于非激活状态时，AppKit 会先问命中视图要不要接受「首次点击」；
    /// 光回 true 不够——有些区域系统仍按「窗口背景」处理，App 不激活，
    /// 窗口就留在所有窗口后面（观感即点一下顶栏就沉下去）。这里顺手激活并置前。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        grabWindow()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        grabWindow()
        // 2.6.1：命中到这里＝这一下没落在任何 SwiftUI 内容上（空白处 / 顶栏缝隙 / 页面间隙）。
        // 直接交给系统的拖窗循环：按住不动就是一次点击，移动就是原生拖窗 —— 1:1 跟手、
        // 由窗口服务合成，不会像逐帧 setFrameOrigin 那样重算阴影掉帧。
        if let w = window {
            let before = w.frame.origin
            w.performDrag(with: event)
            let after = w.frame.origin
            WindowDragCenter.shared.finish(draggedBy: hypot(after.x - before.x, after.y - before.y))
        } else {
            super.mouseDown(with: event)
        }
    }

    /// SwiftUI 认为「此处没有内容」的地方（标题行留白、卡片之间的空隙）hitTest 会返回 nil，
    /// 事件随即落到窗口背景上：既激活不了 App，也拖不动窗口。兜底成自己，
    /// 保证整个窗口矩形都是可交互区域。
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let v = super.hitTest(point) { return v }
        return bounds.contains(point) ? self : nil
    }

    private func grabWindow() {
        guard let w = window else { return }
        if !NSApp.isActive { NSApp.activate() }
        if !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
    }
}

/// 顶部 / 底部的固定拖拽条：真实的 NSView，压在 SwiftUI 内容之上，永远能收到按下。
/// 为什么不用「空白处穿透到 hosting view」那条路：那条路得同时满足「命中不到任何 SwiftUI 内容」
/// 和「窗口服务把这次按下判给本窗口」，任何一环打折就变成点一下窗口沉下去。
/// 这里是一条固定带：按下即激活置前，移动交给系统拖窗循环（1:1 跟手，不掉帧）。
final class WindowDragStrip: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        activate()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        activate()
        guard let w = window else { return }
        let before = w.frame.origin
        w.performDrag(with: event)
        let after = w.frame.origin
        WindowDragCenter.shared.finish(draggedBy: hypot(after.x - before.x, after.y - before.y))
    }

    /// 悬停就提示「这里能拖」
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    private func activate() {
        if !NSApp.isActive { NSApp.activate() }
        if let w = window, !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
    }
}

// 2.6.1：窗口拖拽交还给 AppKit 的「背景拖」（isMovableByWindowBackground）
// 2.4~2.6 用 SwiftUI DragGesture 每帧 setFrameOrigin 搬窗口，实测有硬伤：
//   DragGesture 默认用 .local 坐标系，而窗口本身正跟着鼠标在动 ——
//   相对窗口的位移被自身移动抵消掉一半（实测拖 +120,-80，窗口只走 +56,-45），
//   再叠上半透明面板每帧重算阴影 / 重新合成，观感就是发飘 + 掉帧。
// 试过在视图里塞一个原生 NSView 自己调 performDrag：SwiftUI 会吞掉它的 mouseDown，
// 根本进不来（日志证实 hitTest 命中了，mouseDown 却一次都没到）。
// 最终方案：什么都不拦。空白处的点击本来就会穿透到 hosting view，
// 由 AppKit 的 isMovableByWindowBackground 走系统拖窗循环 —— 实测 1:1 跟手、无掉帧。
// 这里只保留一件事：统计「这次拖了多远」，给贴边收纳用。
@MainActor
final class WindowDragCenter {
    static let shared = WindowDragCenter()
    /// 松手回调：参数是本次拖拽的实际位移（点），贴边收纳靠它判断「是不是真拖了」
    var onDragEnd: ((CGFloat) -> Void)?

    private var startOrigin: NSPoint?
    private var maxDistance: CGFloat = 0
    private var settle: Timer?

    /// 面板收到 mouseDown：记下起点，之后每次 didMove 都拿它算位移
    func noteMouseDown(at origin: NSPoint) {
        startOrigin = origin
        maxDistance = 0
        settle?.invalidate()
    }

    func noteMove(to origin: NSPoint) {
        guard let start = startOrigin else { return }
        maxDistance = max(maxDistance, hypot(origin.x - start.x, origin.y - start.y))
        scheduleFlush()
    }

    /// performDrag 路径：拖窗循环返回时位移已经确定，不用等 didMove 攒
    func finish(draggedBy distance: CGFloat) {
        settle?.invalidate()
        startOrigin = nil
        maxDistance = 0
        if distance > 0 { onDragEnd?(distance) }
    }

    /// 停手 0.25 秒后结算；拖窗是模态循环，期间 Timer 不跑，松手后自然会补上
    private func scheduleFlush() {
        settle?.invalidate()
        settle = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in
            Task { @MainActor in WindowDragCenter.shared.flush(retries: 8) }
        }
    }

    private func flush(retries: Int) {
        // 还按着鼠标 = 拖到一半停住了，别急着结算
        if NSEvent.pressedMouseButtons != 0, retries > 0 {
            settle?.invalidate()
            settle = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
                Task { @MainActor in WindowDragCenter.shared.flush(retries: retries - 1) }
            }
            return
        }
        let distance = maxDistance
        startOrigin = nil
        maxDistance = 0
        if distance > 0 { onDragEnd?(distance) }
    }
}

// 常规应用（有 Dock 图标 / Cmd-Tab / 菜单栏），点击 Dock 图标要能把面板捞回来
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onReopen: (() -> Void)?
    var onShowSettings: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onReopen?()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        for (title, sel) in [("显示主窗口", #selector(showMain)), ("设置…", #selector(showSettings))] {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            m.addItem(it)
        }
        m.addItem(.separator())
        let q = NSMenuItem(title: "退出 分刻", action: #selector(quitNow), keyEquivalent: "")
        q.target = self
        m.addItem(q)
        return m
    }

    @objc private func showMain() { onReopen?() }
    @objc private func showSettings() { onShowSettings?() }
    @objc private func quitNow() { NSApp.terminate(nil) }
}

// 常规应用必须有主菜单，否则菜单栏空白、⌘Q/⌘C/⌘V 全失效
func buildMainMenu(appName: String) -> NSMenu {
    let main = NSMenu()

    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu(title: appName)
    appMenu.addItem(withTitle: "关于 \(appName)",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    main.addItem(editItem)
    let edit = NSMenu(title: "编辑")
    edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit

    return main
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate

// 改名（工资到账器 → 小薪薪）后 Bundle ID 变了，首次启动把老配置迁移过来，数据不丢
func migrateLegacyDefaultsIfNeeded() {
    let ud = UserDefaults.standard
    guard ud.object(forKey: "salary") == nil, ud.object(forKey: "baseEarned") == nil else { return }
    // 按新旧顺序找第一个真有数据的旧域名（suiteName 总能创建新域，所以必须查内容）
    var legacy: UserDefaults?
    for domain in ["com.haofan.qianjin", "com.haofan.salary-counter"] {
        if let d = UserDefaults(suiteName: domain),
           d.object(forKey: "salary") != nil || d.object(forKey: "baseEarned") != nil {
            legacy = d
            break
        }
    }
    guard let old = legacy else { return }
    for k in ["salary", "workDaysText", "workStart", "workEnd", "breakMin",
              "baseEarned", "working", "clockInAt", "customIconData"] {
        if let v = old.object(forKey: k) { ud.set(v, forKey: k) }
    }
}
let panel = KeyablePanel(
    contentRect: NSRect(x: 0, y: 0, width: 372, height: 560),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
// 普通窗口层级：不置顶，切到别的 App 时会被正常遮住
panel.isFloatingPanel = false
panel.level = .normal
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = true
panel.isMovableByWindowBackground = true
panel.hidesOnDeactivate = false
// 2.4.1：这里原本是 true（「只在点文本框时才成为 key，不抢焦点」），
// 但代价是点顶栏留白 / 圆角外沿时面板不接管点击，系统转手交给下层 App，
// 小窗就沉到最底层，观感上跟被隐藏了一样。窗口现在是 normal 层级，
// 点哪儿都该把自己拿到最前，所以改回 false。
panel.becomesKeyOnlyIfNeeded = false

// 素材图演示数据：--shot-salary <月薪> [--shot-worked <分钟>]
// 只影响截图用的独立 defaults 域，正常启动不会走这里
@MainActor
func seedShotDemo(_ model: EarnModel, salary: Double, workedMinutes: Double) {
    model.salaryText = String(Int(salary))
    model.workDaysText = ""
    model.workStartText = "09:00"
    model.workEndText = "18:00"
    model.breakMinText = "60"
    // 本月已过完的日子按理论日薪落账，含两天加班，让「本月累计」看起来是真实用过来的
    let dayPay = salary / 21.0
    let cal = Calendar.current
    for i in 1...4 {
        if let d = cal.date(byAdding: .day, value: -i, to: Date.now) {
            let ot: Double = (i == 2 || i == 3) ? 2700 : 0
            model.debugSeedDayLog(key: dateKey(d), earned: dayPay, ot: ot)
        }
    }
    let start = Date.now.addingTimeInterval(-workedMinutes * 60)
    model.debugStartSession(at: start)
    model.logText = "\(timeStr(start)) 打卡上班，继续计费中"
    model.tick()
    print("SHOT| 月薪 \(Int(salary)) 今日已工作 \(Int(workedMinutes)) 分 · 今日到账 \(fmt(model.displayEarned)) · 本月累计 \(fmt(model.monthEarned)) · 本月加班 \(Int(model.monthOTSeconds / 60)) 分")
}

// 自检：--sim-autoout（配合 EarnModel 的独立 defaults 域）
// 场景：3 小时前打卡、计划下班在 2 分钟前 → 应自动下班；
// 再次打卡应识别为加班；强制跨天应清零累计且继续计费。
@MainActor
func runSimAutoout(_ model: EarnModel) {    model.salaryText = "21000"
    model.workStartText = "09:00"
    model.workEndText = timeStr(Date.now.addingTimeInterval(-120))   // 计划下班 = 2 分钟前
    model.debugStartSession(at: Date.now.addingTimeInterval(-3600 * 3))
    model.tick()
    print("SIM1| 自动下班: working=\(model.working) 到账=\(fmt(model.displayEarned))")
    print("SIM1| log=[\(model.logText)]")
    model.clockIn()
    print("SIM2| 加班打卡: overtimeNow=\(model.overtimeNow) log=[\(model.logText)]")
    model.clockOut()
    print("SIM3| 加班后下班: otMin=\(model.overtimeMinutes) log=[\(model.logText)]")
    model.debugStartSession(at: Date.now.addingTimeInterval(-60))
    model.debugSimulateNewDay()
    print("SIM4| 跨天重置: earned=\(model.displayEarned) workedMin=\(model.workedMinutes) ot=\(model.overtimeSeconds) working=\(model.working)")
    print("SIM4| log=[\(model.logText)]")
    // 本月累计：种一天历史流水（昨天 到账300 / 加班30分钟），今天已重置为 0
    model.debugSeedDayLog(key: dateKey(Date.now.addingTimeInterval(-86400)), earned: 300, ot: 1800)
    print("SIM5| 本月累计: earned=\(fmt(model.monthEarned)) otMin=\(Int(model.monthOTSeconds / 60))")
    // 流水明细：手动添加 → 范围查询 → 删除
    if let err = model.insertDayLog(key: "2026-11-02", earned: 476.19, otMinutes: 45) {
        print("SIM6| 插入失败: \(err)")
    }
    let found = model.dayLogRows(start: "2026-11-01", end: "2026-11-30").first { $0.key == "2026-11-02" }
    print("SIM6| 查询: \(found.map { "\($0.key) ¥\(fmt($0.earned)) 加班\(Int($0.otSeconds / 60))分" } ?? "未找到")")
    let bad = model.insertDayLog(key: "2026-2-30", earned: 1, otMinutes: 0)
    print("SIM6| 非法日期拒绝: \(bad ?? "未拒绝(!)")")
    model.removeDayLog("2026-11-02")
    print("SIM6| 删除后剩余: \(model.dayLogRows(start: "", end: "").count) 条")
}

// 自检：--sim-autoin 验证自动打卡上班
// 场景1：上班时刻刚过 60 秒 → 从上班时刻起算（已计约 1 分钟）
// 场景2：连续 tick 不得重复打卡
// 场景3：关掉开关并下班后，tick 不得被自动打开
// 场景4：上班时刻已过 1 小时 → 从中途（当前时刻）起算，不白送工时
@MainActor
func runSimAutoin(_ model: EarnModel) {
    // 自检不能依赖「今天恰好是工作日」：修复非工作日自动打卡后，
    // 若正好在周六 / 法定节假日跑，默认规则会把下面所有场景全拦住，看起来像回归失败。
    func forceWorkday(_ m: EarnModel) {
        m.useLegalHolidays = false      // 排除调休补班 / 法定假干扰
        m.customWeekdays = Set(1...7)   // 七天全设为工作日
    }
    forceWorkday(model)
    model.salaryText = "21000"
    model.workStartText = timeStr(Date.now.addingTimeInterval(-60))
    model.workEndText = timeStr(Date.now.addingTimeInterval(4 * 3600))
    model.autoInEnabled = true
    model.autoOutEnabled = true

    model.tick()
    print("AUTOIN1| 到点自动上班 working=\(model.working) 已计=\(String(format: "%.3f", model.totalWorkedHours))h 到账=\(fmt(model.displayEarned))")
    print("AUTOIN1| log=[\(model.logText)]")

    let h1 = model.totalWorkedHours
    model.tick()
    print("AUTOIN2| 连续 tick 不重打 增量=\(String(format: "%.4f", model.totalWorkedHours - h1))h working=\(model.working)")

    model.autoInEnabled = false
    model.clockOut()
    model.tick()
    print("AUTOIN3| 开关关闭且已下班 → 不再自动打 working=\(model.working)")

    // 场景4：换一个「1 小时前就该上班」的新域，验证补打从中途起算
    let ud2 = UserDefaults(suiteName: "xiaoxinxin-sim-late")!
    ["salary", "working", "baseEarned", "clockInAt", "autoInKey", "workedBeforeSession",
     "overtimeSeconds", "dayKey", "dayLog"].forEach { ud2.removeObject(forKey: $0) }
    let late = EarnModel(ud: ud2)
    forceWorkday(late)
    late.salaryText = "21000"
    late.workStartText = timeStr(Date.now.addingTimeInterval(-3600))
    late.workEndText = timeStr(Date.now.addingTimeInterval(3600))
    late.autoInEnabled = true
    late.tick()
    print("AUTOIN4| 晚到补打 已计=\(String(format: "%.3f", late.totalWorkedHours))h（应接近 0，不白送）working=\(late.working)")
    print("AUTOIN4| log=[\(late.logText)]")

    // 场景5（关键）：开关开着，用户手动打卡后又手动下班（早退）→ tick 不得再自动打开
    let ud3 = UserDefaults(suiteName: "xiaoxinxin-sim-manual")!
    ["salary", "working", "baseEarned", "clockInAt", "autoInKey", "workedBeforeSession",
     "overtimeSeconds", "dayKey", "dayLog"].forEach { ud3.removeObject(forKey: $0) }
    let manual = EarnModel(ud: ud3)
    forceWorkday(manual)
    manual.salaryText = "21000"
    manual.workStartText = timeStr(Date.now.addingTimeInterval(-60))
    manual.workEndText = timeStr(Date.now.addingTimeInterval(4 * 3600))
    manual.autoInEnabled = true
    manual.tick()               // 自动打上
    manual.clockOut()           // 用户手动下班
    manual.tick()
    print("AUTOIN5| 手动下班后不重打 working=\(manual.working)（应为 false）")

    // 场景6（非工作日回归）：把今天从工作日里勾掉 → 到点也不得自动打卡
    let ud4 = UserDefaults(suiteName: "xiaoxinxin-sim-offday")!
    ["salary", "working", "baseEarned", "clockInAt", "autoInKey", "workedBeforeSession",
     "overtimeSeconds", "dayKey", "dayLog", "customWeekdays", "useLegalHolidays",
     "workStartText", "workEndText"].forEach { ud4.removeObject(forKey: $0) }
    let off = EarnModel(ud: ud4)
    off.salaryText = "21000"
    off.workStartText = timeStr(Date.now.addingTimeInterval(-60))
    off.workEndText = timeStr(Date.now.addingTimeInterval(4 * 3600))
    off.autoInEnabled = true
    off.useLegalHolidays = false        // 排除调休补班日干扰，只看勾选的周几
    let todayDow = Calendar.current.component(.weekday, from: Date.now)
    off.customWeekdays = Set(1...7).subtracting([todayDow])
    off.tick()
    print("AUTOIN6| 今天设为非工作日 → 不自动打卡 working=\(off.working)（应为 false）")
    print("AUTOIN6| log=[\(off.logText)]")

    // 场景7：改回工作日 → 立刻恢复自动打卡，证明不是被 autoInKey 卡住
    off.customWeekdays.insert(todayDow)
    off.tick()
    print("AUTOIN7| 改回工作日 → 恢复自动打卡 working=\(off.working)（应为 true）")
}

// 自检：--sim-v2 覆盖 2.0 全部新逻辑（独立 defaults 域，绝不碰真实数据）
@MainActor
func runSimV2(_ model: EarnModel) {
    // 自检域会被反复复用：先把 2.0/2.1 的开关与任务清空，保证每次结果确定
    model.hiddenButtons = []
    model.hiddenCountdownChips = []
    model.hiddenMoneyChips = []
    model.hiddenRecordDayChips = []
    model.hiddenHomeCards = []
    model.countdowns = []
    model.recordDays = []
    model.activeCountdownId = ""
    model.activeRecordDayId = ""
    model.privacyEnabled = false
    model.privacyUnlockedUntil = nil

    model.salaryText = "3500"
    model.workDaysText = ""
    model.customWeekdays = [2, 3, 4, 5, 6]
    model.useLegalHolidays = true
    print("V2-1| 默认规则 工作日=\(model.workDays) 自动=\(model.isAutoDays) 日薪=\(fmt(model.ratePerDay))")
    model.useLegalHolidays = false
    print("V2-2| 关掉节假日 工作日=\(model.workDays)")
    model.customWeekdays = [2, 3, 4, 5, 6, 7]
    print("V2-3| 勾上周六 工作日=\(model.workDays)")
    model.workDaysText = "18"
    print("V2-4| 手填18天 工作日=\(model.workDays) 自动=\(model.isAutoDays)（应为 false）")
    model.workDaysText = ""
    model.customWeekdays = [2, 3, 4, 5, 6]
    model.useLegalHolidays = true

    for m in ProgressMetric.salaryCases {
        model.progressMetric = m
        let i = model.progressInfo
        print(String(format: "V2-5| %@ ratio=%.3f fill=%.3f 大字=[%@%@]",
                     m.title, i.ratio, i.fill, i.leading, i.trailing))
    }

    // 12 小时（8h 正常 + 4h 加班）→ 150%，主条封顶 100%，超出段 50%
    model.correctWork(hours: 12)
    model.progressMetric = .todayHours
    let ot = model.progressInfo
    print(String(format: "V2-6| 12h/8h ratio=%.2f 大字=%@ fill=%.2f overflow=%.2f",
                 ot.ratio, ot.leading, ot.fill, ot.overflow))

    model.privacyEnabled = true
    model.privacyUnlockedUntil = nil
    let p = model.progressInfo
    print("V2-7| 隐私 大字=\(p.leading) caption=\(p.caption) footer=\(p.footer)")
    print("V2-7| 月薪露出=\(model.displayMoney(model.salary, dec: 0))（应为 --）")
    model.unlockTemporarily(seconds: 60)
    print("V2-8| 临时解锁 privacyActive=\(model.privacyActive) 月薪=\(model.displayMoney(model.salary, dec: 0))")
    model.privacyUnlockedUntil = nil

    print("V2-9| 设PIN=\(model.setPIN("1234") ?? "OK") has=\(model.hasPIN) 校验1234=\(model.verifyPIN("1234")) 校验0000=\(model.verifyPIN("0000"))")

    let cd = CountdownItem(name: "新年", month: 1, day: 1, year: 2027,
                           createdKey: dateKey(Date.now))
    print("V2-10| 添加倒计时=\(model.addCountdown(cd) ?? "OK") 数量=\(model.countdowns.count)")
    model.privacyEnabled = false
    let ci = model.countdownInfo
    print("V2-11| 倒计时 大字=[\(ci.leading)\(ci.trailing)] caption=\(ci.caption) footer=\(ci.footer)")
    let ciAll = ci.leading + ci.trailing + ci.caption + ci.footer
    print("V2-16| 倒计时页无金额=\(!ciAll.contains("¥")) mode=\(ci.mode.rawValue)（应为 countdown）")
    if let cp = model.activeCountdownProgress {
        print("V2-14| 倒计时芯片数据 累计=\(cp.elapsedDays) 剩余=\(cp.daysLeft) 总跨度=\(cp.totalDays) 完成=\(percentText(cp.ratio, dec: 0))")
    }
    model.toggleCountdownChip(.percent)
    print("V2-15| 隐藏完成进度芯片=\(model.isCountdownChipHidden(.percent)) 显示数=\(CountdownChip.allCases.count - model.hiddenCountdownChips.count)/\(CountdownChip.allCases.count)")

    // ── 2.1 架构自检 ─────────────────────────────────────────────
    model.privacyEnabled = true
    model.privacyUnlockedUntil = nil
    let si = model.progressInfo, di = model.countdownInfo
    print("V3-1| 隐私开启 薪酬大字=\(si.leading) caption=\(si.caption)")
    print("V3-1| 隐私开启 倒计时大字=[\(di.leading)\(di.trailing)] caption=\(di.caption)")
    print("V3-2| 隐私未覆盖倒计时=\(!di.caption.contains("隐私") && !di.leading.contains("%") )（应为 true）")
    print("V3-3| 两页数据不串线=\(si.mode == .salary && di.mode == .countdown && si.caption != di.caption)")
    model.privacyEnabled = false

    let rd = RecordDayItem(name: "在一起", year: 2024, month: 5, day: 20, targetDays: 0)
    print("V3-4| 添加纪念日=\(model.addRecordDay(rd) ?? "OK") 数量=\(model.recordDays.count)")
    let ri = model.recordDayInfo
    print("V3-5| 纪念日 大字=[\(ri.leading)\(ri.trailing)] caption=\(ri.caption) footer=\(ri.footer)")
    if let rp = model.activeRecordDayProgress {
        print("V3-6| 纪念日数据 累计=\(rp.elapsedDays) 天 累计时长=\(rp.span.shortText) 总天数=\(rp.span.totalDays)")
    }
    print("V3-7| 纪念日页无金额=\(!(ri.leading + ri.trailing + ri.caption + ri.footer).contains("¥")) mode=\(ri.mode.rawValue)")
    model.toggleRecordDayChip(.duration)
    model.toggleMoneyChip(.dayRate)
    print("V3-8| 三组模块开关独立 纪念日隐藏=\(model.isRecordDayChipHidden(.duration)) 薪酬隐藏=\(model.isMoneyChipHidden(.dayRate)) 倒计时隐藏=\(model.isCountdownChipHidden(.percent))")
    print("V3-9| 互不串线=\(!model.isMoneyChipHidden(.perSec) && !model.isCountdownChipHidden(.elapsed) && !model.isRecordDayChipHidden(.elapsed))")
    model.toggleHomeCard(.recordDay)
    print("V3-10| 首页卡独立隐藏 纪念日卡=\(model.isHomeCardHidden(.recordDay)) 薪酬卡=\(model.isHomeCardHidden(.money)) 倒计时卡=\(model.isHomeCardHidden(.countdown))")
    print("V3-11| 模块命名 Your Money=\(DetailMode.salary.module) Your Days(倒计时)=\(DetailMode.countdown.module) Your Days(纪念日)=\(DetailMode.recordDay.module)")
    print("V3-12| 三个二级页 \(DetailMode.allCases.map { $0.page.heightKey }.joined(separator: "/"))")
    model.removeRecordDay(id: rd.id)

    model.toggleButton(.clockIn)
    print("V2-12| 隐藏打卡上班=\(model.isButtonHidden(.clockIn)) 其他按钮仍显示=\(!model.isButtonHidden(.clockOut))")
    model.removeCountdown(id: cd.id)
    print("V2-13| 删除倒计时后数量=\(model.countdowns.count)")

    // MARK: - 2.2 自检：主题 / 首页卡下限 / 加班段
    print("V4-1| 主题数=\(AppTheme.allCases.count) 预设=\(AppTheme.allCases.map(\.title).joined(separator: " / "))")
    model.selectTheme(.mint)
    print("V4-2| 选薄荷绿 theme=\(model.currentTheme.title) 实色主题=\(!AppPalette.glass) alpha=\(String(format: "%.2f", AppPalette.alpha))")
    model.setThemeAlpha(0.42)
    print("V4-3| 透明度独立可调=\(String(format: "%.2f", AppPalette.alpha)) 背景RGB通道数=\(AppPalette.rgb(AppPalette.bg).count)")
    model.themeColorBinding(2).wrappedValue = Color(red: 0.2, green: 0.4, blue: 0.9)
    print("V4-4| 色卡改重点色 蓝通道=\(String(format: "%.2f", AppPalette.rgb(AppPalette.accent)[2]))（应为 0.90）")
    model.selectTheme(.sony30)
    print("V4-5| Sony30 背景=\(AppPalette.rgb(AppPalette.bg).map { String(format: "%.2f", $0) }.joined(separator: ",")) 四色点缀=\(AppPalette.highlights.count)")
    model.selectTheme(.liquidGlass)

    model.hiddenHomeCards = []
    model.toggleHomeCard(.recordDay)
    model.toggleHomeCard(.countdown)
    let hiddenBefore = model.hiddenHomeCards.count
    model.toggleHomeCard(.money)
    print("V4-6| 最后一张卡被拦下=\(model.hiddenHomeCards.count == hiddenBefore) 提示=[\(model.homeCardGuard ?? "无")] 仍可见=\(HomeCard.allCases.count - model.hiddenHomeCards.count) 张")
    model.toggleHomeCard(.recordDay)

    model.salaryText = "3500"
    model.manualOvertime = false
    let otBefore = model.overtimeSeconds
    model.startOvertime()
    print("V4-7| 开始加班 working=\(model.working) manual=\(model.manualOvertime) overtimeNow=\(model.overtimeNow) 日志=\(model.logText)")
    model.endOvertime()
    print("V4-8| 结束加班 加班秒数 \(String(format: "%.3f", otBefore))→\(String(format: "%.3f", model.overtimeSeconds)) manual复位=\(!model.manualOvertime) working=\(model.working)")
    print("V4-9| 加班按钮已注册=\(HomeButton.allCases.contains(.overtime)) 按钮口径=首页2/薪酬页3/YourDays 0")
    print("V4-10| 主题落盘 themeId=\(model.currentTheme.rawValue) glass=\(AppPalette.glass)")

    // 2.2.1：关于页 / 作者信息 / 主题与版权迭代记录
    let about = aboutCreditsText()
    print("V4-11| 关于页含版本=\(about.contains(APP_VERSION)) Build=\(about.contains(APP_BUILD)) 日期=\(about.contains(APP_RELEASE_DATE)) 开发者=\(about.contains(DEV_NAME))")
    print("V4-12| Sony 声明=\(about.contains("Sony Interactive Entertainment")) 商标归属=\(SONY_COPYRIGHT_NOTICE.contains("商标")) 版权行=\(about.contains(APP_COPYRIGHT_LINE))")
    print("V4-13| 主题与版权迭代 \(RELEASE_HISTORY.count) 条 主题完整=\(RELEASE_HISTORY.allSatisfy { !$0.theme.isEmpty }) 声明完整=\(RELEASE_HISTORY.allSatisfy { !$0.copyright.isEmpty }) 日期完整=\(RELEASE_HISTORY.allSatisfy { !$0.date.isEmpty })")
    print("V4-14| 界面去 emoji：模块图标全空=\(DetailMode.allCases.allSatisfy { $0.icon.isEmpty }) 主题图标全空=\(AppTheme.allCases.allSatisfy { $0.icon.isEmpty })")

    // 2.3 菜单栏显示项：MONEY / DAYS 自选、至少一项、轮播、取值兜底
    let allKinds = StatusBarKind.allCases
    print("V4-15| 菜单栏项 \(allKinds.count) 种 MONEY×\(allKinds.filter { $0.group == .money }.count) DAYS×\(allKinds.filter { $0.group == .days }.count) 小字标签=\(BarGroup.money.tag)/\(BarGroup.days.tag)")
    model.statusBarKinds = [StatusBarKind.moneyToday.rawValue]
    model.toggleStatusBarKind(.moneyToday)
    print("V4-16| 最后一项不可取消=\(model.isStatusBarKindOn(.moneyToday)) 提示=[\(model.statusBarGuard ?? "无")]")
    model.toggleStatusBarKind(.daysCountdown)
    let picked = model.selectedStatusBarKinds
    print("V4-17| 混选=\("\(picked.map { $0.group.tag + "·" + $0.short })") 项数=\(picked.count) 顺序稳定=\(picked.map { $0.rawValue } == allKinds.filter { model.isStatusBarKindOn($0) }.map { $0.rawValue })")
    let values = allKinds.map { model.statusBarValue($0) }
    print("V4-18| 六项取值齐全=\(values.allSatisfy { !$0.text.isEmpty }) 今日=[\(model.statusBarValue(.moneyToday).text)] 倒计时=[\(model.statusBarValue(.daysCountdown).text + model.statusBarValue(.daysCountdown).unit)] 纪念日=[\(model.statusBarValue(.daysRecord).text)]")
    model.privacyEnabled = true
    print("V4-19| 隐私模式金额转百分比=\(model.statusBarValue(.moneyToday).text.contains("%")) 天数不受影响=\(!model.statusBarValue(.daysCountdown).text.contains("%"))")
    model.privacyEnabled = false
    model.statusBarKinds = [StatusBarKind.moneyToday.rawValue]

    // MARK: - 2.4 自检：倒计时起止时间 / 事件管理（改名 / 改日期 / 删除）/ 纪念日累计时长
    var ev = CountdownItem(name: "上线", month: 12, day: 1, year: 2026,
                           mode: "percent", createdKey: dateKey(Date.now))
    ev.startYear = 2026; ev.startMonth = 11; ev.startDay = 1
    ev.targetHour = 20; ev.targetMinute = 0
    print("V5-1| 新增带起止时间=\(model.addCountdown(ev) ?? "OK") 校验=\(countdownRangeError(ev) ?? "通过") 起点=\(ev.startKeyText ?? "自动") 时刻=\(ev.targetTimeText)")
    if let last = model.countdowns.last {
        model.renameCountdown(id: last.id, to: "上线（改名）")
        print("V5-2| 二级页改名=\(model.countdowns.last?.name ?? "空")")
        var fixed = last
        fixed.name = model.countdowns.last?.name ?? "上线"
        fixed.startMonth = 11; fixed.startDay = 2
        print("V5-3| 二级页改起始日=\(model.updateCountdown(id: last.id, with: fixed) ?? "OK") 起始=\(model.countdowns.last?.startKeyText ?? "自动")")
    }
    var badRange = ev
    badRange.startYear = 2026; badRange.startMonth = 12; badRange.startDay = 2
    print("V5-4| 起始晚于目标被拦=\(model.addCountdown(badRange) != nil) 提示=[\(countdownRangeError(badRange) ?? "无")]")
    var badTime = ev
    badTime.targetHour = 25
    print("V5-5| 25 点被拦=\(!badTime.valid)")

    let newRd = RecordDayItem(name: "搬家", year: 2025, month: 8, day: 1)
    print("V5-6| 新增纪念日=\(model.addRecordDay(newRd) ?? "OK") 条数=\(model.recordDays.count)")
    if let last = model.recordDays.last {
        var edit = last
        edit.name = "搬家（改名）"; edit.month = 7
        print("V5-7| 纪念日改名+改日期=\(model.updateRecordDay(id: last.id, with: edit) ?? "OK") 名=\(model.recordDays.last?.name ?? "空") 月=\(model.recordDays.last?.month ?? 0)")
        print("V5-8| 累计时长=\(model.recordDays.last.flatMap { recordDayProgress($0)?.span.shortText } ?? "无") 起点=\(model.recordDays.last?.year ?? 0)/\(model.recordDays.last?.month ?? 0)/\(model.recordDays.last?.day ?? 0)")
        model.removeRecordDay(id: last.id)
        print("V5-9| 删除后条数=\(model.recordDays.count)")
    }
}

MainActor.assumeIsolated {
    migrateLegacyDefaultsIfNeeded()
    // 自检模式用独立 defaults 域，绝不碰真实数据
    let simMode = CommandLine.arguments.contains("--sim-autoout")
        || CommandLine.arguments.contains("--sim-autoin")
        || CommandLine.arguments.contains("--sim-v2")
    // 可用环境变量指定独立 defaults 域（截图/演示用，绝不碰真实数据）
    let suite = ProcessInfo.processInfo.environment["XINXIN_DEFAULTS_SUITE"]
    let model = EarnModel(ud: simMode
        ? (UserDefaults(suiteName: "xiaoxinxin-sim") ?? .standard)
        : (suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard))

    // 自检模式：--sim-v2 验证 2.0 新逻辑；--sim-autoin 验证自动上班；--sim-autoout 验证全链路
    if CommandLine.arguments.contains("--sim-v2") {
        runSimV2(model)
        exit(0)
    }
    if CommandLine.arguments.contains("--sim-autoin") {
        runSimAutoin(model)
        exit(0)
    }
    if simMode {
        runSimAutoout(model)
        exit(0)
    }

    // 导出界面图模式：--export-shots <目录> [--dark] [--shot-salary <月薪>] [--shot-worked <分钟>]
    if let i = CommandLine.arguments.firstIndex(of: "--export-shots"), i + 1 < CommandLine.arguments.count {
        func argValue(_ flag: String) -> String? {
            guard let j = CommandLine.arguments.firstIndex(of: flag), j + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[j + 1]
        }
        if let raw = argValue("--shot-salary"), let salary = Double(raw), salary > 0 {
            seedShotDemo(model, salary: salary,
                         workedMinutes: Double(argValue("--shot-worked") ?? "152") ?? 152)
        }
        model.showOnboarding = false   // 2.0 首启引导不能挡住产品截图
        exportShots(to: CommandLine.arguments[i + 1], model: model,
                    dark: CommandLine.arguments.contains("--dark"))
        exit(0)
    }
    // 2.5.1：不用 NSHostingController——它内部的 NSHostingView 拒绝「首次点击」，
    // 窗口在后台时点顶部留白会被系统吞掉，App 不会激活，窗口就一直沉在后面。
    let hosting = ClickableHostingView(rootView: ContentView(model: model))
    // 关键：不要让 SwiftUI 反向调整窗口尺寸——它会按当前内容高度把窗口拉回去，
    // 和我们自己的贴合同步打架，表现出来就是“展开时窗口变形/抖动”
    hosting.sizingOptions = []
    // 2.6.2：contentView 换成一个纯容器，三件事一起解决：
    // ① 容器底垫一层 1.2% alpha —— 圆角外沿那几个原本完全透明的像素也算「窗口的」，
    //    系统不会再把点在那儿的点击判给后面的 App（「点一下窗口就沉下去」的最后来源）；
    // ② 圆角裁剪只挂在 hosting 的 layer 上，视觉仍是圆角，容器保持矩形以便接住点击；
    // ③ 顶部 / 底部各压一条 12pt 的透明拖拽条（真实 NSView，永远在最上层）。
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 372, height: 560))
    container.autoresizesSubviews = true
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.012).cgColor
    hosting.frame = container.bounds
    hosting.autoresizingMask = [.width, .height]
    container.addSubview(hosting)
    // 2.2.1：窗口层统一圆角。此前只有 SwiftUI 的 clipShape 在裁，NSGlassEffectView 自己
    // 还画一套圆角、系统阴影又按矩形窗口算一套；窗口高度随页面变化（顶部锚定）后，
    // 底部两角会残留旧阴影 / 斜切三角，看起来就是「页面变形」。
    hosting.wantsLayer = true
    hosting.layer?.cornerRadius = 32
    hosting.layer?.cornerCurve = .continuous
    hosting.layer?.masksToBounds = true

    // 顶部 / 底部拖拽条：始终在最上层。按住即拖窗口，点一下也只会把窗口置前
    let stripH: CGFloat = 12
    let topStrip = WindowDragStrip(frame: NSRect(x: 0, y: container.bounds.height - stripH,
                                                 width: container.bounds.width, height: stripH))
    topStrip.autoresizingMask = [.width, .minYMargin]
    let bottomStrip = WindowDragStrip(frame: NSRect(x: 0, y: 0,
                                                    width: container.bounds.width, height: stripH))
    bottomStrip.autoresizingMask = [.width, .maxYMargin]
    container.addSubview(topStrip)
    container.addSubview(bottomStrip)

    panel.contentView = container
    // sizingOptions 关闭后控制器不再提供 preferredContentSize，挂上去时窗口会被缩成 0×0，
    // 内容随即被窗口边界裁掉（首页只剩一条）。这里立刻把尺寸写回去。
    panel.setContentSize(NSSize(width: 372, height: 560))
    panel.invalidateShadow()

    // 主题外观：窗口与 SwiftUI 宿主都按主题明暗走，避免系统深色模式把浅色主题的文字刷白
    let syncAppearance: (Bool) -> Void = { dark in
        let name: NSAppearance.Name = dark ? .darkAqua : .aqua
        panel.appearance = NSAppearance(named: name)
        hosting.appearance = NSAppearance(named: name)
    }
    onAppearanceSync = syncAppearance
    syncAppearance(AppPalette.isDark)

    // 页面切换时同步窗口尺寸（顶部锚定）；进设置页时把面板设为 key 以便输入
    model.onResize = {
        DispatchQueue.main.async {
            let old = panel.frame
            let newW = model.page == .mini ? 330.0 : 372.0
            // 设置页高度用内容高度直接算：fittingSize 要等 SwiftUI 布局/动画结束才更新，
            // 中间几十毫秒会与窗口高度不一致，内容就会溢出画到别的卡片上（观感即“窗口变形”）
            let newH: CGFloat = model.page == .settings
                ? SettingsUIState.viewport(contentHeight: SettingsUIState.shared.contentHeight)
                : max(model.page == .mini ? 90 : 300,
                      SettingsUIState.shared.pageHeights[model.page.heightKey] ?? 0)
            // 量不到内容高度时不改窗口，避免把窗口压成一条
            if model.page != .settings && (SettingsUIState.shared.pageHeights[model.page.heightKey] ?? 0) < 40 { return }
            // 视口高度与窗口高度同帧对齐：先更新视口，再设窗口，SwiftUI 永远不会按“更大的高度”绘制
            if model.page == .settings { SettingsUIState.shared.viewportHeight = newH }
            let newFrame = NSRect(x: old.midX - newW / 2, y: old.maxY - newH, width: newW, height: newH)
            if abs(newFrame.height - old.height) < 0.5 && abs(newFrame.width - old.width) < 0.5 {
                if model.page == .settings && !panel.isKeyWindow { panel.makeKey() }
                return
            }
            // 窗口与内容视口必须同一帧到位：AppKit 动画会让窗口高度落在视口之后，
            // 视口比窗口大的那几帧内容就会被裁掉，看起来就是“变形”
            panel.setFrame(newFrame, display: true, animate: false)
            // 顶部锚定的 resize 会改底部位置：不重算阴影，系统仍按旧高度画，
            // 底部两角就会留下一块旧的斜切阴影（首页/二级页都出现的「变形」）
            panel.invalidateShadow()
            if model.page == .settings && !panel.isKeyWindow { panel.makeKey() }
        }
    }
    // 关闭收纳：进入状态栏模式（图标显示金额+进度），小窗隐藏、继续计费
    model.onHidePanel = {
        model.statusBarMode = true
        panel.orderOut(nil)
    }

    panel.center()

    // 自检/演示用：--show-about 启动即弹出「关于」面板（--about-dump 附带窗口诊断后退出）
    if CommandLine.arguments.contains("--show-about") {
        let dump = CommandLine.arguments.contains("--about-dump")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            showAboutPanel()
            guard dump else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                for w in NSApp.windows {
                    print("WIN| \(type(of: w)) | title=\(w.title) | visible=\(w.isVisible) | key=\(w.isKeyWindow) | \(Int(w.frame.width))x\(Int(w.frame.height))")
                }
                // 把「关于」面板渲染成 PNG 供自检
                if let w = NSApp.windows.first(where: {
                    String(describing: type(of: $0)) == "NSPanel" && $0.isVisible
                }), let cv = w.contentView,
                   let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                    cv.cacheDisplay(in: cv.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/about-panel.png"))
                        print("ABOUT-PNG| /tmp/about-panel.png")
                    }
                }
                exit(0)
            }
        }
    }

    // 截图/演示用：可用环境变量指定初始视图（不影响正常使用）
    // XINXIN_PAGE=home|settings|mini   XINXIN_STATUSBAR=1
    let env = ProcessInfo.processInfo.environment
    if let p = env["XINXIN_PAGE"] {
        switch p {
        case "home": model.page = .home
        case "salary": model.page = .salary
        case "countdown": model.page = .countdown
        case "recordDay": model.page = .recordDay
        case "settings": model.page = .settings
        case "mini": model.page = .mini
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.onResize?() }
    }
    if env["XINXIN_STATUSBAR"] == "1" {
        model.statusBarMode = true
        panel.orderOut(nil)
    }
    // 2.0 截图/演示 hook（只在裸二进制 + 独立 defaults 域使用，正常启动不受影响）
    if let a = env["XINXIN_SHOT_APPEARANCE"] {
        NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
    }
    if let raw = env["XINXIN_SHOT_METRIC"], let m = ProgressMetric(rawValue: raw), m != .countdown {
        model.progressMetric = m
    }
    if let p = env["XINXIN_SHOT_PAGE"] {
        switch p {
        case "home": model.page = .home
        case "salary": model.page = .salary
        case "countdown": model.page = .countdown
        case "recordDay": model.page = .recordDay
        case "settings": model.page = .settings
        case "mini": model.page = .mini
        default: break
        }
    }
    if env["XINXIN_SHOT_PRIVACY"] == "1" { model.privacyEnabled = true }
    if let v = env["XINXIN_SHOT_ONBOARD"] { model.showOnboarding = (v == "1") }
    // 2.2 截图钩子：主题 / 背景透明度 / 加班段状态
    if let raw = env["XINXIN_SHOT_THEME"], let t = AppTheme(rawValue: raw) { model.selectTheme(t) }
    if let a = Double(env["XINXIN_SHOT_ALPHA"] ?? "") { model.setThemeAlpha(a) }
    if env["XINXIN_SHOT_OVERTIME"] == "1" { model.startOvertime() }
    if env["XINXIN_SHOT_CARD_GUARD"] == "1" {
        model.hiddenHomeCards = Set(HomeCard.allCases.dropFirst().map { $0.rawValue })
        model.homeCardGuard = "首页至少要保留一个模块，最后一张不能隐藏"
    }
    if env["XINXIN_SHOT_COUNTDOWN"] == "1" && model.countdowns.isEmpty {
        let demo = CountdownItem(name: "新年", month: 1, day: 1, createdKey: dateKey(Date.now))
        var launch = CountdownItem(name: "项目上线", month: 12, day: 1, year: 2026,
                                   mode: "percent", createdKey: "2026-11-01")
        launch.startYear = 2026; launch.startMonth = 11; launch.startDay = 1
        launch.targetHour = 20; launch.targetMinute = 0
        model.countdowns = [demo, launch]
        model.activeCountdownId = launch.id
    }
    if env["XINXIN_SHOT_RECORDDAY"] == "1" && model.recordDays.isEmpty {
        let demo = RecordDayItem(name: "在一起", year: 2024, month: 5, day: 20, targetDays: 0)
        let job = RecordDayItem(name: "入职", year: 2026, month: 3, day: 2, targetDays: 0)
        model.recordDays = [demo, job]
        model.activeRecordDayId = demo.id
    }
    if env["XINXIN_SHOT_EVENTS"] == "1" {
        SettingsUIState.shared.openEventManager(.countdown)
        SettingsUIState.shared.openEventManager(.anniversary)
    }
    if let h = Double(env["XINXIN_SHOT_WORKED_HOURS"] ?? ""), h > 0, h <= 24 {
        model.correctWork(hours: h)   // 演示 12h → 150% 与橙色第二段
    }
    // 2.3 截图钩子：菜单栏显示项 / 展开指定设置分组
    if let raw = env["XINXIN_SHOT_BARKINDS"] {
        let ids = raw.split(separator: ",").map(String.init).filter { StatusBarKind(rawValue: $0) != nil }
        if !ids.isEmpty { model.statusBarKinds = Set(ids) }
    }
    if env["XINXIN_SHOT_BARROTATE"] == "1" { model.statusBarRotate = true }
    if env["XINXIN_SHOT_BARDATA"] == "0" { model.statusBarShowData = false }
    if let g = env["XINXIN_SHOT_GROUP"] { SettingsUIState.shared.openGroups = [g] }

    // 诊断用：--shot-panel <文件> 把主面板实际渲染结果存成 PNG（校验有无被窗口裁切）
    if let i = CommandLine.arguments.firstIndex(of: "--shot-panel"), i + 1 < CommandLine.arguments.count {
        let path = CommandLine.arguments[i + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let cv = panel.contentView, let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                cv.cacheDisplay(in: cv.bounds, to: rep)
                if let d = rep.representation(using: .png, properties: [:]) {
                    try? d.write(to: URL(fileURLWithPath: path))
                    print("PANEL-SHOT| \(path) \(Int(cv.bounds.width))x\(Int(cv.bounds.height))")
                }
            }
            exit(0)
        }
    }

    // 诊断用：--probe-toggle <组id> [--probe-shots <dir>] 展开指定分组并逐帧打印/截图，检查是否抖动/变形
    if let i = CommandLine.arguments.firstIndex(of: "--probe-toggle"), i + 1 < CommandLine.arguments.count {
        let gid = CommandLine.arguments[i + 1]
        var shotDir: String? = nil
        if let j = CommandLine.arguments.firstIndex(of: "--probe-shots"), j + 1 < CommandLine.arguments.count {
            shotDir = CommandLine.arguments[j + 1]
            try? FileManager.default.createDirectory(atPath: shotDir!, withIntermediateDirectories: true)
        }
        model.page = .settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let f0 = panel.frame
            print("PROBE| before \(Int(f0.width))x\(Int(f0.height)) content=\(Int(SettingsUIState.shared.contentHeight)) open=\(SettingsUIState.shared.openGroups.sorted())")
            withAnimation(.easeInOut(duration: 0.18)) { SettingsUIState.shared.toggleGroup(gid) }
            for k in 0..<36 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(k)) {
                    let f = panel.frame
                    print("PROBE| t=\(k * 30)ms \(Int(f.width))x\(Int(f.height)) content=\(Int(SettingsUIState.shared.contentHeight))")
                    if let dir = shotDir, k % 2 == 0, let cv = panel.contentView,
                       let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                        cv.cacheDisplay(in: cv.bounds, to: rep)
                        if let d = rep.representation(using: .png, properties: [:]) {
                            try? d.write(to: URL(fileURLWithPath: "\(dir)/f\(String(format: "%02d", k)).png"))
                        }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { exit(0) }
        }
    }
    app.mainMenu = buildMainMenu(appName: "分刻")
    app.setActivationPolicy(.regular)   // 常规应用：Dock 图标 + Cmd-Tab，不会被当成后台偷跑
    // 开机自启动（--autostart）：静默停在状态栏，不弹主窗、不抢前台
    if CommandLine.arguments.contains("--autostart") {
        model.statusBarMode = true
        model.logText = "已随机启动，点状态栏图标即可展开；到上班时间会自动开始计费"
    } else {
        forcePanelFront(panel)
        // 启动后按真实内容贴合一次：关掉 sizingOptions 后窗口不会再自动适配内容
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { model.onResize?() }
    }
    let statusBar = StatusBarController(panel: panel, model: model)  // 必须强持有，否则释放后点击失效
    _ = statusBar

    // 统一「把面板捞回来」：小组件点击 / 点 Dock 图标 / 状态栏图标都走这里
    let bringPanelBack: () -> Void = {
        model.statusBarMode = false
        withAnimation { model.page = .home }
        forcePanelFront(panel)
    }
    URLOpener.shared.onOpen = bringPanelBack
    // 2.5：小组件点进来直接落到对应模块
    URLOpener.shared.onOpenPage = { host in
        model.statusBarMode = false
        withAnimation {
            switch host {
            case "days":    model.page = .countdown
            case "money":   model.page = .home
            default:        model.page = .home
            }
        }
        forcePanelFront(panel)
    }
    appDelegate.onReopen = bringPanelBack
    appDelegate.onShowSettings = {
        model.statusBarMode = false
        withAnimation { model.page = .settings }
        forcePanelFront(panel)
    }
    NSAppleEventManager.shared().setEventHandler(
        URLOpener.shared,
        andSelector: #selector(URLOpener.handle(_:reply:)),
        forEventClass: AEEventClass(kInternetEventClass),
        andEventID: AEEventID(kAEGetURL))

    // 自检：--selftest-launch 验证开机自启动的注册/注销（测完还原到测试前的状态）
    if CommandLine.arguments.contains("--selftest-launch") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let before = LaunchAtLogin.isEnabled
            print("LAUNCH| bundle=\(Bundle.main.bundlePath)")
            print("LAUNCH| before enabled=\(before) needsApproval=\(LaunchAtLogin.needsApproval) plist=\(FileManager.default.fileExists(atPath: LaunchAtLogin.plistURL.path))")
            let e1 = LaunchAtLogin.setEnabled(true)
            print("LAUNCH| enable -> \(e1 ?? "OK")  enabled=\(LaunchAtLogin.isEnabled) plist=\(FileManager.default.fileExists(atPath: LaunchAtLogin.plistURL.path))")
            let e2 = LaunchAtLogin.setEnabled(false)
            print("LAUNCH| disable -> \(e2 ?? "OK")  enabled=\(LaunchAtLogin.isEnabled) plist=\(FileManager.default.fileExists(atPath: LaunchAtLogin.plistURL.path))")
            if before { _ = LaunchAtLogin.setEnabled(true) }
            exit(0)
        }
    }

    // 诊断：--status-dump [--status-png <路径>] 打印并渲染菜单栏条目
    if CommandLine.arguments.contains("--status-dump") {
        let png: String? = {
            if let i = CommandLine.arguments.firstIndex(of: "--status-png"), i + 1 < CommandLine.arguments.count {
                return CommandLine.arguments[i + 1]
            }
            return nil
        }()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            statusBar.dumpStatus(png)
            exit(0)
        }
    }

    // 自检：--selftest-correct 校验校正工时算术
    if CommandLine.arguments.contains("--selftest-correct") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            print("RATE| 时薪=\(String(format: "%.4f", model.ratePerHour)) 每秒=\(String(format: "%.6f", model.ratePerSec))")
            print("INI | 工时=\(String(format: "%.3f", model.totalWorkedHours)) 累计=\(String(format: "%.2f", model.displayEarned))")
            for h in [3.0, 1.5, 0.0, 8.0] {
                model.correctWork(hours: h)
                print("SET | 目标=\(h) 工时=\(String(format: "%.3f", model.totalWorkedHours)) 累计=\(String(format: "%.2f", model.displayEarned))")
            }
            exit(0)
        }
    }

    // 自检：--selftest-close 走一遍「点击关闭按钮」的真实路径
    if CommandLine.arguments.contains("--selftest-close") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            print("BEFORE visible=\(panel.isVisible) barMode=\(model.statusBarMode) behavior=\(model.closeBehavior)")
            model.requestClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                print("AFTER  visible=\(panel.isVisible) barMode=\(model.statusBarMode) barTitle=[\(statusBar.barTitle ?? "?")]")
                exit(0)
            }
        }
    }

    // 贴边自动收纳：用户真的把窗口拖到屏幕左 / 右 / 下边缘再松手 → 收进状态栏
    // 2.4.1：旧实现挂在 didMoveNotification 上，页面切换（窗口高度变、origin 跟着变）
    // 和指尖轻微抖动都会排进定时器；窗口只要本来就贴着边，一次点击就能把它收掉。
    // 现在只认「拖拽松手 + 位移 ≥ 40pt」，顶部边缘不再参与（往上推窗口是最常见的操作）。
    var edgeDebounce: Timer?
    // 拖窗由 AppKit 的背景拖完成（isMovableByWindowBackground），这里只跟着统计位移
    NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                           object: panel, queue: .main) { _ in
        Task { @MainActor in WindowDragCenter.shared.noteMove(to: panel.frame.origin) }
    }
    WindowDragCenter.shared.onDragEnd = { distance in
        edgeDebounce?.invalidate()
        guard distance >= 40 else { return }
        edgeDebounce = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in
            Task { @MainActor in
                guard panel.isVisible, !model.statusBarMode, nearScreenEdge(panel.frame) else { return }
                model.statusBarMode = true
                model.logText = "已贴边收纳，状态栏图标可恢复"
                panel.orderOut(nil)
            }
        }
    }

    // 2.4.1：切回本 App 时把窗口重新提到本层级最前。
    // 之前的观感是「点一下窗口顶部，它自己沉到最底层」——点击被系统判成没人接收，
    // 前台切走再切回来也不会把窗口带上来。这里补一道兜底。
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                           object: nil, queue: .main) { _ in
        Task { @MainActor in
            guard panel.isVisible, !model.statusBarMode else { return }
            panel.orderFront(nil)
            if !panel.isKeyWindow { panel.makeKey() }
        }
    }

    app.run()
}
