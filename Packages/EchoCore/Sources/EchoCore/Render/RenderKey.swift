import CryptoKit
import Foundation

/// Identifies the render of one prefix of a clip's AI stack (SPEC § 6.3): SHA-256 of the project ID, the source range
/// and the ordered `kind:strength` of the operations. Operation IDs aren't part of it, so undo finds the same render.
public struct RenderKey: Hashable, Sendable, Codable, CustomStringConvertible {
    /// 64 lowercase hex digits.
    public let hash: String

    public init(projectID: UUID, sourceRange: TimeRangeCodable, operations: some Collection<AIOperation>) {
        let range = "\(Self.number(sourceRange.start, digits: 6)),\(Self.number(sourceRange.duration, digits: 6))"
        let ops = operations.map { "\($0.kind.rawValue):\(Self.number(Double($0.strength), digits: 4))" }
        let text = "\(projectID.uuidString.lowercased())|\(range)|\(ops.joined(separator: ";"))"
        hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A key read back from a cache file name.
    public init?(hash: String) {
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.hash = hash
    }

    /// The keys of every prefix `operations[0...i]`, first operation first.
    public static func prefixes(projectID: UUID, sourceRange: TimeRangeCodable, operations: [AIOperation]) -> [RenderKey] {
        operations.indices.map { RenderKey(projectID: projectID, sourceRange: sourceRange, operations: operations[...$0]) }
    }

    public var description: String { hash }

    /// The waveform cache key of this render's peaks.
    public var waveformKey: String { "render-\(hash)" }

    /// Fixed decimals with a "." in every locale, so keys never depend on the device's settings.
    private static func number(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
