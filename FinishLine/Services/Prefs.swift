import Foundation
import Security

/// Settings keys shared by @AppStorage in the views and by the services.
enum Prefs {
    static let userName = "userName"            // String, default "Edison"
    static let githubOwner = "githubOwner"      // String, default "Epsilonmuz"
    static let stopHour = "stopHour"            // Int, default 0 (midnight)
    static let stopMinute = "stopMinute"        // Int, default 0
    static let wrapUpEnabled = "wrapUpEnabled"  // Bool, default true
    static let breakMinutes = "breakMinutes"    // Int, default 90
    static let lastRitual = "lastRitual"        // Double (timeIntervalSince1970)
    static let lastSnooze = "lastSnooze"        // Double
    static let lastPromotion = "lastPromotion"  // Double
    static let sessionStart = "sessionStart"    // Double, 0 = no session
    static let alarmStatus = "alarmStatus"      // String, human-readable

    static let d = UserDefaults.standard

    static var name: String {
        let n = d.string(forKey: userName) ?? ""
        return n.isEmpty ? "Edison" : n
    }
    static var owner: String {
        let o = d.string(forKey: githubOwner) ?? ""
        return o.isEmpty ? "Epsilonmuz" : o
    }
    static var hour: Int { d.object(forKey: stopHour) as? Int ?? 0 }
    static var minute: Int { d.object(forKey: stopMinute) as? Int ?? 0 }
    static var wrapUp: Bool { d.object(forKey: wrapUpEnabled) as? Bool ?? true }
    static var breakMins: Int { d.object(forKey: breakMinutes) as? Int ?? 90 }

    static func date(_ key: String) -> Date? {
        let t = d.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    static func setDate(_ key: String, _ date: Date?) {
        d.set(date?.timeIntervalSince1970 ?? 0, forKey: key)
    }
}

/// Minimal Keychain wrapper for the GitHub token.
enum KeychainStore {
    private static let service = "com.epsilonmuz.finishline"

    static func save(_ value: String, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// When is tonight's hard stop, and are we inside the stop window right now?
enum StopClock {
    /// Hours after the stop time during which opening the app shows the STOP screen.
    static let windowHours: Double = 4

    static func stop(onDayOf day: Date) -> Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: Prefs.hour, minute: Prefs.minute, second: 0, of: day) ?? day
    }

    /// Start of the stop window we're currently in, if any.
    static func currentWindowStart(now: Date = .now) -> Date? {
        let cal = Calendar.current
        for offset in [0, -1] {
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            let s = stop(onDayOf: day)
            if now >= s && now < s.addingTimeInterval(windowHours * 3600) { return s }
        }
        return nil
    }

    /// The next `count` stop times after `now`.
    static func upcoming(_ count: Int, from now: Date = .now) -> [Date] {
        let cal = Calendar.current
        var out: [Date] = []
        var offset = 0
        while out.count < count && offset < count + 2 {
            if let day = cal.date(byAdding: .day, value: offset, to: now) {
                let s = stop(onDayOf: day)
                if s > now { out.append(s) }
            }
            offset += 1
        }
        return out
    }

    static var nextStop: Date? { upcoming(1).first }

    /// True when we're past the stop time and the shutdown ritual isn't done yet.
    static var mustStopNow: Bool {
        guard let start = currentWindowStart() else { return false }
        if let ritual = Prefs.date(Prefs.lastRitual), ritual >= start { return false }
        // During tonight's one snooze, leave the screen alone until it runs out.
        if let s = Prefs.date(Prefs.lastSnooze), s >= start, Date.now < s.addingTimeInterval(15 * 60) { return false }
        return true
    }

    static var snoozeUsedTonight: Bool {
        guard let start = currentWindowStart(), let s = Prefs.date(Prefs.lastSnooze) else { return false }
        return s >= start
    }

    static func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
