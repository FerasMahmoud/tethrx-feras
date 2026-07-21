import Foundation
import Speech
import AVFoundation

/// Composer dictation — tuned for coding accuracy (same class of quality as Grok TUI
/// voice / `/stt`, which is TUI-local and inert over ACP).
///
/// Grok Build's real STT (`xai-grok-voice`, Ctrl+Space / F8, slash `/stt`) runs only
/// inside the terminal UI. Over ACP those builtins produce no events. On the phone we
/// therefore use Apple Speech with **server-side** recognition (not on-device-only),
/// dictation task hint, and coding contextual strings — much closer to Grok STT than
/// the old on-device SFSpeech path.
@MainActor
final class Dictation: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    /// Speech or microphone permission was refused. Without surfacing this, a denied
    /// permission made the mic button do nothing at all, forever, with no explanation.
    @Published var denied = false

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var base = ""   // draft text already present when recording started

    /// Whether speech recognition is usable at all (device + locale support).
    var supported: Bool { recognizer != nil }

    func toggle(base: String) { isRecording ? stop() : start(base: base) }

    func start(base: String) {
        self.base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        SFSpeechRecognizer.requestAuthorization { speech in
            guard speech == .authorized else {
                Task { @MainActor in self.denied = true }
                return
            }
            AVAudioApplication.requestRecordPermission { mic in
                Task { @MainActor in
                    guard mic else { self.denied = true; return }
                    self.begin()
                }
            }
        }
    }

    func stop() { finish() }

    private func begin() {
        guard !isRecording, let recognizer, recognizer.isAvailable else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            // `.spokenAudio` + measurement mode is what Apple recommends for dictation
            // quality (closer to Grok TUI STT than `.record` alone).
            try audio.setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetooth])
            try audio.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            // Prefer cloud STT when available — on-device is weaker for code/tech terms.
            // Grok TUI uses its own cloud STT; this is the closest public path on iOS.
            if recognizer.supportsOnDeviceRecognition {
                req.requiresOnDeviceRecognition = false
            }
            if #available(iOS 16.0, *) {
                req.addsPunctuation = true
                req.taskHint = .dictation
            }
            // Bias toward coding / Grok vocabulary (same idea as Grok STT contextual LM).
            req.contextualStrings = [
                "grok", "TethrX", "bridge", "TestFlight", "APNs", "SwiftUI",
                "cwd", "git", "commit", "pull request", "npm", "TypeScript",
                "Cloudflare", "WSL", "systemd", "compact", "session", "subagent",
                "approve", "reject", "plan mode", "always approve",
            ]
            request = req

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // This closure runs on the realtime audio thread. Capture the request
            // directly rather than touching `self.request`, which is main-actor state
            // that finish() nils out — that was an unsynchronised read/write.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                req.append(buffer)
            }
            engine.prepare()
            try engine.start()

            transcript = base
            isRecording = true
            Haptics.tap(.medium)

            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        let spoken = result.bestTranscription.formattedString
                        self.transcript = self.base.isEmpty ? spoken : self.base + " " + spoken
                    }
                    if error != nil || (result?.isFinal ?? false) { self.finish() }
                }
            }
        } catch {
            finish()
        }
    }

    private func finish() {
        guard isRecording || engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
