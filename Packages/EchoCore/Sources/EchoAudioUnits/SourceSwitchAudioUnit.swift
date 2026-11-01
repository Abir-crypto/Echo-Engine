import AVFoundation
import CEchoDSP

/// Two inputs, one output: crossfades from one preview player to the other over 20 ms (SPEC § 6.3, § 6.6), starting
/// at an exact render sample time.
public final class SourceSwitchAudioUnit: AUAudioUnit {
    public static let componentDescription = AudioComponentDescription.echoEffect(subType: "ecSW")

    private let source: SwitchHandle
    private let inputs: [AUAudioUnitBus]
    private let outputBus: AUAudioUnitBus
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        source = SwitchHandle(pointer: EESourceSwitchCreate())
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputs = try [AUAudioUnitBus(format: format), AUAudioUnitBus(format: format)]
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: inputs)
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4_096

        let parameter = AUParameterTree.createParameter(
            withIdentifier: "source", name: "source", address: EESourceSwitchParameter.source.rawValue,
            min: 0, max: 1, unit: .indexed, unitName: nil, flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil, dependentParameters: nil
        )
        let tree = AUParameterTree.createTree(withChildren: [parameter])
        tree.implementorValueObserver = { [source] _, value in EESourceSwitchSetSource(source.pointer, value) }
        tree.implementorValueProvider = { [source] _ in EESourceSwitchSource(source.pointer) }
        parameterTree = tree
    }

    deinit {
        EESourceSwitchDestroy(source.pointer)
    }

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    public override func allocateRenderResources() throws {
        let format = outputBus.format
        guard (1...2).contains(format.channelCount), format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              inputs.allSatisfy({ $0.format == format }) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        EESourceSwitchPrepare(source.pointer, format.sampleRate, Int32(format.channelCount), Int32(maximumFramesToRender))
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        EESourceSwitchRenderBlock(source.pointer)
    }

    /// Fades to `input` (0 or 1) starting at `sampleTime` on the engine's render timeline.
    public func crossfade(to input: Int, at sampleTime: AUEventSampleTime) {
        scheduleParameterBlock(sampleTime, 0, EESourceSwitchParameter.source.rawValue, AUValue(input))
    }

    /// Switches at the next render cycle, still with the crossfade (playback stopped or no exact time needed).
    public func select(_ input: Int) {
        parameterTree?.parameter(withAddress: EESourceSwitchParameter.source.rawValue)?.value = AUValue(input)
    }
}

struct SwitchHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}
