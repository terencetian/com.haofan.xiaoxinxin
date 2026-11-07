import WidgetKit
import SwiftUI

// MARK: - 数据快照（主 App 写出的 widget-snapshot.json）

/// 倒计时：只存目标时刻与总跨度，剩余天数由小组件按当前日期自己算
struct SnapCountdown {
    var name = ""
    var mode = "days"          // days / percent
    var targetKey = ""
    var targetTS: Double = 0
    var totalDays = 0
    var ratio: Double = 0
    var yearly = false
    var expired = false

    var hasValue: Bool { targetTS > 0 }

    func targetDate() -> Date? { targetTS > 0 ? Date(timeIntervalSince1970: targetTS) : nil }

    /// 剩余自然日（当天为 0）
    func daysLeft(at now: Date) -> Int {
        guard let t = targetDate() else { return 0 }
        let cal = Calendar.current
        let a = cal.startOfDay(for: now), b = cal.startOfDay(for: t)
        return max(0, cal.dateComponents([.day], from: a, to: b).day ?? 0)
    }

    /// 已走比例：优先用「总跨度 - 剩余」实时算，App 没写快照也不会卡在旧值
    func liveRatio(at now: Date) -> Double {
        guard totalDays > 0 else { return max(0, min(1, ratio)) }
        let passed = totalDays - daysLeft(at: now)
        return max(0, min(1, Double(passed) / Double(totalDays)))
    }
}

/// 纪念日：起始日 + 累计
struct SnapRecordDay {
    var name = ""
    var startKey = ""
    var elapsed = 0
    var years = 0
    var months = 0
    var days = 0

    var hasValue: Bool { !startKey.isEmpty }

