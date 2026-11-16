import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage(Prefs.userName) private var userName = "Edison"
    @AppStorage(Prefs.githubOwner) private var owner = "Epsilonmuz"
    @AppStorage(Prefs.stopHour) private var stopHour = 0
    @AppStorage(Prefs.stopMinute) private var stopMinute = 0
    @AppStorage(Prefs.wrapUpEnabled) private var wrapUp = true
    @AppStorage(Prefs.breakMinutes) private var breakMinutes = 90
    @AppStorage(Prefs.alarmStatus) private var alarmStatus = ""

    @StateObject private var voice = VoiceLineRecorder()
    @State private var token = ""
    @State private var tokenSaved = KeychainStore.read("githubToken") != nil
    @State private var alarmMessage = ""
    @State private var authText = HardStopScheduler.statusText

    private var stopTime: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: stopHour, minute: stopMinute, second: 0, of: .now) ?? .now },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                stopHour = c.hour ?? 0
                stopMinute = c.minute ?? 0
                Task { await HardStopScheduler.rescheduleAll() }
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                hardStopSection
                voiceSection
                Section("You") {
                    TextField("Name on the STOP screen", text: $userName)
                }
                githubSection
                Section {
                    Text(PlanWriter.onDeviceModelAvailable ? "On-device model available: plans are written on your iPhone." : "On-device model not available: plans use a template.")
                        .font(.footnote)
                    Button("Reset prioritizer learning") { Prioritizer.resetLearning() }
                } header: { Text("Smarts") }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
        }
    }

    private var hardStopSection: some View {
        Section {
            DatePicker("Nightly hard stop", selection: stopTime, displayedComponents: .hourAndMinute)
            Toggle("Wrap-up warning 30 min before", isOn: $wrapUp)
                .onChange(of: wrapUp) { _, _ in Task { await HardStopScheduler.rescheduleAll() } }
            Stepper("Break reminder after \(breakMinutes) min", value: $breakMinutes, in: 30...180, step: 15)
            Text(authText).font(.footnote).foregroundStyle(Theme.dim)
            if HardStopScheduler.authState != .authorized {
                Button("Allow loud alarm") {
                    Task {
                        await HardStopScheduler.requestAuthorization()
                        authText = HardStopScheduler.statusText
                        await HardStopScheduler.rescheduleAll()
                    }
                }
            }
            Button("Test the alarm in 1 minute") {
                Task { alarmMessage = await HardStopScheduler.test() }
            }
            if !alarmMessage.isEmpty { Text(alarmMessage).font(.footnote).foregroundStyle(Theme.gold) }
            if !alarmStatus.isEmpty { Text(alarmStatus).font(.caption).foregroundStyle(Theme.dim) }
        } header: {
            Text("Hard stop")
        } footer: {
            Text("The alarm plays at your ringer volume. If earbuds are connected, iOS may route it there, so the STOP screen and your Apple Watch matter more than the sound.")
        }
    }

    private var voiceSection: some View {
        Section {
            HStack {
                Button {
                    if voice.isRecording { voice.stop() } else { Task { await voice.record() } }
                } label: {
                    Label(voice.isRecording ? "Stop recording" : (voice.hasVoice ? "Re-record my voice" : "Record my voice"),
                          systemImage: voice.isRecording ? "stop.circle.fill" : "mic.fill")
                }
                .tint(voice.isRecording ? Theme.stop : Theme.gold)
            }
            if voice.hasVoice {
                Button("Play my voice line") { voice.playVoice() }
                Button("Preview tonight's alarm with my voice") { voice.previewAlarm() }
                Button("Stop playback") { voice.stopPlayback() }
                Button("Remove my voice", role: .destructive) { voice.deleteVoice() }
            }
            if !voice.status.isEmpty { Text(voice.status).font(.footnote).foregroundStyle(Theme.dim) }
        } header: {
            Text("Alarm voice")
        } footer: {
            Text("Record up to 4 seconds, for example: \"\(userName). Hard stop. Write tomorrow's step.\" It's mixed into the end of every hard-stop alarm, with the alarm ducked under it.")
        }
    }

    private var githubSection: some View {
        Section {
            TextField("Default owner", text: $owner)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(tokenSaved ? "Token saved, paste to replace" : "Fine-grained token", text: $token)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save token") {
                KeychainStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines), for: "githubToken")
                tokenSaved = !token.isEmpty
                token = ""
            }
            .disabled(token.isEmpty)
        } header: {
            Text("GitHub")
        } footer: {
            Text("github.com › Settings › Developer settings › Fine-grained tokens. Pick your repos, permission \"Actions: Read-only\". Stored in the iPhone Keychain.")
        }
    }
}
