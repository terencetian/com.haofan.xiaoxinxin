// test_logic.swift — 逻辑层单元测试
// 手工核算的 2026 年期望值：1月21天 / 2月16天 / 5月19天 / 10月18天 / 11月21天

import Foundation
import AppKit

@main
struct LogicTests {
    static func d(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.date(from: s)!
    }

    static func main() {
        let cases: [(String, Int)] = [
            ("2026-01-10", 21),  // 1月：元旦1-3放假，1/4补班
            ("2026-02-15", 16),  // 2月：春节15-23放假，14/28补班
            ("2026-04-15", 21),  // 4月：清明4-6放假（只扣4/6周一），无调休
            ("2026-05-01", 19),  // 5月：劳动节1-5放假，5/9补班
            ("2026-10-01", 18),  // 10月：国庆1-7放假，10/10补班
            ("2026-11-04", 21),  // 11月：无节假日，纯周末扣除
        ]

        var failed = 0
        for (dateStr, expect) in cases {
            let got = monthWorkDays(d(dateStr))
            let ok = got == expect
            print("\(ok ? "✅" : "❌") \(dateStr) 所在月工作日: 期望 \(expect), 实际 \(got)")
            if !ok { failed += 1 }
        }

        // 节假日判定
        assert(!isWorkDate(d("2026-01-01")), "元旦应放假")
        assert(!isWorkDate(d("2026-02-17")), "春节应放假")
        assert(isWorkDate(d("2026-02-14")), "春节补班周六应上班")
        assert(isWorkDate(d("2026-10-10")), "国庆补班周六应上班")
        assert(!isWorkDate(d("2026-11-01")), "普通周日不上班")
        assert(isWorkDate(d("2026-11-04")), "普通周三上班")
        print("✅ 节假日/调休判定 6 项通过")

        // 费率口径：月薪 ÷ 工作日 ÷ 8h ÷ 3600s
        let salary = 20000.0
        let perSec = salary / 21.0 / WORK_HOURS / 3600
        assert(abs(perSec - 0.03286) < 0.0001, "每秒费率 \(perSec)")
        print(String(format: "✅ 费率口径通过：月薪2万/21天 → ¥%.5f/秒", perSec))

        // 每日工时自定义：下班 − 上班 − 休息
        func hours(_ s: String, _ e: String, _ b: Double) -> Double {
            effectiveWorkHours(startStr: s, endStr: e, breakMinutes: b)
        }
        assert(abs(hours("09:00", "18:00", 60) - 8.0) < 1e-9, "默认 09-18 休60 = 8h")
        assert(abs(hours("9:30", "18:00", 30) - 8.0) < 1e-9, "09:30-18:00 休30 = 8h")
        assert(abs(hours("22:00", "06:00", 60) - 7.0) < 1e-9, "跨零点 22-06 休60 = 7h")
        assert(abs(hours("08:00", "20:00", 90) - 10.5) < 1e-9, "08-20 休90 = 10.5h")
        assert(abs(hours("abc", "18:00", 60) - WORK_HOURS) < 1e-9, "非法格式回退默认 8h")
        assert(abs(hours("09:00", "09:30", 60) - WORK_HOURS) < 1e-9, "工时过短回退默认 8h")
        print("✅ 工时自定义 6 项通过（含跨零点与非法回退）")

        // 班次下班时刻（自动下班/加班判定用）
        func endAt(_ dateStr: String, _ hhmm: String, start: String = "09:00") -> String {
            timeStr(shiftEndTime(now: d(dateStr) + 3600, startStr: start, endStr: hhmm)!)  // +1h 进入当天
        }
        func endDay(_ dateStr: String, _ hhmm: String, start: String = "09:00") -> String {
            dateKey(shiftEndTime(now: d(dateStr) + 3600, startStr: start, endStr: hhmm)!)
        }
        assert(endAt("2026-11-05", "18:00") == "18:00", "同日班 → 当天 18:00")
        assert(endDay("2026-11-05", "18:00") == "2026-11-05", "同日班不跨天")
        assert(endDay("2026-11-05", "06:00", start: "22:00") == "2026-11-06", "跨零点班（22 点后打卡）→ 次日 06:00")
        // 跨零点班、现在还在白天（未过当天 start）→ 当天 end
        let noonEnd = shiftEndTime(now: d("2026-11-05") + 12 * 3600, startStr: "22:00", endStr: "06:00")
        assert(noonEnd != nil && dateKey(noonEnd!) == "2026-11-05" && timeStr(noonEnd!) == "06:00",
               "跨零点班（22 点前）→ 当天 06:00")
        assert(shiftEndTime(now: d("2026-11-05"), startStr: "09:00", endStr: "abc") == nil, "非法时间返回 nil")
        print("✅ 班次下班时刻 5 项通过（同日/跨零点/非法）")

        // 班次上班时刻（自动打卡上班判定用）
        func startAt(_ dateStr: String, _ hourOffset: Double, start: String = "09:00", end: String = "18:00") -> Date? {
            shiftStartTime(now: d(dateStr) + hourOffset * 3600, startStr: start, endStr: end)
        }
        let s1 = startAt("2026-11-05", 10)   // 上班后 1 小时
        assert(s1 != nil && dateKey(s1!) == "2026-11-05" && timeStr(s1!) == "09:00", "同日班 → 当天 09:00")
        let s2 = startAt("2026-11-05", 8)    // 还没到上班时间
        assert(s2 != nil && dateKey(s2!) == "2026-11-05" && timeStr(s2!) == "09:00", "同日班未到点 → 当天 09:00")
        let s3 = startAt("2026-11-05", 23, start: "22:00", end: "06:00")
        assert(s3 != nil && dateKey(s3!) == "2026-11-05" && timeStr(s3!) == "22:00", "跨零点班（22 点后）→ 当天 22:00")
        let s4 = startAt("2026-11-06", 2, start: "22:00", end: "06:00")
        assert(s4 != nil && dateKey(s4!) == "2026-11-05" && timeStr(s4!) == "22:00", "跨零点班（次日凌晨 2 点）→ 前一日 22:00")
        let s5 = startAt("2026-11-05", 12, start: "22:00", end: "06:00")
        assert(s5 != nil && dateKey(s5!) == "2026-11-04" && timeStr(s5!) == "22:00", "跨零点班（白天 12 点）→ 前一晚 22:00")
        assert(shiftStartTime(now: d("2026-11-05"), startStr: "abc", endStr: "18:00") == nil, "非法时间返回 nil")
        // 跨零点前后半夜必须算同一班次（否则会自动打卡两次）
        assert(shiftKey(s3!) == shiftKey(s4!), "跨零点前后半夜班次标识一致")
        print("✅ 班次上班时刻 6 项通过（同日/跨零点/班次标识/非法）")

        // 流水明细日期校验
        assert(isValidDayKey("2026-11-05"))
        assert(isValidDayKey("2024-02-29"), "闰年 2/29 有效")
        assert(!isValidDayKey("2026-02-30"), "2/30 应拒绝")
        assert(!isValidDayKey("2026-13-01"), "13 月应拒绝")
        assert(!isValidDayKey("2026-1-5"), "位数不足应拒绝")
        assert(!isValidDayKey("abc"), "乱串应拒绝")
        print("✅ 日期校验 6 项通过")

        // 吸色：黄底超人图 → 应提取出含黄色的主色对
        if let img = NSImage(contentsOf: URL(fileURLWithPath: "assets/action-kamen.png")),
           let (a, b) = extractPalette(img) {
            func hex(_ c: NSColor) -> String {
                let x = c.usingColorSpace(.sRGB)!
                return String(format: "#%02x%02x%02x", Int(x.redComponent*255), Int(x.greenComponent*255), Int(x.blueComponent*255))
            }
            print("✅ 吸色成功：主1 \(hex(a)) / 主2 \(hex(b))")
        } else {
            print("❌ 吸色失败"); failed += 1
        }

        // MARK: - 2.0 自定义工作日规则
        func check(_ cond: Bool, _ msg: String) { if !cond { print("❌ " + msg); failed += 1 } }
        func ruleDays(_ dateStr: String, _ weekdays: Set<Int>, _ legal: Bool,
                      _ manual: Int? = nil) -> Int {
            monthWorkDays(d(dateStr), rule: WorkdayRule(weekdays: weekdays,
                                                        useLegalHolidays: legal,
                                                        manualDays: manual))
        }
        let wdMonFri: Set<Int> = [2, 3, 4, 5, 6]
        check(ruleDays("2026-11-15", wdMonFri, true) == 21, "默认规则应等于旧口径 21 天")
        check(ruleDays("2026-11-15", wdMonFri, false) == 21, "11 月无节假日，关掉节假日仍 21 天")
        check(ruleDays("2026-10-15", wdMonFri, true) == 18, "叠加国庆+调休应 18 天")
        check(ruleDays("2026-10-15", wdMonFri, false) == 22, "不叠加节假日应 22 天")
        check(ruleDays("2026-11-15", [2, 3, 4, 5, 6, 7], false) == 25, "勾上周六 11 月应 25 天")
        check(ruleDays("2026-11-15", [1, 2, 3, 4, 5, 6, 7], false) == 30, "全周勾选应 30 天")
        check(ruleDays("2026-11-15", [2], false) == 5, "只勾周一应 5 天")
        check(ruleDays("2026-11-15", [], false) == 0, "一个都不勾应 0 天")
        check(ruleDays("2026-11-15", wdMonFri, true, 18) == 18, "手动天数优先级最高")
        check(ruleDays("2026-12-15", wdMonFri, true, 18) == 18, "手动天数跨月仍生效")
        check(monthWorkDays(d("2026-12-03"), rule: .default)
              == monthWorkDays(d("2026-12-28"), rule: .default), "同月任意日期算出的工作日应一致")
        check(isWorkDate(d("2026-11-07"), rule: WorkdayRule(weekdays: [7], useLegalHolidays: false, manualDays: nil)),
              "自定义周六应为工作日")
        check(!isWorkDate(d("2026-11-07"), rule: WorkdayRule(weekdays: [2], useLegalHolidays: false, manualDays: nil)),
              "未勾选的周六不应为工作日")
        check(isWorkDate(d("2026-10-10"), rule: WorkdayRule(weekdays: [2], useLegalHolidays: true, manualDays: nil)),
              "叠加节假日时调休补班应算工作日")
        print("✅ 自定义工作日规则 14 项通过（周几掩码 / 节假日开关 / 手动天数 / 跨月）")

        // MARK: - 2.0 进度口径（可超 100%）
        check(abs(hoursProgress(workedSeconds: 8 * 3600, plannedHours: 8) - 1.0) < 1e-9, "8h/8h = 100%")
        check(abs(hoursProgress(workedSeconds: 12 * 3600, plannedHours: 8) - 1.5) < 1e-9, "8h+4h 加班 = 150%")
        check(hoursProgress(workedSeconds: 0, plannedHours: 8) == 0, "未工作 = 0%")
        check(hoursProgress(workedSeconds: 3600, plannedHours: 0) == 0, "计划工时为 0 兜底")
        check(clampedProgress(1.5) == 1 && clampedProgress(-0.2) == 0, "进度条填充封顶 0...1")
        check(percentText(1.5) == "150.0%", "百分比文案应为 150.0%")
        check(ProgressMetric.allCases.count == 5, "首批应内置 5 种统计内容")
        print("✅ 进度口径 7 项通过（含加班超 100%）")

        // MARK: - 2.1 自定义日期倒计时
        let now = d("2026-11-07")
        let xmas = CountdownItem(name: "圣诞节", month: 12, day: 25, createdKey: "2026-11-07")
        check(xmas.valid && xmas.isYearly, "年度重复项应合法")
        if let p = countdownProgress(xmas, now: now) {
            check(p.daysLeft == 48, "11/7 → 12/25 应剩 48 天，实际 \(p.daysLeft)")
            check(p.targetKey == "2026-12-25", "目标日应为 2026-12-25")
            check(p.ratio > 0 && p.ratio < 1, "年度重复进度应在 0...1 之间")
            check(p.totalDays > p.elapsedDays, "总天数应大于已过天数")
        } else { check(false, "年度重复倒计时计算失败") }

        let once = CountdownItem(name: "新年", month: 1, day: 1, year: 2027,
                                mode: "percent", createdKey: "2026-11-07")
        if let p = countdownProgress(once, now: now) {
            check(p.daysLeft == 55, "11/7 → 2027/1/1 应剩 55 天，实际 \(p.daysLeft)")
            check(p.ratio == 0 && p.elapsedDays == 0, "创建当天完成度应为 0")
            check(p.totalDays == 55, "一次性目标分母应为起点→目标天数")
        } else { check(false, "一次性倒计时计算失败") }

        let past = CountdownItem(name: "已过", month: 1, day: 1, year: 2026, createdKey: "2025-12-01")
        if let p = countdownProgress(past, now: now) {
            check(p.expired && p.daysLeft == 0 && p.ratio == 1, "过期目标应标记 expired 且进度 100%")
        } else { check(false, "过期倒计时不应返回 nil") }

        let todayItem = CountdownItem(name: "今天", month: 11, day: 7, createdKey: "2026-11-07")
        if let p = countdownProgress(todayItem, now: now) {
            check(p.daysLeft == 0 && p.targetKey == "2026-11-07", "目标日就是今天应剩 0 天")
        } else { check(false, "当天目标计算失败") }

        check(!CountdownItem(name: "非法", month: 13, day: 1, createdKey: "2026-11-07").valid,
              "13 月应判非法")
        check(CountdownItem(name: "闰日", month: 2, day: 29, createdKey: "2026-11-07").valid,
              "2/29 应合法（非闰年顺延）")
        print("✅ 自定义日期倒计时 11 项通过（年度重复 / 一次性 / 过期 / 当天 / 非法）")

        // MARK: - 2.4 倒计时自定义起止时间 + 纪念日累计时长
        var timed = CountdownItem(name: "上线", month: 12, day: 1, year: 2026, createdKey: "2026-11-01")
        timed.startYear = 2026; timed.startMonth = 11; timed.startDay = 1
        timed.targetHour = 20; timed.targetMinute = 0
        check(timed.hasCustomStart && timed.hasCustomTime, "自定义起始日 / 目标时刻应生效")
        if let p = countdownProgress(timed, now: d("2026-11-16")) {
            check(p.targetKey == "2026-12-01", "带时刻的目标日仍为 2026-12-01")
            check(p.totalDays == 30, "起点 11/1 → 目标 12/1 总跨度 30 天，实际 \(p.totalDays)")
            check(p.ratio > 0.48 && p.ratio < 0.50, "按秒算的进度应≈49%，实际 \(p.ratio)")
        } else { check(false, "带时间倒计时计算失败") }
        check(countdownRangeError(timed) == nil, "起始早于目标应通过校验")
        var badRange = timed
        badRange.startYear = 2026; badRange.startMonth = 12; badRange.startDay = 2
        check(countdownRangeError(badRange) != nil, "起始晚于目标应报错")
        check(!CountdownItem(name: "错时", month: 1, day: 1, targetHour: 25).valid, "25 时应判非法")

        let span = elapsedSpan(from: d("2024-05-20"), to: d("2026-11-07"))
        check(span.years == 2 && span.months == 5 && span.days == 18,
              "2024/5/20 → 2026/11/7 应为 2 年 5 个月 18 天，实际 \(span.shortText)")
        check(span.totalDays == calendarDays(from: d("2024-05-20"), to: d("2026-11-07")),
              "累计总天数应与自然日差一致")
        if let r = recordDayProgress(RecordDayItem(name: "在一起", year: 2024, month: 5, day: 20),
                                     now: d("2026-11-07")) {
            check(r.span.years == 2 && r.span.months == 5 && r.span.days == 18,
                  "纪念日进度应带累计时长，实际 \(r.span.shortText)")
        } else { check(false, "纪念日累计时长计算失败") }
        print("✅ 2.4 倒计时起止时间 + 纪念日累计时长 8 项通过")

        // MARK: - 2.1 记录日 / 纪念日
        let rd1 = RecordDayItem(name: "在一起", year: 2026, month: 10, day: 1)
        check(rd1.valid && rd1.milestoneStep == 100, "合法记录日 + 默认百天里程碑")
        if let r = recordDayProgress(rd1, now: d("2026-11-07")) {
            check(r.elapsedDays == 37, "10/1 → 11/7 应累计 37 天，实际 \(r.elapsedDays)")
            check(r.startKey == "2026-10-01", "起始日期键应为 2026-10-01")
            check(r.milestoneDone == 37 && r.daysToMilestone == 63, "百天里程碑内应走 37/100")
            check(abs(r.ratio - 0.37) < 1e-9, "里程碑进度应为 37%")
            check(r.milestoneIndex == 0 && r.started, "第一个里程碑且已开始")
        } else { check(false, "记录日计算失败") }

        let rd2 = RecordDayItem(name: "入职", year: 2026, month: 1, day: 1, targetDays: 50)
        if let r = recordDayProgress(rd2, now: d("2026-11-07")) {
            check(r.milestoneStep == 50 && r.elapsedDays == 310, "自定义 50 天目标 / 累计 310 天")
            check(r.milestoneDone == 10 && r.daysToMilestone == 40, "310 天应落在第 7 个里程碑的第 10 天")
            check(r.milestoneIndex == 6, "已完成 6 个里程碑")
        } else { check(false, "自定义目标记录日计算失败") }

        let rd3 = RecordDayItem(name: "百天", year: 2026, month: 7, day: 30)
        if let r = recordDayProgress(rd3, now: d("2026-11-07")) {
            check(r.elapsedDays == 100 && r.milestoneDone == 100 && r.daysToMilestone == 0,
                  "正好第 100 天应显示 100% / 还差 0 天")
            check(r.ratio == 1, "里程碑当天进度应为 100%")
        } else { check(false, "里程碑当天计算失败") }

        let future = RecordDayItem(name: "未来", year: 2027, month: 1, day: 1)
        if let r = recordDayProgress(future, now: d("2026-11-07")) {
            check(!r.started && r.elapsedDays == 0, "未来起始日应标记未开始且累计 0 天")
        } else { check(false, "未来记录日不应返回 nil") }

        check(!RecordDayItem(name: "非法", year: 1960, month: 1, day: 1).valid, "1960 年应判非法")
        check(!RecordDayItem(name: "非法", year: 2026, month: 13, day: 1).valid, "13 月应判非法")
        check(!RecordDayItem(name: "非法", year: 2026, month: 1, day: 1, targetDays: -1).valid,
              "负目标天数应判非法")
        check(recordDayProgress(RecordDayItem(name: "非法", year: 2026, month: 2, day: 31)) == nil,
              "非法日期应返回 nil")
        print("✅ 记录日 12 项通过（累计天数 / 自定义目标 / 里程碑当天 / 未来日期 / 非法）")

        if failed == 0 {
            print("\n=== ALL TESTS PASSED ===")
        } else {
            print("\n=== \(failed) TESTS FAILED ===")
            exit(1)
        }
    }
}
