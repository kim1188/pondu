import Foundation

/// SDK와 URLSession이 던지는 오류를 `BackendError`로 바꾼다.
/// SDK 오류 타입의 세부 모양(PostgrestError, AuthError, FunctionsError)에 기대지 않고,
/// 서버가 `message`로 보낸 코드 문자열을 찾는 방식이라 SDK 버전이 바뀌어도 동작한다.
enum ErrorMapping {
    /// 긴 코드부터 비교해야 `request_not_found`가 `not_found`로 읽히지 않는다.
    private static let codesLongestFirst = BackendError.contractCodes.sorted { $0.count > $1.count }

    static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let backendError = error as? BackendError { return backendError }
        if let urlError = error as? URLError { return map(urlError) }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return map(URLError(URLError.Code(rawValue: nsError.code))) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? URLError { return map(underlying) }

        if let code = serverCode(in: error) { return BackendError(code: code) }
        return BackendError.unknown
    }

    static func map(_ urlError: URLError) -> Error {
        switch urlError.code {
        case .cancelled: return CancellationError()
        case .timedOut: return BackendError.timeout
        default: return BackendError.network
        }
    }

    /// 로그인(메일 코드) 단계의 오류.
    static func mapAuth(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let backendError = error as? BackendError { return backendError }
        if let urlError = error as? URLError { return map(urlError) }
        let text = String(describing: error).lowercased() + " " + error.localizedDescription.lowercased()
        if text.contains("nsurlerrordomain") || text.contains("offline") || text.contains("network connection") {
            return BackendError.network
        }
        if text.contains("korea.ac.kr") || text.contains("가입할 수") || text.contains("email_domain_not_allowed")
            || text.contains("before_user_created") || text.contains("hook") {
            return BackendError(code: "email_domain_not_allowed")
        }
        if text.contains("expired") { return BackendError(code: "otp_expired") }
        if text.contains("rate") && text.contains("limit") || text.contains("too many") || text.contains("429") || text.contains("security purposes") {
            return BackendError(code: "rate_limited")
        }
        if text.contains("invalid") || text.contains("token") || text.contains("otp") {
            return BackendError(code: "otp_invalid")
        }
        return BackendError.unknown
    }

    /// PostgrestError 같은 오류에서 서버가 보낸 코드(`raise exception using message = '<코드>'`)를 찾는다.
    static func serverCode(in error: Error) -> String? {
        for child in Mirror(reflecting: error).children where child.label == "message" {
            if let message = child.value as? String, let code = knownCode(inText: message) { return code }
        }
        return knownCode(inText: String(describing: error))
    }

    static func knownCode(inText text: String) -> String? {
        codesLongestFirst.first { text.contains($0) }
    }

    /// 서버 함수(HTTP)의 응답 본문에서 코드를 찾는다. `{"error": "quota_exceeded"}`, `{"code": ...}`, 중첩 모두 허용.
    static func code(inBody data: Data) -> String? {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            var strings: [String] = []
            collect(value, into: &strings)
            if let exact = strings.first(where: { BackendError.contractCodes.contains($0) }) { return exact }
            if let contained = strings.compactMap({ knownCode(inText: $0) }).first { return contained }
        }
        return String(data: data, encoding: .utf8).flatMap { knownCode(inText: $0) }
    }

    private static func collect(_ value: JSONValue, into strings: inout [String]) {
        switch value {
        case .string(let text): strings.append(text)
        case .array(let items): items.forEach { collect($0, into: &strings) }
        case .object(let dict): dict.values.forEach { collect($0, into: &strings) }
        default: break
        }
    }

    /// HTTP 응답이 실패면 오류를 던진다.
    static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw BackendError.unknown }
        guard !(200..<300).contains(http.statusCode) else { return }
        if let code = code(inBody: body) { throw BackendError(code: code) }
        throw status(http.statusCode)
    }

    static func status(_ statusCode: Int) -> BackendError {
        switch statusCode {
        case 401: return BackendError(code: "not_authenticated")
        case 403: return BackendError(code: "forbidden")
        case 404: return BackendError(code: "not_found")
        case 429: return BackendError(code: "rate_limited")
        case 408, 504: return BackendError.timeout
        default: return BackendError.unknown
        }
    }
}
