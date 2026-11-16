import SwiftUI
import SwiftData

/// "What should I do right now?" Give three cues, get one task.
struct NowView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var router: AppRouter
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query(filter: #Predicate<Idea> { !$0.archived && $0.promotedAt == nil }) private var ideas: [Idea]

    @AppStorage("cueMinutes") private var minutes = 60
    @AppStorage("cueEnergy") private var energyRaw = 2
    @AppStorage("cueAtDesk") private var atDesk = true
    @AppStorage(Prefs.sessionStart) private var sessionStart: Double = 0
    @AppStorage(Prefs.breakMinutes) private var breakMinutes = 90

    @State private var skipped: Set<String> = []
    @State private var doneNote = ""
    @State private var showDone = false
    @State private var copied = false

    private var cues: Cues {
        Cues(minutes: minutes, energy: Difficulty(rawValue: energyRaw) ?? .medium, atDesk: atDesk)
    }

    private var ranked: [Suggestion] {
        Prioritizer.rank(projects: projects, ideaCount: ideas.count, cues: cues)
    }

    /// The best suggestion you haven't skipped yet.
    private var current: Suggestion? {
        ranked.first { !skipped.contains(key($0)) } ?? ranked.first
    }

    private func key(_ s: Suggestion) -> String { "\(s.kind.rawValue)-\(s.project?.name ?? "")" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stopBanner
                    cueCard
                    if let s = current { suggestionCard(s) }
                    sessionCard
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("Now")
            .refreshable { await CIRefresher.refresh(projects) }
            .sheet(isPresented: $showDone) { doneSheet }
        }
    }

    // MARK: Pieces

    private var stopBanner: some View {
        HStack {
            Image(systemName: "moon.zzz.fill").foregroundStyle(Theme.stop)
            if let next = StopClock.nextStop {
                Text("Hard stop at \(StopClock.timeString(next))")
                Spacer()
                Text(next, style: .relative).foregroundStyle(Theme.dim)
            }
        }
        .font(.subheadline.weight(.medium))
    }

    private var cueCard: some View {
        Card {
            SectionLabel(text: "Your cues")
            Picker("Time", selection: $minutes) {
                Text("15 min").tag(15)
                Text("1 hour").tag(60)
                Text("2+ hours").tag(150)
            }
            .pickerStyle(.segmented)
            Picker("Energy", selection: $energyRaw) {
                Text("Low").tag(1)
                Text("Medium").tag(2)
                Text("High").tag(3)
            }
            .pickerStyle(.segmented)
            Picker("Place", selection: $atDesk) {
                Text("At the Mac").tag(true)
                Text("Away").tag(false)
            }
            .pickerStyle(.segmented)
        }
        .onChange(of: minutes) { _, _ in skipped.removeAll() }
        .onChange(of: energyRaw) { _, _ in skipped.removeAll() }
        .onChange(of: atDesk) { _, _ in skipped.removeAll() }
    }

    private func suggestionCard(_ s: Suggestion) -> some View {
        Card {
            SectionLabel(text: "Do this now")
            Text(s.title)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            if !s.detail.isEmpty, s.detail != s.title {
                Text(s.detail).foregroundStyle(Theme.dim)
            }
            if !s.reason.isEmpty {
                Label(s.reason, systemImage: "sparkle")
                    .font(.footnote)
                    .foregroundStyle(Theme.gold)
            }
            if let p = s.project { LadderView(milestone: p.milestone).padding(.top, 4) }

            HStack(spacing: 10) {
                switch s.kind {
                case .reviewIdeas:
                    Button("Open Vault") { router.tab = .ideas }
                        .buttonStyle(.borderedProminent)
                case .writeStep, .nothing:
                    Button(s.kind == .nothing ? "Projects" : "Write step") { router.tab = .projects }
                        .buttonStyle(.borderedProminent)
                default:
                    Button("Done") { showDone = true }
                        .buttonStyle(.borderedProminent)
                }
                if s.kind != .nothing {
                    Button("Skip") {
                        Prioritizer.learn(from: s, done: false)
                        skipped.insert(key(s))
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                if let p = s.project {
                    Menu {
                        Button("Open in Claude Code") {
                            ClaudeLink.copy(for: p)
                            if let url = ClaudeLink.url(for: p) { openURL(url) }
                        }
                        Button("Copy prompt") { ClaudeLink.copy(for: p); copied = true }
                    } label: {
                        Label("Ask Claude", systemImage: "wand.and.stars")
                    }
                }
            }
            .padding(.top, 6)
            if copied { Text("Prompt copied").font(.caption).foregroundStyle(Theme.dim) }
        }
    }

    private var sessionCard: some View {
        Card {
            SectionLabel(text: "Work session")
            if sessionStart > 0 {
                let start = Date(timeIntervalSince1970: sessionStart)
                HStack {
                    Text("Working for")
                    Text(start, style: .timer).monospacedDigit().foregroundStyle(Theme.gold)
                }
                Text("Break reminder at \(breakMinutes) min.").font(.footnote).foregroundStyle(Theme.dim)
                Button("End session") {
                    sessionStart = 0
                    NotificationScheduler.cancelBreak()
                }
                .buttonStyle(.bordered)
            } else {
                Text("Start a session to get a break reminder after \(breakMinutes) minutes.")
                    .font(.footnote).foregroundStyle(Theme.dim)
                Button("Start session") {
                    sessionStart = Date.now.timeIntervalSince1970
                    Task { await NotificationScheduler.scheduleBreak(minutes: breakMinutes) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var doneSheet: some View {
        NavigationStack {
            Form {
                Section("What did you get done? (one line)") {
                    TextField("e.g. fixed the preset crash", text: $doneNote)
                }
                Section {
                    Text("Writing it yourself matters: progress you record counts for more than progress tracked for you.")
                        .font(.footnote).foregroundStyle(Theme.dim)
                }
            }
            .navigationTitle("Nice.")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showDone = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let s = current, let p = s.project {
                            p.log(doneNote.isEmpty ? s.title : doneNote)
                            if s.kind == .nextStep { p.nextThen = ""; p.nextIf = "" }
                            Prioritizer.learn(from: s, done: true)
                        }
                        doneNote = ""
                        showDone = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
