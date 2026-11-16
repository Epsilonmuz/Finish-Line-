import SwiftUI
import SwiftData
import UIKit

/// Full-screen takeover after the hard stop. You can only leave it by doing
/// the 2-minute shutdown ritual, or by using tonight's single snooze.
struct StopScreenView: View {
    @Binding var isPresented: Bool
    @Environment(\.modelContext) private var context
    @State private var showRitual = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                Text("STOP")
                    .font(.system(size: 104, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.stop)
                    .scaleEffect(pulse ? 1.04 : 0.96)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                Text("\(Prefs.name), done for today.")
                    .font(.title2.weight(.semibold))
                if let start = StopClock.currentWindowStart() {
                    Text("You chose to stop at \(StopClock.timeString(start)).")
                        .foregroundStyle(Theme.dim)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Save and close the project on your Mac", systemImage: "laptopcomputer")
                    Label("Write tomorrow's first step (2 min)", systemImage: "pencil.line")
                    Label("Headphones off", systemImage: "headphones")
                }
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 8)
                Spacer()
                Button {
                    showRitual = true
                } label: {
                    Text("Start shutdown")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Theme.stop, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
                Button(StopClock.snoozeUsedTonight ? "No snooze left tonight" : "Snooze 15 min (1 left, logged)") {
                    Task {
                        await HardStopScheduler.snooze()
                        context.insert(EventLog(kind: "snooze", detail: "Snoozed hard stop 15 min"))
                        isPresented = false
                    }
                }
                .disabled(StopClock.snoozeUsedTonight)
                .foregroundStyle(Theme.dim)
            }
            .padding(28)
        }
        .interactiveDismissDisabled()
        .onAppear {
            pulse = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        .sheet(isPresented: $showRitual) {
            ShutdownRitualView { isPresented = false }
                .interactiveDismissDisabled()
        }
    }
}

/// Write tomorrow's if-then step, log what you did, then you're released.
struct ShutdownRitualView: View {
    var onFinish: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.createdAt) private var projects: [Project]

    @State private var selected: Project?
    @State private var cue = ""
    @State private var action = ""
    @State private var didToday = ""

    private var active: [Project] { projects.filter { $0.state == .active } }

    var body: some View {
        NavigationStack {
            Form {
                if !active.isEmpty {
                    Section("Tomorrow, first thing") {
                        Picker("Project", selection: $selected) {
                            ForEach(active) { p in Text(p.name).tag(Project?.some(p)) }
                        }
                        TextField("When… (e.g. I open Xcode after lunch)", text: $cue, axis: .vertical)
                        TextField("…I will (one action)", text: $action, axis: .vertical)
                    }
                }
                Section("Today, in one line (optional)") {
                    TextField("What got done", text: $didToday)
                }
                Section {
                    Text("Stopping with a clear next step makes tomorrow's start easy, and lets tonight's work go.")
                        .font(.footnote).foregroundStyle(Theme.dim)
                }
            }
            .navigationTitle("Shutdown")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done for today") { finish() }
                        .disabled(!active.isEmpty && action.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { if selected == nil { selected = active.first } }
        }
    }

    private func finish() {
        if let p = selected {
            if !action.isEmpty {
                p.nextIf = cue
                p.nextThen = action
            }
            if !didToday.isEmpty { p.log(didToday) }
        }
        Prefs.setDate(Prefs.lastRitual, .now)
        Prefs.d.set(0.0, forKey: Prefs.sessionStart)
        NotificationScheduler.cancelBreak()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
        onFinish()
    }
}