    func startDate() -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.date(from: startKey)
    }

    /// 累计自然日
    func elapsedDays(at now: Date) -> Int {
        guard let s = startDate() else { return max(0, elapsed) }
        let cal = Calendar.current
        return max(0, cal.dateComponents([.day], from: cal.startOfDay(for: s),
                                         to: cal.startOfDay(for: now)).day ?? elapsed)
    }

    /// 累计时长拆成 年 / 个月 / 天
    func span(at now: Date) -> (y: Int, m: Int, d: Int) {
        guard let s = startDate() else { return (years, months, days) }
        let cal = Calendar.current
        let a = cal.startOfDay(for: s), b = cal.startOfDay(for: now)
        guard b >= a else { return (0, 0, 0) }
        let c = cal.dateComponents([.year, .month, .day], from: a, to: b)
        return (c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// 主题皮肤：App 侧把当前调色板写进快照，小组件按同一套色值渲染
struct ThemeSkin {
    var id = "sky"
    var bg: Color = .white
    var text: Color = Color(red: 0.07, green: 0.16, blue: 0.27)
    var accent: Color = Color(red: 0.16, green: 0.52, blue: 0.90)
    var accentDeep: Color = Color(red: 0.12, green: 0.37, blue: 0.65)
    var bar: [Color] = [Color(red: 0.16, green: 0.52, blue: 0.90), Color(red: 0.12, green: 0.37, blue: 0.65)]
    var glass = false
    var alpha: Double = 1

    var secondary: Color { text.opacity(0.56) }
    var faint: Color { text.opacity(0.36) }
    var track: Color { text.opacity(0.13) }

    var isDark: Bool {
        let n = NSColor(bg).usingColorSpace(.sRGB) ?? .white
        let l = 0.299 * Double(n.redComponent) + 0.587 * Double(n.greenComponent) + 0.114 * Double(n.blueComponent)
        return l < 0.5
    }

    static func rgb(_ v: [Double]) -> Color {
        guard v.count >= 3 else { return .white }
        return Color(red: v[0], green: v[1], blue: v[2])
    }

    /// 四套内置主题（和 App 的 AppTheme.preset 一一对应），快照残缺时兜底
    static func preset(_ id: String) -> ThemeSkin {
        switch id {
        case "mint":
            return ThemeSkin(id: "mint",
                             bg: .white,
                             text: rgb([0.08, 0.20, 0.17]),
                             accent: rgb([0.10, 0.68, 0.50]),
                             accentDeep: rgb([0.07, 0.49, 0.36]),
                             bar: [rgb([0.10, 0.68, 0.50]), rgb([0.07, 0.49, 0.36])])
        case "sony30":
            return ThemeSkin(id: "sony30",
                             bg: rgb([0.82, 0.83, 0.84]),
                             text: rgb([0.15, 0.16, 0.18]),
                             accent: rgb([0.28, 0.31, 0.36]),
                             accentDeep: rgb([0.20, 0.22, 0.26]),
                             bar: [rgb([0.20, 0.70, 0.35]), rgb([0.88, 0.20, 0.24]),
                                   rgb([0.20, 0.45, 0.85]), rgb([0.85, 0.45, 0.75])])
        case "liquidGlass":
            var s = ThemeSkin(id: "liquidGlass",
                              bg: .white,
                              text: rgb([0.12, 0.13, 0.15]),
                              accent: rgb([0.84, 0.00, 0.08]),
                              accentDeep: rgb([0.60, 0.00, 0.06]),
                              glass: true,
                              alpha: 0.58)
            s.bar = [s.accent, s.accentDeep]
            return s
        default:
            return ThemeSkin(id: "sky",
                             bg: .white,
                             text: rgb([0.07, 0.16, 0.27]),
                             accent: rgb([0.16, 0.52, 0.90]),
                             accentDeep: rgb([0.12, 0.37, 0.65]),
                             bar: [rgb([0.16, 0.52, 0.90]), rgb([0.12, 0.37, 0.65])])
        }
    }
}

struct Snap {
    var baseEarned: Double = 0
    var clockInAt: Date?
    var working = false
    var ratePerSec: Double = 0
    var ratePerDay: Double = 0
    var workedBeforeSession: Double = 0
    var salary: Double = 0
    var debugTag: String = ""   // 诊断用：本次读到哪条通道 / 时间戳

    // 2.0 隐私模式：小组件同步收起所有金额，只留按工时算的百分比进度
    var privacy = false
    var plannedHours: Double = 8
    var progressRatio: Double = 0
    var progressText: String = ""
    var metric: String = "todaySalary"
    var monthRatio: Double = 0

    // 2.5：主题配色 + Your Days
    var theme = ThemeSkin.preset("sky")
    var countdown: SnapCountdown?
    var record: SnapRecordDay?

    /// 隐私模式下按工时实时算的进度（8h=100%，加班可超 100%）
    func privacyRatio(at date: Date) -> Double {
        guard plannedHours > 0 else { return 0 }
        return Double(workedSeconds(at: date)) / (plannedHours * 3600)
    }
    /// 条 / 环填充比例，恒在 0...1
    func displayProgress(at date: Date) -> Double {
        privacy ? min(1, max(0, privacyRatio(at: date))) : progress(at: earned(at: date))
    }
    /// 大字：正常显示金额，隐私模式显示百分比（可超 100%）
    func mainText(at date: Date) -> String {
        guard privacy else { return "¥" + fmtMoney(earned(at: date)) }
        return String(format: "%.0f%%", privacyRatio(at: date) * 100)
    }
    /// 进度说明里的百分比数值（隐私模式可 >100%）
    func shownRatio(at date: Date) -> Double {
        privacy ? privacyRatio(at: date) : progress(at: earned(at: date))
    }

    // 在给定时刻推算的实时值（时间线每个 entry 各自算，分钟级跳动不用主 App 参与）
    func earned(at date: Date) -> Double {
        guard working, let start = clockInAt else { return baseEarned }
        return baseEarned + max(0, date.timeIntervalSince(start)) * ratePerSec
    }
    func workedMinutes(at date: Date) -> Int {
        var sec = workedBeforeSession
        if working, let start = clockInAt { sec += max(0, date.timeIntervalSince(start)) }
        return Int(sec / 60)
    }
    func workedSeconds(at date: Date) -> Int {
        var sec = workedBeforeSession
        if working, let start = clockInAt { sec += max(0, date.timeIntervalSince(start)) }
        return Int(sec)
    }
    func progress(at date: Double) -> Double {
        ratePerDay > 0 ? min(1, date / ratePerDay) : 0
    }

    /// 沙盒内 homeDirectoryForCurrentUser 指向容器目录，必须用 passwd 里的真实家目录
    static let realHome: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    static func load() -> Snap {
        // 通道优先级：ASCII 家目录 → 中文家目录 → 主 App 偏好域 → 自己容器缓存 → 容器旧副本。
        // 沙盒的 home-relative 临时豁免在 ad-hoc 签名下不一定生效，所以多路兜底并保留诊断标记。
        let asciiURL = realHome.appendingPathComponent("Library/Application Support/Xiaoxinxin/widget-snapshot.json")
        let realURL = realHome.appendingPathComponent("Library/Application Support/小薪薪/widget-snapshot.json")
        let containerURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/小薪薪/widget-snapshot.json")

        var miss = ""
        if let hit = fromBridge() {
            cacheRaw(hit)
            return tagged(hit.snap, "HT " + hm(hit.stamp))
        }
        miss += "h"
        if let hit = decode(at: asciiURL) {
            cacheRaw(hit)
            return tagged(hit.snap, "RA " + hm(hit.stamp) + " " + miss)
        }
        miss += "a"
        if let hit = decode(at: realURL) {
            cacheRaw(hit)
            return tagged(hit.snap, "RH " + hm(hit.stamp) + " " + miss)
        }
        miss += "j"
        if let (snap, stamp) = fromAppPrefs() {
            return tagged(snap, "PR " + hm(stamp) + " " + miss)
        }
        miss += "p"
        if let cached = cachedRaw(), let hit = decode(data: cached.data, fallbackStamp: cached.stamp) {
            return tagged(hit.snap, "CA " + hm(hit.stamp) + " " + miss)
        }
        miss += "c"
        if let hit = decode(at: containerURL) {
            return tagged(hit.snap, "CT " + hm(hit.stamp) + " " + miss)
        }
        return tagged(Snap(), "NONE " + miss)
    }

    /// 本机回环数据桥：主 App 在 127.0.0.1:47821 上提供快照（outbound 网络是标准沙盒能力）
    static let bridgeURL = URL(string: "http://127.0.0.1:47821/state")!

    private static func fromBridge() -> (snap: Snap, stamp: Double, raw: Data)? {
        var req = URLRequest(url: bridgeURL)
        req.timeoutInterval = 2
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { d, _, _ in out = d; sem.signal() }.resume()
        guard sem.wait(timeout: .now() + 2.5) == .success, let d = out else { return nil }
        return decode(data: d, fallbackStamp: 0)
    }

    private static func tagged(_ s: Snap, _ tag: String) -> Snap {
        var c = s
        c.debugTag = tag
        return c
    }

    /// 主 App 自己的偏好域：沙盒允许读其他 App 的偏好，这条通道不依赖文件豁免
    private static func fromAppPrefs() -> (Snap, Double)? {
        guard let d = UserDefaults(suiteName: "com.haofan.xiaoxinxin"),
              let ts = d.object(forKey: "wSavedAt") as? Double, ts > 0 else { return nil }
        var s = Snap()
        s.baseEarned = d.double(forKey: "wBaseEarned")
        let ci = d.double(forKey: "wClockInAt")
        s.clockInAt = ci > 0 ? Date(timeIntervalSince1970: ci) : nil
        s.working = d.bool(forKey: "wWorking")
        s.ratePerSec = d.double(forKey: "wRatePerSec")
        s.ratePerDay = d.double(forKey: "wRatePerDay")
        s.workedBeforeSession = d.double(forKey: "wWorkedBefore")
        s.salary = d.double(forKey: "wSalary")
        s.privacy = (d.object(forKey: "wPrivacy") as? Bool) ?? false
        s.plannedHours = (d.object(forKey: "wPlannedHours") as? Double) ?? 8
        s.progressRatio = d.double(forKey: "wProgressRatio")
        s.monthRatio = d.double(forKey: "wMonthRatio")
        // 2.5：主题与日子走 JSON 字符串镜像
        if let raw = d.string(forKey: "wThemeJSON"), let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            s.theme = theme(from: obj)
        }
        if let raw = d.string(forKey: "wDaysJSON"), let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            s.countdown = countdown(from: obj["countdown"] as? [String: Any])
            s.record = recordDay(from: obj["record"] as? [String: Any])
        }
        let alive = (d.object(forKey: "wAlive") as? Bool) ?? true
        applyFreeze(&s, alive: alive, stamp: ts)
        return (s, ts)
    }

    // MARK: 扩展自己容器里的「上次成功快照」
    private static let cacheKey = "lastGoodSnapshot"

    private static func cacheRaw(_ hit: (snap: Snap, stamp: Double, raw: Data)) {
        UserDefaults.standard.set(hit.raw, forKey: cacheKey)
    }
    private static func cachedRaw() -> (data: Data, stamp: Double)? {
        guard let d = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return (d, 0)
    }

    static func hm(_ ts: Double) -> String {
        guard ts > 0 else { return "0" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    private static func log(_ msg: String) {
        NSLog("[SalaryWidget] %@", msg)
    }

    /// 停表规则：主 App 明确退出（alive=false），或 3 分钟没心跳（崩溃/休眠），
    /// 就把当前值烘焙进 baseEarned 再停表，避免时间线按旧 clockInAt 无限累加
    private static func applyFreeze(_ s: inout Snap, alive: Bool, stamp: Double) {
        let stale = stamp > 0 && Date.now.timeIntervalSince1970 - stamp > 180
        guard s.working, !alive || stale, let start = s.clockInAt else { return }
        let extra = max(0, min(stamp, Date.now.timeIntervalSince1970) - start.timeIntervalSince1970)
        s.baseEarned += extra * s.ratePerSec
        s.workedBeforeSession += extra
        s.working = false
        s.clockInAt = nil
    }

    // MARK: 主题 / Days 解析

    private static func theme(from obj: [String: Any]) -> ThemeSkin {
        let id = obj["id"] as? String ?? "sky"
        var skin = ThemeSkin.preset(id)
        skin.id = id
        if let v = obj["bg"] as? [Double], v.count >= 3 { skin.bg = ThemeSkin.rgb(v) }
        if let v = obj["text"] as? [Double], v.count >= 3 { skin.text = ThemeSkin.rgb(v) }
        if let v = obj["accent"] as? [Double], v.count >= 3 {
            skin.accent = ThemeSkin.rgb(v)
            skin.accentDeep = Color(red: v[0] * 0.72, green: v[1] * 0.72, blue: v[2] * 0.72)
        }
        if let a = obj["alpha"] as? Double { skin.alpha = a }
        skin.glass = (id == "liquidGlass")
        // Sony 30th 的进度条用初代四色按键；其余主题是主色双色渐变
        skin.bar = id == "sony30" ? ThemeSkin.preset("sony30").bar : [skin.accent, skin.accentDeep]
        return skin
    }

    private static func countdown(from obj: [String: Any]?) -> SnapCountdown? {
        guard let o = obj else { return nil }
        var c = SnapCountdown()
        c.name = o["name"] as? String ?? "倒计时"
        c.mode = o["mode"] as? String ?? "days"
        c.targetKey = o["targetKey"] as? String ?? ""
        c.targetTS = o["targetTS"] as? Double ?? 0
        c.totalDays = o["totalDays"] as? Int ?? 0
        c.ratio = o["ratio"] as? Double ?? 0
        c.yearly = o["yearly"] as? Bool ?? false
        c.expired = o["expired"] as? Bool ?? false
        return c.hasValue ? c : nil
    }

    private static func recordDay(from obj: [String: Any]?) -> SnapRecordDay? {
        guard let o = obj else { return nil }
        var r = SnapRecordDay()
        r.name = o["name"] as? String ?? "纪念日"
        r.startKey = o["startKey"] as? String ?? ""
        r.elapsed = o["elapsed"] as? Int ?? 0
        r.years = o["years"] as? Int ?? 0
        r.months = o["months"] as? Int ?? 0
        r.days = o["days"] as? Int ?? 0
        return r.hasValue ? r : nil
    }

    private static func decode(at url: URL) -> (snap: Snap, stamp: Double, raw: Data)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970
        return decode(data: data, fallbackStamp: mtime ?? 0)
    }

    private static func decode(data: Data, fallbackStamp: Double) -> (snap: Snap, stamp: Double, raw: Data)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var s = Snap()
        s.baseEarned = obj["baseEarned"] as? Double ?? 0
        s.clockInAt = (obj["clockInAt"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        s.working = obj["working"] as? Bool ?? false
        s.ratePerSec = obj["ratePerSec"] as? Double ?? 0
        s.ratePerDay = obj["ratePerDay"] as? Double ?? 0
        s.workedBeforeSession = obj["workedBeforeSession"] as? Double ?? 0
        s.salary = obj["salary"] as? Double ?? 0
        s.privacy = obj["privacy"] as? Bool ?? false
        s.plannedHours = obj["plannedHours"] as? Double ?? 8
        s.progressRatio = obj["progressRatio"] as? Double ?? 0
        s.progressText = obj["progressText"] as? String ?? ""
        s.metric = obj["metric"] as? String ?? "todaySalary"
        s.monthRatio = obj["monthRatio"] as? Double ?? 0
        if let t = obj["theme"] as? [String: Any] { s.theme = theme(from: t) }
        if let d = obj["days"] as? [String: Any] {
            s.countdown = countdown(from: d["countdown"] as? [String: Any])
            s.record = recordDay(from: d["record"] as? [String: Any])
        }
        let stamp = (obj["savedAt"] as? Double) ?? fallbackStamp
        let alive = (obj["alive"] as? Bool) ?? true
        applyFreeze(&s, alive: alive, stamp: stamp)
        return (s, stamp, data)
    }
}

extension Snap {
    func progress(at date: Date) -> Double { progress(at: earned(at: date)) }
}

struct SalaryEntry: TimelineEntry {
    let date: Date
    let snap: Snap
}

struct SalaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SalaryEntry {
        SalaryEntry(date: .now, snap: demoSnap)
    }
    func getSnapshot(in context: Context, completion: @escaping (SalaryEntry) -> Void) {
        completion(SalaryEntry(date: .now, snap: context.isPreview ? demoSnap : Snap.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SalaryEntry>) -> Void) {
        let snap = Snap.load()
        var entries: [SalaryEntry] = [SalaryEntry(date: .now, snap: snap)]
        // 计费中：未来 20 分钟每秒一个 entry —— 金额/进度环看起来是实时走数的。
        // 小组件里 TimelineView 的 periodic 调度会被系统忽略，唯一可行的办法就是预生成 entry；
        // entry 只是 (date, snap)，预计算开销可忽略。
        if snap.working {
            for s in 1...(10 * 60) {
                entries.append(SalaryEntry(date: .now.addingTimeInterval(Double(s)), snap: snap))
            }
            completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(9 * 60))))
        } else {
            completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(30 * 60))))
        }
    }
    private var demoSnap: Snap {
        var s = Snap()
        s.baseEarned = 187.5
        s.working = true
        s.clockInAt = .now.addingTimeInterval(-3600 * 4.27)
        s.ratePerSec = 0.0165
        s.ratePerDay = 476.19
        s.salary = 3500
        s.monthRatio = 0.118
        s.theme = ThemeSkin.preset("sky")
        var cd = SnapCountdown()
        cd.name = "新年"
        cd.targetTS = Date.now.addingTimeInterval(55 * 86400).timeIntervalSince1970
        cd.totalDays = 365
        s.countdown = cd
        var rd = SnapRecordDay()
        rd.name = "在一起"
        rd.startKey = "2020-10-06"
        s.record = rd
        return s
    }
}

