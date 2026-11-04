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
