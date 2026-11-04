import EchoCore
import Foundation

/// Returns an audio project for the take (or throws `error`) and remembers each call.
public actor FakeRecordedProjectBuilder: RecordedProjectBuilding {
    public struct Call: Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let session: TakeSession
        public let editingSource: RecordingMetadata.Take
    }

    public private(set) var calls: [Call] = []
    private let error: RecordingError?

    public init(error: RecordingError? = nil) {
        self.error = error
    }

    public func buildProject(id: UUID, title: String, session: TakeSession, editingSource: RecordingMetadata.Take) async throws -> Project {
        calls.append(Call(id: id, title: title, session: session, editingSource: editingSource))
        if let error { throw error }
        return Project(
            id: id, title: title, mediaType: .audio, origin: .recorded, sourceFileName: "takes/processed.caf",
            sourceInfo: SourceInfo(
                duration: 1, container: "com.apple.coreaudio-format", audioCodec: "lpcm", videoCodec: nil, byteSize: 0,
                channelCount: 1, sampleRate: 48_000
            ),
            recording: RecordingMetadata(
                channelNames: session.channelNames, editingSource: editingSource, markers: session.markers,
                parameterChanges: session.parameterChanges
            ),
            createdAt: session.startedAt
        )
    }
}
