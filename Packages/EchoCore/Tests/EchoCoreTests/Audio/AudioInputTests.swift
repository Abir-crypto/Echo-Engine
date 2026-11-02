import EchoCore
import EchoCoreFakes
import Testing

@MainActor
struct AudioInputTests {
    private let builtIn = AudioInput(id: "builtin", name: "iPhone Microphone", kind: .builtInMic, channelCount: 1, supportsStereo: true)
    private let airPods = AudioInput(id: "bt", name: "AirPods", kind: .bluetooth, channelCount: 1, supportsStereo: false)

    @Test func bluetoothInputsWarnAboutDelay() {
        // SPEC § 13.2: "Higher delay, not ideal with auto-tune or backing tracks".
        #expect(airPods.hasHigherDelay)
        #expect(!builtIn.hasHigherDelay)
    }

    @Test func theLatencyOffsetAddsInputOutputAndBuffer() {
        // SPEC § 13.6: offset = inputLatency + outputLatency + ioBufferDuration.
        let latency = AudioLatency(inputSeconds: 0.004, outputSeconds: 0.006, ioBufferSeconds: 0.005)
        #expect(abs(latency.roundTripSeconds - 0.015) < 1e-12)
    }

    @Test func theFakeListsAndSelectsInputs() throws {
        let devices = FakeAudioDeviceManager(inputs: [builtIn, airPods])
        try devices.activateForRecording()
        #expect(devices.availableInputs() == [builtIn, airPods])

        try devices.selectInput(id: "builtin", builtInMode: .stereo)

        #expect(devices.selectedInput == builtIn)
        #expect(devices.selectedInputChannelCount == 1)
        #expect(devices.builtInMode == .stereo)
        #expect(devices.recordingActivations == 1)
        #expect(throws: AudioDeviceError.inputUnavailable) { try devices.selectInput(id: "gone", builtInMode: .mono) }
    }
}