// MARK: - 排版原子（全部按字重/字号分层，不用 emoji、不用彩色图标）

private func fmtMoney(_ v: Double) -> String { String(format: "%.2f", v) }
private func fmtHM(_ min: Int) -> String { "\(min / 60)h\(String(format: "%02d", min % 60))m" }

private struct Label: View {
    let text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .heavy))
            .tracking(1.1)
            .foregroundStyle(color)
    }
}

/// 主题色进度条：轨道用文本色的淡化版，填充走主题渐变（Sony 30th 是四色）
private struct ThemeBar: View {
    let p: Double
    let colors: [Color]
    let track: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(1, max(0, p))))
            }
        }
        .frame(height: height)
    }
}

private struct StatusDot: View {
    let on: Bool
    let color: Color
    var body: some View {
        Circle()
            .fill(on ? color : color.opacity(0.28))
            .frame(width: 6, height: 6)
    }
}

/// 倒计时大字「55 天」
private struct DayNumber: View {
    let value: String
    let unit: String
    let color: Color
    let size: CGFloat
    let unitColor: Color
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(unit)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(unitColor)
        }
    }
}

// MARK: - MONEY（工资）

struct MoneySmallView: View {
    let entry: SalaryEntry

    var body: some View {
        let now = entry.date
        let s = entry.snap
        let skin = s.theme
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Label(text: "MONEY", color: skin.accent)
                Spacer(minLength: 2)
                StatusDot(on: s.working, color: skin.accent)
                Text(s.privacy ? "隐私" : (s.working ? "计费中" : "未打卡"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(skin.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Text(s.mainText(at: now))
                .font(.system(size: 25, weight: .heavy, design: .rounded))
                .foregroundStyle(skin.accent)
                .lineLimit(1).minimumScaleFactor(0.42)
                .padding(.bottom, 9)
            ThemeBar(p: s.displayProgress(at: now), colors: skin.bar, track: skin.track, height: 6)
            Text(String(format: "今日 %.1f%% · 本月 %.1f%%",
                        s.shownRatio(at: now) * 100, (s.privacy ? s.progressRatio : s.monthRatio) * 100))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(skin.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.top, 7)
            Spacer(minLength: 2)
        }
        .padding(13)
    }
}

struct MoneyMediumView: View {
    let entry: SalaryEntry

    var body: some View {
        let now = entry.date
        let s = entry.snap
        let skin = s.theme
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    Label(text: "MONEY", color: skin.accent)
                    Text("今日已赚").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(skin.faint)
                }
                Text(s.mainText(at: now))
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(skin.accent)
                    .lineLimit(1).minimumScaleFactor(0.5)
                ThemeBar(p: s.displayProgress(at: now), colors: skin.bar, track: skin.track, height: 7)
                HStack(spacing: 6) {
                    Text(String(format: "今日 %.1f%%", s.shownRatio(at: now) * 100))
                    Text("·").foregroundStyle(skin.faint)
                    Text(String(format: "本月 %.1f%%", (s.privacy ? s.progressRatio : s.monthRatio) * 100))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(skin.secondary)
                .lineLimit(1)
            }
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 4) {
                    StatusDot(on: s.working, color: skin.accent)
                    Text(s.privacy ? "隐私" : (s.working ? "计费中" : "未打卡"))
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(skin.secondary)
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text("已工作").font(.system(size: 9, weight: .medium)).foregroundStyle(skin.faint)
                    Text(fmtHM(s.workedMinutes(at: now)))
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(skin.text.opacity(0.85))
                }
            }
            .frame(width: 66, alignment: .trailing)
        }
        .padding(14)
    }
}

