import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 사진 크기 계산(순수 함수). 긴 변 1600px와 480px, 확대하지 않는다.
enum PhotoSizing {
    static let fullLongSide = 1600
    static let thumbLongSide = 480
    static let fullMaxBytes = 400_000
    static let thumbMaxBytes = 60_000
    /// 용량 상한을 넘으면 한 단계씩 낮춰 다시 인코딩한다.
    static let qualityLadder: [Double] = [0.7, 0.55, 0.42, 0.3, 0.2]

    static func targetSize(width: Int, height: Int, longSide limit: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let long = max(width, height)
        if long <= limit { return (width, height) }
        let scale = Double(limit) / Double(long)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// ImageIO 썸네일 생성에 넘길 최대 픽셀(원본보다 키우지 않는다).
    static func maxPixel(originalWidth: Int, originalHeight: Int, limit: Int) -> Int {
        min(limit, max(originalWidth, originalHeight))
    }
}

/// 저장소 경로 규칙: {user_id}/{session_id}/full.heic, thumb.heic. 서버 경로는 소문자 uuid.
enum PhotoPaths {
    static func full(userID: UUID, sessionID: UUID) -> String {
        "\(userID.uuidString.lowercased())/\(sessionID.uuidString.lowercased())/full.heic"
    }
    static func thumb(userID: UUID, sessionID: UUID) -> String {
        "\(userID.uuidString.lowercased())/\(sessionID.uuidString.lowercased())/thumb.heic"
    }
}

struct ProcessedPhoto: Equatable {
    let fullURL: URL
    let thumbURL: URL
    let fullBytes: Int
    let thumbBytes: Int
}

enum PhotoError: Error { case decode, encode }

protocol PhotoProcessing {
    /// 촬영한 원본 데이터를 큰 것·작은 것 HEIC 두 장으로 줄여 directory에 full.heic, thumb.heic로 쓴다.
    func process(imageData: Data, into directory: URL) async throws -> ProcessedPhoto
}

struct HEICPhotoProcessor: PhotoProcessing {
    func process(imageData: Data, into directory: URL) async throws -> ProcessedPhoto {
        try await Task.detached(priority: .utility) {
            try HEICPhotoProcessor.run(imageData: imageData, directory: directory)
        }.value
    }

    private static func run(imageData: Data, directory: URL) throws -> ProcessedPhoto {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { throw PhotoError.decode }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard w > 0, h > 0 else { throw PhotoError.decode }

        let fullURL = directory.appendingPathComponent("full.heic")
        let thumbURL = directory.appendingPathComponent("thumb.heic")
        let fullBytes = try encode(source, maxPixel: PhotoSizing.maxPixel(originalWidth: w, originalHeight: h, limit: PhotoSizing.fullLongSide),
                                   byteLimit: PhotoSizing.fullMaxBytes, to: fullURL)
        let thumbBytes = try encode(source, maxPixel: PhotoSizing.maxPixel(originalWidth: w, originalHeight: h, limit: PhotoSizing.thumbLongSide),
                                    byteLimit: PhotoSizing.thumbMaxBytes, to: thumbURL)
        return ProcessedPhoto(fullURL: fullURL, thumbURL: thumbURL, fullBytes: fullBytes, thumbBytes: thumbBytes)
    }

    private static func encode(_ source: CGImageSource, maxPixel: Int, byteLimit: Int, to url: URL) throws -> Int {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 촬영 방향 반영
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw PhotoError.decode }
        var lastSize = 0
        for quality in PhotoSizing.qualityLadder {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else { throw PhotoError.encode }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw PhotoError.encode }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            lastSize = size
            if size > 0 && size <= byteLimit { break }
        }
        return lastSize
    }
}
