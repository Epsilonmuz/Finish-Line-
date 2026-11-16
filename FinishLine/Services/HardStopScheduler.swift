import Foundation
import SwiftUI
import AlarmKit
import ActivityKit
import UserNotifications

struct StopMetadata: AlarmMetadata {}

/// The hard stop. Uses AlarmKit (breaks through Silent mode and Focus) when
/// you allow it, otherwise falls back to a regular notification with the
/// same sound. Schedules the next 7 nights, each with a different variant.
@MainActor
enum HardStopScheduler {
    private static let idsKey = "alarmKitIDs"
    static let nightsAhead = 7

    static var authState: AlarmManager.AuthorizationState { AlarmManager.shared.authorizationState }

    static var statusText: String {
        switch authState {
        case .authorized: return "Loud alarm on. Breaks through Silent and Focus."
        case .denied: return "Alarms not allowed, using notifications (quieter, respect Silent). Turn on in Settings › Finish Line."
        case .notDetermined: return "Tap \"Allow loud alarm\" to let the hard stop break through Silent mode."
        @unknown default: return "Alarm status unknown"
        }
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            let state = try await AlarmManager.shared.requestAuthorization()
            return state == .authorized
        } catch {
            return false
        }
    }

    private static var running = false
    private static var runAgain = false

    /// Rebuild every scheduled stop, wrap-up and review reminder.
    /// Guarded so overlapping calls never leave duplicate alarms behind.
    static func rescheduleAll() async {
        if running { runAgain = true; return }
        running = true
        repeat {
            runAgain = false
            await reschedule()
        } while runAgain
        running = false
    }

    private static func reschedule() async {
        cancelAlarms()
        await NotificationScheduler.clear(prefixes: ["stop-", "wrapup-"])

        let stops = StopClock.upcoming(nightsAhead)
        var usedAlarmKit = false

        if authState == .authorized {
            var ids: [String] = []
            for date in stops {
                if let id = try? await schedule(at: date, sound: SoundLibrary.variant(for: date)) {
                    ids.append(id.uuidString)
                    usedAlarmKit = true
                }
            }
            UserDefaults.standard.set(ids, forKey: idsKey)
        }

        if !usedAlarmKit {
            for date in stops {
                await NotificationScheduler.add(
                    id: "stop-\(Int(date.timeIntervalSince1970))",
                    title: "STOP. \(Prefs.name), done for today.",
                    body: "Open Finish Line, write tomorrow's step, close the session.",
                    sound: SoundLibrary.variant(for: date),
                    at: date)
            }
        }

        if Prefs.wrapUp {
            for date in stops {
                let warn = date.addingTimeInterval(-30 * 60)
                guard warn > .now else { continue }
                await NotificationScheduler.add(
                    id: "wrapup-\(Int(date.timeIntervalSince1970))",
                    title: "30 minutes to hard stop",
                    body: "Finish the step you're on. Don't start a new one.",
                    sound: SoundLibrary.wrapUp,
                    at: warn)
            }
        }
        await NotificationScheduler.scheduleWeeklyReview()

        // Keep a pending snooze alive across reschedules.
        if let snoozedAt = Prefs.date(Prefs.lastSnooze) {
            let due = snoozedAt.addingTimeInterval(15 * 60)
            if due > .now { await scheduleSnooze(at: due) }
        }

        Prefs.d.set(usedAlarmKit ? "AlarmKit: \(stops.count) nights scheduled" : "Notifications: \(stops.count) nights scheduled",
                    forKey: Prefs.alarmStatus)
    }

    /// The one allowed snooze: 15 minutes, a different sound, logged by the caller.
    static func snooze(minutes: Int = 15) async {
        Prefs.setDate(Prefs.lastSnooze, .now)
        await scheduleSnooze(at: Date.now.addingTimeInterval(Double(minutes) * 60))
    }

    private static func scheduleSnooze(at date: Date) async {
        if authState == .authorized, let id = try? await schedule(at: date, sound: SoundLibrary.snooze) {
            var ids = UserDefaults.standard.stringArray(forKey: idsKey) ?? []
            ids.append(id.uuidString)
            UserDefaults.standard.set(ids, forKey: idsKey)
        } else {
            await NotificationScheduler.add(id: "stop-snooze", title: "Snooze is over. STOP.",
                                            body: "No more snoozes tonight.", sound: SoundLibrary.snooze, at: date)
        }
    }

    /// Fires a test alarm one minute from now.
    static func test() async -> String {
        let date = Date.now.addingTimeInterval(60)
        let sound = SoundLibrary.variant(for: StopClock.nextStop ?? .now)
        if authState == .authorized {
            do {
                _ = try await schedule(at: date, sound: sound, title: "Test: hard stop")
                return "Test alarm in 1 minute. Lock your phone and wait."
            } catch {
                return "AlarmKit error: \(error.localizedDescription). Falling back to a notification."
            }
        }
        await NotificationScheduler.add(id: "stop-test", title: "Test: hard stop", body: "This is how the fallback sounds.",
                                        sound: sound, at: date)
        return "Test notification in 1 minute (loud alarm not allowed yet)."
    }

    private static func schedule(at date: Date, sound: String, title: String? = nil) async throws -> UUID {
        let id = UUID()
        let titleText = title ?? "STOP. \(Prefs.name), done for today."
        let stopButton = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: titleText), stopButton: stopButton)
        let attributes = AlarmAttributes<StopMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: StopMetadata(),
            tintColor: Color.red)
        let config = AlarmManager.AlarmConfiguration(
            countdownDuration: nil,
            schedule: .fixed(date),
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: nil,
            sound: .named(SoundLibrary.fileName(sound)))
        _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
        return id
    }

    private static func cancelAlarms() {
        // Cancel everything this app has scheduled, including alarms whose IDs we lost.
        if let all = try? AlarmManager.shared.alarms {
            for alarm in all { try? AlarmManager.shared.cancel(id: alarm.id) }
        }
        let ids = UserDefaults.standard.stringArray(forKey: idsKey) ?? []
        for s in ids {
            if let id = UUID(uuidString: s) { try? AlarmManager.shared.cancel(id: id) }
        }
        UserDefaults.standard.set([String](), forKey: idsKey)
    }
}

