import SwiftUI
import UIKit
import ImageIO

/// 사진 경로 → 화면용 이미지. 디스크 캐시, 같은 경로 요청 합치기, 메모리 캐시를 맡는다.
/// 서명 주소는 캐시에 없을 때만 발급한다. 사진은 수정되지 않으므로 만료 없이 보관한다.
public final class ImageLoader: @unchecked Sendable {
    private let backend: Backend
    public let diskCache: DiskCache
    private let session: URLSession
    private let flight = InFlight<String, Data>()
    private let memory = NSCache<NSString, UIImage>()

    public init(backend: Backend, diskCache: DiskCache = DiskCache(), session: URLSession? = nil) {
        self.backend = backend
        self.diskCache = diskCache
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = RequestTimeout.standard
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration)
        memory.countLimit = 120
    }

    /// 경로로 이미지를 얻는다. 호출한 작업이 취소되면(화면을 벗어나면) CancellationError.
    public func image(forPath path: String, maxPixelSize: CGFloat = 1600) async throws -> UIImage {
        let cacheKey = "\(path)#\(Int(maxPixelSize))" as NSString
        if let cached = memory.object(forKey: cacheKey) { return cached }

        let data = try await imageData(forPath: path)
        try Task.checkCancellation()
        guard let image = Self.downsample(data, maxPixelSize: maxPixelSize) else { throw BackendError.unknown }
        memory.setObject(image, forKey: cacheKey)
        return image
    }

    public func clearCaches() {
        memory.removeAllObjects()
        diskCache.removeAll()
    }

    private func imageData(forPath path: String) async throws -> Data {
        if let data = diskCache.data(forKey: path) { return data }
        let backend = self.backend
        let session = self.session
        let diskCache = self.diskCache
        return try await flight.run(key: path) {
            let url = try await backend.signedURL(path: path)
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw BackendError.unknown
            }
            diskCache.store(data, forKey: path)
            return data
        }
    }

    /// 화면 크기에 맞게 줄여서 읽는다. 원본 크기로 펼치지 않아 메모리를 아낀다.
    static func downsample(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct ImageLoaderKey: EnvironmentKey {
    static let defaultValue: ImageLoader? = nil
}

extension EnvironmentValues {
    /// 앱 껍데기가 `.environment(\.imageLoader, ...)`로 넣는다. 없으면 `RemoteImage`는 자리표시만 그린다.
    public var imageLoader: ImageLoader? {
        get { self[ImageLoaderKey.self] }
        set { self[ImageLoaderKey.self] = newValue }
    }
}

/// 비공개 저장소의 사진. 화면에 들어올 때 받기 시작하고, 벗어나면 취소한다(`.task`가 맡는다).
public struct RemoteImage: View {
    private let path: String?
    private let contentMode: ContentMode
    private let maxPixelSize: CGFloat
    @Environment(\.imageLoader) private var loader
    @State private var image: UIImage?
    @State private var failed = false

    /// - Parameters:
    ///   - path: 저장소 경로(`photo_thumb_path` 등). nil이면 자리표시.
    ///   - maxPixelSize: 화면에 쓰는 크기에 맞춘다. 피드 썸네일은 480 이하.
    public init(path: String?, contentMode: ContentMode = .fill, maxPixelSize: CGFloat = 1600) {
        self.path = path
        self.contentMode = contentMode
        self.maxPixelSize = maxPixelSize
    }

    public var body: some View {
        ZStack {
            Theme.Palette.secondaryBackground
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "photo")
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .clipped()
        .skeleton(image == nil && !failed && path != nil)
        // id가 바뀌면 이전 작업이 취소되고, 화면을 벗어나도 취소된다.
        .task(id: path) { await load() }
    }

    private func load() async {
        image = nil
        failed = false
        guard let path else { return }
        guard let loader else { failed = true; return }
        do {
            let loaded = try await loader.image(forPath: path, maxPixelSize: maxPixelSize)
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
