// 小薪薪 — macOS 悬浮小窗版 v2
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
    @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) { onOpen?() }
}

// MARK: - 开发者信息（同时写进 Info.plist，可用 plutil 查验）
let DEV_NAME = "逍狗屁屁"
let DEV_TAGLINE = "让每一秒都看得见价值"
// 版本号单一来源 = Info.plist 的 CFBundleShortVersionString / CFBundleVersion（plutil 改一处，界面全跟）
// 裸二进制（脱离 bundle 跑自检）读不到 Info.plist 时用下面的兜底值
let APP_VERSION = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    ?? ProcessInfo.processInfo.environment["XINXIN_VERSION"] ?? "1.2"
let APP_BUILD = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
    ?? ProcessInfo.processInfo.environment["XINXIN_BUILD"] ?? "3"

/// 标准「关于」面板：开发者署名 + 版本 + 版权
@MainActor
func showAboutPanel() {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.lineSpacing = 3
    let credits = NSMutableAttributedString(
        string: "开发者　\(DEV_NAME)\n\(DEV_TAGLINE)",
        attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ])
    credits.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 11.5),
                         range: NSRange(location: 4, length: DEV_NAME.count))

    NSApp.orderFrontStandardAboutPanel(options: [
        .applicationName: "小薪薪",
        .applicationVersion: APP_VERSION,
        .version: "Build \(APP_BUILD)",
        .credits: credits,
    ] as [NSApplication.AboutPanelOptionKey: Any])
    NSApp.activate()
}

// MARK: - 计薪模型

enum Page { case home, settings, mini }

@MainActor
final class EarnModel: ObservableObject {
    @Published var page: Page = .home
    @Published var salaryText: String
    @Published var workDaysText: String      // 空 = 自动按节假日
    @Published var workStartText: String     // 上班时间 HH:mm
    @Published var workEndText: String       // 下班时间 HH:mm
    @Published var breakMinText: String      // 每日休息时长（分钟）
    @Published var manualHoursText: String = ""  // 手动补录已上班小时数
    @Published var working = false
    @Published var displayEarned: Double = 0
    @Published var gains: [Gain] = []
    @Published var logText: String = ""
    @Published var accentA = Color(red: 1, green: 0.41, blue: 0.38)
    @Published var accentB = Color(red: 0.88, green: 0.18, blue: 0.13)
    @Published var iconImage: NSImage?
    @Published var statusBarMode = false     // 缩小至状态栏：状态栏图标直接显示金额+进度
    @Published var closeBehavior: String     // 点击关闭按钮时："hide"=收纳到状态栏，"quit"=直接退出
    @Published var barSymbol: String         // 状态栏金额前缀符号/emoji，可自定义（空=只显示数字）
    @Published var autoOutEnabled: Bool      // 到点自动下班：到计划下班时刻自动打卡下班
    @Published var autoInEnabled: Bool       // 到点自动上班：到计划上班时刻自动打卡上班
    @Published var launchAtLogin: Bool       // 开机自动启动（登录项）
    @Published var launchAtLoginError: String?
    @Published var overtimeSeconds: Double = 0   // 今日加班累计秒数（自动下班后/过了下班时间再打卡的时段）
    @Published var dayLogRevision = 0        // 流水增删计数：驱动本月累计芯片刷新

    private var dayKey = ""                  // 当前计费日 yyyy-MM-dd，用于跨天自动重置
    private var autoInKey = ""               // 已自动打过卡的班次标识，同一班次只自动打一次
    private var dayLog: [String: [String: Double]] = [:]   // 历史流水：dateKey -> ["earned": 当日到账, "ot": 当日加班秒]

    var onResize: (() -> Void)?
    var onHidePanel: (() -> Void)?           // 关闭收纳：由入口注入隐藏面板的实现

    private var baseEarned: Double = 0
    private var clockInAt: Date?
    private var lastGainMark: Double = 0
    private var workedBeforeSession: Double = 0   // 今日此前已完成计费段的累计秒数
    private var timer: Timer?
    private let ud: UserDefaults
    private var tickCount = 0
    private var snapTimer: DispatchSourceTimer?   // 快照心跳：不依赖界面存活
    private var snapBeat = 0
    private var napToken: NSObjectProtocol?

    // WidgetKit 数据快照：主 App（未沙盒）写出，小组件扩展（沙盒）经临时豁免授权读取
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
        let dir = dataDir.appendingPathComponent("Library/Application Support/小薪薪", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget-snapshot.json")
    }

