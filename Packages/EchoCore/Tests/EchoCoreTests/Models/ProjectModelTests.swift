import EchoCore
import Foundation
import Testing

struct ProjectModelTests {
    private let created = Date(timeIntervalSince1970: 1_793_000_000)

    private var sourceInfo: SourceInfo {
        SourceInfo(
            duration: 125.5, container: "com.apple.quicktime-movie", audioCodec: "aac ", videoCodec: "hvc1",
            byteSize: 48_000_000, channelCount: 2, sampleRate: 48_000
        )
    }

    private func newProject() -> Project {
        Project(
            title: "Beach vlog", mediaType: .video, origin: .imported,
            sourceFileName: "source.mov", sourceInfo: sourceInfo, createdAt: created
        )
    }

    @Test func newProjectHasOneClipAndTrimCoveringTheFullSource() {
        let project = newProject()
        let full = TimeRangeCodable(start: 0, duration: 125.5)
        #expect(project.schemaVersion == Project.currentSchemaVersion)
        #expect(project.clips.count == 1)
        #expect(project.clips[0].sourceRange == full)
        #expect(project.clips[0].aiStack.isEmpty)
        #expect(project.clips[0].manual == ManualSettings())
        #expect(project.trimRange == full)
        #expect(project.outputLoudness == nil)
        #expect(project.updatedAt == project.createdAt)
    }

