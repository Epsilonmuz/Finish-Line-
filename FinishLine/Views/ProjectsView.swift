import SwiftUI
import SwiftData

/// Two active slots. Everything else is frozen until a slot frees up.
struct ProjectsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Project.createdAt) private var projects: [Project]

    @State private var showAdd = false
    @State private var activating: Project?
    @State private var refreshError: String?

    static let maxActive = 2

    private var active: [Project] { projects.filter { $0.state == .active } }
    private var frozen: [Project] { projects.filter { $0.state == .frozen } }
    private var shipped: [Project] { projects.filter { $0.state == .shipped } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if active.isEmpty {
                        Text("No active project. Pick one below.").foregroundStyle(Theme.dim)
                    }
                    ForEach(active) { p in
                        NavigationLink { ProjectDetailView(project: p) } label: { ProjectRow(project: p) }
                    }
                } header: {
                    Text("Active · \(active.count)/\(Self.maxActive)")
                } footer: {
                    if let stale = active.first(where: { $0.daysSinceProgress >= 28 }) {
                        Text("\(stale.name) hasn't moved in \(stale.daysSinceProgress) days. Freezing it is a fine choice, not a failure.")
                    } else if let refreshError {
                        Text(refreshError)
                    }
                }

                Section("Frozen") {
                    ForEach(frozen) { p in
                        NavigationLink { ProjectDetailView(project: p) } label: { ProjectRow(project: p) }
                            .swipeActions {
                                Button("Activate") { activating = p }.tint(Theme.gold)
                            }
                    }
                    if frozen.isEmpty { Text("Nothing frozen.").foregroundStyle(Theme.dim) }
                }

                if !shipped.isEmpty {
                    Section("Shipped (used for real)") {
                        ForEach(shipped) { p in
                            NavigationLink { ProjectDetailView(project: p) } label: { ProjectRow(project: p) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Projects")
            .toolbar {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
            .refreshable { refreshError = await CIRefresher.refresh(projects) }
            .sheet(isPresented: $showAdd) { AddProjectSheet() }
            .sheet(item: $activating) { p in ActivateSheet(project: p, active: active) }
        }
    }
}

struct ProjectRow: View {
    let project: Project
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.name).font(.headline)
                Spacer()
                if project.ciFailing {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.calm)
                }
            }
            LadderView(milestone: project.milestone)
            if !project.ciSummary.isEmpty {
                Text(project.ciSummary).font(.caption).foregroundStyle(Theme.dim)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AddProjectSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.githubOwner) private var owner = "Epsilonmuz"
    @State private var name = ""
    @State private var repo = ""
    @State private var repoOwner = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name (e.g. Epsilon Bounce)", text: $name)
                }
                Section {
                    TextField("Owner", text: $repoOwner, prompt: Text(owner))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Repo (e.g. Epsilon-Bounce)", text: $repo)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("GitHub repo (optional)")
                } footer: {
                    Text("New projects start frozen. Activate one when a slot is free.")
                }
            }
            .navigationTitle("Add project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let o = repoOwner.isEmpty ? owner : repoOwner
                        context.insert(Project(name: name, repoOwner: repo.isEmpty ? "" : o, repoName: repo))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// Activating asks "why this one?". If both slots are full, it's a logged swap.
struct ActivateSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let active: [Project]

    @State private var why = ""
    @State private var freezeTarget: Project?

    private var needsSwap: Bool { active.count >= ProjectsView.maxActive }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Why this one, why now?", text: $why, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Commit to \(project.name)")
                } footer: {
                    Text("Focusing on a goal you've really committed to helps push rival projects out of mind.")
                }
                if needsSwap {
                    Section {
                        Picker("Freeze", selection: $freezeTarget) {
                            Text("Choose…").tag(Project?.none)
                            ForEach(active) { p in Text(p.name).tag(Project?.some(p)) }
                        }
                    } header: {
                        Text("Both slots are full: swap one out")
                    } footer: {
                        Text("Swaps are allowed and logged. Breaking a hard ban usually makes people quit the whole system.")
                    }
                }
            }
            .navigationTitle("Activate")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(needsSwap ? "Swap" : "Activate") { activate() }
                        .disabled(why.trimmingCharacters(in: .whitespaces).isEmpty || (needsSwap && freezeTarget == nil))
                }
            }
        }
    }

    private func activate() {
        if needsSwap, let out = freezeTarget {
            out.state = .frozen
            out.log("Frozen to make room for \(project.name)")
            context.insert(EventLog(kind: "swap", detail: "\(out.name) → \(project.name): \(why)"))
        }
        project.state = .active
        project.whyThisOne = why
        project.activatedAt = .now
        project.log("Activated: \(why)")
        dismiss()
    }
}