// MARK: - DAYS（日子：倒计时 + 纪念日）

struct DaysSmallView: View {
    let entry: SalaryEntry

    var body: some View {
        let now = entry.date
        let s = entry.snap
        let skin = s.theme
        let cd = s.countdown
        let rd = s.record
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Label(text: "DAYS", color: skin.accent)
                Spacer(minLength: 2)
                Text(cd?.name ?? "倒计时")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(skin.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if let cd {
                DayNumber(value: "\(cd.daysLeft(at: now))", unit: "天",
                          color: skin.accent, size: 30, unitColor: skin.secondary)
                ThemeBar(p: cd.liveRatio(at: now), colors: skin.bar, track: skin.track, height: 5)
                    .padding(.top, 8)
                Text("距 \(cd.targetKey)")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(skin.faint)
                    .lineLimit(1)
                    .padding(.top, 6)
            } else {
                Text("未设置").font(.system(size: 20, weight: .heavy)).foregroundStyle(skin.faint)
                Text("在 App 里添加倒计时")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(skin.faint)
                    .padding(.top, 4)
            }
            Rectangle().fill(skin.track).frame(height: 1)
                .padding(.top, 12)
            HStack(spacing: 4) {
                Text("纪念日 · \(rd?.name ?? "未设置")")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(skin.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(rd.map { "\($0.elapsedDays(at: now)) 天" } ?? "—")
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(skin.accent)
            }
            .padding(.top, 9)
            Spacer(minLength: 2)
        }
        .padding(13)
    }
}

struct DaysMediumView: View {
    let entry: SalaryEntry

