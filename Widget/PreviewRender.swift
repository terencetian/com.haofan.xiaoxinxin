#if WIDGET_PREVIEW
// 仅用于本地渲染校验：把小组件视图按四套主题各渲染一张 PNG。
// 正常构建（扩展 / 主 App）不含本文件，也不定义 WIDGET_PREVIEW。
import SwiftUI
import AppKit
import WidgetKit

@main
struct PreviewMain {
    static func main() { PreviewRender.run() }
}

@MainActor
enum PreviewRender {
    static func demo(theme: ThemeSkin) -> Snap {
        var s = Snap()
        s.salary = 3500
        s.ratePerDay = 166.67
        s.ratePerSec = 166.67 / (8 * 3600)
        s.working = true
        s.clockInAt = Date.now.addingTimeInterval(-4.27 * 3600)
        s.workedBeforeSession = 0
        s.baseEarned = 0
        s.monthRatio = 0.118
        s.plannedHours = 8
        s.theme = theme
        var cd = SnapCountdown()
        cd.name = "新年"
        let target = Calendar.current.date(byAdding: .day, value: 55, to: Date.now) ?? Date.now
        cd.targetTS = target.timeIntervalSince1970
        cd.targetKey = key(target)
        cd.totalDays = 365
        s.countdown = cd
        var rd = SnapRecordDay()
        rd.name = "在一起"
        rd.startKey = "2020-10-06"
        s.record = rd
        return s
    }

    static func key(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func render<V: View>(_ view: V, size: CGSize, to path: String) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func run() {
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/widget-preview"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let themes: [(String, ThemeSkin)] = [
            ("sky", ThemeSkin.preset("sky")),
            ("mint", ThemeSkin.preset("mint")),
            ("sony30", ThemeSkin.preset("sony30")),
            ("liquidGlass", ThemeSkin.preset("liquidGlass")),
        ]
        let small = CGSize(width: 170, height: 170)
        let medium = CGSize(width: 350, height: 170)
        for (name, skin) in themes {
            let snap = demo(theme: skin)
            let entry = SalaryEntry(date: .now, snap: snap)
            render(box(MoneySmallView(entry: entry), skin: skin, size: small), size: small,
                   to: "\(out)/money-small-\(name).png")
            render(box(MoneyMediumView(entry: entry), skin: skin, size: medium), size: medium,
                   to: "\(out)/money-medium-\(name).png")
            render(box(DaysSmallView(entry: entry), skin: skin, size: small), size: small,
                   to: "\(out)/days-small-\(name).png")
            render(box(DaysMediumView(entry: entry), skin: skin, size: medium), size: medium,
                   to: "\(out)/days-medium-\(name).png")
        }
        print("WIDGET-PREVIEW| \(out)")
    }

    /// 小组件圆角以系统为准，这里给 22pt 连续圆角，贴近桌面上看到的样子
    static func box<V: View>(_ content: V, skin: ThemeSkin, size: CGSize) -> some View {
        content
            .frame(width: size.width, height: size.height)
            .background(ThemeBackground(skin: skin))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

#endif
