import SwiftUI
import UIKit
import SwiftData
import UserNotifications
import AppIntents

@main
struct FinishLineApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var router = AppRouter.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
        }
        .modelContainer(for: [Project.self, ProgressLog.self, Idea.self, EventLog.self])
    }
}

@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum Tab: Hashable { case now, projects, ideas, settings }

    @Published var tab: Tab = .now
    @Published var pendingCapture = false
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Show banners and play sounds even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        await MainActor.run {
            if id.hasPrefix("review") { AppRouter.shared.tab = .ideas }
            else { AppRouter.shared.tab = .now }
        }
    }
}

// MARK: - Quick capture from Siri, Shortcuts, the Action button or Lock Screen

struct CaptureIdeaIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Idea"
    static let description = IntentDescription("Park a new idea in the Finish Line Idea Vault without starting it.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.tab = .ideas
        AppRouter.shared.pendingCapture = true
        return .result()
    }
}

struct FinishLineShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureIdeaIntent(),
            phrases: [
                "Capture an idea in \(.applicationName)",
                "Park an idea in \(.applicationName)",
            ],
            shortTitle: "Capture Idea",
            systemImageName: "lightbulb")
    }
}
