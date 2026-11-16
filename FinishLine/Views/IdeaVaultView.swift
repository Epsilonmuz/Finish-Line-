import SwiftUI
import SwiftData

/// Park ideas instead of starting them. Capture any time; the list opens on
/// review day (Sunday) and you can promote at most one idea a week.
struct IdeaVaultView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var router: AppRouter
    @Query(filter: #Predicate<Idea> { !$0.archived && $0.promotedAt == nil }, sort: \Idea.createdAt, order: .reverse)
    private var ideas: [Idea]

    @StateObject private var speech = SpeechCapture()
    @AppStorage("captureLang") private var lang = "es-US"
    @AppStorage(Prefs.lastPromotion) private var lastPromotion: Double = 0

    @State private var draftText = ""
    @State private var draftPlan = ""
    @State private var makingPlan = false
    @State private var reviewOpenedEarly = false
    @State private var promoteMessage: String?

    private var isReviewDay: Bool { Calendar.current.component(.weekday, from: .now) == 1 }
    private var reviewOpen: Bool { isReviewDay || reviewOpenedEarly }

    private var canPromote: Bool {
        guard lastPromotion > 0 else { return true }
        return Date.now.timeIntervalSince1970 - lastPromotion >= 7 * 24 * 3600
    }

    var body: some View {
        NavigationStack {
            List {
                captureSection
                if !draftText.isEmpty { draftSection }
                reviewSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Idea Vault")
            .onAppear(perform: handlePendingCapture)
            .onChange(of: router.pendingCapture) { _, _ in handlePendingCapture() }
            .onChange(of: speech.isRecording) { _, recording in
                if !recording && !speech.transcript.isEmpty { draftText = speech.transcript; makePlan() }
            }
        }
    }

    private var captureSection: some View {
        Section {
            Picker("Language", selection: $lang) {
                ForEach(SpeechCapture.languages, id: \.code) { l in Text(l.label).tag(l.code) }
            }
            .pickerStyle(.segmented)

            Button {
                if speech.isRecording { speech.stop() } else { Task { await speech.start(localeID: lang) } }
            } label: {
                HStack {
                    Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(speech.isRecording ? Theme.stop : Theme.gold)
                    VStack(alignment: .leading) {
                        Text(speech.isRecording ? "Listening… tap to stop" : "Say the idea").font(.headline)
                        Text("It gets parked with a 3-line plan. Not started.").font(.caption).foregroundStyle(Theme.dim)
                    }
                }
            }
            .buttonStyle(.plain)

            if speech.isRecording && !speech.transcript.isEmpty {
                Text(speech.transcript).foregroundStyle(Theme.dim)
            }
            if let err = speech.errorText { Text(err).font(.footnote).foregroundStyle(Theme.stop) }

            Button("Type it instead") { draftText = " " }
                .font(.footnote)
        } header: {
            Text("Capture")
        }
    }

    private var draftSection: some View {
        Section {
            TextField("Idea", text: $draftText, axis: .vertical)
            if makingPlan {
                ProgressView("Writing the plan…")
            } else {
                TextField("3-line plan", text: $draftPlan, axis: .vertical)
                    .font(.callout)
                Button("Make plan") { makePlan() }
                    .disabled(draftText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button("Park it") { park() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Discard", role: .destructive) { draftText = ""; draftPlan = "" }
            }
        } header: {
            Text("New idea")
        } footer: {
            Text(PlanWriter.onDeviceModelAvailable ? "Plan written on your iPhone." : "On-device model not available on this iPhone: fill in the template.")
        }
    }

    private var reviewSection: some View {
        Section {
            if reviewOpen {
                if ideas.isEmpty { Text("Vault is empty.").foregroundStyle(Theme.dim) }
                ForEach(ideas) { idea in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(idea.title).font(.headline)
                        Text(idea.plan).font(.footnote).foregroundStyle(Theme.dim)
                        Text(idea.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2).foregroundStyle(Theme.dim)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Archive") { idea.archived = true }.tint(.gray)
                    }
                    .swipeActions(edge: .leading) {
                        Button("Promote") { promote(idea) }.tint(Theme.gold)
                    }
                }
                if let promoteMessage { Text(promoteMessage).font(.footnote).foregroundStyle(Theme.gold) }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(ideas.count) ideas parked").font(.headline)
                    Text("The list opens on Sunday for your weekly review. Out of sight keeps them from pulling you off your active projects.")
                        .font(.footnote).foregroundStyle(Theme.dim)
                }
                Button("Open review now") { reviewOpenedEarly = true }
                    .font(.footnote)
            }
        } header: {
            Text("Weekly review")
        } footer: {
            if reviewOpen {
                Text(canPromote ? "Swipe right to promote one idea to a frozen project. One per week." : "You already promoted an idea this week.")
            }
        }
    }

    // MARK: Actions

    private func handlePendingCapture() {
        guard router.pendingCapture else { return }
        router.pendingCapture = false
        Task { await speech.start(localeID: lang) }
    }

    private func makePlan() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        makingPlan = true
        Task {
            draftPlan = await PlanWriter.plan(for: text, languageCode: lang)
            makingPlan = false
        }
    }

    private func park() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = draftPlan.isEmpty ? PlanWriter.template(for: text, languageCode: lang) : draftPlan
        context.insert(Idea(text: text, plan: plan, languageCode: lang))
        draftText = ""
        draftPlan = ""
    }

    private func promote(_ idea: Idea) {
        guard canPromote else {
            promoteMessage = "One promotion per week. This one waits."
            return
        }
        idea.promotedAt = .now
        lastPromotion = Date.now.timeIntervalSince1970
        context.insert(Project(name: idea.title, notes: "\(idea.text)\n\n\(idea.plan)"))
        context.insert(EventLog(kind: "promote", detail: idea.title))
        promoteMessage = "\"\(idea.title)\" is now a frozen project."
    }
}