    func writeWidgetSnapshot(reload: Bool = false, alive: Bool = true) {
        let dict: [String: Any] = [
            "baseEarned": baseEarned,
            "clockInAt": clockInAt?.timeIntervalSince1970 ?? 0,
            "working": working,
            "ratePerSec": ratePerSec,
            "ratePerDay": ratePerDay,
            "workedBeforeSession": workedBeforeSession,
            "salary": salary,
            "savedAt": Date.now.timeIntervalSince1970,
            "alive": alive,   // 主 App 是否还活着：false 表示已退出，小组件据此停表
        ]
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
        ud.synchronize()
        if reload {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    let autoDays: Int
    var salary: Double { Double(salaryText) ?? 0 }
    var workDays: Int { Int(workDaysText) ?? autoDays }
    var isAutoDays: Bool { workDaysText.isEmpty || Int(workDaysText) == autoDays }
    var effectiveHours: Double {
        effectiveWorkHours(startStr: workStartText, endStr: workEndText,
                           breakMinutes: Double(Int(breakMinText) ?? 60))
    }
    var ratePerSec: Double { salary / Double(workDays) / effectiveHours / 3600 }
    var ratePerHour: Double { salary / Double(workDays) / effectiveHours }
    var ratePerDay: Double { salary / Double(workDays) }
    var progress: Double { ratePerDay > 0 ? min(1, displayEarned / ratePerDay) : 0 }
    // 今日已工作秒数 = 已结束段 + 正在进行的计费段（重启后也不会漏算）
    var workedSeconds: Double {
        guard working, let start = clockInAt else { return workedBeforeSession }
        return workedBeforeSession + max(0, Date.now.timeIntervalSince(start))
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
    // 加班中：当前计费段是在计划下班之后打卡的
    var overtimeNow: Bool {
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

    init(ud: UserDefaults = .standard) {
        self.ud = ud
        salaryText = ud.string(forKey: "salary") ?? ""
        workDaysText = ud.string(forKey: "workDaysText") ?? ""
        workStartText = ud.string(forKey: "workStart") ?? "09:00"
        workEndText = ud.string(forKey: "workEnd") ?? "18:00"
        breakMinText = ud.string(forKey: "breakMin") ?? "60"
        closeBehavior = ud.string(forKey: "closeBehavior") ?? "hide"
        barSymbol = ud.string(forKey: "barSymbol") ?? ""
        autoDays = monthWorkDays(Date.now)
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
            logText = "⏰ \(timeStr(clockInAt!)) 打卡上班，继续计费中"
        }
        loadIcon()
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
            self.writeWidgetSnapshot(reload: self.snapBeat % 20 == 0)   // 每 5 分钟强刷一次时间线
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
        if let img = iconImage, let (a, b) = extractPalette(img) {
            accentA = Color(nsColor: a)
            accentB = Color(nsColor: b)
        }
    }

    func setCustomIcon(_ data: Data?) {
        if let data { ud.set(data, forKey: "customIconData") } else { ud.removeObject(forKey: "customIconData") }
        loadIcon()
    }

    func tick() {
        checkDayRollover()
        autoClockInIfNeeded()
        autoClockOutIfNeeded()
        guard working, let start = clockInAt else { return }
        displayEarned = baseEarned + Date.now.timeIntervalSince(start) * ratePerSec
        if displayEarned - lastGainMark >= 0.01 {
            lastGainMark = displayEarned
            spawnGain()
        }
        tickCount += 1
        if tickCount % 900 == 0 { writeWidgetSnapshot() }   // 30fps 计时 → 约每 30 秒落一次快照
        // 每 5 分钟强制刷新一次小组件时间线：小组件自身只有 10 分钟的预生成 entry，
        // 靠这条心跳兜住 chronod 不按期 reload 的情况
        if tickCount % 9000 == 0 { writeWidgetSnapshot(reload: true) }
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
            logText = "🌙 \(timeStr(clockInAt!)) 加班打卡，已过下班时间，按原费率继续计费"
        } else {
            logText = "⏰ \(timeStr(clockInAt!)) 打卡上班，金币开始滚动"
        }
        persist()
    }

    func clockOut(auto: Bool = false) {
        guard working, let start = clockInAt else { return }
        let elapsed = max(0, Date.now.timeIntervalSince(start))
        baseEarned += elapsed * ratePerSec
        workedBeforeSession += elapsed
        // 本段开始于计划下班之后 → 计入加班时长
        if let end = scheduledEnd, start >= end { overtimeSeconds += elapsed }
        displayEarned = baseEarned
        working = false
        clockInAt = nil
        if auto {
            logText = "🏁 \(timeStr(Date.now)) 已到下班时间，自动打卡下班，今日共到账 ¥\(fmt(baseEarned))"
        } else {
            logText = "🏁 \(timeStr(Date.now)) 下班打卡，今日共到账 ¥\(fmt(baseEarned))"
                + (overtimeMinutes > 0 ? "（含加班 \(overtimeMinutes) 分钟）" : "")
        }
        persist()
    }

    // 昨日账目落流水；只保留最近两个月，防止无限增长
    private func flushDayLog(_ key: String) {
        guard baseEarned > 0 || overtimeSeconds > 0 else { return }
        dayLog[key] = ["earned": baseEarned, "ot": overtimeSeconds]
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
        logText = wasWorking ? "🌅 跨入新的一天，今日累计已重置，继续计费"
                             : "🌅 新的一天，今日累计已重置"
        persist()
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
        let key = shiftKey(start)
        guard autoInKey != key else { return }               // 本班次已自动打过（含跨零点前后半夜）
        autoInKey = key
        ud.set(autoInKey, forKey: "autoInKey")
        // 刚好到点（2 分钟内）从上班时刻起算；开机晚了则从当前时刻起算，不白送工时
        let lateBy = now.timeIntervalSince(start)
        let origin = lateBy <= 120 ? start : now
        clockIn(at: origin)
        logText = lateBy <= 120
            ? "🌅 \(timeStr(origin)) 已到上班时间，自动打卡上班"
            : "🌅 \(timeStr(origin)) 自动打卡上班（已过上班时间，从中途起算）"
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
        ud.set(salaryText, forKey: "salary")
        baseEarned = 0
        displayEarned = 0
        lastGainMark = 0
        workedBeforeSession = 0
        if working {
            clockInAt = Date.now
            logText = "↻ 月薪已更新，从现在重新计费"
        }
        persist()
    }

    func onWorkDaysChanged() {
        ud.set(workDaysText, forKey: "workDaysText")
    }

    func onScheduleChanged() {
        ud.set(workStartText, forKey: "workStart")
        ud.set(workEndText, forKey: "workEnd")
        ud.set(breakMinText, forKey: "breakMin")
        // 工时变化会改变费率：当前计费段从现在重新起算，保证金额不重复计算
        if working {
            clockInAt = Date.now
            lastGainMark = baseEarned
            logText = "↻ 工作时长已更新，从现在按新费率计费"
        }
    }

    // 校正工时：把今天实际工作的总时长设为指定值（多记/少记均可），
    // 与当前已计工时的差额按费率折算，直接反映到今日累计与进度条
    func correctWork(hours: Double) {
        guard hours >= 0, hours <= 24 else { return }
        let current = totalWorkedHours
        let delta = hours - current
        guard abs(delta) > 0.001 else {
            logText = "⏱ 工时无需校正，当前已是 \(fmt(current, 1)) 小时"
            return
        }
        baseEarned += delta * 3600 * ratePerSec
        if baseEarned < 0 { baseEarned = 0 }
        displayEarned = baseEarned
        workedBeforeSession = max(0, workedBeforeSession + delta * 3600)
        lastGainMark = baseEarned
        let verb = delta > 0 ? "补记" : "核减"
        logText = "⏱ 校正为 \(fmt(hours, 1)) 小时（\(verb) \(fmt(abs(delta), 1))h），今日累计 ¥\(fmt(baseEarned))"
        if abs(totalWorkedHours - hours) > 0.05 {
            logText = "⏱ 计费中，工时最低为本段 \(fmt(totalWorkedHours, 1)) 小时"
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

enum Glass {
    /// 玻璃填充：浅色 = 白雾，深色 = 深灰雾（透明度略高，保证层次）
    static func fill(_ a: Double) -> Color {
        dynColor(NSColor(white: 1, alpha: a),
                 NSColor(white: 0.11, alpha: min(0.94, 0.26 + a * 1.15)))
    }
    /// 玻璃描边：浅色 = 亮白线，深色 = 低透明白细线
    static func line(_ a: Double) -> Color {
        dynColor(NSColor(white: 1, alpha: a),
                 NSColor(white: 1, alpha: max(0.055, a * 0.24)))
    }
}

// 喜庆红：深色下提亮，避免在暗背景上糊成一团
let redDeep = dynColor(NSColor(red: 0.84, green: 0, blue: 0.08, alpha: 1),
                       NSColor(red: 1.0, green: 0.38, blue: 0.34, alpha: 1))

struct IconChip: View {
    let icon: String
    let value: String
    let label: String
    var highlight = false

    var body: some View {
        VStack(spacing: 3) {
            Text(icon).font(.system(size: 14))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(highlight ? redDeep : Color.primary.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 首页

struct HomeView: View {
    @ObservedObject var model: EarnModel

    var body: some View {
        VStack(spacing: 0) {
            header
            amountView
            progressZone
            if model.salary <= 0 { goToSettingsHint }
            chips
            buttons
            logLine
        }
        .padding(20)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("💰 小薪薪").font(.system(size: 15, weight: .bold))
                .fixedSize()
            Text("v\(APP_VERSION)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(Glass.fill(0.32)))
                .overlay(Capsule().strokeBorder(Glass.line(0.5), lineWidth: 1))
            Spacer(minLength: 2)
            HStack(spacing: 4) {
                Circle()
                    .fill(model.overtimeNow ? Color.orange : (model.working ? Color.red : Color.gray.opacity(0.6)))
                    .frame(width: 7, height: 7)
                    .shadow(color: model.overtimeNow ? .orange : (model.working ? .red : .clear), radius: 4)
                Text(model.overtimeNow ? "加班中" : (model.working ? "计费中" : "未打卡"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Capsule().fill(Glass.fill(0.35)))
            .overlay(Capsule().strokeBorder(Glass.line(0.5), lineWidth: 1))
            .fixedSize()
            // 大小窗口切换：完整 ↔ 迷你条
            GlassIconButton(symbol: "rectangle.compress.vertical", help: "缩小为迷你条（可再展回大窗）") { withAnimation { model.page = .mini } }
            // 收缩至状态栏：小窗隐藏，菜单栏图标继续走数
            GlassIconButton(symbol: "menubar.rectangle", help: "收缩至状态栏（菜单栏继续显示金额）") { model.collapseToStatusBar() }
            GlassIconButton(symbol: "gearshape", help: "设置") { withAnimation { model.page = .settings } }
            GlassIconButton(symbol: "xmark", help: model.closeBehavior == "quit" ? "退出小薪薪" : "收纳到状态栏") { model.requestClose() }
        }
        .padding(.bottom, 2)
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
            Text(model.overtimeNow ? "加班计费中 · 今日已到账"
                 : (model.working ? "正在进账 · 今日已到账" : "今日已到账"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("¥" + fmt(floor(model.displayEarned * 100) / 100))
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(model.working || model.displayEarned > 0 ? redDeep : Color.secondary.opacity(0.4))
                Text(String(format: "%02d", Int(floor(model.displayEarned * 10000)) % 100))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(model.working || model.displayEarned > 0 ? redDeep.opacity(0.75) : Color.secondary.opacity(0.4))
            }
            .frame(height: 52, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { gainLayer }
        .clipped()
    }

    // 金币进度条
    private var progressZone: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Glass.fill(0.38))
                        .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
                        .frame(height: 12)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                    Capsule()
                        .fill(LinearGradient(colors: [model.accentA, model.accentB], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, w * model.progress), height: 12)
                        .shadow(color: model.accentB.opacity(0.45), radius: 6)
                    Image(nsImage: model.iconImage ?? NSImage())
                        .resizable().scaledToFill()
                        .frame(width: 42, height: 42)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Glass.line(0.9), lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                        .offset(x: max(0, w * model.progress) - 21, y: -20)
                }
                .frame(width: w, height: 42, alignment: .bottomLeading)
            }
            .frame(height: 46)
            Text(progressText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 12)
    }

    private var progressText: String {
        guard model.salary > 0 else { return "在 ⚙️ 设置中填写月薪后开始累计进度" }
        if model.overtimeNow {
            return String(format: "已过下班时间，加班计费中 · 已加班 %d 分钟", model.overtimeMinutes)
        }
        if !model.working && model.overtimeMinutes > 0 {
            return String(format: "今日进度 %.1f%% · 今日已加班 %d 分钟", model.progress * 100, model.overtimeMinutes)
        }
        return String(format: "今日进度 %.1f%% · 距离全天还差 ¥%@", model.progress * 100,
                      fmt(max(0, model.ratePerDay - model.displayEarned)))
    }

    private var chipOTText: String {
        let m = Int(model.monthOTSeconds / 60)
        return m >= 60 ? "\(m/60)时\(m%60)分" : "\(m)分"
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

    private var chips: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                IconChip(icon: "💰", value: model.salary > 0 ? "¥" + fmt(model.salary, 0) : "--", label: "月薪")
                IconChip(icon: "📅", value: "\(model.workDays) 天\(model.isAutoDays ? "" : "·手动")", label: "工作日/月")
                IconChip(icon: "☀️", value: model.salary > 0 ? "¥" + fmt(model.ratePerDay) : "--", label: "日薪", highlight: true)
            }
            HStack(spacing: 8) {
                IconChip(icon: "⏱️", value: model.salary > 0 ? "¥" + fmt(model.ratePerHour) : "--", label: "时薪")
                IconChip(icon: "⚡", value: model.salary > 0 ? "¥" + fmt(model.ratePerSec, 4) : "--", label: "每秒进账", highlight: true)
                IconChip(icon: "⌛", value: model.workedMinutes >= 60
                         ? "\(model.workedMinutes/60)时\(model.workedMinutes%60)分" : "\(model.workedMinutes)分",
                         label: "今日已工作")
            }
            HStack(spacing: 8) {
                // 本月累计进账（点击在下方日志行查看构成）
                Button {
                    model.logText = "📈 本月累计进账 ¥\(fmt(model.monthEarned))，其中今日实时 ¥\(fmt(model.displayEarned))"
                } label: {
                    IconChip(icon: "📈", value: model.salary > 0 ? "¥" + fmt(model.monthEarned) : "--",
                             label: "本月累计进账", highlight: true)
                }
                .buttonStyle(.plain)
                // 本月累计加班时长
                Button {
                    let m = model.monthOTSeconds / 60
                    model.logText = m >= 60
                        ? String(format: "🌙 本月累计加班 %d 小时 %d 分钟", Int(m) / 60, Int(m) % 60)
                        : "🌙 本月累计加班 \(Int(m)) 分钟"
                } label: {
                    IconChip(icon: "🌙", value: chipOTText, label: "本月加班时长")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 14)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button(action: { withAnimation { model.clockIn() } }) {
                Text("打卡上班")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(LinearGradient(colors: [Color(red: 1, green: 0.41, blue: 0.38),
                                                                       Color(red: 0.88, green: 0.18, blue: 0.13)],
                                                              startPoint: .top, endPoint: .bottom)))
                    .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)],
                                                           startPoint: .top, endPoint: .center)).blendMode(.plusLighter).allowsHitTesting(false))
                    .overlay(Capsule().strokeBorder(Glass.line(0.5), lineWidth: 1))
                    .shadow(color: Color(red: 0.88, green: 0.18, blue: 0.13).opacity(0.45), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(model.salary <= 0 || model.working)
            .opacity(model.salary > 0 && !model.working ? 1 : 0.45)

            Button(action: { withAnimation { model.clockOut() } }) {
                Text("打卡下班")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(Glass.fill(0.42)))
                    .overlay(Capsule().strokeBorder(Glass.line(0.6), lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(!model.working)
            .opacity(model.working ? 1 : 0.45)
        }
    }

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
    @Published var contentHeight: CGFloat = 0   // 内容实际高度（折叠状态不同）→ 窗口自适应
    @Published var viewportHeight: CGFloat = 0  // SwiftUI 视口高度：始终等于窗口高度，避免溢出绘制
    @Published var pageHeights: [String: CGFloat] = [:]   // 首页/迷你条的内容自然高度（关掉 sizingOptions 后只能自己量）
    var forceHeight: CGFloat?                   // 导出截图时的高度上限
    var exportMode = false                      // 导出截图：按内容高度贴合，避免滚动裁切/居中留白

    static let allGroups = ["salary", "time", "correct", "look", "window", "ledger"]

    /// 设置页高度上限：内容短则贴合内容，超出上限在页内滚动
    static func maxViewport() -> CGFloat {
        if let f = shared.forceHeight { return f }
        if let s = ProcessInfo.processInfo.environment["XINXIN_SETTINGS_H"], let v = Double(s), v >= 400 {
            return CGFloat(v)
        }
        return min(955, max(560, (NSScreen.main?.visibleFrame.height ?? 900) - 32))
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
}

struct SettingsView: View {
    @ObservedObject var model: EarnModel
    @ObservedObject private var ui = SettingsUIState.shared

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
                    Text("⚙️ 设置").font(.system(size: 15, weight: .bold))
                    Spacer()
                    GlassIconButton(symbol: ui.openGroups.count == SettingsUIState.allGroups.count
                                    ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                                    help: ui.openGroups.count == SettingsUIState.allGroups.count ? "全部折叠" : "全部展开") {
                        toggleAllGroups()
                    }
                    GlassIconButton(symbol: "chevron.left", help: "返回") { withAnimation { model.page = .home } }
                }
                .padding(.bottom, 2)

                // MARK: 💰 薪酬与工作天数
                group("salary", icon: "💰", title: "薪酬与工作天数",
                      summary: model.salary > 0 ? "¥\(fmt(model.salary, 0))/月 · \(model.workDays) 天" : "未设置") {
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

                    caption("本月按 2026 国办法定节假日自动计算为 \(model.autoDays) 天（已扣节假日、含调休补班）。清空即恢复自动。")
                }

                // MARK: ⏰ 工作时间 · 自动打卡
                group("time", icon: "⏰", title: "工作时间 · 自动打卡",
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

                // MARK: ⏱ 工时校正
                group("correct", icon: "⏱", title: "工时校正",
                      summary: String(format: "今日已计 %.1f 小时", model.totalWorkedHours)) {
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

                // MARK: 🎨 外观与图标
                group("look", icon: "🎨", title: "外观与图标",
                      summary: (model.iconImage != nil ? "自定义图标" : "默认金币")
                               + (model.barSymbol.isEmpty ? " · 状态栏仅数字" : " · \(model.barSymbol)")) {
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
                    caption("图标自动裁圆并吸取主色，用于进度条与背景渐变。")

                    fieldLabel("状态栏符号", trailing: model.barSymbol.isEmpty ? "当前：仅数字" : "当前：\(model.barSymbol)")
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
                        ForEach(["💰", "⏱", "☀️", "🌱", "⚡"], id: \.self) { e in
                            Button { model.barSymbol = e; model.onBarSymbolChanged() } label: {
                                Text(e).font(.system(size: 15))
                                    .frame(width: 30, height: 28)
                            }
                            .buttonStyle(.plain)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Glass.fill(model.barSymbol == e ? 0.6 : 0.24)))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Glass.line(model.barSymbol == e ? 0.75 : 0.45), lineWidth: 1))
                        }
                    }
                    caption("金额前面的字符，任意 emoji 或符号都可以；留空则只显示数字。")
                }

                // MARK: 🪟 窗口行为
                group("window", icon: "🪟", title: "窗口与启动",
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
                        warnLine("⚠️ " + err)
                    } else if LaunchAtLogin.needsApproval {
                        warnLine("⚠️ 登录项已登记，还需到「系统设置 → 通用 → 登录项」允许小薪薪。")
                    }
                    caption("配合「工作时间 · 自动打卡」可实现开机后到点自动开始计费，不用每天手动点打卡。")
                }

                // MARK: 📋 流水明细
                group("ledger", icon: "📋", title: "流水明细",
                      summary: "共 \(model.dayLogTotal) 天 · 可查询/增删") {
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

                // 开发者署名（点击查看关于）
                Button { showAboutPanel() } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(red: 0.84, green: 0, blue: 0.08).opacity(0.42))
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
                .help("关于小薪薪 · 开发者 \(DEV_NAME)")
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
                                @ViewBuilder content: () -> C) -> some View {
        let open = ui.openGroups.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button { toggleGroup(id) } label: {
                HStack(spacing: 7) {
                    Text(icon).font(.system(size: 12))
                    Text(title).font(.system(size: 12, weight: .bold))
                    Spacer(minLength: 6)
                    Text(summary)
                        .font(.system(size: 10.5, weight: .semibold))
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
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.horizontal, 13)
                    .padding(.bottom, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Glass.fill(0.2)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .strokeBorder(Glass.line(open ? 0.6 : 0.42), lineWidth: 1))
    }

    // 折叠/展开不做图层过渡动画：SwiftUI 的插入动画会在布局更新前就把内容画出来，
    // 那几帧内容会压到下面的卡片上（用户看到的就是“窗口变形”）。一次性切换最稳。
    private func toggleGroup(_ id: String) {
        ui.toggleGroup(id)
    }

    private func toggleAllGroups() {
        ui.toggleAllGroups()
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
                .onChange(of: binding.wrappedValue) { _ in onChange() }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Glass.fill(0.24)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Glass.line(0.5), lineWidth: 1))
    }


