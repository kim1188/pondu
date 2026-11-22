import UIKit
import PonduCore

/// 백그라운드 사진 올리기가 끝났을 때 앱이 깨어나는 경로만 맡는다.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundTransfers.handleEvents(forSessionIdentifier: identifier, completion: completionHandler)
    }
}
