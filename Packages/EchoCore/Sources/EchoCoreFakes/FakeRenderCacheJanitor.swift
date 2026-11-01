import EchoCore
import Foundation

/// Deletes nothing; records each call.
public actor FakeRenderCacheJanitor: RenderCacheJanitoring {
    public private(set) var sweeps: [(current: EditState, history: [EditState])] = []
    public private(set) var prunes: [EditState] = []

    public init() {}

    public func sweep(projectID: UUID, sourceRange: TimeRangeCodable, current: EditState, history: [EditState]) {
        sweeps.append((current, history))
    }

    public func prune(projectID: UUID, sourceRange: TimeRangeCodable, current: EditState) {
        prunes.append(current)
    }
}
