import Foundation
import AVFoundation

/// Alarm sounds. The bundled WAVs are rendered on the phone into
/// Library/Sounds as 44.1 kHz 16-bit mono CAF files (the format that has been
/// reported to work with AlarmKit custom sounds). If you've recorded your own
/// voice line in Settings, it's mixed into the end of every hard-stop variant.
enum SoundLibrary {
    /// Nightly rotation (so you don't get used to one sound).
    static let hardStopVariants = [
        "FL_HardStop_A_880_bell",
        "FL_HardStop_B_740_knock",
        "FL_HardStop_C_988_bell",
        "FL_HardStop_D_660_knock",
    ]
    static let snooze = "FL_Snooze_E_830_bell"
    static let wrapUp = "FL_WrapUp"

    /// Max length of your voice line, in seconds.
    static let maxVoiceSeconds: Double = 4

    static var soundsDir: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Sounds", isDirectory: true)
    }

    static var voiceURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice_line.caf")
    }

    static var hasVoice: Bool { FileManager.default.fileExists(atPath: voiceURL.path) }

    /// File name to hand to AlarmKit / notifications (extension included).
    static func fileName(_ base: String) -> String { "\(base).caf" }

    static func renderedURL(_ base: String) -> URL { soundsDir.appendingPathComponent(fileName(base)) }

    static func variant(for date: Date) -> String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        return hardStopVariants[day % hardStopVariants.count]
    }

    /// Render every sound. Call at launch and whenever the voice line changes.
    @discardableResult
    static func prepareAll() -> String? {
        do {
            try FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)
            for base in hardStopVariants + [snooze] {
                try render(base: base, withVoice: hasVoice)
            }
            try render(base: wrapUp, withVoice: false)
            return nil
        } catch {
            return "Couldn't prepare alarm sounds: \(error.localizedDescription)"
        }
    }

    private static func render(base: String, withVoice: Bool) throws {
        guard let src = Bundle.main.url(forResource: base, withExtension: "wav") else {
            throw NSError(domain: "FinishLine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(base).wav in app bundle"])
        }
        let alarmFile = try AVAudioFile(forReading: src)
        let format = alarmFile.processingFormat
        guard let alarm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(alarmFile.length)) else { return }
        try alarmFile.read(into: alarm)

        if withVoice, let voice = try? loadVoice(matching: format), let a = alarm.floatChannelData, let v = voice.floatChannelData {
            let total = Int(alarm.frameLength)
            let vLen = min(Int(voice.frameLength), Int(maxVoiceSeconds * format.sampleRate))
            let tail = Int(0.3 * format.sampleRate)
            let start = max(0, total - vLen - tail)
            // Normalise the voice, then duck the alarm under it.
            var vPeak: Float = 0.0001
            for i in 0..<vLen { vPeak = max(vPeak, abs(v[0][i])) }
            let vGain = 0.95 / vPeak
            let fade = Int(0.08 * format.sampleRate)
            for i in 0..<vLen where start + i < total {
                let duckIn = min(1, Float(i) / Float(max(fade, 1)))
                let duck = 1 - 0.8 * duckIn
                a[0][start + i] = a[0][start + i] * duck + v[0][i] * vGain
            }
            // Keep the alarm ducked through the short tail after the voice.
            if start + vLen < total {
                for i in (start + vLen)..<total { a[0][i] *= 0.2 }
            }
            // Peak-normalise to about -1 dBFS.
            var peak: Float = 0.0001
            for i in 0..<total { peak = max(peak, abs(a[0][i])) }
            let g = 0.89 / peak
            for i in 0..<total { a[0][i] *= g }
        }

        let dest = renderedURL(base)
        try? FileManager.default.removeItem(at: dest)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let out = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try out.write(from: alarm)
    }

    /// Load the recorded voice line, converted to the alarm's format if needed.
    private static func loadVoice(matching format: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        guard hasVoice else { return nil }
        let file = try AVAudioFile(forReading: voiceURL)
        guard let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try file.read(into: raw)
        if file.processingFormat.sampleRate == format.sampleRate && file.processingFormat.channelCount == format.channelCount {
            return raw
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        let ratio = format.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(raw.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var err: NSError?
        _ = converter.convert(to: converted, error: &err) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return raw
        }
        if let err { throw err }
        return converted
    }
}

/// Records and plays back your spoken alarm line (Settings › Alarm voice).
@MainActor
final class VoiceLineRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var hasVoice = SoundLibrary.hasVoice
    @Published var status = ""

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?

    func record() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            status = "Allow the microphone in Settings › Finish Line."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            try? FileManager.default.removeItem(at: SoundLibrary.voiceURL)
            let rec = try AVAudioRecorder(url: SoundLibrary.voiceURL, settings: settings)
            rec.delegate = self
            _ = rec.record(forDuration: SoundLibrary.maxVoiceSeconds)
            recorder = rec
            isRecording = true
            status = "Recording… say it like you mean it (max \(Int(SoundLibrary.maxVoiceSeconds)) s)"
        } catch {
            status = "Couldn't record: \(error.localizedDescription)"
        }
    }

    func stop() {
        recorder?.stop()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.isRecording = false
            self.hasVoice = SoundLibrary.hasVoice
            try? AVAudioSession.sharedInstance().setActive(false)
            if flag {
                self.status = "Saved. Mixing it into your alarms…"
                let err = SoundLibrary.prepareAll()
                self.status = err ?? "Done. Your voice now ends every hard-stop alarm."
                await HardStopScheduler.rescheduleAll()
            } else {
                self.status = "Recording failed, try again."
            }
        }
    }

    func playVoice() { play(SoundLibrary.voiceURL) }

    /// Preview tonight's full alarm, voice included.
    func previewAlarm() {
        play(SoundLibrary.renderedURL(SoundLibrary.variant(for: StopClock.nextStop ?? .now)))
    }

    func stopPlayback() { player?.stop() }

    func deleteVoice() {
        try? FileManager.default.removeItem(at: SoundLibrary.voiceURL)
        hasVoice = false
        status = SoundLibrary.prepareAll() ?? "Voice removed. Alarms end with the bell or knocks again."
        Task { await HardStopScheduler.rescheduleAll() }
    }

    private func play(_ url: URL) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch {
            status = "Couldn't play: \(error.localizedDescription)"
        }
    }
}
