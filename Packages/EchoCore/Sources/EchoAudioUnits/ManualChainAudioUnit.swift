import AVFoundation
import CEchoDSP

/// The live manual chain (SPEC § 8): input gain → gate → EQ → de-esser → compressor → pitch shift → reverb. The limiter
/// is `OutputLimiterAudioUnit`, after Auto Level. Parameter addresses are `EEManualChainParameter`.
public final class ManualChainAudioUnit: EchoEffectAudioUnit {
    public static let componentDescription = AudioComponentDescription.echoEffect(subType: "ecMC")

    override class var effectKind: EEEffectKind { .manualChain }

    /// The address of an EQ band's field.
    public static func eqAddress(band: Int, field: EEEQBandField) -> AUParameterAddress {
        EEManualChainParameter.eqFirst.rawValue + UInt64(band) * EEManualChainParameter.eqStride.rawValue + field.rawValue
    }

    override class var parameters: [AUParameter] {
        typealias P = EEManualChainParameter
        let toggle: ClosedRange<AUValue> = 0...1
        var parameters = [
            parameter("inputGain", address: P.inputGain.rawValue, range: -24...24, unit: .decibels),
            parameter("gateEnabled", address: P.gateEnabled.rawValue, range: toggle, unit: .boolean),
            parameter("gateThreshold", address: P.gateThreshold.rawValue, range: -80...0, unit: .decibels),
            parameter("gateRange", address: P.gateRange.rawValue, range: -80...0, unit: .decibels),
            parameter("gateAttack", address: P.gateAttack.rawValue, range: 0.1...100, unit: .milliseconds),
            parameter("gateRelease", address: P.gateRelease.rawValue, range: 5...2_000, unit: .milliseconds),
            parameter("deEsserEnabled", address: P.deEsserEnabled.rawValue, range: toggle, unit: .boolean),
            parameter("deEsserFrequency", address: P.deEsserFrequency.rawValue, range: 4_000...10_000, unit: .hertz),
            parameter("deEsserAmount", address: P.deEsserAmount.rawValue, range: 0...1, unit: .generic),
            parameter("compressorEnabled", address: P.compressorEnabled.rawValue, range: toggle, unit: .boolean),
            parameter("compressorThreshold", address: P.compressorThreshold.rawValue, range: -60...0, unit: .decibels),
            parameter("compressorRatio", address: P.compressorRatio.rawValue, range: 1...20, unit: .ratio),
            parameter("compressorAttack", address: P.compressorAttack.rawValue, range: 0.1...200, unit: .milliseconds),
            parameter("compressorRelease", address: P.compressorRelease.rawValue, range: 5...2_000, unit: .milliseconds),
            parameter("compressorMakeup", address: P.compressorMakeup.rawValue, range: 0...24, unit: .decibels),
            parameter("pitchSemitones", address: P.pitchSemitones.rawValue, range: -12...12, unit: .relativeSemiTones),
            parameter("reverbEnabled", address: P.reverbEnabled.rawValue, range: toggle, unit: .boolean),
            parameter("reverbRoomSize", address: P.reverbRoomSize.rawValue, range: 0...1, unit: .generic),
            parameter("reverbDamping", address: P.reverbDamping.rawValue, range: 0...1, unit: .generic),
            parameter("reverbMix", address: P.reverbMix.rawValue, range: 0...1, unit: .generic),
            parameter("bypass", address: P.bypass.rawValue, range: toggle, unit: .boolean),
        ]
        for band in 0..<Int(P.eqBandCount.rawValue) {
            parameters += [
                parameter("eq\(band)Kind", address: eqAddress(band: band, field: .kind), range: 0...3, unit: .indexed,
                          valueStrings: ["lowShelf", "peaking", "highShelf", "bypass"]),
                parameter("eq\(band)Frequency", address: eqAddress(band: band, field: .frequency), range: 20...20_000, unit: .hertz),
                parameter("eq\(band)Gain", address: eqAddress(band: band, field: .gain), range: -18...18, unit: .decibels),
                parameter("eq\(band)Q", address: eqAddress(band: band, field: .Q), range: 0.3...8, unit: .generic),
            ]
        }
        return parameters
    }
}

/// Auto Level gain, then the final look-ahead true-peak limiter (SPEC § 6.6, § 6.7, § 8): ceiling −6…0 dB, always on.
public final class OutputLimiterAudioUnit: EchoEffectAudioUnit {
    public static let componentDescription = AudioComponentDescription.echoEffect(subType: "ecLM")

    override class var effectKind: EEEffectKind { .outputLimiter }

    override class var parameters: [AUParameter] {
        [
            parameter("ceiling", address: EEOutputLimiterParameter.ceiling.rawValue, range: -6...0, unit: .decibels),
            parameter("bypass", address: EEOutputLimiterParameter.bypass.rawValue, range: 0...1, unit: .boolean),
            parameter("autoLevelGain", address: EEOutputLimiterParameter.gain.rawValue, range: -20...20, unit: .decibels),
        ]
    }
}

public enum EchoAudioUnits {
    /// Registers the effects in-process so `AVAudioUnitEffect(audioComponentDescription:)` can create them. Idempotent.
    public static func register() {
        _ = registration
    }

    private static let registration: Void = {
        AUAudioUnit.registerSubclass(
            ManualChainAudioUnit.self, as: ManualChainAudioUnit.componentDescription, name: "Echo Engine: Manual chain", version: 1
        )
        AUAudioUnit.registerSubclass(
            OutputLimiterAudioUnit.self, as: OutputLimiterAudioUnit.componentDescription, name: "Echo Engine: Limiter", version: 1
        )
        AUAudioUnit.registerSubclass(
            SourceSwitchAudioUnit.self, as: SourceSwitchAudioUnit.componentDescription, name: "Echo Engine: Source switch", version: 1
        )
    }()
}
