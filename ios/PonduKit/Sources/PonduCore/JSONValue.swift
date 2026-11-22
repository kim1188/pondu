import Foundation

/// 서버 함수 인자와 임의 JSON을 담는 값.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "지원하지 않는 JSON 값")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - 만들기 편의

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    /// nil이면 `.null`.
    public static func optional(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }
    public static func optional(_ value: UUID?) -> JSONValue { value.map { .string($0.uuidString.lowercased()) } ?? .null }
    public static func optional(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
    public static func optional(_ value: Date?) -> JSONValue { value.map { .string(PonduJSON.formatDate($0)) } ?? .null }

    public static func uuid(_ value: UUID) -> JSONValue { .string(value.uuidString.lowercased()) }
    public static func date(_ value: Date) -> JSONValue { .string(PonduJSON.formatDate(value)) }
    public static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
    public static func strings(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }
}

// MARK: - 공용 JSON 코덱

/// 서버와 주고받는 JSON의 규칙(snake_case, ISO 8601 UTC 시각)을 한 곳에 둔다.
public enum PonduJSON {
    /// 서버가 주는 시각: `2026-11-22T10:15:30.123456+00:00`, `...Z`, 소수 없는 형태.
    public static func parseDate(_ text: String) -> Date? {
        let normalized = truncateFraction(text)
        if let date = fractionalFormatter.date(from: normalized) { return date }
        return plainFormatter.date(from: normalized)
    }

    public static func formatDate(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    /// `2026-11-22` 형태의 날짜(`date` 열).
    public static func parseDay(_ text: String) -> Date? {
        dayFormatter.date(from: text)
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let last = keys.last!
            // 분야 이름을 키로 쓰는 사전(estimate_factors, by_category)은 그대로 둔다.
            if last.intValue == nil, categoryRawValues.contains(last.stringValue) { return last }
            return AnyKey(stringValue: camelCase(last.stringValue)) ?? last
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = PonduJSON.parseDate(text) ?? PonduJSON.parseDay(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "시각 형식을 읽을 수 없음: \(text)")
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PonduJSON.formatDate(date))
        }
        return encoder
    }

    /// 인코딩 가능한 값을 인자용 JSONValue로 바꾼다.
    public static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try makeEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: 내부

    private static let categoryRawValues = Set(Category.allCases.map(\.rawValue))

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func camelCase(_ key: String) -> String {
        guard key.contains("_") else { return key }
        let parts = key.split(separator: "_", omittingEmptySubsequences: true)
        guard let first = parts.first else { return key }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// 소수 자릿수를 3자리로 맞춘다(ISO8601DateFormatter가 6자리를 못 읽는 경우 대비).
    private static func truncateFraction(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return text }
        var end = text.index(after: dot)
        while end < text.endIndex, text[end].isASCII, text[end].isNumber { end = text.index(after: end) }
        let digits = text[text.index(after: dot)..<end]
        guard digits.count != 3 else { return text }
        let fixed = String((digits + "000").prefix(3))
        return String(text[..<dot]) + "." + fixed + String(text[end...])
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
