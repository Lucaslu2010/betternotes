import AVFoundation
import SwiftData
import XCTest
@testable import BetterNotes

@MainActor
final class AudioPlaybackTests: XCTestCase {
    /// A short mono 16-bit WAV of a quiet tone, standing in for a recording.
    private func wav(seconds: Double, sampleRate: Int = 44_100) -> Data {
        let count = Int(seconds * Double(sampleRate))
        var pcm = Data()
        for i in 0..<count {
            var sample = Int16(2_000 * sin(2 * Double.pi * 440 * Double(i) / Double(sampleRate)))
            pcm.append(Data(bytes: &sample, count: 2))
        }
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8)
        d += le(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8) + le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1))
        d += le(UInt32(sampleRate)) + le(UInt32(sampleRate * 2)) + le(UInt16(2)) + le(UInt16(16))
        d += Data("data".utf8) + le(UInt32(pcm.count)) + pcm
        return d
    }

    func testPlaybackStartsWithoutStallingTheMainThread() async throws {
        let recorder = AudioRecorder()
        let element = PageElement(type: .audioRecording, x: 0, y: 0)
        var longestGap: TimeInterval = 0
        var last = CACurrentMediaTime()
        let probe = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            let now = CACurrentMediaTime()
            longestGap = max(longestGap, now - last)
            last = now
        }
        defer { probe.invalidate() }

        recorder.play(data: wav(seconds: 3), elementID: element.persistentModelID)
        let deadline = Date().addingTimeInterval(8)
        while !recorder.isPlaying, recorder.lastError == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertNil(recorder.lastError, "playback failed: \(recorder.lastError ?? "")")
        XCTAssertTrue(recorder.isPlaying, "playback never started")
        XCTAssertLessThan(longestGap, 0.2, "the main thread stalled for \(longestGap)s starting playback")
        recorder.stopPlayback()
    }
}
