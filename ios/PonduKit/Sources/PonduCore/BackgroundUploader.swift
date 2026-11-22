import Foundation

/// 앱 껍데기(AppDelegate)가 `handleEventsForBackgroundURLSession`에서 부른다.
public enum BackgroundTransfers {
    static let completionHandler = Locked<(() -> Void)?>(nil)

    /// 앱이 백그라운드 전송 때문에 깨어났을 때 시스템이 준 완료 핸들러를 보관한다.
    /// 전송이 모두 끝나면 업로더가 호출한다. `SupabaseBackend`를 앱 시작 때 만들어 두어야 이벤트가 전달된다.
    public static func handleEvents(forSessionIdentifier identifier: String, completion: @escaping () -> Void) {
        guard identifier == BackgroundUploader.identifier else {
            completion()
            return
        }
        completionHandler.withValue { $0 = completion }
    }
}

/// 사진 올리기. 백그라운드 URLSession이라 앱을 닫아도 이어진다.
/// 호출한 쪽의 `await`는 앱이 살아 있는 동안만 결과를 받는다. 앱이 종료됐다 다시 뜨면 전송은 끝까지 가지만
/// 결과 알림은 오지 않으므로, 호출한 쪽은 "서버에 올라갔는지"를 `attach_session_photo` 성공으로 판단하고
/// 대기 중인 사진을 앱 시작 때 다시 올려야 한다(같은 경로에 덮어쓰기라 여러 번 올려도 안전).
final class BackgroundUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let identifier = "kr.pondu.app.upload"

    private var session: URLSession!
    private let waiters = Locked<[Int: CheckedContinuation<Void, Error>]>([:])

    init(identifier: String = BackgroundUploader.identifier) {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = RequestTimeout.photo
        configuration.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// 파일은 전송이 끝날 때까지 지워지면 안 된다(앱 지원 폴더 같은 곳에 둘 것).
    func upload(request: URLRequest, fileURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = session.uploadTask(with: request, fromFile: fileURL)
            waiters.withValue { $0[task.taskIdentifier] = continuation }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation = waiters.withValue({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            continuation.resume(throwing: ErrorMapping.map(error))
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) {
            continuation.resume()
        } else {
            continuation.resume(throwing: ErrorMapping.status(status))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = BackgroundTransfers.completionHandler.withValue { current -> (() -> Void)? in
            defer { current = nil }
            return current
        }
        guard let handler else { return }
        DispatchQueue.main.async { handler() }
    }
}
