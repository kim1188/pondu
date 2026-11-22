#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import Observation
import SwiftUI
import UIKit

/// 인앱 카메라. 사진 보관함은 열지 않는다(권한도 요청하지 않는다).
@MainActor
@Observable
final class CameraModel {
    enum Access { case unknown, authorized, denied }
    var access: Access = .unknown
    var isCapturing = false
    var errorMessage: String?

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "pondu.camera")
    private var configured = false
    private var delegate: PhotoCaptureDelegate?

    func prepare() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            access = .authorized
        case .notDetermined:
            access = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        default:
            access = .denied
        }
        guard access == .authorized else { return }
        configureIfNeeded()
        let session = self.session
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        } else {
            errorMessage = "카메라를 쓸 수 없어요."
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
    }

    /// 촬영해서 원본 데이터를 돌려준다. 줄이기는 호출한 쪽이 뒤에서 한다.
    func capture() async -> Data? {
        guard access == .authorized, !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let d = PhotoCaptureDelegate { data in continuation.resume(returning: data) }
            self.delegate = d
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: d)
        }
    }
}

final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let onFinish: (Data?) -> Void
    init(onFinish: @escaping (Data?) -> Void) { self.onFinish = onFinish }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error != nil { onFinish(nil); return }
        onFinish(photo.fileDataRepresentation())
    }
}

private final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> UIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct CameraView: View {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void
    @State private var model = CameraModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.access {
            case .authorized:
                CameraPreview(session: model.session).ignoresSafeArea()
            case .denied:
                VStack(spacing: 12) {
                    Text("카메라를 쓸 수 없어요").font(.headline).foregroundStyle(.white)
                    Text("설정에서 카메라를 허용하거나, 사진 없이 시작할 수 있어요.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                }.padding(24)
            case .unknown:
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Button("닫기", action: onCancel).foregroundStyle(.white).padding()
                    Spacer()
                }
                Spacer()
                if model.access == .authorized {
                    Button {
                        Task {
                            if let data = await model.capture() { onCapture(data) }
                        }
                    } label: {
                        Circle().strokeBorder(.white, lineWidth: 4).background(Circle().fill(.white.opacity(0.25)))
                            .frame(width: 76, height: 76)
                    }
                    .disabled(model.isCapturing)
                    .accessibilityLabel("사진 찍기")
                    .padding(.bottom, 32)
                }
            }
        }
        .task { await model.prepare() }
        .onDisappear { model.stop() }
    }
}
#endif
