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

// MARK: - 2.0 自定义工作日规则
//
// Calendar.weekday：1=周日，2=周一 … 7=周六。
// 旧版把「周一~周五 + 法定节假日」写死，且在启动时只算一次（跨月不重算）；
// 2.0 起由调用方每次传入规则，按当前月份实时计算，手填天数优先级最高。

struct WorkdayRule {
    var weekdays: Set<Int>          // 允许计薪的星期
    var useLegalHolidays: Bool      // 是否叠加国办法定节假日 / 调休补班
    var manualDays: Int?            // 手动指定每月天数（>0 时直接采用）

    static let `default` = WorkdayRule(weekdays: [2, 3, 4, 5, 6],
                                       useLegalHolidays: true, manualDays: nil)
}

func isWorkDate(_ d: Date, rule: WorkdayRule) -> Bool {
    let key = dateKey(d)
    if rule.useLegalHolidays {
        if HOLIDAYS.contains(key) { return false }
        if EXTRA_WORKDAYS.contains(key) { return true }
    }
    let dow = Calendar.current.component(.weekday, from: d)
    return rule.weekdays.contains(dow)
}

func monthWorkDays(_ date: Date, rule: WorkdayRule) -> Int {
    if let n = rule.manualDays, n > 0 { return n }
    let cal = Calendar.current
    let ym = cal.dateComponents([.year, .month], from: date)
    guard let range = cal.range(of: .day, in: .month, for: date) else { return 22 }
    var n = 0
    for day in range {
        var dc = DateComponents()
        dc.year = ym.year; dc.month = ym.month; dc.day = day
        if let d = cal.date(from: dc), isWorkDate(d, rule: rule) { n += 1 }
    }
    return n
}

// 兼容 1.x 单测与调用：不传规则 = 默认法定口径
func isWorkDate(_ d: Date) -> Bool { isWorkDate(d, rule: .default) }
func monthWorkDays(_ date: Date) -> Int { monthWorkDays(date, rule: .default) }

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

// 当前班次的计划上班时刻（shiftEndTime 的对称函数，供自动打卡上班使用）。
// 同日班 → 当天 start；跨零点班 → now 已过当天 start 则为当天，否则为前一天（凌晨仍属昨晚的班次）。
func shiftStartTime(now: Date, startStr: String, endStr: String) -> Date? {
    func comps(_ s: String) -> (Int, Int)? {
        let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]),
              h >= 0, h < 24, m >= 0, m < 60 else { return nil }
        return (h, m)
    }
    guard let (eh, em) = comps(endStr), let (sh, sm) = comps(startStr) else { return nil }
    let cal = Calendar.current
    guard let startToday = cal.date(bySettingHour: sh, minute: sm, second: 0, of: now) else { return nil }
    let crossMidnight = (eh * 60 + em) <= (sh * 60 + sm)
    if !crossMidnight { return startToday }
    return now >= startToday ? startToday : cal.date(byAdding: .day, value: -1, to: startToday)
}

// 班次标识：以计划上班时刻所在日期为准，跨零点班次的前后半夜算同一个班次
func shiftKey(_ start: Date) -> String { dateKey(start) }

// MARK: - 午休窗口与可计费时长（三端同口径）

private func clockComps(_ s: String) -> (Int, Int)? {
    let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
    guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]),
          h >= 0, h < 24, m >= 0, m < 60 else { return nil }
    return (h, m)
}

