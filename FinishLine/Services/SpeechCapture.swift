import Foundation
import AVFoundation
import Speech

/// Voice capture for the Idea Vault. Spanish or English, chosen per note,
/// transcribed on the iPhone when the device supports it.
@MainActor
final class SpeechCapture: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var errorText: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    struct LangOption: Hashable {
        let code: String
        let label: String
    }
    static let languages = [LangOption(code: "es-US", label: "Español"), LangOption(code: "en-US", label: "English")]

    func requestPermissions() async -> Bool {
        let speechOK: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        let micOK = await AVAudioApplication.requestRecordPermission()
        if !speechOK || !micOK {
            errorText = "Allow Microphone and Speech Recognition in Settings › Finish Line."
        }
        return speechOK && micOK
    }

    func start(localeID: String) async {
        errorText = nil
        transcript = ""
        guard await requestPermissions() else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)), recognizer.isAvailable else {
            errorText = "Speech recognition for this language isn't available right now."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                req.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let finished = error != nil || (result?.isFinal ?? false)
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if finished { self.stopAudio() }
                }
            }
        } catch {
            errorText = "Couldn't start recording: \(error.localizedDescription)"
            stopAudio()
        }
    }

    func stop() {
        request?.endAudio()
        stopAudio()
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