/// Wrap-up warnings, break reminders, weekly review, and the alarm fallback.
enum NotificationScheduler {
    static let center = UNUserNotificationCenter.current()

    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func add(id: String, title: String, body: String, sound: String, at date: Date) async {
        guard date > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: SoundLibrary.fileName(sound)))
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func clear(prefixes: [String]) async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { id in prefixes.contains { id.hasPrefix($0) } }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Sunday 11:00: review the Idea Vault, promote at most one.
    static func scheduleWeeklyReview() async {
        center.removePendingNotificationRequests(withIdentifiers: ["review-weekly"])
        let content = UNMutableNotificationContent()
        content.title = "Weekly review"
        content.body = "Open the Idea Vault. Promote at most one idea, or none."
        content.sound = .default
        var comps = DateComponents()
        comps.weekday = 1
        comps.hour = 11
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: "review-weekly", content: content, trigger: trigger))
    }

    /// Break reminder after a long stretch of work.
    static func scheduleBreak(minutes: Int) async {
        center.removePendingNotificationRequests(withIdentifiers: ["break"])
        let content = UNMutableNotificationContent()
        content.title = "\(minutes) minutes in. Take a 10-minute break."
        content.body = "Stand up, look far away, drink water. Short breaks reliably cut fatigue."
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: SoundLibrary.fileName(SoundLibrary.wrapUp)))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Double(minutes) * 60, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: "break", content: content, trigger: trigger))
    }

    static func cancelBreak() {
        center.removePendingNotificationRequests(withIdentifiers: ["break"])
    }
}
