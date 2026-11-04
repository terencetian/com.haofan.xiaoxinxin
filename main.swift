// 小薪薪 — macOS 悬浮小窗版 v2
// 功能：Liquid Glass 界面 / 设置页(月薪+工作日自动计算) / 金币进度条(图标吸色)
//       明细芯片 / 迷你模式 / 状态栏常驻(含状态栏迷你金额显示)
//       关闭默认收纳到状态栏(设置可选直接退出) / 校正工时
// 纯逻辑(节假日/费率/吸色)在 Logic.swift，测试在 test_logic.swift

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WidgetKit

struct Gain: Identifiable { let id = UUID(); let xOffset: CGFloat }

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
let APP_VERSION = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.2"
let APP_BUILD = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "3"

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
    NSApp.activate(ignoringOtherApps: true)
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

    var onResize: (() -> Void)?
    var onHidePanel: (() -> Void)?           // 关闭收纳：由入口注入隐藏面板的实现

    private var baseEarned: Double = 0
    private var clockInAt: Date?
    private var lastGainMark: Double = 0
    private var workedBeforeSession: Double = 0   // 今日此前已完成计费段的累计秒数
    private var timer: Timer?
    private let ud = UserDefaults.standard
    private var tickCount = 0

    // WidgetKit 数据快照：主 App（未沙盒）写出，小组件扩展（沙盒）经临时豁免授权读取
    static let widgetSnapURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/小薪薪", isDirectory: true)
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

    func writeWidgetSnapshot(reload: Bool = false) {
        let dict: [String: Any] = [
            "baseEarned": baseEarned,
            "clockInAt": clockInAt?.timeIntervalSince1970 ?? 0,
            "working": working,
            "ratePerSec": ratePerSec,
            "ratePerDay": ratePerDay,
            "workedBeforeSession": workedBeforeSession,
            "salary": salary,
            "savedAt": Date.now.timeIntervalSince1970,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: Self.widgetSnapURL, options: .atomic)
            if let c = Self.widgetContainerSnapURL { try? data.write(to: c, options: .atomic) }
        }
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

    init() {
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
        if working && clockInAt != nil {
            logText = "⏰ \(timeStr(clockInAt!)) 打卡上班，继续计费中"
        }
        loadIcon()
        writeWidgetSnapshot()   // 启动即落快照，小组件第一次刷新就有数据
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
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
        guard working, let start = clockInAt else { return }
        displayEarned = baseEarned + Date.now.timeIntervalSince(start) * ratePerSec
        if displayEarned - lastGainMark >= 0.01 {
            lastGainMark = displayEarned
            spawnGain()
        }
        tickCount += 1
        if tickCount % 900 == 0 { writeWidgetSnapshot() }   // 30fps 计时 → 约每 30 秒落一次快照
    }

    private func spawnGain() {
        let g = Gain(xOffset: CGFloat.random(in: -90...90))
        withAnimation(.easeOut(duration: 0.15)) { gains.append(g) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeIn(duration: 0.2)) { self?.gains.removeAll { $0.id == g.id } }
        }
    }

    func clockIn() {
        clockInAt = Date.now
        lastGainMark = baseEarned
        working = true
        logText = "⏰ \(timeStr(clockInAt!)) 打卡上班，金币开始滚动"
        persist()
    }

    func clockOut() {
        guard working, let start = clockInAt else { return }
        let elapsed = max(0, Date.now.timeIntervalSince(start))
        baseEarned += elapsed * ratePerSec
        workedBeforeSession += elapsed
        displayEarned = baseEarned
        working = false
        clockInAt = nil
        logText = "🏁 \(timeStr(Date.now)) 下班打卡，今日共到账 ¥\(fmt(baseEarned))"
        persist()
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
        if let c = clockInAt { ud.set(c, forKey: "clockInAt") } else { ud.removeObject(forKey: "clockInAt") }
        writeWidgetSnapshot(reload: true)   // 打卡/校正/改薪等关键事件 → 通知小组件刷新
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
            v.material = .hudWindow
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

let redDeep = Color(red: 0.84, green: 0, blue: 0.08)

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
                .fill(Color.white.opacity(0.32))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
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
                .background(Circle().fill(Color.white.opacity(0.35)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
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
        HStack(spacing: 8) {
            Text("💰 小薪薪").font(.system(size: 15, weight: .bold))
            Text("v\(APP_VERSION)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.32)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(model.working ? Color.red : Color.gray.opacity(0.6))
                    .frame(width: 7, height: 7)
                    .shadow(color: model.working ? .red : .clear, radius: 4)
                Text(model.working ? "计费中" : "未打卡")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.35)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
            GlassIconButton(symbol: "minus", help: "迷你模式") { withAnimation { model.page = .mini } }
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
            Text(model.working ? "正在进账 · 今日已到账" : "今日已到账")
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
                        .fill(Color.white.opacity(0.38))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
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
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2.5))
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
        return String(format: "今日进度 %.1f%% · 距离全天还差 ¥%@", model.progress * 100,
                      fmt(max(0, model.ratePerDay - model.displayEarned)))
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
            .background(Capsule().fill(Color.white.opacity(0.4)))
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
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
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
                    .background(Capsule().fill(Color.white.opacity(0.42)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
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

struct SettingsView: View {
    @ObservedObject var model: EarnModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("⚙️ 设置").font(.system(size: 15, weight: .bold))
                Spacer()
                GlassIconButton(symbol: "chevron.left", help: "返回") { withAnimation { model.page = .home } }
            }
            .padding(.bottom, 6)

            sectionLabel("每月税后工资")
            HStack(spacing: 6) {
                Text("¥").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                TextField("输入每月税后工资", text: $model.salaryText).textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                Text("/月").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 1))

            sectionLabel("每月工作天数")
            HStack(spacing: 6) {
                TextField("自动 \(model.autoDays) 天（按法定节假日）", text: $model.workDaysText)
                    .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold))
                Text("天").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.white.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 1))

            Text("本月按 2026 国办法定节假日自动计算为 \(model.autoDays) 天（已扣节假日、含调休补班）。清空即恢复自动。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            sectionLabel("每日工作时长", trailing: String(format: "= %.1f 小时/天", model.effectiveHours))
            HStack(spacing: 8) {
                scheduleField(label: "上班", text: $model.workStartText, placeholder: "09:00", width: 58)
                scheduleField(label: "下班", text: $model.workEndText, placeholder: "18:00", width: 58)
                scheduleField(label: "休息", text: $model.breakMinText, placeholder: "60", width: 46, unit: "分钟")
                Spacer(minLength: 0)
            }

            Text("实际计费工时 = 下班 − 上班 − 休息，默认 09:00–18:00 休 60 分钟即 8 小时。费率 = 月薪 ÷ 工作日 ÷ 实际工时。支持跨零点（如 22:00–06:00）。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            sectionLabel("校正今日工时")
            HStack(spacing: 8) {
                TextField("如 5.5", text: $model.manualHoursText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .frame(width: 60)
                Text("小时").font(.system(size: 11)).foregroundStyle(.secondary)
                Button {
                    model.correctWork(hours: Double(model.manualHoursText) ?? -1)
                    model.manualHoursText = ""
                } label: {
                    Text("✓ 校正")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(Color.white.opacity(0.42)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
                .disabled((Double(model.manualHoursText) ?? -1) < 0)
                .opacity((Double(model.manualHoursText) ?? -1) >= 0 ? 1 : 0.62)
                Spacer()
                Text("当前已计 \(String(format: "%.1f", model.totalWorkedHours)) 小时")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.24)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.5), lineWidth: 1))

            Text("填今天实际工作的总小时数（0–24，多了少了都行），App 会与已计工时求差额并按当前费率补记或核减。适合忘打卡、中途外出、加班补差。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            sectionLabel("进度条图标")
            HStack(spacing: 12) {
                if let img = model.iconImage {
                    Image(nsImage: img).resizable().scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                }
                VStack(spacing: 8) {
                    Button { uploadIcon() } label: {
                        Text("上传自定义图标")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background(Capsule().fill(Color.white.opacity(0.42)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))

                    Button { model.setCustomIcon(nil) } label: {
                        Text("恢复默认金币")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background(Capsule().fill(Color.white.opacity(0.42)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
                }
            }
            .padding(.bottom, 8)

            Text("图标自动裁圆并吸取主色，用于进度条与背景渐变。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            sectionLabel("点击关闭按钮时")
            HStack(spacing: 8) {
                closeOption("收纳到状态栏", value: "hide", icon: "dock.rectangle")
                closeOption("直接退出", value: "quit", icon: "power")
            }

            Text("收纳到状态栏：小窗隐藏，状态栏图标继续显示金额与进度，点击随时恢复。直接退出：结束 App，今日累计会保留到下次打开。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            sectionLabel("状态栏符号", trailing: model.barSymbol.isEmpty ? "当前：仅数字" : "当前：\(model.barSymbol)")
            HStack(spacing: 8) {
                TextField("留空=仅数字", text: $model.barSymbol)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .frame(width: 78)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.3)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                    .onChange(of: model.barSymbol) { _ in model.onBarSymbolChanged() }
                ForEach(["💰", "⏱", "☀️", "🌱", "⚡"], id: \.self) { e in
                    Button { model.barSymbol = e; model.onBarSymbolChanged() } label: {
                        Text(e).font(.system(size: 15))
                            .frame(width: 30, height: 28)
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(model.barSymbol == e ? 0.6 : 0.24)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(model.barSymbol == e ? 0.75 : 0.45), lineWidth: 1))
                }
            }
            Text("金额前面的字符，任意 emoji 或符号都可以；留空则只显示数字。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

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
                .background(Capsule().fill(Color.white.opacity(0.3)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.62), lineWidth: 1))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
            }
            .buttonStyle(.plain)
            .help("关于小薪薪 · 开发者 \(DEV_NAME)")
            .padding(.top, 14)

            Spacer(minLength: 0)
        }
        .padding(20)
    }

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
                    : AnyShapeStyle(Color.white.opacity(0.32)))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0.5 : 0.55), lineWidth: 1))
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
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.3)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
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
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2))
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.4))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
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
            }
            Text(model.working ? "计费中 · 点击展开" : "点击展开")
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

    var body: some View {
        ZStack {
            GlassPanel(cornerRadius: 32).ignoresSafeArea()
            // 图标主色染色层
            RadialGradient(colors: [model.accentA.opacity(0.22), .clear],
                           center: UnitPoint(x: 0.1, y: 0.0), startRadius: 0, endRadius: 420)
                .ignoresSafeArea().allowsHitTesting(false)
            RadialGradient(colors: [model.accentB.opacity(0.18), .clear],
                           center: UnitPoint(x: 0.9, y: 1.0), startRadius: 0, endRadius: 420)
                .ignoresSafeArea().allowsHitTesting(false)

            switch model.page {
            case .home: HomeView(model: model)
            case .settings: SettingsView(model: model)
            case .mini: MiniView(model: model)
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
            unpinPanelFromEdge(panel)
            panel.makeKeyAndOrderFront(nil)
        } else if panel.isVisible {
            panel.orderOut(nil)
        } else {
            unpinPanelFromEdge(panel)
            panel.makeKeyAndOrderFront(nil)
        }
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

        let full = NSMenuItem(title: "🔍 完整界面（放大）", action: #selector(showFull), keyEquivalent: "")
        full.target = self
        statusMenu.addItem(full)

        let mini = NSMenuItem(title: "▫️ 迷你条（缩小）", action: #selector(showMini), keyEquivalent: "")
        mini.target = self
        statusMenu.addItem(mini)

        let bar = NSMenuItem(title: model.statusBarMode ? "📌 恢复小窗显示" : "📌 缩小至状态栏（显示金额+进度）",
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
        unpinPanelFromEdge(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() { showPanel(as: .settings) }
    @objc private func showFull() { showPanel(as: .home) }
    @objc private func showMini() { showPanel(as: .mini) }
    @objc private func toggleStatusBarMode() {
        if model.statusBarMode {
            model.statusBarMode = false
            unpinPanelFromEdge(panel)
            panel.makeKeyAndOrderFront(nil)
        } else {
            model.statusBarMode = true
            panel.orderOut(nil)
        }
    }
    @objc private func punchFromMenu() {
        if model.working { model.clockOut() } else { model.clockIn() }
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
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

// MARK: - 界面图导出（产品手册用：--export-shots <目录>）

final class BackdropView: NSView {
    var colors: [NSColor] = []
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 32, yRadius: 32)
        NSColor.white.setFill()
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
func exportShots(to dir: String, model: EarnModel) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let pages: [(String, Page, CGFloat, CGFloat)] = [
        ("home", .home, 372, 470),
        ("settings", .settings, 372, 700),
        ("mini", .mini, 330, 120),
    ]
    for (name, page, width, minHeight) in pages {
        model.page = page
        let hosting = NSHostingView(rootView: ContentView(model: model))
        var h = max(minHeight, hosting.fittingSize.height)
        if page == .settings { h = max(h, hosting.fittingSize.height) }
        let pad: CGFloat = 46
        let box = NSSize(width: width + pad * 2, height: h + pad * 2)
        let container = BackdropView(frame: NSRect(origin: .zero, size: box))
        container.wantsLayer = true
        container.colors = [
            NSColor(model.accentA).withAlphaComponent(0.35),
            NSColor(model.accentB).withAlphaComponent(0.25)
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
            try? data.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
        model.page = .home
    }
    print("导出完成：\(dir)")
}

// MARK: - 入口

// 无边框面板默认不能成为 key window（键盘输入进不来）——必须子类化放行
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.isFloatingPanel = true
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = true
panel.isMovableByWindowBackground = true
panel.hidesOnDeactivate = false
panel.becomesKeyOnlyIfNeeded = true   // 只在点击文本框等需要键盘的场景成为 key，不抢焦点

MainActor.assumeIsolated {
    migrateLegacyDefaultsIfNeeded()
    let model = EarnModel()

    // 导出界面图模式：--export-shots <目录>
    if let i = CommandLine.arguments.firstIndex(of: "--export-shots"), i + 1 < CommandLine.arguments.count {
        exportShots(to: CommandLine.arguments[i + 1], model: model)
        exit(0)
    }
    let hosting = NSHostingController(rootView: ContentView(model: model))
    panel.contentViewController = hosting

    // 页面切换时同步窗口尺寸（顶部锚定）；进设置页时把面板设为 key 以便输入
    model.onResize = {
        DispatchQueue.main.async {
            let old = panel.frame
            let fit = hosting.view.fittingSize
            let newW = model.page == .mini ? 330.0 : 372.0
            let newH = max(90, fit.height)
            let newFrame = NSRect(x: old.midX - newW / 2, y: old.maxY - newH, width: newW, height: newH)
            panel.setFrame(newFrame, display: true, animate: false)
            if model.page == .settings { panel.makeKey() }
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
    app.mainMenu = buildMainMenu(appName: "小薪薪")
    app.setActivationPolicy(.regular)   // 常规应用：Dock 图标 + Cmd-Tab，不会被当成后台偷跑
    app.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    let statusBar = StatusBarController(panel: panel, model: model)  // 必须强持有，否则释放后点击失效
    _ = statusBar

    // 统一「把面板捞回来」：小组件点击 / 点 Dock 图标 / 状态栏图标都走这里
    let bringPanelBack: () -> Void = {
        model.statusBarMode = false
        withAnimation { model.page = .home }
        unpinPanelFromEdge(panel)
        panel.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
    }
    URLOpener.shared.onOpen = bringPanelBack
    appDelegate.onReopen = bringPanelBack
    appDelegate.onShowSettings = {
        model.statusBarMode = false
        withAnimation { model.page = .settings }
        unpinPanelFromEdge(panel)
        panel.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
    }
    NSAppleEventManager.shared().setEventHandler(
        URLOpener.shared,
        andSelector: #selector(URLOpener.handle(_:reply:)),
        forEventClass: AEEventClass(kInternetEventClass),
        andEventID: AEEventID(kAEGetURL))

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