// 班次内的休息区间。以前只有「休息时长」没有起点，结果分母扣了休息、分子按墙钟跑，
// 9:00–18:00 休 60 分在 16:38 会算成 95%，实际应约 83%。
// 现在按用户填的「休息开始」定位；时刻落在班次外（或非法）时回退「有效工时对半分」。
func breakWindow(shiftStart: Date, shiftEnd: Date,
                 breakStartStr: String, breakMinutes: Double) -> (start: Date, end: Date) {
    let cal = Calendar.current
    let span = shiftEnd.timeIntervalSince(shiftStart)
    guard span > 0 else { return (shiftStart, shiftStart) }
    let brk = min(max(0, breakMinutes) * 60, span)
    guard brk > 0 else { return (shiftStart, shiftStart) }

    var start: Date
    if let (h, m) = clockComps(breakStartStr),
       let t = cal.date(bySettingHour: h, minute: m, second: 0, of: shiftStart) {
        start = t
        // 跨零点班次（22:00–06:00 休 02:00–03:00）：休息时刻比上班早 → 落到次日
        if start < shiftStart { start = cal.date(byAdding: .day, value: 1, to: start) ?? t }
    } else {
        start = shiftStart.addingTimeInterval((span - brk) / 2)
    }
    if start < shiftStart || start >= shiftEnd {
        start = shiftStart.addingTimeInterval((span - brk) / 2)
    }
    if start.addingTimeInterval(brk) > shiftEnd {
        start = shiftEnd.addingTimeInterval(-brk)
    }
    return (start, start.addingTimeInterval(brk))
}

