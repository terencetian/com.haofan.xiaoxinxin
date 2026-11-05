// Logic.swift — 纯逻辑层（可独立编译跑测试）

import AppKit
import Foundation

let WORK_HOURS: Double = 8.0

// 每日实际计费工时 = 下班 − 上班 − 休息；支持跨零点（如 22:00–06:00）
// 输入非法（格式错/时长过短）时回退默认 8 小时
func effectiveWorkHours(startStr: String, endStr: String, breakMinutes: Double) -> Double {
    func parse(_ s: String) -> Double? {
        let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard p.count == 2, let h = Double(p[0]), let m = Double(p[1]),
              h >= 0, h < 24, m >= 0, m < 60 else { return nil }
        return h + m / 60
    }
    guard let s = parse(startStr), let e = parse(endStr) else { return WORK_HOURS }
    var span = e - s
    if span <= 0 { span += 24 }   // 跨零点
    let hours = span - breakMinutes / 60
    return hours >= 0.5 ? hours : WORK_HOURS   // 有效工时不足半小时视为配置错误
}

// MARK: - 2026 年法定节假日（国办发〔2025〕放假安排）

let HOLIDAY_RANGES: [(String, String)] = [
    ("2026-01-01", "2026-01-03"),  // 元旦
    ("2026-02-15", "2026-02-23"),  // 春节
    ("2026-04-04", "2026-04-06"),  // 清明
    ("2026-05-01", "2026-05-05"),  // 劳动节
    ("2026-06-19", "2026-06-21"),  // 端午
    ("2026-09-25", "2026-09-27"),  // 中秋
    ("2026-10-01", "2026-10-07"),  // 国庆
]
let EXTRA_WORKDAYS: Set<String> = ["2026-01-04", "2026-02-14", "2026-02-28",
                                   "2026-05-09", "2026-09-20", "2026-10-10"]

func dateKey(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

// 严格校验 yyyy-MM-dd（格式 + 真实日历有效性，拒绝 2026-02-30 这类）
func isValidDayKey(_ s: String) -> Bool {
    guard s.count == 10 else { return false }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.isLenient = false
    guard let d = f.date(from: s) else { return false }
    return f.string(from: d) == s
}

let HOLIDAYS: Set<String> = {
    var s = Set<String>()
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    for (a, b) in HOLIDAY_RANGES {
        var d = f.date(from: a)!
        let end = f.date(from: b)!
        while d <= end { s.insert(dateKey(d)); d = Calendar.current.date(byAdding: .day, value: 1, to: d)! }
    }
    return s
}()

func isWorkDate(_ d: Date) -> Bool {
    let key = dateKey(d)
    if HOLIDAYS.contains(key) { return false }
    if EXTRA_WORKDAYS.contains(key) { return true }
    let dow = Calendar.current.component(.weekday, from: d)
    return dow != 1 && dow != 7
}

func monthWorkDays(_ date: Date) -> Int {
    let cal = Calendar.current
    let ym = cal.dateComponents([.year, .month], from: date)
    guard let range = cal.range(of: .day, in: .month, for: date) else { return 22 }
    var n = 0
    for day in range {
        var dc = DateComponents()
        dc.year = ym.year; dc.month = ym.month; dc.day = day
        if let d = cal.date(from: dc), isWorkDate(d) { n += 1 }
    }
    return n
}

func fmt(_ n: Double, _ dec: Int = 2) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = dec
    formatter.maximumFractionDigits = dec
    formatter.groupingSeparator = ","
    formatter.decimalSeparator = "."
    return formatter.string(from: NSNumber(value: n)) ?? String(format: "%.\(dec)f", n)
}

func timeStr(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}

// 当前班次的计划下班时刻。
// 同日班（start < end）→ 当天 end 时刻；跨零点班（start >= end）→ now 已过当天 start 则为次日 end，否则为当天 end。
// 时间文本非法返回 nil。
func shiftEndTime(now: Date, startStr: String, endStr: String) -> Date? {
    func comps(_ s: String) -> (Int, Int)? {
        let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]),
              h >= 0, h < 24, m >= 0, m < 60 else { return nil }
        return (h, m)
    }
    guard let (eh, em) = comps(endStr), let (sh, sm) = comps(startStr) else { return nil }
    let cal = Calendar.current
    guard let endToday = cal.date(bySettingHour: eh, minute: em, second: 0, of: now),
          let startToday = cal.date(bySettingHour: sh, minute: sm, second: 0, of: now) else { return nil }
    let crossMidnight = (eh * 60 + em) <= (sh * 60 + sm)
    if !crossMidnight { return endToday }
    return now >= startToday ? cal.date(byAdding: .day, value: 1, to: endToday) : endToday
}

// MARK: - 主色提取（图标吸色）

func extractPalette(_ image: NSImage) -> (NSColor, NSColor)? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = 48, h = 48
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return nil }
    let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

    var buckets: [Int: (r: Double, g: Double, b: Double, n: Int)] = [:]
    for i in stride(from: 0, to: w * h * 4, by: 4) {
        let r = Double(p[i]) / 255, g = Double(p[i+1]) / 255, b = Double(p[i+2]) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { continue }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        if s < 0.25 || l < 0.15 || l > 0.85 { continue }
        var hue: Double
        if mx == r { hue = (g - b) / d + (g < b ? 6 : 0) }
        else if mx == g { hue = (b - r) / d + 2 }
        else { hue = (r - g) / d + 4 }
        let bin = Int(hue * 60 / 30) % 12
        var bk = buckets[bin] ?? (0, 0, 0, 0)
        bk.r += r; bk.g += g; bk.b += b; bk.n += 1
        buckets[bin] = bk
    }
    let tops = buckets.map { (bin: $0.key, r: $0.value.r / Double($0.value.n),
                              g: $0.value.g / Double($0.value.n), b: $0.value.b / Double($0.value.n),
                              n: $0.value.n) }.sorted { $0.n > $1.n }
    guard let first = tops.first else { return nil }
    var second: (bin: Int, r: Double, g: Double, b: Double, n: Int)?
    for t in tops.dropFirst() {
        var dist = abs(t.bin - first.bin) * 30
        dist = min(dist, 360 - dist)
        if dist >= 60 { second = t; break }
    }
    func col(_ t: (bin: Int, r: Double, g: Double, b: Double, n: Int)) -> NSColor {
        NSColor(red: t.r, green: t.g, blue: t.b, alpha: 1)
    }
    return (col(first), col(second ?? first))
}
