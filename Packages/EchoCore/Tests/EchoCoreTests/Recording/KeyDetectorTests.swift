import AVFoundation
import Foundation
import Testing
@testable import EchoCore

/// Key detection (SPEC § 13.5, § 19) on synthesized chord progressions.
struct KeyDetectorTests {
    /// Chords (each a list of MIDI notes) of `seconds` each, as rich tones (four harmonics), written to a 44.1 kHz CAF.
    private func progression(_ chords: [[Int]], seconds: Double = 2) throws -> URL {
        let rate = 44_100.0
        let url = try temporaryFolder().appending(path: "progression.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        for chord in chords {
            let frames = AVAudioFrameCount(seconds * rate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for frame in 0..<Int(frames) {
                let time = Double(frame) / rate
                var sample = 0.0
                for note in chord {
                    let frequency = 440 * pow(2, Double(note - 69) / 12)
                    for harmonic in 1...4 { sample += sin(2 * .pi * frequency * Double(harmonic) * time) / Double(harmonic) }
                }
                buffer.floatChannelData![0][frame] = Float(0.1 * sample / Double(chord.count))
            }
            try file.write(from: buffer)
        }
        return url
    }

    @Test func aMinorProgression() async throws {
        // Am – Dm – E – Am
        let url = try progression([[57, 60, 64], [50, 53, 57], [52, 56, 59], [57, 60, 64]])
        #expect(try await ChromaKeyDetector().detectKey(of: url) == MusicalKey(tonic: 9, scale: .minor))
    }

    @Test func cMajorProgression() async throws {
        // C – F – G – C
        let url = try progression([[48, 52, 55], [53, 57, 60], [55, 59, 62], [48, 52, 55]])
        #expect(try await ChromaKeyDetector().detectKey(of: url) == MusicalKey(tonic: 0, scale: .major))
    }

    @Test func eFlatMajorWithItsFlats() async throws {
        // E♭ – A♭ – B♭ – E♭
        let url = try progression([[51, 55, 58], [56, 60, 63], [58, 62, 65], [51, 55, 58]])
        #expect(try await ChromaKeyDetector().detectKey(of: url) == MusicalKey(tonic: 3, scale: .major))
    }

    @Test func noiseHasNoKey() {
        #expect(ChromaKeyDetector.key(for: [Float](repeating: 1, count: 12)) == nil, "flat chroma: no key")
        #expect(ChromaKeyDetector.key(for: [Float](repeating: 0, count: 12)) == nil, "silence")
    }

    @Test func profilesMatchTheirOwnKeys() {
        for tonic in 0..<12 {
            let chroma = (0..<12).map { ChromaKeyDetector.minorProfile[(($0 - tonic) % 12 + 12) % 12] }
            #expect(ChromaKeyDetector.key(for: chroma) == MusicalKey(tonic: tonic, scale: .minor))
        }
    }
}
