import SwiftUI
import PonduCore

// MARK: - 공용 작은 뷰

/// ErrorRetryView의 생성자 모양이 계약에 없어서 이 타깃 안에 둔 작은 대체품.
struct TogetherRetryView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            Button("다시 시도", action: retry).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

struct InitialAvatar: View {
    let name: String
    var size: CGFloat = 36
    var body: some View {
        Text(String(name.prefix(1)))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary, in: Circle())
            .accessibilityHidden(true)
    }
}

extension View {
    /// 짧은 알림. 값이 생기면 문구를 띄우고 비운다.
    func togetherToast(_ text: Binding<String?>) -> some View {
        alert("알림", isPresented: Binding(get: { text.wrappedValue != nil },
                                         set: { if !$0 { text.wrappedValue = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(text.wrappedValue ?? "")
        }
    }
}

// MARK: - 피드

struct FeedView: View {
    let deps: AppDependencies
    @Bindable var model: FeedModel
    var onFindFriends: () -> Void

    @State private var historyFor: FeedCardDTO?
    @State private var commentsFor: FeedCardDTO?
    @State private var reportTarget: FeedCardDTO?
    @State private var blockTarget: FeedCardDTO?

    var body: some View {
        VStack(spacing: 0) {
            scopeBar
            content
        }
        .task { await model.reload() }
        .refreshable { await model.reload() }
        .sheet(item: Binding(get: { historyFor.map(CardRef.init) }, set: { historyFor = $0?.card })) { ref in
            NavigationStack {
                HistorySheet(backend: deps.backend, card: ref.card)
            }
        }
        .sheet(item: Binding(get: { commentsFor.map(CardRef.init) }, set: { commentsFor = $0?.card })) { ref in
            NavigationStack {
                CommentsSheet(backend: deps.backend, card: ref.card) { [weak model] id, delta in
                    model?.adjustCommentCount(sessionID: id, by: delta)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("신고 이유", isPresented: Binding(get: { reportTarget != nil },
                                                          set: { if !$0 { reportTarget = nil } }),
                            titleVisibility: .visible) {
            ForEach(["스팸", "부적절한 내용", "괴롭힘", "기타"], id: \.self) { reason in
                Button(reason) {
                    guard let card = reportTarget else { return }
                    reportTarget = nil
                    Task { await model.report(sessionID: card.sessionId, reason: reason) }
                }
            }
            Button("취소", role: .cancel) { reportTarget = nil }
        }
        .confirmationDialog("이 사람을 차단할까요?", isPresented: Binding(get: { blockTarget != nil },
                                                                 set: { if !$0 { blockTarget = nil } }),
                            titleVisibility: .visible) {
            Button("차단", role: .destructive) {
                guard let card = blockTarget else { return }
                blockTarget = nil
                Task { await model.block(author: card.author) }
            }
            Button("취소", role: .cancel) { blockTarget = nil }
        } message: {
            Text("서로의 기록이 보이지 않게 돼요.")
        }
        .togetherToast($model.toast)
    }

    // 친구 전체 / 크루별 전환
    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("친구 전체", selected: model.scope == .friends) {
                    Task { await model.setScope(.friends) }
                }
                ForEach(model.crews, id: \.id) { crew in
                    chip(crew.name, selected: model.scope == .crew(crew.id)) {
                        Task { await model.setScope(.crew(crew.id)) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            List {
                ForEach(0..<4, id: \.self) { _ in FeedCardPlaceholder().listRowSeparator(.hidden) }
            }
            .listStyle(.plain)
            .skeleton(true)
            .disabled(true)
        case .failed:
            TogetherRetryView(message: "피드를 불러오지 못했어요.") { Task { await model.reload() } }
            Spacer()
        case .ready:
            if model.items.isEmpty {
                TogetherEmptyView(isCrew: model.scope != .friends, onFindFriends: onFindFriends)
            } else {
                List {
                    ForEach(model.items) { item in
                        FeedCardView(
                            item: item,
                            canJoin: model.canJoin(item),
                            onReact: { Task { await model.toggleReaction(on: item.id) } },
                            onJoin: { model.join(item.card) },
                            onHistory: { historyFor = item.card },
                            onComments: { commentsFor = item.card },
                            onReport: { reportTarget = item.card },
                            onBlock: { blockTarget = item.card },
                            isMine: item.card.author.id == model.currentUserID
                        )
                        .listRowSeparator(.hidden)
                        .task { await model.loadMoreIfNeeded(current: item) }
                    }
                    if model.isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

/// 시트가 다시 그려져도 모델이 새로 만들어지지 않게 @State로 들고 있는 겉 뷰.
private struct HistorySheet: View {
    let card: FeedCardDTO
    @State private var model: ThreadHistoryModel
    init(backend: Backend, card: FeedCardDTO) {
        self.card = card
        _model = State(initialValue: ThreadHistoryModel(backend: backend, sessionID: card.sessionId))
    }
    var body: some View {
        ThreadHistoryView(model: model, title: card.shareTitle ?? card.primaryCategory.displayName)
    }
}

private struct CommentsSheet: View {
    @State private var model: CommentsModel
    init(backend: Backend, card: FeedCardDTO, onDelta: @escaping @MainActor (UUID, Int) -> Void) {
        let m = CommentsModel(backend: backend, sessionID: card.sessionId)
        let id = card.sessionId
        m.onCountChange = { delta in onDelta(id, delta) }
        _model = State(initialValue: m)
    }
    var body: some View { CommentsView(model: model) }
}

private struct CardRef: Identifiable {
    let card: FeedCardDTO
    var id: UUID { card.sessionId }
}

// MARK: - 빈 화면 (친구가 없을 때 초대 안내)

struct TogetherEmptyView: View {
    let isCrew: Bool
    var onFindFriends: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "person.2").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(isCrew ? "아직 이 크루에 공유된 기록이 없어요" : "아직 보이는 기록이 없어요")
                .font(.headline)
            Text(isCrew ? "구성원이 공개 대상을 크루로 하고 시작하면 여기에 나와요."
                        : "친구를 추가하면 친구가 지금 하는 일과 최근 기록이 여기에 시간순으로 나와요.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !isCrew {
                Button("아이디로 친구 찾기", action: onFindFriends).buttonStyle(.borderedProminent)
                ShareLink(item: "같이 기록해 봐요. 앱을 설치하고 내 아이디로 친구 추가해 주세요.") {
                    Label("친구에게 초대 보내기", systemImage: "square.and.arrow.up")
                }
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 카드

struct FeedCardPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Circle().frame(width: 36, height: 36); Text("이름 이름").font(.headline) }
            Text("공유 제목이 들어가는 자리").font(.body)
            Rectangle().frame(height: 120)
            Text("00:00에 시작 · 기록 방식").font(.caption)
        }
        .padding(.vertical, 8)
    }
}

struct FeedCardView: View {
    let item: FeedItem
    let canJoin: Bool
    let onReact: () -> Void
    let onJoin: () -> Void
    let onHistory: () -> Void
    let onComments: () -> Void
    let onReport: () -> Void
    let onBlock: () -> Void
    let isMine: Bool

    private var card: FeedCardDTO { item.card }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // 사람·사진·한 줄 진척이 앞. 시간과 기록 방식은 아래에 작게.
            Text(card.shareTitle ?? card.primaryCategory.displayName)
                .font(.body.weight(.medium))
            if let note = card.progressNote, !note.isEmpty {
                Text("“\(note)”").font(.callout).foregroundStyle(.primary)
            }
            if let path = card.photoThumbPath ?? card.photoPath {
                RemoteImage(path: path)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("\(card.author.displayName)님이 남긴 사진")
            }
            if let with = card.joinedWith {
                Text("\(with.displayName)와 함께").font(.footnote).foregroundStyle(.secondary)
            }
            meta
            actions
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 10) {
            InitialAvatar(name: card.author.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.author.displayName).font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(card.primaryCategory.color).frame(width: 8, height: 8)
                    Text(card.primaryCategory.displayName).font(.caption).foregroundStyle(.secondary)
                    if item.card.status == .live {
                        Text("진행 중").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    } else if item.card.status == .paused {
                        Text("잠시 쉬는 중").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if !isMine {
                Menu {
                    Button("신고", role: .destructive, action: onReport)
                    Button("이 사람 차단", role: .destructive, action: onBlock)
                } label: {
                    Image(systemName: "ellipsis").padding(8).contentShape(Rectangle())
                }
                .accessibilityLabel("더 보기")
            }
        }
    }

    private var meta: some View {
        let labels = TogetherText.methodLabels(captureMode: card.captureMode,
                                               endCorrected: card.endCorrected,
                                               offlineStarted: card.offlineStarted)
        let time = card.startedAt.formatted(date: .omitted, time: .shortened) + "에 시작"
        let duration = TogetherText.minutesText(seconds: card.durationSeconds, isLive: item.isActive)
        return Text(([time, duration] + labels).joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if canJoin {
                Button("같이 하기", action: onJoin).buttonStyle(.borderedProminent).controlSize(.small)
            }
            Button("지난 기록", action: onHistory).buttonStyle(.bordered).controlSize(.small)
            Button(action: onReact) {
                Label(item.reactionCount > 0 ? "수고했어 \(item.reactionCount)" : "수고했어",
                      systemImage: item.myReaction == nil ? "hand.thumbsup" : "hand.thumbsup.fill")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .tint(item.myReaction == nil ? .secondary : .accentColor)
            Button(item.commentCount > 0 ? "한마디 \(item.commentCount)" : "한마디", action: onComments)
                .buttonStyle(.bordered).controlSize(.small)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

// MARK: - 지난 기록, 한마디

struct ThreadHistoryView: View {
    @Bindable var model: ThreadHistoryModel
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                List { ForEach(0..<3, id: \.self) { _ in FeedCardPlaceholder() } }.listStyle(.plain).skeleton(true)
            case .failed:
                TogetherRetryView(message: "지난 기록을 불러오지 못했어요.") { Task { await model.load() } }
            case .ready:
                if model.cards.isEmpty {
                    Text("볼 수 있는 지난 기록이 아직 없어요.").foregroundStyle(.secondary)
                } else {
                    List(model.cards, id: \.sessionId) { card in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(card.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.weight(.medium))
                            if let note = card.progressNote, !note.isEmpty { Text("“\(note)”").font(.callout) }
                            if let path = card.photoThumbPath ?? card.photoPath {
                                RemoteImage(path: path).frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            Text((TogetherText.methodLabels(captureMode: card.captureMode, endCorrected: card.endCorrected,
                                                            offlineStarted: card.offlineStarted)
                                  + [TogetherText.minutesText(seconds: card.durationSeconds, isLive: card.status == .live)])
                                .joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        .task { await model.load() }
    }
}

struct CommentsView: View {
    @Bindable var model: CommentsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.phase {
                case .loading:
                    List { ForEach(0..<3, id: \.self) { _ in Text("이름 한마디가 들어가는 자리") } }.skeleton(true)
                case .failed:
                    TogetherRetryView(message: "한마디를 불러오지 못했어요.") { Task { await model.load() } }
                    Spacer()
                case .ready:
                    if model.comments.isEmpty {
                        Text("첫 한마디를 남겨 보세요.").foregroundStyle(.secondary).frame(maxHeight: .infinity)
                    } else {
                        List(model.comments) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.authorName).font(.subheadline.weight(.semibold))
                                Text(c.body).font(.body)
                            }
                            .opacity(c.isPending ? 0.5 : 1)
                        }
                        .listStyle(.plain)
                    }
                }
            }
            Divider()
            HStack {
                TextField("한마디", text: $model.draft, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
                Button("보내기") { Task { await model.send() } }.disabled(!model.canSend)
            }
            .padding(12)
        }
        .navigationTitle("한마디")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        .task { await model.load() }
        .togetherToast($model.toast)
    }
}
