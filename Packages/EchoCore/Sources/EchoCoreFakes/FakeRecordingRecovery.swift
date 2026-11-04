import EchoCore
import Foundation

/// Hands out `takes`; `recover` returns a project titled as asked (or throws `recoverError`) and drops the take.
public actor FakeRecordingRecovery: RecordingRecovering {
    public private(set) var takes: [UnfinishedTake]
    public private(set) var recovered: [UUID] = []
    public private(set) var deleted: [UUID] = []
    private let recoverError: RecordingError?

    public init(takes: [UnfinishedTake] = [], recoverError: RecordingError? = nil) {
        self.takes = takes
        self.recoverError = recoverError
    }

    public func unfinishedTakes() async -> [UnfinishedTake] { takes }

    public func recover(_ take: UnfinishedTake, title: String) async throws -> Project {
        if let recoverError { throw recoverError }
        takes.removeAll { $0.id == take.id }
        recovered.append(take.id)
        return Project(
            id: take.id, title: title, mediaType: .audio, origin: .recorded, sourceFileName: "takes/processed.caf",
            sourceInfo: SourceInfo(
                duration: take.duration, container: "com.apple.coreaudio-format", audioCodec: "lpcm", videoCodec: nil,
                byteSize: 0, channelCount: 1, sampleRate: 48_000
            ),
            recording: RecordingMetadata(channelNames: take.session.channelNames, markers: take.session.markers),
            createdAt: take.session.startedAt
        )
    }

    public func delete(_ take: UnfinishedTake) async throws {
        takes.removeAll { $0.id == take.id }
        deleted.append(take.id)
    }
}