    private var settingsMaxHeight: CGFloat { SettingsUIState.maxViewport() }

    private func sectionLabel(_ s: String, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(s).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.9))
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14).padding(.bottom, 6)
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
                            .fill(LinearGradient(colors: [model.accentA, model.accentB], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, geo.size.width * model.progress))
                    }
                }
                .frame(height: 9)
                Text("¥" + fmt(model.displayEarned, 4))
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
            Text(model.overtimeNow ? "加班中 · 点击展开" : (model.working ? "计费中 · 点击展开" : "点击展开"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { model.page = .home } }
    }
}

// MARK: - 根视图

struct ContentView: View {
    @ObservedObject var model: EarnModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            GlassPanel(cornerRadius: 32).ignoresSafeArea()
            // 图标主色染色层（深色下略增强，避免整块发灰）
            RadialGradient(colors: [model.accentA.opacity(scheme == .dark ? 0.30 : 0.22), .clear],
                           center: UnitPoint(x: 0.1, y: 0.0), startRadius: 0, endRadius: 420)
                .ignoresSafeArea().allowsHitTesting(false)
            RadialGradient(colors: [model.accentB.opacity(scheme == .dark ? 0.26 : 0.18), .clear],
                           center: UnitPoint(x: 0.9, y: 1.0), startRadius: 0, endRadius: 420)
                .ignoresSafeArea().allowsHitTesting(false)