// [from, to] 这段真实时间里真正计入工作的秒数：与休息区间重叠的部分不计，
// 班次之外（提前到 / 加班）按 1:1 计。休息期间进度冻结而不是倒退，下班刚好 100%。
func billableSeconds(from: Date, to: Date, startStr: String, endStr: String,
                     breakStartStr: String, breakMinutes: Double) -> Double {
    let wall = to.timeIntervalSince(from)
    guard wall > 0 else { return 0 }
    guard let s0 = shiftStartTime(now: from, startStr: startStr, endStr: endStr),
          let s1 = shiftEndTime(now: from, startStr: startStr, endStr: endStr) else { return wall }

    func overlap(_ a: Date, _ b: Date) -> Double {
        let lo = max(from, a), hi = min(to, b)
        return hi > lo ? hi.timeIntervalSince(lo) : 0
    }
    let win = breakWindow(shiftStart: s0, shiftEnd: s1,
                          breakStartStr: breakStartStr, breakMinutes: breakMinutes)
    let inShift = overlap(s0, s1)
    let worked = overlap(s0, win.start) + overlap(win.end, s1)
    return worked + max(0, wall - inShift)
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

// MARK: - 2.0 进度条统计内容
//
// 进度条不再绑死「今日已赚 ÷ 日薪」：所有口径统一算出一个 ratio（可 > 1，
// 例如 8 小时工时 + 4 小时加班 = 1.5），由 UI 决定怎么画、怎么标数字。

enum ProgressMetric: String, CaseIterable, Codable {
    case todaySalary    // 今日工资进度
    case monthSalary    // 本月工资进度
    case todayHours     // 今日工时进度（可超 100%）
    case monthHours     // 本月工时进度（可超 100%）
    case countdown      // 自定义日期倒计时

    var title: String {
        switch self {
        case .todaySalary: return "今日工资进度"
        case .monthSalary: return "本月工资进度"
        case .todayHours:  return "今日工时进度"
        case .monthHours:  return "本月工时进度"
        case .countdown:   return "日期倒计时"
        }
    }

    var detail: String {
        switch self {
        case .todaySalary: return "今日已到账 ÷ 日薪"
        case .monthSalary: return "本月累计 ÷ 月薪"
        case .todayHours:  return "今日已工作 ÷ 计划工时，加班可超 100%"
        case .monthHours:  return "本月已工作 ÷ 本月应出勤工时"
        case .countdown:   return "按天走数，可显示剩余天数或完成百分比"
        }
    }

    var isMoney: Bool { self == .todaySalary || self == .monthSalary }
}

/// 工时进度：workedSeconds ÷ 计划工时，加班时自然超过 1
func hoursProgress(workedSeconds: Double, plannedHours: Double) -> Double {
    guard plannedHours > 0, workedSeconds > 0 else { return 0 }
    return workedSeconds / (plannedHours * 3600)
}

/// 把可 >1 的进度安全地折成「条内填充比例」，超出部分由 UI 另画第二段
func clampedProgress(_ r: Double) -> Double { min(1, max(0, r)) }

/// 百分比文案：加班 4h（8h 为满）→ 150.0%
func percentText(_ r: Double, dec: Int = 1) -> String {
    String(format: "%.\(dec)f%%", max(0, r) * 100)
}

// MARK: - 2.1 自定义日期倒计时（按天维度走数）

struct CountdownItem: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""             // 新年 / 生日 / 纪念日
    var month: Int = 1
    var day: Int = 1
    var year: Int? = nil              // nil = 每年重复；有值 = 一次性目标
    var mode: String = "days"         // "days" = 剩余天数；"percent" = 完成百分比
    var createdKey: String = ""       // 创建日 yyyy-MM-dd（一次性目标的百分比起点）

    // 2.4：用户可自己指定起始日期与目标时刻；留空 = 沿用旧口径
    // （一次性用创建日、每年重复用上一次同月同日；时刻默认 00:00）
    var startYear: Int? = nil
    var startMonth: Int? = nil
    var startDay: Int? = nil
    var targetHour: Int? = nil
    var targetMinute: Int? = nil

    var isYearly: Bool { year == nil }
    var modeTitle: String { mode == "percent" ? "百分比" : "天数" }

    /// 是否设置了自定义起始日
    var hasCustomStart: Bool {
        guard let y = startYear, let m = startMonth, let d = startDay else { return false }
        guard (1970...2100).contains(y), (1...12).contains(m), (1...31).contains(d) else { return false }
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d
        guard let date = Calendar.current.date(from: dc) else { return false }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return c.year == y && c.month == m && c.day == d
    }

    var startKeyText: String? {
        guard hasCustomStart, let y = startYear, let m = startMonth, let d = startDay else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// 目标时刻文本 HH:mm
    var targetTimeText: String { String(format: "%02d:%02d", targetHour ?? 0, targetMinute ?? 0) }
    var hasCustomTime: Bool { (targetHour ?? 0) != 0 || (targetMinute ?? 0) != 0 }

    var valid: Bool {
        guard (1...12).contains(month), (1...31).contains(day) else { return false }
        if let y = year, !(1970...2100).contains(y) { return false }
        if let h = targetHour, !(0...23).contains(h) { return false }
        if let mi = targetMinute, !(0...59).contains(mi) { return false }
        if startYear != nil || startMonth != nil || startDay != nil, !hasCustomStart { return false }
        // 用闰年校验月日组合（允许 2/29，非闰年由 Calendar 归一化到 3/1）
        var dc = DateComponents()
        dc.year = 2024; dc.month = month; dc.day = day
        return Calendar.current.date(from: dc) != nil
    }
}

/// 2.4：自定义起始日必须早于目标日（每年重复的目标日跨年顺延，不做该校验）
func countdownRangeError(_ item: CountdownItem) -> String? {
    guard item.hasCustomStart, let key = item.startKeyText, let y = item.year else { return nil }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    guard let s = f.date(from: key),
          let t = f.date(from: String(format: "%04d-%02d-%02d", y, item.month, item.day)) else { return nil }
    return t <= s ? "起始日必须早于目标日" : nil
}

struct CountdownProgress {
    var daysLeft: Int          // 距目标日剩余自然日（当天为 0）
    var totalDays: Int         // 起点 → 目标日的总天数（百分比分母）
    var elapsedDays: Int
    var ratio: Double          // 0...1，进度条走数用
    var targetKey: String      // yyyy-MM-dd
    var expired: Bool          // 一次性目标已过
}

/// 自然日差（跨时区/夏令时安全：先归一到当天 00:00）
func calendarDays(from: Date, to: Date) -> Int {
    let cal = Calendar.current
    let a = cal.startOfDay(for: from), b = cal.startOfDay(for: to)
    return cal.dateComponents([.day], from: a, to: b).day ?? 0
}

/// 构造指定年月日的当天 00:00；非法月日（如非闰年 2/29）由 Calendar 归一化
private func makeDay(year: Int, month: Int, day: Int) -> Date? {
    var dc = DateComponents()
    dc.year = year; dc.month = month; dc.day = day
    dc.hour = 0; dc.minute = 0; dc.second = 0
    return Calendar.current.date(from: dc)
}

/// 构造指定年月日 + 时刻（2.4：倒计时支持精确到分钟）
private func makeMoment(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date? {
    var dc = DateComponents()
    dc.year = year; dc.month = month; dc.day = day
    dc.hour = max(0, min(23, hour)); dc.minute = max(0, min(59, minute)); dc.second = 0
    return Calendar.current.date(from: dc)
}

/// 计算倒计时进度。年度重复：过了今年就顺延到明年；一次性：过期返回 expired=true。
/// 2.4：起点优先用用户设置的起始日，其次才是创建日 / 上一次同月同日；
/// 目标可带时刻，进度按秒算（跨天也连续），天数仍按自然日给。
func countdownProgress(_ item: CountdownItem, now: Date = Date()) -> CountdownProgress? {
    guard item.valid else { return nil }
    let cal = Calendar.current
    let today = cal.startOfDay(for: now)
    let thisYear = cal.component(.year, from: today)
    let hour = item.targetHour ?? 0
    let minute = item.targetMinute ?? 0

    let target: Date?
    if let y = item.year {
        target = makeMoment(year: y, month: item.month, day: item.day, hour: hour, minute: minute)
    } else if let t = makeMoment(year: thisYear, month: item.month, day: item.day, hour: hour, minute: minute) {
        target = t >= now ? t
            : makeMoment(year: thisYear + 1, month: item.month, day: item.day, hour: hour, minute: minute)
    } else {
        target = nil
    }
    guard let target else { return nil }

    // 百分比起点：用户指定起始日 > 年度重复的「上一次同月同日」> 一次性目标的创建日
    var start: Date?
    if let key = item.startKeyText {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        start = f.date(from: key).map { cal.startOfDay(for: $0) }
    }
    if start == nil {
        if item.isYearly {
            let lastYear = cal.component(.year, from: target) - 1
            start = makeMoment(year: lastYear, month: item.month, day: item.day, hour: hour, minute: minute)
        } else if isValidDayKey(item.createdKey) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "Asia/Shanghai")
            start = f.date(from: item.createdKey).map { cal.startOfDay(for: $0) }
        }
    }
    if start == nil || start! >= target {
        start = cal.date(byAdding: .day, value: -365, to: target)
    }
    let begin = start!
    let totalSeconds = max(60, target.timeIntervalSince(begin))
    let elapsedSeconds = min(totalSeconds, max(0, now.timeIntervalSince(begin)))
    let total = max(1, calendarDays(from: begin, to: target))
    let elapsed = min(total, max(0, calendarDays(from: begin, to: min(now, target))))
    let left = max(0, calendarDays(from: today, to: target))
    return CountdownProgress(daysLeft: left, totalDays: total, elapsedDays: elapsed,
                             ratio: min(1, elapsedSeconds / totalSeconds),
                             targetKey: dateKey(target),
                             expired: !item.isYearly && target < now)
}

