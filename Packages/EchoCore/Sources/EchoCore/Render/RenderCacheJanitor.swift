import Foundation

/// Keeps a project's render cache to what undo/redo can reach (SPEC § 4.3, § 6.4).
public protocol RenderCacheJanitoring: Sendable {
    /// Mark and sweep after a stack or history change: keeps the renders of every prefix of `current` and of every
    /// `history` state, deletes the rest. Over budget, deletes the oldest history states' renders first (never the
    /// current state's). `history` is oldest first (`EditHistory.allStates`).
    func sweep(projectID: UUID, sourceRange: TimeRangeCodable, current: EditState, history: [EditState]) async throws
    /// On project close: only the current state's prefixes stay.
    func prune(projectID: UUID, sourceRange: TimeRangeCodable, current: EditState) async throws
}

public actor RenderCacheJanitor: RenderCacheJanitoring {
    /// Reachable renders may use at most this much, or 10 % of the free space if that is less (SPEC § 6.4).
    public static let maximumBytes: Int64 = 2_000_000_000

    private let cache: any RenderCaching
    private let storage: any StorageEstimating
    private let waveforms: any WaveformProviding

    public init(cache: any RenderCaching, storage: any StorageEstimating, waveforms: any WaveformProviding) {
        self.cache = cache
        self.storage = storage
        self.waveforms = waveforms
    }

    public func sweep(projectID: UUID, sourceRange: TimeRangeCodable, current: EditState, history: [EditState]) async throws {
        let keep = keys(of: current, projectID: projectID, sourceRange: sourceRange)
        let historyKeys = history.map { keys(of: $0, projectID: projectID, sourceRange: sourceRange) }
        let reachable = historyKeys.reduce(keep) { $0.union($1) }

        let entries = try await cache.entries(projectID: projectID)
        try await remove(Set(entries.map(\.key)).subtracting(reachable), projectID: projectID)

        var sizes = Dictionary(entries.filter { reachable.contains($0.key) }.map { ($0.key, $0.bytes) }, uniquingKeysWith: max)
        var total = sizes.values.reduce(0, +)
        let budget = self.budget()
        var index = 0
        while total > budget, index < historyKeys.count {
            // Evict this state's renders unless the current state or a newer history state still needs them.
            let stillNeeded = historyKeys[(index + 1)...].reduce(keep) { $0.union($1) }
            let evict = historyKeys[index].subtracting(stillNeeded).filter { sizes[$0] != nil }
            try await remove(evict, projectID: projectID)
            for key in evict {
                total -= sizes.removeValue(forKey: key) ?? 0
            }
            index += 1
        }
    }

    public func prune(projectID: UUID, sourceRange: TimeRangeCodable, current: EditState) async throws {
        let keep = keys(of: current, projectID: projectID, sourceRange: sourceRange)
        let entries = try await cache.entries(projectID: projectID)
        try await remove(Set(entries.map(\.key)).subtracting(keep), projectID: projectID)
    }

    /// Renders and their waveform peaks go together.
    private func remove(_ keys: Set<RenderKey>, projectID: UUID) async throws {
        guard !keys.isEmpty else { return }
        try await cache.remove(keys, projectID: projectID)
        try? await waveforms.remove(keys: Set(keys.map(\.waveformKey)), projectID: projectID)
    }

    private func keys(of state: EditState, projectID: UUID, sourceRange: TimeRangeCodable) -> Set<RenderKey> {
        Set(RenderKey.prefixes(projectID: projectID, sourceRange: sourceRange, operations: state.aiStack))
    }

    /// min(2 GB, 10 % of free space); 2 GB when the free space can't be read.
    private func budget() -> Int64 {
        guard let available = try? storage.availableBytes() else { return Self.maximumBytes }
        return min(Self.maximumBytes, available / 10)
    }
}