            // 只量「页面内容」的自然高度：ZStack 会被背景渐变撑满，量它等于量窗口
            Group {
                switch model.page {
                case .home: HomeView(model: model).fixedSize(horizontal: false, vertical: true)
                case .settings: SettingsView(model: model)
                case .mini: MiniView(model: model).fixedSize(horizontal: false, vertical: true)
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: PageContentHeightKey.self, value: g.size.height)
            })
        }
        .onPreferenceChange(PageContentHeightKey.self) { h in
            // 关闭 sizingOptions 后 hosting 的 fittingSize 恒为 0，只能自己量内容高度
            guard h > 40 else { return }
            let key = model.page == .settings ? "settings" : (model.page == .mini ? "mini" : "home")
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
    private var refreshTimer: Timer?
    var barTitle: String? { statusItem.button?.title }   // 自检用

    init(panel: NSPanel, model: EarnModel) {
        self.panel = panel
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusMenu.delegate = self

        applyDefaultIcon()
        statusItem.button?.toolTip = "小薪薪（左键：显示/隐藏小窗，双指点按：菜单）"
        // 菜单永久挂在图标上：触控板双指点按（右键）由系统直接弹出，事件层 100% 可靠；
        // 左键点击在 menuNeedsUpdate 里拦截，转为显示/隐藏小窗
        statusItem.menu = statusMenu
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshBar() }
        }
    }

    private func applyDefaultIcon() {
        let img = NSImage(systemSymbolName: "banknote.fill", accessibilityDescription: "小薪薪")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.title = ""
    }

    // 状态栏迷你进度条（模板图，自动适配深浅色）
    private func progressImage(_ p: Double, active: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 36, height: 14))
        img.lockFocus()
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 1, width: 36, height: 12), xRadius: 6, yRadius: 6).fill()
        NSColor.white.withAlphaComponent(active ? 1.0 : 0.7).setFill()
        let w = max(4, CGFloat(p) * 36)
        NSBezierPath(roundedRect: NSRect(x: 0, y: 1, width: w, height: 12), xRadius: 6, yRadius: 6).fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    private func refreshBar() {
        if model.statusBarMode {
            barModeActive = true
            statusItem.button?.image = progressImage(model.progress, active: model.working)
            statusItem.button?.title = (model.barSymbol.isEmpty ? "" : model.barSymbol + " ") + fmt(model.displayEarned, 2)
            statusItem.button?.toolTip = String(format: "今日进度 %.1f%% · 已工作 %d 分钟\n左键点击恢复小窗",
                                                model.progress * 100, model.workedMinutes)
        } else if barModeActive {
            barModeActive = false
            applyDefaultIcon()
            statusItem.button?.toolTip = "小薪薪（左键：显示/隐藏，右键：菜单）"
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

    private func handleLeftClick() {
        if model.statusBarMode {
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

        let salaryItem = NSMenuItem(title: model.salary > 0
            ? "💰 薪酬：¥\(fmt(model.salary, 0)) /月"
            : "💰 薪酬：未设置（点击设置）", action: #selector(openSettings), keyEquivalent: "")
        salaryItem.target = self
        statusMenu.addItem(salaryItem)

        let daysItem = NSMenuItem(title: "📅 工作日：\(model.workDays) 天/月（\(model.isAutoDays ? "自动" : "手动")）",
                                  action: #selector(openSettings), keyEquivalent: "")
        daysItem.target = self
        statusMenu.addItem(daysItem)

        statusMenu.addItem(.separator())

        let punch = NSMenuItem(title: model.working ? "🏁 打卡下班" : "🕐 打卡上班",
                               action: #selector(punchFromMenu), keyEquivalent: "")
        punch.target = self
        statusMenu.addItem(punch)

        let full = NSMenuItem(title: "🔍 完整界面（大窗）", action: #selector(showFull), keyEquivalent: "")
        full.target = self
        statusMenu.addItem(full)

        let mini = NSMenuItem(title: "▫️ 迷你条（小窗，可展回大窗）", action: #selector(showMini), keyEquivalent: "")
        mini.target = self
        statusMenu.addItem(mini)

        let bar = NSMenuItem(title: model.statusBarMode ? "📌 恢复小窗显示" : "📌 收缩至状态栏（菜单栏走数）",
                             action: #selector(toggleStatusBarMode), keyEquivalent: "")
        bar.target = self
        statusMenu.addItem(bar)

        let toggle = NSMenuItem(title: panel.isVisible ? "隐藏小窗" : "显示小窗",
                                action: #selector(togglePanel), keyEquivalent: "h")
        toggle.target = self
        statusMenu.addItem(toggle)

        statusMenu.addItem(.separator())
        let about = NSMenuItem(title: "ⓘ 关于小薪薪 v\(APP_VERSION)（开发者 \(DEV_NAME)）",
                               action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        statusMenu.addItem(about)

        let quit = NSMenuItem(title: "退出小薪薪", action: #selector(quitApp), keyEquivalent: "q")
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
    return frame.minX <= v.minX + threshold || frame.maxX >= v.maxX - threshold
        || frame.minY <= v.minY + threshold || frame.maxY >= screen.frame.maxY - threshold
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
    if f.maxY > screen.frame.maxY - margin { f.origin.y = screen.frame.maxY - margin - f.height }
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
        ("home", .home, 372, 470),
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
        let q = NSMenuItem(title: "退出 小薪薪", action: #selector(quitNow), keyEquivalent: "")
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
panel.becomesKeyOnlyIfNeeded = true   // 只在点击文本框等需要键盘的场景成为 key，不抢焦点

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
    model.logText = "⏰ \(timeStr(start)) 打卡上班，继续计费中"
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
    manual.salaryText = "21000"
    manual.workStartText = timeStr(Date.now.addingTimeInterval(-60))
    manual.workEndText = timeStr(Date.now.addingTimeInterval(4 * 3600))
    manual.autoInEnabled = true
    manual.tick()               // 自动打上
    manual.clockOut()           // 用户手动下班
    manual.tick()
    print("AUTOIN5| 手动下班后不重打 working=\(manual.working)（应为 false）")
}

MainActor.assumeIsolated {
    migrateLegacyDefaultsIfNeeded()
    // 自检模式用独立 defaults 域，绝不碰真实数据
    let simMode = CommandLine.arguments.contains("--sim-autoout")
        || CommandLine.arguments.contains("--sim-autoin")
    // 可用环境变量指定独立 defaults 域（截图/演示用，绝不碰真实数据）
    let suite = ProcessInfo.processInfo.environment["XINXIN_DEFAULTS_SUITE"]
    let model = EarnModel(ud: simMode
        ? (UserDefaults(suiteName: "xiaoxinxin-sim") ?? .standard)
        : (suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard))

    // 自检模式：--sim-autoin 验证自动上班；--sim-autoout 验证 自动下班 → 加班打卡 → 跨天重置 全链路
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
        exportShots(to: CommandLine.arguments[i + 1], model: model,
                    dark: CommandLine.arguments.contains("--dark"))
        exit(0)
    }
    let hosting = NSHostingController(rootView: ContentView(model: model))
    // 关键：不要让 SwiftUI 反向调整窗口尺寸——它会按当前内容高度把窗口拉回去，
    // 和我们自己的贴合同步打架，表现出来就是“展开时窗口变形/抖动”
    hosting.sizingOptions = []
    panel.contentViewController = hosting
    // sizingOptions 关闭后控制器不再提供 preferredContentSize，挂上去时窗口会被缩成 0×0，
    // 内容随即被窗口边界裁掉（首页只剩一条）。这里立刻把尺寸写回去。
    panel.setContentSize(NSSize(width: 372, height: 560))

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
                      SettingsUIState.shared.pageHeights[model.page == .mini ? "mini" : "home"] ?? 0)
            // 量不到内容高度时不改窗口，避免把窗口压成一条
            if model.page != .settings && (SettingsUIState.shared.pageHeights[model.page == .mini ? "mini" : "home"] ?? 0) < 40 { return }
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
    app.mainMenu = buildMainMenu(appName: "小薪薪")
    app.setActivationPolicy(.regular)   // 常规应用：Dock 图标 + Cmd-Tab，不会被当成后台偷跑
    // 开机自启动（--autostart）：静默停在状态栏，不弹主窗、不抢前台
    if CommandLine.arguments.contains("--autostart") {
        model.statusBarMode = true
        model.logText = "🌤 已随机启动，点状态栏图标即可展开；到上班时间会自动开始计费"
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

    // 贴边自动收纳：拖到屏幕边缘停住约 0.3 秒 → 缩小至状态栏
    var edgeDebounce: Timer?
    NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
        edgeDebounce?.invalidate()
        edgeDebounce = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            Task { @MainActor in
                guard panel.isVisible, !model.statusBarMode, nearScreenEdge(panel.frame) else { return }
                model.statusBarMode = true
                model.logText = "📌 已贴边收纳，状态栏图标可恢复"
                panel.orderOut(nil)
            }
        }
    }

    app.run()
}
