import SwiftUI
import PonduCore

struct FriendsView: View {
    @Bindable var model: FriendsModel
    @State private var removeTarget: ProfileCard?
    @State private var blockTarget: ProfileCard?

    var body: some View {
        List {
            if model.searchPhase != .idle {
                searchSection
            } else {
                listSections
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("친구")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "아이디나 이름으로 찾기")
        .onChange(of: model.query) { _, new in model.queryChanged(new) }
        .task { await model.load() }
        .refreshable { await model.load() }
        .confirmationDialog("친구를 삭제할까요?", isPresented: Binding(get: { removeTarget != nil },
                                                               set: { if !$0 { removeTarget = nil } }),
                            titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                guard let u = removeTarget else { return }
                removeTarget = nil
                Task { await model.removeFriend(u) }
            }
            Button("취소", role: .cancel) { removeTarget = nil }
        }
        .confirmationDialog("이 사람을 차단할까요?", isPresented: Binding(get: { blockTarget != nil },
                                                                 set: { if !$0 { blockTarget = nil } }),
                            titleVisibility: .visible) {
            Button("차단", role: .destructive) {
                guard let u = blockTarget else { return }
                blockTarget = nil
                Task { await model.block(u) }
            }
            Button("취소", role: .cancel) { blockTarget = nil }
        } message: { Text("서로의 기록이 보이지 않게 돼요.") }
        .togetherToast($model.toast)
    }

    @ViewBuilder private var searchSection: some View {
        Section {
            switch model.searchPhase {
            case .waiting, .searching:
                ForEach(0..<3, id: \.self) { _ in PersonRowPlaceholder() }.skeleton(true)
            case .done where model.results.isEmpty:
                Text("찾는 사람이 없어요. 같은 학교의 아이디나 이름을 확인해 주세요.").foregroundStyle(.secondary)
            default:
                ForEach(model.results, id: \.id) { user in
                    PersonRow(user: user) {
                        switch model.relation(to: user.id) {
                        case .none:
                            Button("요청") { Task { await model.sendRequest(to: user) } }.buttonStyle(.bordered)
                        case .requested:
                            Text("요청함").font(.footnote).foregroundStyle(.secondary)
                        case .friend:
                            Text("친구").font(.footnote).foregroundStyle(.secondary)
                        case .incoming:
                            Button("수락") { Task { await model.respond(to: user, accept: true) } }.buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var listSections: some View {
        switch model.phase {
        case .loading:
            Section { ForEach(0..<4, id: \.self) { _ in PersonRowPlaceholder() } }.skeleton(true)
        case .failed:
            ErrorRetryView(message: "친구 목록을 불러오지 못했어요.") { Task { await model.load() } }
        case .ready:
            if model.hasNoRelations {
                Section {
                    VStack(spacing: 10) {
                        Text("아직 친구가 없어요").font(.headline)
                        Text("위 검색창에 친구의 아이디를 입력하거나, 초대를 보내 보세요.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        ShareLink(item: "같이 기록해 봐요. 앱을 설치하고 내 아이디로 친구 추가해 주세요.") {
                            Label("친구에게 초대 보내기", systemImage: "square.and.arrow.up")
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            }
            if !model.incoming.isEmpty {
                Section("받은 요청") {
                    ForEach(model.incoming, id: \.id) { user in
                        PersonRow(user: user) {
                            HStack {
                                Button("거절") { Task { await model.respond(to: user, accept: false) } }.buttonStyle(.bordered)
                                Button("수락") { Task { await model.respond(to: user, accept: true) } }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }
            if !model.outgoing.isEmpty {
                Section("보낸 요청") {
                    ForEach(model.outgoing, id: \.id) { user in
                        PersonRow(user: user) { Text("요청함").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            if !model.friends.isEmpty {
                Section("친구 \(model.friends.count)명") {
                    ForEach(model.friends, id: \.id) { user in
                        PersonRow(user: user) { EmptyView() }
                            .swipeActions {
                                Button("삭제", role: .destructive) { removeTarget = user }
                                Button("차단") { blockTarget = user }.tint(.orange)
                            }
                    }
                }
            }
        }
    }
}

struct PersonRow<Trailing: View>: View {
    let user: ProfileCard
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            InitialAvatar(name: user.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName).font(.body)
                Text("@\(user.handle)" + (user.departmentName.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}

struct PersonRowPlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle().frame(width: 36, height: 36)
            VStack(alignment: .leading) { Text("이름 이름"); Text("@아이디").font(.caption) }
            Spacer()
        }
    }
}
