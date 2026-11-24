import Foundation

public enum ScheduleCalendar {
    public static func validate(_ trigger: ScheduleTrigger) throws {
        switch trigger {
        case .interval(let seconds):
            guard seconds.isFinite, seconds >= 1, seconds <= 366 * 86_400 else { throw ScheduleError.invalidTrigger }
        case .daily(let hour, let minute, let zone):
            guard (0...23).contains(hour), (0...59).contains(minute), zone.utf8.count <= 100,
                  TimeZone(identifier: zone) != nil else { throw ScheduleError.invalidTrigger }
        }
    }
    /// interval锚定原计划点；漏过多个周期只产生一个claim，下一点推进到now之后。
    /// daily按显式时区：DST缺失时间取下一个有效时间，重复时间只取当天第一次。
    public static func nextFire(for trigger: ScheduleTrigger, after now: Date, anchor: Date? = nil) throws -> Date {
        try validate(trigger)
        guard valid(now), anchor.map(valid) != false else { throw ScheduleError.invalidClock }
        switch trigger {
        case .interval(let interval):
            let base = anchor ?? now
            let elapsed = max(0, now.timeIntervalSince(base))
            let periods = floor(elapsed / interval) + 1
            let next = base.addingTimeInterval(periods * interval)
            guard valid(next), next > now, next > base else { throw ScheduleError.invalidClock }
            return next
        case .daily(let hour, let minute, let timeZoneID):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneID)!
            let baseline = max(now, anchor ?? now)
            let day = calendar.startOfDay(for: baseline)
            for offset in 0..<4 {
                guard let date = calendar.date(byAdding: .day, value: offset, to: day),
                      let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date,
                        matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) else { continue }
                if fire > baseline, calendar.isDate(fire, inSameDayAs: date), valid(fire) { return fire }
            }
            throw ScheduleError.invalidClock
        }
    }
    static func valid(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= -62_135_596_800 && seconds <= 253_402_300_799
    }
}
