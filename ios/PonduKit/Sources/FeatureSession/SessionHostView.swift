import SwiftUI

/// 앱 화면 위에 진행 중 막대와 시작·종료 화면을 얹는 겉 뷰.
/// `SessionHostView(controller:) { 탭 화면 }` 또는 content 없이 `SessionHostView(controller:)`로 쓴다.
@MainActor
public struct SessionHostView<Content: View>: View {
    private let controller: SessionController
    private let content: Content
    @Environment(\.scenePhase) private var scenePhase

    public init(controller: SessionController, @ViewBuilder content: () -> Content) {
        self.controller = controller
        self.content = content()
    }

    public var body: some View {
        // 막대를 safeAreaInset으로 얹으면 탭 안의 내비게이션 막대(제목, 뒤로, 추가 버튼)를 덮는다.
        // 세로로 쌓아서 탭 화면 전체가 막대 아래에서 시작하게 한다.
        VStack(spacing: 0) {
            if let live = controller.live {
                LiveBar(controller: controller, live: live)
            }
            content
        }
            .sheet(isPresented: routeBinding(.start)) {
                if let draft = controller.draft { StartSessionView(controller: controller, draft: draft) }
            }
            .sheet(isPresented: routeBinding(.end)) { EndSessionView(controller: controller) }
            .sheet(isPresented: routeBinding(.confirmEnd)) { ConfirmEndView(controller: controller) }
            .overlay(alignment: .bottom) {
                if let toast = controller.toast {
                    Text(toast).font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule()).padding(.bottom, 90)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: controller.toast)
            .alert(controller.alert?.title ?? "", isPresented: alertBinding, presenting: controller.alert) { _ in
                Button("확인", role: .cancel) {}
            } message: { info in
                Text(info.message)
            }
            .task { await controller.resume() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await controller.resume() } }
            }
    }

    private func routeBinding(_ route: SessionController.Route) -> Binding<Bool> {
        Binding(
            get: { controller.route == route },
            set: { shown in
                guard !shown, controller.route == route else { return }
                if route == .start { controller.cancelStart() } else { controller.route = .none }
            })
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { controller.alert != nil }, set: { if !$0 { controller.alert = nil } })
    }
}

extension SessionHostView where Content == EmptyView {
    public init(controller: SessionController) {
        self.init(controller: controller) { EmptyView() }
    }
}
