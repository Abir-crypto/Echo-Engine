import AudioToolbox
import CEchoDSP
@testable import EchoCore
import EchoAudioUnits
import Testing

struct ManualChainParameterTests {
    private let unit = try! ManualChainAudioUnit(componentDescription: ManualChainAudioUnit.componentDescription)

    @Test func everySettingsParameterIsSetExactlyOnce() {
        let addresses = ManualSettings().manualChainParameterValues.map(\.address)
        let settingsAddresses = (0..<EEManualChainParameter.count.rawValue).filter { $0 != EEManualChainParameter.bypass.rawValue }
        #expect(addresses.sorted() == settingsAddresses, "bypass is Hold for original, not a setting")
        #expect(unit.parameterTree?.allParameters.count == Int(EEManualChainParameter.count.rawValue))
    }

    @Test func theAudioUnitStartsAtTheModelsDefaults() throws {
        let tree = try #require(unit.parameterTree)
        for (address, value) in ManualSettings().manualChainParameterValues {
            #expect(tree.parameter(withAddress: address)?.value == value, "address \(address)")
        }
    }

    @Test func theModelsRangesFitTheParameters() throws {
        typealias P = EEManualChainParameter
        let tree = try #require(unit.parameterTree)
        func fits(_ range: ClosedRange<Float>, _ address: UInt64) -> Bool {
            guard let parameter = tree.parameter(withAddress: address) else { return false }
            return parameter.minValue <= range.lowerBound && range.upperBound <= parameter.maxValue
        }
        #expect(fits(ManualSettings.inputGainRange, P.inputGain.rawValue))
        #expect(fits(ManualSettings.pitchRange, P.pitchSemitones.rawValue))
        #expect(fits(ManualSettings.Gate.thresholdRange, P.gateThreshold.rawValue))
        #expect(fits(ManualSettings.DeEsser.frequencyRange, P.deEsserFrequency.rawValue))
        #expect(fits(ManualSettings.Gate.attenuationRange, P.gateRange.rawValue))
        #expect(fits(ManualSettings.Gate.attackRange, P.gateAttack.rawValue))
        #expect(fits(ManualSettings.Gate.releaseRange, P.gateRelease.rawValue))
        #expect(fits(ManualSettings.unitRange, P.deEsserAmount.rawValue))
        #expect(fits(ManualSettings.Compressor.ratioRange, P.compressorRatio.rawValue))
        #expect(fits(ManualSettings.Compressor.thresholdRange, P.compressorThreshold.rawValue))
        #expect(fits(ManualSettings.Compressor.attackRange, P.compressorAttack.rawValue))
        #expect(fits(ManualSettings.Compressor.releaseRange, P.compressorRelease.rawValue))
        #expect(fits(ManualSettings.Compressor.makeupRange, P.compressorMakeup.rawValue))
        for address in [P.reverbRoomSize, .reverbDamping, .reverbMix] {
            #expect(fits(ManualSettings.unitRange, address.rawValue))
        }
        #expect(fits(EQBand.frequencyRange, ManualChainAudioUnit.eqAddress(band: 3, field: .frequency)))
        #expect(fits(EQBand.gainRange, ManualChainAudioUnit.eqAddress(band: 3, field: .gain)))
        #expect(fits(EQBand.qRange, ManualChainAudioUnit.eqAddress(band: 3, field: .Q)))

        let limiter = try OutputLimiterAudioUnit(componentDescription: OutputLimiterAudioUnit.componentDescription)
        let ceiling = try #require(limiter.parameterTree?.parameter(withAddress: EEOutputLimiterParameter.ceiling.rawValue))
        #expect(ceiling.minValue == ManualSettings.Limiter.ceilingRange.lowerBound)
        #expect(ceiling.maxValue == ManualSettings.Limiter.ceilingRange.upperBound)
        #expect(ceiling.value == ManualSettings.Limiter().ceilingDB)
    }

    @Test func unknownAndMissingEQBandsAreBypassed() {
        var manual = ManualSettings()
        manual.eq = [EQBand(kind: .unknown, frequencyHz: 500, q: 1)]
        let values = Dictionary(uniqueKeysWithValues: manual.manualChainParameterValues.map { ($0.address, $0.value) })
        let bypass = AUValue(EEEQBandKind.bypass.rawValue)
        #expect(values[ManualChainAudioUnit.eqAddress(band: 0, field: .kind)] == bypass)
        #expect(values[ManualChainAudioUnit.eqAddress(band: 5, field: .kind)] == bypass)
    }

    @Test func parameterChangesAreReadBack() throws {
        let gain = try #require(unit.parameterTree?.parameter(withAddress: EEManualChainParameter.inputGain.rawValue))
        gain.value = 7.5
        #expect(gain.value == 7.5)
    }
}

extension ManualChainParameterTests {
    @Test func bypassStartsOff() throws {
        let tree = try #require(unit.parameterTree)
        #expect(tree.parameter(withAddress: EEManualChainParameter.bypass.rawValue)?.value == 0)
        let limiter = try OutputLimiterAudioUnit(componentDescription: OutputLimiterAudioUnit.componentDescription)
        #expect(limiter.parameterTree?.parameter(withAddress: EEOutputLimiterParameter.bypass.rawValue)?.value == 0)
    }
}
