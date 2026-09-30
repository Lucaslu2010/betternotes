import Foundation
import AVFoundation
import SwiftData
import Speech

/// Handles recording and playback of audio memos attached to pages.
@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {

    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var elapsed: TimeInterval = 0
    @Published var lastError: String?

    /// Progress of the current playback, 0.0–1.0. Published so SwiftUI views
    /// can animate a progress bar.
    @Published var playbackProgress: Double = 0
    /// Current playback time in seconds (for display).
    @Published var playbackTime: TimeInterval = 0
    /// The element ID of the audio currently playing, so the UI knows which
    /// element to show as "playing."
    @Published var playingElementID: PersistentIdentifier?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var tickTimer: Timer?
    private var playbackTimer: Timer?
    private var currentURL: URL?
    private var transcriptionTask: SFSpeechRecognitionTask?
    private var transcriptionContinuation: CheckedContinuation<String, Error>?
    private var transcriptionURL: URL?
    private var recordingRequestID: UUID?
    private var playbackRequestID: UUID?

    override init() {
        super.init()
    }

    // MARK: - Recording

    @MainActor
    @discardableResult
    func startRecording() async -> Bool {
        guard !isRecording else { return false }
        stopPlayback(deactivatesSession: false)
        lastError = nil
        let requestID = UUID()
        recordingRequestID = requestID
        await requestPermissionIfNeeded()

        guard recordingRequestID == requestID else { return false }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            recordingRequestID = nil
            lastError = AppLocalization.text("Microphone permission denied")
            return false
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memo-\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        // Configure the audio session off the main thread to avoid the 1–2s
        // UI hang caused by synchronous setActive calls.
        let sessionReady = await Task.detached(priority: .userInitiated) { () -> Bool in
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try session.setActive(true)
                return true
            } catch {
                return false
            }
        }.value

        guard recordingRequestID == requestID else {
            if sessionReady {
                deactivateAudioSession()
            }
            return false
        }
        guard sessionReady else {
            recordingRequestID = nil
            lastError = AppLocalization.text("Failed to configure the audio session")
            return false
        }

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record() else {
                throw AudioRecordingError.couldNotStart
            }
            self.recorder = recorder
        } catch {
            recordingRequestID = nil
            try? FileManager.default.removeItem(at: url)
            deactivateAudioSession()
            lastError = "Failed to start recording. \(error.localizedDescription)"
            return false
        }
        recordingRequestID = nil
        isRecording = true
        currentURL = url
        startTick()
        return true
    }

    @discardableResult
    func stopRecording() -> Data? {
        recordingRequestID = nil
        guard isRecording else { return nil }
        isRecording = false
        stopTick()
        elapsed = 0

        guard let url = currentURL else {
            recorder?.stop()
            recorder = nil
            deactivateAudioSession()
            lastError = AppLocalization.text("The recording file could not be found.")
            return nil
        }

        // AVAudioRecorder.stop() is asynchronous — the encoder may still be
        // flushing to disk when we try to read. Wait briefly for the file to
        // be fully written before reading. Without this, Data(contentsOf:)
        // can race the encoder and return a truncated/empty file, losing the
        // recording.
        recorder?.stop()
        let recorderRef = recorder
        let deadline = Date().addingTimeInterval(2.0)
        while recorderRef?.isRecording == true, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }

        deactivateAudioSession()
        currentURL = nil
        recorder = nil
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { throw AudioRecordingError.emptyFile }
            return data
        } catch {
            lastError = AppLocalization.format("The recording could not be saved. %@", error.localizedDescription)
            return nil
        }
    }

    func cancelPendingRecording() {
        recordingRequestID = nil
    }

    func cancelTranscription() {
        guard transcriptionContinuation != nil else { return }
        finishTranscription(.failure(AudioTranscriptionError.cancelled))
    }

    // MARK: - Playback

    func play(data: Data, elementID: PersistentIdentifier) {
        guard !isRecording else {
            lastError = AppLocalization.text("Stop the current recording before playing another audio note.")
            return
        }
        guard !data.isEmpty else {
            lastError = AppLocalization.text("This recording has no audio data.")
            return
        }
        stopPlayback(deactivatesSession: false)
        lastError = nil
        let requestID = UUID()
        playbackRequestID = requestID
        Task { @MainActor in
            do {
                let sessionReady = await Task.detached(priority: .userInitiated) { () -> Bool in
                    let session = AVAudioSession.sharedInstance()
                    do {
                        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                        try session.setActive(true)
                        return true
                    } catch {
                        return false
                    }
                }.value
                guard self.playbackRequestID == requestID else {
                    if sessionReady, self.playbackRequestID == nil {
                        self.deactivateAudioSession()
                    }
                    return
                }
                guard sessionReady else { throw AudioPlaybackError.sessionUnavailable }

                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                guard player.prepareToPlay(), player.play() else {
                    throw AudioPlaybackError.couldNotStart
                }
                self.player = player
                self.playingElementID = elementID
                self.isPlaying = true
                self.startPlaybackTick()
            } catch {
                self.stopPlayback()
                self.lastError = "Unable to play this recording. \(error.localizedDescription)"
            }
        }
    }

    func stopPlayback() {
        stopPlayback(deactivatesSession: true)
    }

    func pausePlayback() {
        guard let player, player.isPlaying else { return }
        player.pause()
        isPlaying = false
        playbackTime = player.currentTime
        if player.duration > 0 {
            playbackProgress = min(player.currentTime / player.duration, 1)
        }
        stopPlaybackTick()
    }

    func resumePlayback() {
        guard let player, playingElementID != nil else { return }
        guard player.play() else {
            lastError = AudioPlaybackError.couldNotStart.localizedDescription
            stopPlayback()
            return
        }
        isPlaying = true
        lastError = nil
        startPlaybackTick()
    }

    private func stopPlayback(deactivatesSession: Bool) {
        playbackRequestID = nil
        player?.stop()
        isPlaying = false
        player = nil
        playbackProgress = 0
        playbackTime = 0
        playingElementID = nil
        stopPlaybackTick()
        if deactivatesSession {
            deactivateAudioSession()
        }
    }

    private func deactivateAudioSession() {
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Seek to a specific position (0.0–1.0 of total duration).
    func seek(to progress: Double) {
        guard let player, player.duration > 0 else { return }
        let clamped = min(max(progress, 0), 1)
        let target = player.duration * clamped
        player.currentTime = target
        playbackTime = target
        playbackProgress = clamped
    }

    // MARK: - Transcription

    func transcribe(data: Data) async throws -> String {
        guard !data.isEmpty else { throw AudioTranscriptionError.emptyRecording }
        let status = await requestSpeechPermission()
        guard status == .authorized else { throw AudioTranscriptionError.permissionDenied }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw AudioTranscriptionError.unavailable
        }

        transcriptionTask?.cancel()
        if transcriptionContinuation != nil {
            finishTranscription(.failure(AudioTranscriptionError.cancelled))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-\(UUID().uuidString).m4a")
        try data.write(to: url, options: .atomic)
        transcriptionURL = url

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        return try await withCheckedThrowingContinuation { continuation in
            transcriptionContinuation = continuation
            transcriptionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.transcriptionContinuation != nil else { return }
                    if let error {
                        self.finishTranscription(.failure(error))
                    } else if let result, result.isFinal {
                        let text = result.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        self.finishTranscription(text.isEmpty
                            ? .failure(AudioTranscriptionError.noSpeech)
                            : .success(text))
                    }
                }
            }
        }
    }

    private func requestSpeechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func finishTranscription(_ result: Result<String, Error>) {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if let url = transcriptionURL { try? FileManager.default.removeItem(at: url) }
        transcriptionURL = nil
        // Atomically capture and nil-out the continuation BEFORE resuming.
        // Without this, the speech callback and cancelTranscription() can
        // both pass the non-nil guard and call resume() twice, which traps.
        guard let continuation = transcriptionContinuation else { return }
        transcriptionContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: - Permission

    func requestPermissionIfNeeded() async {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { _ in cont.resume() }
            }
        }
    }

    // MARK: - Timer

    private func startTick() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
            }
        }
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func startPlaybackTick() {
        stopPlaybackTick()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.playbackTime = player.currentTime
                let duration = player.duration
                if duration > 0 {
                    self.playbackProgress = min(player.currentTime / duration, 1)
                }
            }
        }
    }

    private func stopPlaybackTick() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    // MARK: - Delegates

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.player = nil
            self.playbackRequestID = nil
            self.playbackProgress = 0
            self.playbackTime = 0
            self.playingElementID = nil
            self.stopPlaybackTick()
            self.deactivateAudioSession()
            if !flag {
                self.lastError = AppLocalization.text("The audio player stopped before the recording finished.")
            }
        }
    }
}

private enum AudioRecordingError: LocalizedError {
    case couldNotStart, emptyFile

    var errorDescription: String? {
        switch self {
        case .couldNotStart: return AppLocalization.text("The recorder could not start.")
        case .emptyFile: return AppLocalization.text("The recording file is empty.")
        }
    }
}

private enum AudioPlaybackError: LocalizedError {
    case couldNotStart, sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .couldNotStart: return AppLocalization.text("The audio player could not start.")
        case .sessionUnavailable: return AppLocalization.text("The audio session is unavailable.")
        }
    }
}

private enum AudioTranscriptionError: LocalizedError {
    case emptyRecording, permissionDenied, unavailable, noSpeech, cancelled

    var errorDescription: String? {
        switch self {
        case .emptyRecording: return AppLocalization.text("This recording has no audio data.")
        case .permissionDenied: return AppLocalization.text("Speech recognition permission is required to transcribe audio.")
        case .unavailable: return AppLocalization.text("Speech recognition is currently unavailable.")
        case .noSpeech: return AppLocalization.text("No speech could be recognized in this recording.")
        case .cancelled: return AppLocalization.text("The previous transcription was cancelled.")
        }
    }
}