    @Test func projectRoundTripsThroughJSON() throws {
        var project = newProject()
        project.clips[0].aiStack = [
            AIOperation(kind: .noiseSuppression, strength: 0.8),
            AIOperation(kind: .clearVoice, strength: 1),
        ]
        project.clips[0].manual.compressor.isEnabled = true
        project.clips[0].manual.eq[2].gainDB = 3.5
        project.trimRange = TimeRangeCodable(start: 4.25, duration: 100)
        project.outputLoudness = .custom(lufs: -18)
        project.basePresetID = UUID()
        project.recording = RecordingMetadata(
            channelNames: ["Host", "Guest 1"],
            markers: [.init(time: 61.5, kind: .interruption)]
        )

        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded == project)
    }

    @Test func missingOptionalPropertiesDecodeAsNil() throws {
        var project = newProject()
        project.outputLoudness = .podcast
        project.basePresetID = UUID()
        project.recording = RecordingMetadata(channelNames: ["Mic"])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        for key in ["outputLoudness", "basePresetID", "recording"] {
            json.removeValue(forKey: key)
        }

        let decoded = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.outputLoudness == nil)
        #expect(decoded.basePresetID == nil)
        #expect(decoded.recording == nil)
    }

    @Test func unknownAIFeatureIsKeptAndWrittenBackUnchanged() throws {
        let json = Data(#"{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","kind":"dereverb","strength":0.5}"#.utf8)
        let operation = try JSONDecoder().decode(AIOperation.self, from: json)
        #expect(operation.kind == .unknown)
        #expect(operation.strength == 0.5)

        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(operation)) as? [String: Any]
        #expect(reencoded?["kind"] as? String == "dereverb")
    }

    @Test func unknownRawValuesDecodeAsUnknown() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode([AIFeature].self, from: Data(#"["dereverb"]"#.utf8)) == [.unknown])
        #expect(try decoder.decode([MediaType].self, from: Data(#"["image"]"#.utf8)) == [.unknown])
        #expect(try decoder.decode([ProjectOrigin].self, from: Data(#"["shared"]"#.utf8)) == [.unknown])
        #expect(try decoder.decode([EQBand.Kind].self, from: Data(#"["notch"]"#.utf8)) == [.unknown])
        #expect(try decoder.decode([RecordingMetadata.Take].self, from: Data(#"["stem"]"#.utf8)) == [.unknown])
        #expect(try decoder.decode([RecordingMetadata.Marker.Kind].self, from: Data(#"["note"]"#.utf8)) == [.unknown])
    }

    @Test func knownRawValuesStillDecode() throws {
        let features = try JSONDecoder().decode([AIFeature].self, from: Data(#"["noiseSuppression","voiceLeveler"]"#.utf8))
        #expect(features == [.noiseSuppression, .voiceLeveler])
    }

    @Test func processedMeansAnyAIStepManualChangeOrLoudnessTarget() {
        #expect(!newProject().isProcessed)

        var withAI = newProject()
        withAI.clips[0].aiStack = [AIOperation(kind: .voiceLeveler, strength: 1)]
        #expect(withAI.isProcessed)

        var withManual = newProject()
        withManual.clips[0].manual.inputGainDB = 2
        #expect(withManual.isProcessed)

        var withLoudness = newProject()
        withLoudness.outputLoudness = .youtube
        #expect(withLoudness.isProcessed)
    }

    @Test func valuesThisVersionCantWriteBackAreDetected() {
        #expect(!newProject().containsUnknownValues)

        var withUnknownOp = newProject()
        withUnknownOp.clips[0].aiStack = [AIOperation(kind: .unknown, strength: 1)]
        #expect(!withUnknownOp.containsUnknownValues, "unknown AI ops keep their raw kind and stay editable")

        var unknownMedia = newProject()
        unknownMedia.mediaType = .unknown
        var unknownBand = newProject()
        unknownBand.clips[0].manual.eq[0].kind = .unknown
        var unknownLoudness = newProject()
        unknownLoudness.outputLoudness = .unknown(kind: "netflix", lufs: -27)
        var unknownMarker = newProject()
        unknownMarker.recording = RecordingMetadata(channelNames: ["Mic"], markers: [.init(time: 1, kind: .unknown)])
        for project in [unknownMedia, unknownBand, unknownLoudness, unknownMarker] {
            #expect(project.containsUnknownValues)
        }
    }

    @Test func manualSettingsDefaultToNeutral() {
        let manual = ManualSettings()
        #expect(manual.inputGainDB == 0)
        #expect(manual.pitchSemitones == 0)
        #expect(!manual.gate.isEnabled)
        #expect(!manual.deEsser.isEnabled)
        #expect(!manual.compressor.isEnabled)
        #expect(!manual.reverb.isEnabled)
        #expect(manual.limiter.ceilingDB == -1)
        #expect(manual.eq.map(\.kind) == [.lowShelf, .peaking, .peaking, .peaking, .peaking, .highShelf])
        #expect(manual.eq.allSatisfy { $0.gainDB == 0 })
    }
}

struct LoudnessTargetTests {
    @Test func platformTargetsMatchSpec() {
        #expect([LoudnessTarget.youtube, .instagram, .tiktok, .spotify].allSatisfy { $0.lufs == -14 })
        #expect([LoudnessTarget.podcast, .appleMusic].allSatisfy { $0.lufs == -16 })
        #expect(LoudnessTarget.custom(lufs: -20).lufs == -20)
        #expect(LoudnessTarget.truePeakCeiling == -1)
    }

    @Test(arguments: [
        LoudnessTarget.youtube, .instagram, .tiktok, .spotify, .podcast, .appleMusic, .custom(lufs: -23),
        .unknown(kind: "netflix", lufs: -27),
    ])
    func roundTripsThroughJSON(_ target: LoudnessTarget) throws {
        #expect(try JSONDecoder().decode(LoudnessTarget.self, from: JSONEncoder().encode(target)) == target)
    }

    @Test func unknownPlatformKeepsItsKindAndLoudness() throws {
        let json = Data(#"{"kind":"netflix","lufs":-27}"#.utf8)
        let target = try JSONDecoder().decode(LoudnessTarget.self, from: json)
        #expect(target == .unknown(kind: "netflix", lufs: -27))
        #expect(target.lufs == -27)
        #expect(target.isUnknown)

        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any]
        #expect(reencoded?["kind"] as? String == "netflix")
    }

    @Test func unknownPlatformWithoutLoudnessFailsToDecode() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LoudnessTarget.self, from: Data(#"{"kind":"netflix"}"#.utf8))
        }
    }
}
