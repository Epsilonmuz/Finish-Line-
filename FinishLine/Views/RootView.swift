import SwiftUI
import SwiftData

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @Query private var projects: [Project]
    @State private var showStop = false
    @State private var didSetUp = false

    private let ticker = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $router.tab) {
            NowView()
                .tabItem { Label("Now", systemImage: "scope") }
                .tag(AppRouter.Tab.now)
            ProjectsView()
                .tabItem { Label("Projects", systemImage: "flag.checkered") }
                .tag(AppRouter.Tab.projects)
            IdeaVaultView()
                .tabItem { Label("Vault", systemImage: "lightbulb") }
                .tag(AppRouter.Tab.ideas)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppRouter.Tab.settings)
        }
        .fullScreenCover(isPresented: $showStop) {
            StopScreenView(isPresented: $showStop)
        }
        .task {
            guard !didSetUp else { return }
            didSetUp = true
            await firstSetUp()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            checkStop()
            Task {
                await HardStopScheduler.rescheduleAll()
                await CIRefresher.refresh(projects)
            }
        }
        .onReceive(ticker) { _ in checkStop() }
    }

    private func checkStop() {
        if StopClock.mustStopNow && !showStop { showStop = true }
    }

    private func firstSetUp() async {
        SoundLibrary.prepareAll()
        await NotificationScheduler.requestAuthorization()
        if HardStopScheduler.authState == .notDetermined {
            await HardStopScheduler.requestAuthorization()
        }
        await HardStopScheduler.rescheduleAll()
        await CIRefresher.refresh(projects)
        checkStop()
    }
}
