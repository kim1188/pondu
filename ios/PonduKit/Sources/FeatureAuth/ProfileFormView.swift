import SwiftUI
import PonduCore

/// 아이디·이름·학과 입력과 저장 버튼. 가입의 프로필 만들기와 프로필 수정이 같이 쓴다.
struct ProfileFormView: View {
    @Bindable var model: ProfileFormModel
    let submitTitle: String
    let onSubmit: () -> Void
    @State private var showsDepartmentPicker = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 2) {
                    Text("@").foregroundStyle(Theme.Palette.textSecondary)
                    TextField("아이디", text: $model.handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .textContentType(.username)
                        .onChange(of: model.handle) { _, _ in model.handleChanged() }
                }
                handleHint
            } header: {
                Text("아이디")
            }

            Section {
                TextField("이름 (1~20자)", text: $model.displayName)
                    .textContentType(.name)
                    .onChange(of: model.displayName) { _, newValue in
                        if newValue.count > ProfileRules.nameRange.upperBound {
                            model.displayName = String(newValue.prefix(ProfileRules.nameRange.upperBound))
                        }
                    }
            } header: {
                Text("이름")
            }

            Section {
                Button {
                    showsDepartmentPicker = true
                } label: {
                    HStack {
                        Text("학과")
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Spacer()
                        departmentLabel
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            } footer: {
                Text("학과는 건너뛰어도 돼요.")
            }

            if let message = model.errorMessage {
                Section {
                    Text(message)
                        .font(Theme.Font.callout)
                        .foregroundStyle(Theme.Palette.danger)
                }
            }

            Section {
                Button(action: onSubmit) {
                    HStack(spacing: Theme.Spacing.s) {
                        if model.isSaving { ProgressView() }
                        Text(model.isSaving ? "저장하는 중…" : submitTitle)
                            .font(Theme.Font.headline)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!model.canSubmit)
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showsDepartmentPicker) {
            DepartmentPickerView(model: model)
        }
    }

    @ViewBuilder
    private var departmentLabel: some View {
        switch model.departmentsState {
        case .loading where model.departmentName == nil:
            Text("불러오는 중").foregroundStyle(Theme.Palette.textSecondary).skeleton(true)
        default:
            Text(model.departmentName ?? "선택 안 함").foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    @ViewBuilder
    private var handleHint: some View {
        switch model.handleStatus {
        case .idle:
            hint("영문 소문자, 숫자, 밑줄로 3~20자", color: Theme.Palette.textSecondary)
        case .invalidFormat:
            hint("아이디는 영문 소문자, 숫자, 밑줄로 3~20자여야 해요.", color: Theme.Palette.danger)
        case .checking:
            HStack(spacing: Theme.Spacing.s) {
                ProgressView().controlSize(.small)
                Text("확인 중…").font(Theme.Font.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
        case .available:
            hint("사용할 수 있어요.", color: Theme.Palette.success)
        case .unchanged:
            if model.isEditing { hint("지금 쓰는 아이디예요.", color: Theme.Palette.textSecondary) }
        case .taken:
            hint("이미 쓰고 있는 아이디예요.", color: Theme.Palette.danger)
        case .checkFailed:
            hint("지금은 확인하지 못했어요. 저장할 때 다시 확인해요.", color: Theme.Palette.warning)
        }
    }

    private func hint(_ text: String, color: Color) -> some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(color)
    }
}

/// 학과 고르기(검색 가능, 선택 안 함 가능).
struct DepartmentPickerView: View {
    @Bindable var model: ProfileFormModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [DepartmentDTO] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return model.departments }
        return model.departments.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("학과")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "학과 검색")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                }
        }
        .task {
            if model.departmentsState == .idle { await model.loadDepartments() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.departmentsState {
        case .idle, .loading:
            List(0..<8, id: \.self) { _ in
                Text("학과 이름 자리").skeleton(true)
            }
            .listStyle(.plain)
        case .failed(let message):
            ErrorRetryView(message: message) { Task { await model.loadDepartments() } }
        case .loaded:
            List {
                Button {
                    model.departmentID = nil
                    dismiss()
                } label: {
                    row("선택 안 함", selected: model.departmentID == nil)
                }
                ForEach(filtered) { department in
                    Button {
                        model.departmentID = department.id
                        dismiss()
                    } label: {
                        row(department.name, selected: model.departmentID == department.id)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Theme.Palette.accent) }
        }
    }
}