/// 2.4：纪念日的「累计时长」= 起始日到今天，拆成 X 年 Y 个月 Z 天
struct ElapsedSpan: Equatable {
    var years = 0
    var months = 0
    var days = 0
    var totalDays = 0

    var shortText: String {
        var parts: [String] = []
        if years > 0 { parts.append("\(years) 年") }
        if months > 0 { parts.append("\(months) 个月") }
        if days > 0 || parts.isEmpty { parts.append("\(days) 天") }
        return parts.joined(separator: " ")
    }
}

func elapsedSpan(from start: Date, to end: Date = Date()) -> ElapsedSpan {
    let cal = Calendar.current
    let s = cal.startOfDay(for: start), e = cal.startOfDay(for: end)
    guard e >= s else { return ElapsedSpan() }
    let c = cal.dateComponents([.year, .month, .day], from: s, to: e)
    return ElapsedSpan(years: c.year ?? 0, months: c.month ?? 0, days: c.day ?? 0,
                       totalDays: cal.dateComponents([.day], from: s, to: e).day ?? 0)
}

// MARK: - 2.1 记录日 / 纪念日（从起始日累计天数，与倒计时方向相反）

struct RecordDayItem: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""             // 在一起 / 入职 / 搬家 …
    var year: Int = 2026              // 起始年份
    var month: Int = 1
    var day: Int = 1
    var targetDays: Int = 0           // 0 = 自动按 100 天里程碑；>0 = 自定义目标天数
    var mode: String = "days"         // "days" = 累计天数；"percent" = 里程碑百分比

    var milestoneStep: Int { targetDays > 0 ? targetDays : 100 }
    var modeTitle: String { mode == "percent" ? "百分比" : "天数" }

    var valid: Bool {
        guard (1970...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return false }
        guard targetDays >= 0, targetDays <= 100000 else { return false }
        var dc = DateComponents()
        dc.year = year; dc.month = month; dc.day = day
        guard let date = Calendar.current.date(from: dc) else { return false }
        // 记录日必须是真实存在的日期：Calendar 会把 2/31 归一到 3/3，这里要挡掉
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return c.year == year && c.month == month && c.day == day
    }
}

