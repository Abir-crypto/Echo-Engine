import AVFoundation
import CEchoDSP

/// An in-process effect Audio Unit around a `CEchoDSP` effect (SPEC § 4.5): one input and one output bus with the
/// same mono or stereo float format, processed in place. The render block is the effect's own Objective-C++ block, so
/// rendering never touches Swift. Parameters go through `parameterTree` only and ramp in the kernels. Subclasses
/// name their effect and parameters.
public class EchoEffectAudioUnit: AUAudioUnit {
    class var effectKind: EEEffectKind { fatalError("Subclasses name their effect") }
    class var parameters: [AUParameter] { [] }

    private let effect: EffectHandle
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        effect = EffectHandle(pointer: EEEffectCreate(Self.effectKind))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4_096

        let tree = AUParameterTree.createTree(withChildren: Self.parameters)
        tree.implementorValueObserver = { [effect] parameter, value in
            EEEffectSetParameter(effect.pointer, parameter.address, value)
        }
        tree.implementorValueProvider = { [effect] parameter in
            EEEffectParameter(effect.pointer, parameter.address)
        }
        // Parameters cache their value; start them at the effect's neutral defaults.
        for parameter in tree.allParameters {
            parameter.value = EEEffectParameter(effect.pointer, parameter.address)
        }
        parameterTree = tree
    }

    deinit {
        EEEffectDestroy(effect.pointer)
    }

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    public override var canProcessInPlace: Bool { true }

    /// Frames the effect delays audio by; valid once render resources are allocated.
    public var latencyFrames: Int { Int(EEEffectLatencyFrames(effect.pointer)) }

    public override var latency: TimeInterval {
        Double(latencyFrames) / outputBus.format.sampleRate
    }

    /// Clears delay lines and envelopes at the next render cycle (after a seek or stop). Any thread.
    public func requestReset() {
        EEEffectRequestReset(effect.pointer)
    }

    public override func reset() {
        super.reset()
        requestReset()
    }

    public override func allocateRenderResources() throws {
        let format = outputBus.format
        guard inputBus.format.channelCount == format.channelCount, (1...2).contains(format.channelCount),
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              inputBus.format.sampleRate == format.sampleRate else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        EEEffectPrepare(effect.pointer, format.sampleRate, Int32(format.channelCount), Int32(maximumFramesToRender))
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        EEEffectRenderBlock(effect.pointer)
    }

    static func parameter(
        _ identifier: String,
        address: UInt64,
        range: ClosedRange<AUValue>,
        unit: AudioUnitParameterUnit,
        valueStrings: [String]? = nil
    ) -> AUParameter {
        AUParameterTree.createParameter(
            withIdentifier: identifier,
            name: identifier,
            address: address,
            min: range.lowerBound,
            max: range.upperBound,
            unit: unit,
            unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable, .flag_CanRamp],
            valueStrings: valueStrings,
            dependentParameters: nil
        )
    }
}

/// The effect pointer, shared with the parameter tree's callbacks; the effect is internally thread-safe.
struct EffectHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

extension AudioComponentDescription {
    /// An in-process Echo Engine effect.
    static func echoEffect(subType: String) -> AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCharacterCode(subType),
            componentManufacturer: fourCharacterCode("EchE"),
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    private static func fourCharacterCode(_ text: String) -> FourCharCode {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
