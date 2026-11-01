import AVFoundation
import EchoAudioUnits
import Testing

@MainActor
struct SourceSwitchTests {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private func constant(_ value: Float, frames: AVAudioFrameCount = 96_000) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = value }
        return buffer
    }

    @Test func crossfadesBetweenItsInputsAtTheScheduledSample() throws {
        EchoAudioUnits.register()
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        let first = AVAudioPlayerNode(), second = AVAudioPlayerNode()
        let switchNode = AVAudioUnitEffect(audioComponentDescription: SourceSwitchAudioUnit.componentDescription)
        [first, second, switchNode].forEach(engine.attach)
        #expect(switchNode.numberOfInputs == 2)
        engine.connect(first, to: switchNode, fromBus: 0, toBus: 0, format: format)
        engine.connect(second, to: switchNode, fromBus: 0, toBus: 1, format: format)
        engine.connect(switchNode, to: engine.mainMixerNode, format: format)
        try engine.start()
        first.scheduleBuffer(try constant(0.25))
        second.scheduleBuffer(try constant(0.75))
        first.play()
        second.play()
        let unit = try #require(switchNode.auAudioUnit as? SourceSwitchAudioUnit)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))

        _ = try engine.renderOffline(2_048, to: output)
        #expect(abs(output.floatChannelData![0][2_047] - 0.25) < 1e-6, "input 0 at first")

        let now = try #require(first.lastRenderTime).sampleTime
        unit.crossfade(to: 1, at: now + 1_000)
        var rendered: [Float] = []
        for _ in 0..<2 {
            _ = try engine.renderOffline(2_048, to: output)
            rendered += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
        }

        // `lastRenderTime` is the next sample to render, so the fade starts exactly 1,000 samples in and lasts 20 ms.
        let firstChanged = try #require(rendered.firstIndex { abs($0 - 0.25) > 1e-6 })
        #expect(firstChanged == 1_000)
        #expect(abs(rendered[1_000 + 480] - 0.5) < 0.01, "halfway after 10 ms")
        #expect(abs(rendered[1_000 + 960] - 0.75) < 1e-6, "input 1 after 20 ms")
    }
}