struct RecordDayProgress {
    var elapsedDays: Int        // 从起始日到今天已记录的自然日
    var startKey: String        // yyyy-MM-dd
    var milestoneStep: Int      // 里程碑步长（自定义目标或 100 天）
    var milestoneDone: Int      // 当前里程碑内已走天数
    var daysToMilestone: Int    // 距下一个里程碑
    var milestoneIndex: Int     // 已完成的里程碑个数
    var ratio: Double           // 0...1，里程碑进度
    var started: Bool           // 起始日是否已到（未来日期 → false）
    var span: ElapsedSpan = ElapsedSpan()   // 2.4：累计时长（X 年 Y 个月 Z 天）
}

/// 纪念日进度：起点为某个历史日期，按自然日累计。
/// 2.4 起主展示改成「累计时长」，里程碑只作为附带信息保留。
func recordDayProgress(_ item: RecordDayItem, now: Date = Date()) -> RecordDayProgress? {
    guard item.valid, let start = makeDay(year: item.year, month: item.month, day: item.day) else { return nil }
    let cal = Calendar.current
    let today = cal.startOfDay(for: now)
    let elapsed = max(0, calendarDays(from: start, to: today))
    let step = max(1, item.milestoneStep)
    let remainder = elapsed % step
    // 正好落在里程碑当天：显示 100%，第二天再归零重新走
    let done = (elapsed > 0 && remainder == 0) ? step : remainder
    return RecordDayProgress(
        elapsedDays: elapsed,
        startKey: dateKey(start),
        milestoneStep: step,
        milestoneDone: done,
        daysToMilestone: step - done,
        milestoneIndex: elapsed / step,
        ratio: min(1, Double(done) / Double(step)),
        started: start <= today,
        span: elapsedSpan(from: start, to: now))
}

// MARK: - 事件顺序调整（倒计时 / 纪念日共用，纯逻辑、可被单测覆盖）
//
// 数组本身就是唯一的顺序来源：存盘直接 encode 整个数组，因此任何重排只要改数组，
// 显示顺序与本机会话一致。activeCountdownId / activeRecordDayId 按 id 引用，不受位置影响。

enum EventOrder {
    /// 拖拽：把 id 插到 targetID 之前（先移除再按 id 重找落点，避免索引偏移）
    static func place<T: Identifiable>(_ items: inout [T], id: T.ID, before targetID: T.ID) -> Bool
    where T.ID: Equatable {
        guard id != targetID,
              let from = items.firstIndex(where: { $0.id == id }) else { return false }
        let moved = items.remove(at: from)
        guard let to = items.firstIndex(where: { $0.id == targetID }) else {
            items.insert(moved, at: from)   // 目标已不存在 → 原样还原
            return false
        }
        items.insert(moved, at: to)
        return true
    }

    /// 菜单「上移 / 下移」：相对位移，越界自动夹紧
    static func shift<T: Identifiable>(_ items: inout [T], id: T.ID, by delta: Int) -> Bool
    where T.ID: Equatable {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return false }
        return move(&items, from: from, to: from + delta)
    }

    /// 菜单「置顶 / 置底」：绝对位置，越界自动夹紧
    static func place<T: Identifiable>(_ items: inout [T], id: T.ID, at index: Int) -> Bool
    where T.ID: Equatable {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return false }
        return move(&items, from: from, to: index)
    }

    static func move<T>(_ items: inout [T], from: Int, to: Int) -> Bool {
        guard items.count > 1, from >= 0, from < items.count else { return false }
        let dest = max(0, min(items.count - 1, to))
        guard dest != from else { return false }
        let moved = items.remove(at: from)
        items.insert(moved, at: dest)
        return true
    }
}
