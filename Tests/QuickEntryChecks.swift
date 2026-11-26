import Foundation

@main
enum QuickEntryChecks {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 10))!

        func expect(_ input: String, title: String, day: Int, month: Int = 11, year: Int = 2026,
                    hour: Int? = nil, minute: Int = 0) {
            let parsed = QuickEntryParser.parse(input, now: now, calendar: calendar)
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                           hour: hour ?? 0, minute: minute))!
            precondition(parsed == .init(title: title, date: date, hasTime: hour != nil), input)
        }

        expect("明天下午 3 点给客户回电话", title: "给客户回电话", day: 27, hour: 15)
        expect("后天早上七点半 取车", title: "取车", day: 28, hour: 7, minute: 30)
        expect("今天 14:05，提交材料", title: "提交材料", day: 26, hour: 14, minute: 5)
        expect("下周一 开会", title: "开会", day: 30)
        expect("12月3日 交报告", title: "交报告", day: 3, month: 12)
        expect("2月29日 提交", title: "提交", day: 29, month: 2, year: 2028)
        expect("2026-11-27 0:00 开始", title: "开始", day: 27, hour: 0)
        for invalid in ["整理行李", "明天", "明天下午三点", "明天 25点 见面", "今天 18:70 离开", "2026-02-30 看书"] {
            precondition(QuickEntryParser.parse(invalid, now: now, calendar: calendar) == nil, invalid)
        }
        print("Quick entry checks passed")
    }
}
