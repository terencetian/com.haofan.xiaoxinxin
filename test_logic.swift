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

        if failed == 0 {
            print("\n=== ALL TESTS PASSED ===")
        } else {
            print("\n=== \(failed) TESTS FAILED ===")
            exit(1)
        }
    }
}
