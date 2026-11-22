import SwiftUI
import PonduCore

/// 내 프로필 수정. 설정 화면의 내비게이션에서 밀어 넣는다. 저장하면 기기 저장분(`deps.profiles`)도 함께 고친다.
/// 기기 저장분으로 먼저 채워 그리고, 서버 값으로 갱신한다.
@MainActor
public struct ProfileEditView: View {
    @State private var model: ProfileFormModel
    @Environment(\.dismiss) private var dismiss
    private let onSaved: ((Profile) -> Void)?

    /// - Parameter onSaved: 저장이 끝난 뒤 불린다(앱 껍데기가 상단 프로필 표시를 갱신할 때).
    public init(deps: AppDependencies, onSaved: ((Profile) -> Void)? = nil) {
        let cached = deps.profiles.load(userID: deps.backend.currentUserID)
        _model = State(initialValue: ProfileFormModel(backend: deps.backend, profiles: deps.profiles, initial: cached))
        self.onSaved = onSaved
    }

    public var body: some View {
        ProfileFormView(model: model, submitTitle: "저장") {
            Task {
                if let saved = await model.submit() {
                    onSaved?(saved)
                    dismiss()
                }
            }
        }
        .navigationTitle("프로필 수정")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadForEditing() }
    }
}
