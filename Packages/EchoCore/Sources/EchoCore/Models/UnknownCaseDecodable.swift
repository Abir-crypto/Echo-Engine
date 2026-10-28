/// A persisted string enum that decodes raw values written by newer app versions as `.unknown`
/// instead of failing, so older versions can still open the project (SPEC § 5.3).
public protocol UnknownCaseDecodable: RawRepresentable<String>, Decodable {
    static var unknown: Self { get }
}

extension UnknownCaseDecodable {
    public init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}
