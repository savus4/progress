import Foundation

struct DailyReminderTimelineSchedule: Equatable {
    let timelineID: UUID
    let times: [DailyReminderTime]
    let skippedDay: Date?
    var name: String? = nil
}

struct DailyReminderScheduleState: Equatable {
    let timelines: [DailyReminderTimelineSchedule]
    let timeZoneIdentifier: String
}
