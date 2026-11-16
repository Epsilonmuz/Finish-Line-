import SwiftUI
import SwiftData

struct ProjectDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Bindable var project: Project

    @State private var confirmRung: Milestone?
    @State private var logNote = ""
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                LadderView(milestone: project.milestone)
                if let next = project.milestone.next {
                    if next == .buildsGreen {
                        Text("Moves up automatically when every CI check is green.")
                            .font(.footnote).foregroundStyle(Theme.dim)
                        Button("Mark \"\(next.title)\" myself") { confirmRung = next }
                    } else {
                        Button("I confirm: \(next.title)") { confirmRung = next }
                    }
                } else {
                    Label("Shipped and used for real.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.gold)
                }
            } header: { Text("Progress") }

            Section {
                TextField("When… (cue: time, place)", text: $project.nextIf, axis: .vertical)
                TextField("…I will (one concrete action)", text: $project.nextThen, axis: .vertical)
                Stepper("About \(project.nextMinutes) min", value: $project.nextMinutes, in: 5...240, step: 5)
                Picker("Difficulty", selection: $project.nextDifficultyRaw) {
                    ForEach(Difficulty.allCases) { d in Text(d.label).tag(d.rawValue) }
                }
                Toggle("Needs the Mac", isOn: $project.nextNeedsMac)
            } header: {
                Text("Next step (if-then)")
            } footer: {
                Text("Example: When I open Xcode after dinner, I will fix the preset crash.")
            }

            Section("Log progress") {
                HStack {
                    TextField("What did you do?", text: $logNote)
                    Button("Log") {
                        project.log(logNote)
                        logNote = ""
                    }
                    .disabled(logNote.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                if project.hasRepo {
                    Text("\(project.repoOwner)/\(project.repoName)").font(.footnote.monospaced())
                    if !project.ciSummary.isEmpty { Text(project.ciSummary) }
                    if !project.ciDetail.isEmpty { Text(project.ciDetail).font(.footnote) }
                    if let url = URL(string: project.ciURL), !project.ciURL.isEmpty {
                        Button("Open latest run on GitHub") { openURL(url) }
                    }
                    Button("Refresh CI") { Task { await CIRefresher.refresh([project]) } }
                } else {
                    TextField("Owner", text: $project.repoOwner).textInputAutocapitalization(.never)
                    TextField("Repo", text: $project.repoName).textInputAutocapitalization(.never)
                }
            } header: { Text("GitHub CI") }

            Section("Ask Claude") {
                Button("Open in Claude Code with the next step") {
                    ClaudeLink.copy(for: project)
                    if let url = ClaudeLink.url(for: project) { openURL(url) }
                }
                Button("Copy prompt") { ClaudeLink.copy(for: project) }
            }

            if !project.whyThisOne.isEmpty || !project.notes.isEmpty {
                Section("Why / notes") {
                    if !project.whyThisOne.isEmpty { Text(project.whyThisOne) }
                    if !project.notes.isEmpty { Text(project.notes).font(.footnote) }
                }
            }

            Section("History") {
                ForEach(project.sortedLogs.prefix(30)) { log in
                    VStack(alignment: .leading) {
                        Text(log.note)
                        Text(log.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(Theme.dim)
                    }
                }
            }

            Section {
                if project.state == .active {
                    Button("Freeze this project") {
                        project.state = .frozen
                        project.log("Frozen")
                        context.insert(EventLog(kind: "freeze", detail: project.name))
                    }
                }
                Button("Delete project", role: .destructive) { confirmDelete = true }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(project.name)
        .confirmationDialog("Move up the ladder?", isPresented: Binding(
            get: { confirmRung != nil }, set: { if !$0 { confirmRung = nil } }
        ), presenting: confirmRung) { rung in
            Button("Yes: \(rung.title)") { advance(to: rung) }
        } message: { rung in
            Text(rung == .usedInSession ? "Only if you really used it in a session, without lag." : "Confirm \(rung.title).")
        }
        .confirmationDialog("Delete \(project.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                let doomed = project
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { context.delete(doomed) }
            }
        }
    }

    private func advance(to rung: Milestone) {
        project.milestone = rung
        project.log("Reached \"\(rung.title)\"")
        if rung == .usedInSession {
            project.state = .shipped
            context.insert(EventLog(kind: "ship", detail: project.name))
        }
    }
}
