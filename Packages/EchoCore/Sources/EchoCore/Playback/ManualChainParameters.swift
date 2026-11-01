import AudioToolbox
import CEchoDSP
import EchoAudioUnits

extension ManualSettings {
    /// The manual chain's parameter values (SPEC § 8) by `EEManualChainParameter` address. Missing EQ bands are
    /// bypassed; bands past the sixth are ignored.
    var manualChainParameterValues: [(address: AUParameterAddress, value: AUValue)] {
        typealias P = EEManualChainParameter
        var values: [(address: AUParameterAddress, value: AUValue)] = [
            (P.inputGain.rawValue, inputGainDB),
            (P.gateEnabled.rawValue, gate.isEnabled ? 1 : 0),
            (P.gateThreshold.rawValue, gate.thresholdDB),
            (P.gateRange.rawValue, gate.rangeDB),
            (P.gateAttack.rawValue, gate.attackMs),
            (P.gateRelease.rawValue, gate.releaseMs),
            (P.deEsserEnabled.rawValue, deEsser.isEnabled ? 1 : 0),
            (P.deEsserFrequency.rawValue, deEsser.frequencyHz),
            (P.deEsserAmount.rawValue, deEsser.amount),
            (P.compressorEnabled.rawValue, compressor.isEnabled ? 1 : 0),
            (P.compressorThreshold.rawValue, compressor.thresholdDB),
            (P.compressorRatio.rawValue, compressor.ratio),
            (P.compressorAttack.rawValue, compressor.attackMs),
            (P.compressorRelease.rawValue, compressor.releaseMs),
            (P.compressorMakeup.rawValue, compressor.makeupDB),
            (P.pitchSemitones.rawValue, pitchSemitones),
            (P.reverbEnabled.rawValue, reverb.isEnabled ? 1 : 0),
            (P.reverbRoomSize.rawValue, reverb.roomSize),
            (P.reverbDamping.rawValue, reverb.damping),
            (P.reverbMix.rawValue, reverb.mix),
        ]
        for index in 0..<Int(P.eqBandCount.rawValue) {
            let band = index < eq.count ? eq[index] : nil
            values += [
                (ManualChainAudioUnit.eqAddress(band: index, field: .kind), band.map { AUValue($0.kind.parameterValue.rawValue) } ?? AUValue(EEEQBandKind.bypass.rawValue)),
                (ManualChainAudioUnit.eqAddress(band: index, field: .frequency), band?.frequencyHz ?? 1_000),
                (ManualChainAudioUnit.eqAddress(band: index, field: .gain), band?.gainDB ?? 0),
                (ManualChainAudioUnit.eqAddress(band: index, field: .Q), band?.q ?? 1),
            ]
        }
        return values
    }
}

extension EQBand.Kind {
    var parameterValue: EEEQBandKind {
        switch self {
        case .lowShelf: .lowShelf
        case .peaking: .peaking
        case .highShelf: .highShelf
        case .unknown: .bypass
        }
    }
}
