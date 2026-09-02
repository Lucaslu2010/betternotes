import XCTest
import AVFoundation
import Speech
@testable import BetterNotes

/// AudioRecorder is the app's last untested service. Recording itself needs a
/// microphone, but everything around it — the guards that refuse impossible
/// requests, the playback transport, and the continuation bookkeeping that
/// makes transcription cancellable — is state machinery, and that is where the
/// crashes live: a double `resume()` on a continuation traps the process.
@MainActor
final class AudioRecorderTests: XCTestCase {

    /// A second of real, silent PCM audio — enough for AVAudioPlayer to open.
    private func sampleAudio() throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        // A quiet tone rather than pure silence, so the file is real audio.
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frames) {
                channel[frame] = 0.1 * sinf(2 * .pi * 440 * Float(frame) / 44100)
            }
        }
        try file.write(from: buffer)
        return try Data(contentsOf: url)
    }

    // MARK: - Guards

    func testStoppingWhenNotRecordingReturnsNothing() {
        let recorder = AudioRecorder()
        XCTAssertNil(recorder.stopRecording())
        XCTAssertFalse(recorder.isRecording)
    }

    func testPlayingEmptyDataIsRefusedWithAnError() {
        let recorder = AudioRecorder()
        recorder.play(data: Data(), elementID: PageElement(type: .audioRecording, x: 0, y: 0).persistentModelID)
        XCTAssertFalse(recorder.isPlaying)
        XCTAssertNotNil(recorder.lastError, "an empty recording played silently instead of reporting why")
        XCTAssertNil(recorder.playingElementID)
    }

    func testPlaybackIsRefusedWhileRecording() throws {
        let recorder = AudioRecorder()
        recorder.isRecording = true
        recorder.play(data: try sampleAudio(),
                      elementID: PageElement(type: .audioRecording, x: 0, y: 0).persistentModelID)
        XCTAssertFalse(recorder.isPlaying)
        XCTAssertNotNil(recorder.lastError)
        recorder.isRecording = false
    }

    func testTranscribingNothingFailsBeforeAskingForPermission() async {
        let recorder = AudioRecorder()
        do {
            _ = try await recorder.transcribe(data: Data())
            XCTFail("an empty recording was sent for transcription")
        } catch {
            // The error type is file-private, so assert on the message the
            // user would actually be shown.
            XCTAssertEqual(error.localizedDescription, "This recording has no audio data.")
        }
    }

    // MARK: - Transport with no player loaded

    func testTransportControlsAreInertWithNothingLoaded() {
        // These are wired to always-visible UI, so they get tapped in states
        // the designer never pictured. None of them may crash or invent state.
        let recorder = AudioRecorder()
        recorder.pausePlayback()
        recorder.resumePlayback()
        recorder.seek(to: 0.5)
        recorder.stopPlayback()
        XCTAssertFalse(recorder.isPlaying)
        XCTAssertEqual(recorder.playbackProgress, 0)
        XCTAssertEqual(recorder.playbackTime, 0)
        XCTAssertNil(recorder.playingElementID)
    }

    func testSeekingOutOfRangeIsClampedRatherThanTrusted() {
        let recorder = AudioRecorder()
        recorder.seek(to: -5)
        XCTAssertEqual(recorder.playbackProgress, 0)
        recorder.seek(to: 12)
        XCTAssertLessThanOrEqual(recorder.playbackProgress, 1)
    }

    // MARK: - Cancellation bookkeeping

    func testCancellingWithNothingInFlightDoesNothing() {
        // cancelTranscription resumes a stored continuation. Calling it when
        // none is stored must not resume anything — a second resume traps.
        let recorder = AudioRecorder()
        recorder.cancelTranscription()
        recorder.cancelTranscription()
        recorder.cancelPendingRecording()
        XCTAssertNil(recorder.lastError)
    }

    func testCancellingTwiceDuringTranscriptionResumesOnlyOnce() async throws {
        // The real trap: the speech callback and cancelTranscription() both
        // reaching resume(). If the continuation were not cleared before being
        // resumed, this would crash the test process rather than fail it.
        //
        // Only meaningful once speech permission has been decided — before
        // that, transcribe() is still parked on the permission request and has
        // no continuation stored, and a test host has no UI to grant it on.
        try XCTSkipUnless(SFSpeechRecognizer.authorizationStatus() == .authorized,
                          "speech recognition is not authorized in this environment")
        let recorder = AudioRecorder()
        let audio = try sampleAudio()

        let task = Task { try await recorder.transcribe(data: audio) }
        try await Task.sleep(for: .milliseconds(300))
        recorder.cancelTranscription()
        recorder.cancelTranscription()

        // Bounded: a hang here is itself the failure, not a stalled suite.
        let finished = Task {
            try? await Task.sleep(for: .seconds(10))
            task.cancel()
        }
        _ = try? await task.value
        finished.cancel()
    }

    // MARK: - Playback transport with audio loaded

    func testPlayPauseResumeAndStopMoveThroughTheExpectedStates() async throws {
        let recorder = AudioRecorder()
        let elementID = PageElement(type: .audioRecording, x: 0, y: 0).persistentModelID
        recorder.play(data: try sampleAudio(), elementID: elementID)

        // play() configures the session in a detached task, so let it land.
        try await Task.sleep(for: .milliseconds(600))
        try XCTSkipUnless(recorder.isPlaying,
                          "no audio route in this environment: \(recorder.lastError ?? "unknown")")
        XCTAssertEqual(recorder.playingElementID, elementID)

        recorder.pausePlayback()
        XCTAssertFalse(recorder.isPlaying)
        XCTAssertEqual(recorder.playingElementID, elementID,
                       "pausing dropped the element, so the UI would stop showing which note is loaded")

        recorder.resumePlayback()
        XCTAssertTrue(recorder.isPlaying, "a paused recording could not be resumed")

        recorder.seek(to: 0.5)
        XCTAssertEqual(recorder.playbackProgress, 0.5, accuracy: 0.01)

        recorder.stopPlayback()
        XCTAssertFalse(recorder.isPlaying)
        XCTAssertNil(recorder.playingElementID)
        XCTAssertEqual(recorder.playbackProgress, 0)
        XCTAssertEqual(recorder.playbackTime, 0)
    }
}
