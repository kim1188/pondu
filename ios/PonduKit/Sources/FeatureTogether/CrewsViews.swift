import SwiftUI
import PonduCore

struct CrewsView: View {
    let deps: AppDependencies
    @Bindable var model: CrewsModel
    var onChanged: () -> Void

    @State private var showCreate = false
    @State private var showJoin = false
    @State private var nameInput = ""
    @State private var codeInput = ""

    var body: some View {
        List {
            switch model.phase {
            case .loading:
                ForEach(0..<3, id: \.self) { _ in Text("크루 이름 자리") }.skeleton(true)
            case .failed:
                TogetherRetryView(message: "크루를 불러오지 못했어요.") { Task { await model.load() } }
            case .ready:
                if model.crews.isEmpty {
                    VStack(spacing: 8) {
                        Text("아직 크루가 없어요").font(.headline)
                        Text("크루를 만들어 초대 코드를 나누거나, 받은 코드를 입력해 들어갈 수 있어요.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                ForEach(model.crews, id: \.id) { crew in
                    NavigationLink {
                        CrewDetailView(deps: deps, crewsModel: model, crew: crew, onChanged: onChanged)
                    } label: {
                        HStack {
                            Text(crew.name)
                            Spacer()
                            Text("\(crew.memberCount)명").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("크루")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("크루 만들기", systemImage: "plus") { nameInput = ""; showCreate = true }
                    Button("초대 코드 입력", systemImage: "key") { codeInput = ""; showJoin = true }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("크루 추가")
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .alert("크루 만들기", isPresented: $showCreate) {
            TextField("크루 이름", text: $nameInput)
            Button("만들기") {
                let name = nameInput
                Task { if await model.create(name: name) != nil { onChanged() } }
            }
            Button("취소", role: .cancel) {}
        }
        .alert("초대 코드 입력", isPresented: $showJoin) {
            TextField("초대 코드", text: $codeInput).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("들어가기") {
                let code = codeInput
                Task { if await model.join(inviteCode: code) != nil { onChanged() } }
            }
            Button("취소", role: .cancel) {}
        }
        .togetherToast($model.toast)
    }
}

struct CrewDetailView: View {
    let deps: AppDependencies
    let crewsModel: CrewsModel
    let crew: CrewDTO
    var onChanged: () -> Void

    @State private var members: CrewMembersModel
    @State private var confirmLeave = false
    @State private var removeTarget: CrewMemberDTO?
    @Environment(\.dismiss) private var dismiss

    init(deps: AppDependencies, crewsModel: CrewsModel, crew: CrewDTO, onChanged: @escaping () -> Void) {
        self.deps = deps
        self.crewsModel = crewsModel
        self.crew = crew
        self.onChanged = onChanged
        _members = State(initialValue: CrewMembersModel(backend: deps.backend, crew: crew))
    }

    var body: some View {
        List {
            Section("초대 코드") {
                HStack {
                    Text(crew.inviteCode).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    ShareLink(item: "크루 '\(crew.name)'에 들어와요. 초대 코드: \(crew.inviteCode)") {
                        Label("공유", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section("구성원") {
                switch members.phase {
                case .loading:
                    ForEach(0..<3, id: \.self) { _ in PersonRowPlaceholder() }.skeleton(true)
                case .failed:
                    TogetherRetryView(message: "구성원을 불러오지 못했어요.") { Task { await members.load() } }
                case .ready:
                    ForEach(members.members) { m in
                        HStack(spacing: 12) {
                            InitialAvatar(name: m.displayName)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.displayName)
                                Text("@\(m.handle)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if m.isOwner { Text("운영자").font(.footnote).foregroundStyle(.secondary) }
                        }
                        .swipeActions {
                            if members.isOwner && !m.isOwner && m.id != deps.backend.currentUserID {
                                Button("내보내기", role: .destructive) { removeTarget = m }
                            }
                        }
                    }
                }
            }
            Section {
                Button("크루 나가기", role: .destructive) { confirmLeave = true }
            }
        }
        .navigationTitle(crew.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await members.load() }
        .confirmationDialog("이 크루에서 나갈까요?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("나가기", role: .destructive) {
                Task {
                    if await crewsModel.leave(crew) { onChanged(); dismiss() }
                }
            }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("구성원을 내보낼까요?", isPresented: Binding(get: { removeTarget != nil },
                                                                set: { if !$0 { removeTarget = nil } }),
                            titleVisibility: .visible) {
            Button("내보내기", role: .destructive) {
                guard let m = removeTarget else { return }
                removeTarget = nil
                Task { await members.remove(m) }
            }
            Button("취소", role: .cancel) { removeTarget = nil }
        }
        .togetherToast($members.toast)
    }
}
