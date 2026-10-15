import Foundation

struct DailyReminderScheduleState: Equatable {
    let times: [DailyReminderTime]
    let skippedDay: Date?
    let timeZoneIdentifier: String
}
