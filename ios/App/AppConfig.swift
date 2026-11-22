import Foundation
import PonduCore

/// 빌드 설정(xcconfig → Info.plist)에서 프로젝트 주소와 공개용 키를 읽는다. 관리자 키는 앱에 없다.
struct AppConfig {
    let backend: BackendConfig

    enum LoadError: Error {
        case missing
        case invalidURL
    }

    static func load(bundle: Bundle = .main) -> Result<AppConfig, LoadError> {
        let urlText = (bundle.object(forInfoDictionaryKey: "PonduSupabaseURL") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = (bundle.object(forInfoDictionaryKey: "PonduSupabaseAnonKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !urlText.isEmpty, !key.isEmpty, !urlText.contains("YOUR-PROJECT-REF"), !key.contains("YOUR-PUBLIC") else {
            return .failure(.missing)
        }
        guard let url = URL(string: urlText), url.scheme == "https", url.host != nil else { return .failure(.invalidURL) }
        return .success(AppConfig(backend: BackendConfig(url: url, anonKey: key)))
    }
}
