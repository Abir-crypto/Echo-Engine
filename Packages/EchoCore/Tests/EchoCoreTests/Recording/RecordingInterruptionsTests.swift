import EchoCoreFakes
import Foundation
import Testing
@testable import EchoCore

@MainActor
struct RecordingInterruptionsTests {
    private let usb = AudioInput(id: "usb", name: "Interface", kind: .usb, channelCount: 2, supportsStereo: false)
    private let builtIn = AudioInput(id: "built-in", name: "iPhone Microphone", kind: .builtInMic, channelCount: 1, supportsStereo: true)

    /// A take recording from the USB interface.
    private func recording() throws -> (RecordingInterruptions, FakeRecordingEngine, FakeAudioDeviceManager) {
        let devices = FakeAudioDeviceManager(inputs: [usb, builtIn])
        try devices.selectInput(id: usb.id, builtInMode: .mono)
        let engine = FakeRecordingEngine(inputChannels: 2)
        let interruptions = RecordingInterruptions(devices: devices, engine: engine)
        interruptions.track(inputID: usb.id, builtInMode: .mono)
        try engine.prepare(.mono(channels: [0, 1]))
        try engine.startTake(in: TakeFolder(url: URL(filePath: "/takes")))
        return (interruptions, engine, devices)
    }

    @Test func aCallPausesTheTakeAndResumeWaitsUntilItIsOver() throws {
        let (interruptions, engine, devices) = try recording()
        engine.elapsedSeconds = 12
        interruptions.handle(.interruptionBegan)
        #expect(engine.state == .pausedByInterruption(.interruption))
        #expect(engine.markers == [RecordingMetadata.Marker(time: 12, kind: .interruption)])
        #expect(!interruptions.canResume, "the call is still going on")

        interruptions.handle(.interruptionEnded)
        #expect(engine.state == .pausedByInterruption(.interruption), "never resumes by itself")
        #expect(interruptions.canResume)
        try interruptions.resume()
        #expect(engine.state == .recording)
        #expect(devices.recordingActivations == 1)
        #expect(devices.selectedInput == usb)
    }

    @Test func aLostInputPausesUntilItIsBack() throws {
        let (interruptions, engine, devices) = try recording()
        devices.inputs = [builtIn]
        devices.currentInputID = builtIn.id
        interruptions.handle(.inputDeviceRemoved)
        #expect(engine.state == .pausedByInterruption(.routeChange))
        #expect(!interruptions.canResume)
        #expect(throws: RecordingError.inputChanged) { try interruptions.resume() }
        #expect(engine.state == .pausedByInterruption(.routeChange), "never continues on the built-in mic")

        devices.inputs = [usb, builtIn]
        interruptions.handle(.availableInputsChanged)
        #expect(interruptions.canResume)
        try interruptions.resume()
        #expect(engine.state == .recording)
        #expect(devices.currentInputID == usb.id)
    }

    @Test func resumeWaitsForTheSessionToBeAvailable() throws {
        let (interruptions, engine, devices) = try recording()
        interruptions.handle(.interruptionBegan)
        interruptions.handle(.interruptionEnded)
        devices.error = AudioDeviceError.inputUnavailable
        #expect(throws: RecordingError.engineUnavailable) { try interruptions.resume() }
        #expect(engine.state == .pausedByInterruption(.interruption))
    }

    @Test func routeChangesContinueOnlyOnTheRecordedInput() throws {
        let (interruptions, engine, devices) = try recording()
        #expect(engine.continuesAfterRouteChange?() == true, "headphones unplugged: the interface still records")
        devices.currentInputID = builtIn.id
        #expect(engine.continuesAfterRouteChange?() == false, "iOS switched to the built-in mic")
        #expect(!interruptions.canResume, "nothing to resume while recording")
    }

    @Test func outputChangesAloneDoNothing() throws {
        let (interruptions, engine, _) = try recording()
        interruptions.handle(.outputDeviceRemoved)
        interruptions.handle(.availableInputsChanged)
        #expect(engine.state == .recording)
    }
}