    var body: some View {
        let now = entry.date
        let s = entry.snap
        let skin = s.theme
        HStack(alignment: .center, spacing: 16) {
            countdownColumn(now: now, skin: skin, cd: s.countdown)
            Rectangle().fill(skin.track).frame(width: 1, height: 84)
            recordColumn(now: now, skin: skin, rd: s.record)
        }
        .padding(14)
    }

    @ViewBuilder
    private func countdownColumn(now: Date, skin: ThemeSkin, cd: SnapCountdown?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Label(text: "DAYS", color: skin.accent)
                Text(cd?.name ?? "倒计时")
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(skin.faint)
                    .lineLimit(1)
            }
            if let cd {
                DayNumber(value: "\(cd.daysLeft(at: now))", unit: "天",
                          color: skin.accent, size: 30, unitColor: skin.secondary)
                ThemeBar(p: cd.liveRatio(at: now), colors: skin.bar, track: skin.track, height: 6)
                Text(String(format: "距 %@ · 已走 %.0f%%", cd.targetKey, cd.liveRatio(at: now) * 100))
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(skin.secondary)
                    .lineLimit(1)
            } else {
                Text("未设置").font(.system(size: 20, weight: .heavy)).foregroundStyle(skin.faint)
                Text("在 App 里添加倒计时")
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(skin.faint)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func recordColumn(now: Date, skin: ThemeSkin, rd: SnapRecordDay?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Label(text: "纪念日", color: skin.faint)
                Text(rd?.name ?? "未设置")
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(skin.faint)
                    .lineLimit(1)
            }
            if let rd {
                let sp = rd.span(at: now)
                DayNumber(value: "\(rd.elapsedDays(at: now))", unit: "天",
                          color: skin.accent, size: 30, unitColor: skin.secondary)
                Text(spanText(sp.y, sp.m, sp.d))
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundStyle(skin.text.opacity(0.82))
                    .lineLimit(1)
                Text("从 \(rd.startKey) 起")
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(skin.secondary)
                    .lineLimit(1)
            } else {
                Text("未设置").font(.system(size: 20, weight: .heavy)).foregroundStyle(skin.faint)
                Text("在 App 里添加纪念日")
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(skin.faint)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spanText(_ y: Int, _ m: Int, _ d: Int) -> String {
        var parts: [String] = []
        if y > 0 { parts.append("\(y) 年") }
        if m > 0 { parts.append("\(m) 个月") }
        if d > 0 || parts.isEmpty { parts.append("\(d) 天") }
        return parts.joined(separator: " ")
    }
}

// MARK: - 通知中心 / 锁屏 / 菜单栏（accessory，系统自带材质，不铺背景）

struct MoneyCircularView: View {
    let entry: SalaryEntry
    var body: some View {
        let now = entry.date
        let p = entry.snap.displayProgress(at: now)
        let shown = entry.snap.shownRatio(at: now)
        let skin = entry.snap.theme
        ZStack {
            Circle().stroke(skin.track, lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0.015, p))
                .stroke(LinearGradient(colors: skin.bar, startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(entry.snap.privacy ? "%" : "¥")
                    .font(.system(size: 12, weight: .heavy)).foregroundStyle(.primary)
                Text(String(format: "%.0f%%", shown * 100))
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
    }
}

struct MoneyRectangularView: View {
    let entry: SalaryEntry
    var body: some View {
        let now = entry.date
        let s = entry.snap
        let shown = s.shownRatio(at: now)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("MONEY").font(.system(size: 8.5, weight: .heavy)).tracking(1.0)
                if s.working {
                    Circle().fill(s.theme.accent).frame(width: 5, height: 5)
                    Text("计费中").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Text(s.privacy ? String(format: "今日进度 %.0f%%", shown * 100)
                           : "¥\(fmtMoney(s.earned(at: now)))")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(s.theme.accent)
            if let cd = s.countdown {
                Text("· DAYS \(cd.name) \(cd.daysLeft(at: now)) 天")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text(String(format: "进度 %.1f%% · 已工作 %@", shown * 100, fmtHM(s.workedMinutes(at: now))))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

struct MoneyInlineView: View {
    let entry: SalaryEntry
    var body: some View {
        let s = entry.snap
        let cd = s.countdown.map { " · \($0.name) \($0.daysLeft(at: entry.date)) 天" } ?? ""
        return Text(s.privacy
                    ? String(format: "小薪薪 %.0f%%", s.shownRatio(at: entry.date) * 100) + cd
                    : "小薪薪 ¥\(fmtMoney(s.earned(at: entry.date)))\(cd)")
    }
}

struct DaysRectangularView: View {
    let entry: SalaryEntry
    var body: some View {
        let now = entry.date
        let s = entry.snap
        VStack(alignment: .leading, spacing: 2) {
            Text("DAYS").font(.system(size: 8.5, weight: .heavy)).tracking(1.0)
            if let cd = s.countdown {
                Text("\(cd.name) · \(cd.daysLeft(at: now)) 天")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(s.theme.accent)
            }
            if let rd = s.record {
                let sp = rd.span(at: now)
                Text("\(rd.name) · 累计 \(rd.elapsedDays(at: now)) 天")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("\(sp.y) 年 \(sp.m) 个月 \(sp.d) 天")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Widget 配置

/// 背景：主题底色 + 主色极淡的角向晕染，和 App 窗口的观感一致
struct ThemeBackground: View {
    let skin: ThemeSkin
    var body: some View {
        ZStack {
            if skin.glass {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color.white.opacity(0.58 + skin.alpha * 0.22))
            } else {
                skin.bg
            }
            LinearGradient(colors: [skin.accent.opacity(skin.isDark ? 0.24 : 0.12), .clear],
                           startPoint: .topLeading, endPoint: .center)
            LinearGradient(colors: [skin.accentDeep.opacity(skin.isDark ? 0.20 : 0.06), .clear],
                           startPoint: .bottomTrailing, endPoint: .center)
        }
    }
}

struct MoneySwitch: View {
    @Environment(\.widgetFamily) private var family
    let entry: SalaryEntry

    var body: some View {
        let content: AnyView = switch family {
        case .systemSmall: AnyView(MoneySmallView(entry: entry))
        case .systemMedium: AnyView(MoneyMediumView(entry: entry))
        case .accessoryCircular: AnyView(MoneyCircularView(entry: entry))
        case .accessoryRectangular: AnyView(MoneyRectangularView(entry: entry))
        case .accessoryInline: AnyView(MoneyInlineView(entry: entry))
        default: AnyView(MoneyMediumView(entry: entry))
        }
        if family == .systemSmall || family == .systemMedium {
            content.containerBackground(for: .widget) { ThemeBackground(skin: entry.snap.theme) }
        } else {
            content
        }
    }
}

struct DaysSwitch: View {
    @Environment(\.widgetFamily) private var family
    let entry: SalaryEntry

    var body: some View {
        let content: AnyView = switch family {
        case .systemSmall: AnyView(DaysSmallView(entry: entry))
        case .systemMedium: AnyView(DaysMediumView(entry: entry))
        case .accessoryRectangular: AnyView(DaysRectangularView(entry: entry))
        default: AnyView(DaysSmallView(entry: entry))
        }
        if family == .systemSmall || family == .systemMedium {
            content.containerBackground(for: .widget) { ThemeBackground(skin: entry.snap.theme) }
        } else {
            content
        }
    }
}

struct MoneyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SalaryWidget", provider: SalaryProvider()) { entry in
            MoneySwitch(entry: entry)
                .widgetURL(URL(string: "xiaoxinxin://money"))
        }
        .configurationDisplayName("小薪薪 · 工资 MONEY")
        .description("今日到账与进度，配色跟随 App 主题；开启隐私模式自动改为百分比")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DaysWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DaysWidget", provider: SalaryProvider()) { entry in
            DaysSwitch(entry: entry)
                .widgetURL(URL(string: "xiaoxinxin://days"))
        }
        .configurationDisplayName("小薪薪 · 日子 DAYS")
        .description("倒计时剩余天数与纪念日累计，配色跟随 App 主题")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#if !WIDGET_PREVIEW
@main
struct SalaryWidgetBundle: WidgetBundle {
    var body: some Widget {
        MoneyWidget()
        DaysWidget()
    }
}
#endif
