import EchoCore
import Foundation

/// Records delivered files and answers with `outcome`, or fails.
public actor FakeExportDestination: ExportDestination {
    public nonisolated let kind: DestinationKind
    public private(set) var delivered: [URL] = []
    public var outcome: DeliveryOutcome
    public var error: (any Error)?

    public init(kind: DestinationKind, outcome: DeliveryOutcome = .delivered) {
        self.kind = kind
        self.outcome = outcome
    }

    public func setOutcome(_ outcome: DeliveryOutcome) { self.outcome = outcome }
    public func setError(_ error: (any Error)?) { self.error = error }

    public func deliver(_ file: URL) async throws -> DeliveryOutcome {
        if let error { throw error }
        delivered.append(file)
        return outcome
    }
}
