import WidgetKit
import SwiftUI

// MARK: - 数据快照（主 App 写出的 widget-snapshot.json）

struct Snap {
    var baseEarned: Double = 0
    var clockInAt: Date?
    var working = false
    var ratePerSec: Double = 0
    var ratePerDay: Double = 0
    var workedBeforeSession: Double = 0
    var salary: Double = 0
    var debugTag: String = ""   // 诊断用：本次读到哪条通道 / 时间戳

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
        s.clockInAt = .now.addingTimeInterval(-3600)
        s.ratePerSec = 0.0165
        s.ratePerDay = 476.19
        s.salary = 10000
        return s
    }
}

// MARK: - 通用样式

private let bgGrad = LinearGradient(
    colors: [Color(red: 0.09, green: 0.14, blue: 0.30), Color(red: 0.12, green: 0.09, blue: 0.24)],
    startPoint: .topLeading, endPoint: .bottomTrailing)
private let gold = Color(red: 1.0, green: 0.79, blue: 0.24)
private let goldDeep = Color(red: 0.96, green: 0.62, blue: 0.16)

private func fmtMoney(_ v: Double) -> String { String(format: "%.2f", v) }
private func fmtHM(_ min: Int) -> String { "\(min / 60)h\(String(format: "%02d", min % 60))m" }
private func fmtHMS(_ sec: Int) -> String {
    "\(sec / 3600)h\(String(format: "%02d", (sec % 3600) / 60))m\(String(format: "%02d", sec % 60))s"
}

/// 金色进度环 + 中心金额
private struct RingView: View {
    let progress: Double
    let lineWidth: CGFloat
    var body: some View {
        ZStack {
            Circle().stroke(gold.opacity(0.22), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.015, progress))
                .stroke(AngularGradient(colors: [gold, goldDeep], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct CoinBadge: View {
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [gold, goldDeep], startPoint: .top, endPoint: .bottom))
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 1)
            Text("¥").font(.system(size: size * 0.52, weight: .heavy)).foregroundStyle(Color(red: 0.42, green: 0.16, blue: 0.02))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

// MARK: - 桌面小组件

struct SalarySmallView: View {
    let entry: SalaryEntry
    var body: some View {
        content(at: entry.date)
    }

    @ViewBuilder
    private func content(at now: Date) -> some View {
        let earned = entry.snap.earned(at: now)
        let p = entry.snap.progress(at: now)
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                CoinBadge(size: 18)
                Text("小薪薪").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Circle()
                    .fill(entry.snap.working ? Color(red: 1, green: 0.35, blue: 0.3) : Color.gray.opacity(0.6))
                    .frame(width: 6, height: 6)
            }
            ZStack {
                RingView(progress: p, lineWidth: 8).frame(width: 78, height: 78)
                VStack(spacing: 1) {
                    Text("¥\(fmtMoney(earned))")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(gold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .frame(width: 58)      // 必须限宽，否则文字会从环上溢出
                    Text("今日").font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Text(String(format: "进度 %.1f%%", p * 100) + " · " + entry.snap.debugTag)
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(2)
    }
}

struct SalaryMediumView: View {
    let entry: SalaryEntry
    var body: some View {
        content(at: entry.date)
    }

    @ViewBuilder
    private func content(at now: Date) -> some View {
        let earned = entry.snap.earned(at: now)
        let p = entry.snap.progress(at: now)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                CoinBadge(size: 34)
                Text("小薪薪").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 4) {
                    Circle()
                        .fill(entry.snap.working ? Color(red: 1, green: 0.35, blue: 0.3) : Color.gray.opacity(0.6))
                        .frame(width: 6, height: 6)
                    Text(entry.snap.working ? "计费中" : "未打卡")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 86, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                Text("¥\(fmtMoney(earned))")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(gold)
                    .lineLimit(1).minimumScaleFactor(0.5)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule().fill(LinearGradient(colors: [gold, goldDeep], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(10, geo.size.width * p))
                        Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                    }
                }
                .frame(height: 9)
                HStack {
                    Text(String(format: "进度 %.1f%%", p * 100))
                    Spacer()
                    Text("已工作 \(fmtHMS(entry.snap.workedSeconds(at: now)))")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(4)
    }
}

// MARK: - 通知中心 / 锁屏 / 菜单栏（accessory）

struct SalaryCircularView: View {
    let entry: SalaryEntry
    var body: some View {
        let p = entry.snap.progress(at: entry.date)
        ZStack {
            RingView(progress: p, lineWidth: 5)
            VStack(spacing: 0) {
                Text("¥")
                    .font(.system(size: 13, weight: .heavy)).foregroundStyle(.primary)
                Text(String(format: "%.0f%%", p * 100))
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
    }
}

struct SalaryRectangularView: View {
    let entry: SalaryEntry
    var body: some View {
        let earned = entry.snap.earned(at: entry.date)
        let p = entry.snap.progress(at: entry.date)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("小薪薪").font(.system(size: 11, weight: .bold))
                if entry.snap.working {
                    Circle().fill(Color(red: 1, green: 0.35, blue: 0.3)).frame(width: 5, height: 5)
                    Text("计费中").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Text("今日 ¥\(fmtMoney(earned))")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(goldDeep)
            Text(String(format: "进度 %.1f%% · 已工作 %@", p * 100, fmtHM(entry.snap.workedMinutes(at: entry.date))))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct SalaryInlineView: View {
    let entry: SalaryEntry
    var body: some View {
        Text("小薪薪 ¥\(fmtMoney(entry.snap.earned(at: entry.date))) · \(String(format: "%.0f%%", entry.snap.progress(at: entry.date) * 100))")
    }
}

// MARK: - Widget 配置

struct SalaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SalaryWidget", provider: SalaryProvider()) { entry in
            SalarySwitch(entry: entry)
                .widgetURL(URL(string: "xiaoxinxin://open"))
        }
        .configurationDisplayName("小薪薪 · 工资到账")
        .description("实时显示今日到账金额与当日进度")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// 按 family 分发视图；accessory 系统自带材质，不加自绘背景
struct SalarySwitch: View {
    @Environment(\.widgetFamily) private var family
    let entry: SalaryEntry

    var body: some View {
        let content: AnyView = switch family {
        case .systemSmall: AnyView(SalarySmallView(entry: entry))
        case .systemMedium: AnyView(SalaryMediumView(entry: entry))
        default: AnyView(SalaryRectangularView(entry: entry))
        }
        if family == .systemSmall || family == .systemMedium {
            content.containerBackground(for: .widget) { bgGrad }
        } else {
            content
        }
    }
}

@main
struct SalaryWidgetBundle: WidgetBundle {
    var body: some Widget { SalaryWidget() }
}
