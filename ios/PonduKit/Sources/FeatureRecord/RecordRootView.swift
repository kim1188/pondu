import SwiftUI
import PonduCore

/// 기록 탭: 잔디, 분야별 시간, 이어가는 일별 이력, 세션 목록.
@MainActor
public struct RecordRootView: View {
    private let deps: AppDependencies
    @State private var model: RecordModel

    public init(deps: AppDependencies) {
        self.deps = deps
        _model = State(initialValue: RecordModel(backend: deps.backend, now: deps.now))
    }

    public var body: some View {
        NavigationStack {
            List {
                if let code = model.errorCode, !model.hasContent {
                    RecordErrorRow(code: code) { Task { await model.refresh() } }
                } else {
                    heatmapSection
                    categorySection
                    threadSection
                    sessionSection
                }
            }
            .navigationTitle("기록")
            .refreshable { await model.refresh() }
            .task { await model.load() }
        }
    }

    // MARK: 잔디

    private var heatmapSection: some View {
        Section("기록이 남은 날") {
            if model.hasContent {
                HeatmapView(columns: model.heatmapColumns)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                Text("최근 \(Heatmap.defaultWeeks)주 · 세션을 기록한 날만 표시해요").font(.footnote).foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.15)).frame(height: 110).skeleton(true)
            }
        }
    }

    // MARK: 분야별 시간

    private var categorySection: some View {
        Section("분야별 시간") {
            if let s = model.summary {
                if s.byCategory.isEmpty {
                    Text("아직 기록이 없어요. 세션을 시작하면 여기에 쌓여요.").foregroundStyle(.secondary)
                } else {
                    let maxSeconds = max(s.byCategory.map(\.seconds).max() ?? 1, 1)
                    ForEach(s.byCategory.sorted { $0.seconds > $1.seconds }) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(RecordStyle.name(row.category))
                                Spacer()
                                Text(RecordLabels.duration(row.seconds)).foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                Capsule().fill(RecordStyle.color(row.category))
                                    .frame(width: max(4, geo.size.width * CGFloat(row.seconds / maxSeconds)), height: 6)
                            }.frame(height: 6)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                ForEach(0..<3, id: \.self) { _ in Text("분야 이름 00시간").skeleton(true) }
            }
        }
    }

    // MARK: 이어가는 일별 이력

    private var threadSection: some View {
        Section("이어가는 일") {
            if let s = model.summary {
                if s.threads.isEmpty {
                    Text("이어가는 일이 생기면 여기서 이력을 볼 수 있어요.").foregroundStyle(.secondary)
                } else {
                    ForEach(s.threads) { t in
                        NavigationLink {
                            ThreadHistoryView(deps: deps, thread: t)
                        } label: {
                            HStack {
                                Text(t.title).lineLimit(1)
                                Spacer()
                                Text(RecordLabels.duration(t.seconds)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                ForEach(0..<2, id: \.self) { _ in Text("이어가는 일 이름").skeleton(true) }
            }
        }
    }

    // MARK: 세션 목록

    private var sessionSection: some View {
        Section("세션") {
            if model.sessions.items.isEmpty && !model.sessions.hasLoaded {
                ForEach(0..<4, id: \.self) { _ in SessionRowPlaceholder() }
            } else if model.sessions.items.isEmpty {
                Text("아직 세션이 없어요.").foregroundStyle(.secondary)
            } else {
                ForEach(model.sessions.items) { s in
                    SessionRow(session: s)
                        .task { await model.sessions.loadMoreIfNeeded(current: s) }
                }
                if model.sessions.isLoading { ProgressView().frame(maxWidth: .infinity) }
            }
        }
    }
}

/// 한 이어가는 일의 세션 이력(같은 목록 모델, 스레드 필터).
struct ThreadHistoryView: View {
    let thread: RecordSummary.ThreadStat
    @State private var list: SessionListModel

    init(deps: AppDependencies, thread: RecordSummary.ThreadStat) {
        self.thread = thread
        _list = State(initialValue: SessionListModel(backend: deps.backend, threadID: thread.threadId))
    }

    var body: some View {
        List {
            if let code = list.errorCode, list.items.isEmpty {
                RecordErrorRow(code: code) { Task { await list.reload() } }
            } else if list.items.isEmpty && !list.hasLoaded {
                ForEach(0..<4, id: \.self) { _ in SessionRowPlaceholder() }
            } else if list.items.isEmpty {
                Text("이 일의 세션이 아직 없어요.").foregroundStyle(.secondary)
            } else {
                ForEach(list.items) { s in
                    SessionRow(session: s).task { await list.loadMoreIfNeeded(current: s) }
                }
            }
        }
        .navigationTitle(thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await list.reload() }
        .refreshable { await list.reload() }
    }
}

struct SessionRow: View {
    let session: RecordSession
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(RecordStyle.color(session.primaryCategory)).frame(width: 8, height: 8)
                Text(session.shareTitle ?? RecordStyle.name(session.primaryCategory)).font(.body).lineLimit(1)
                Spacer()
                Text(RecordLabels.duration(session.durationSeconds)).foregroundStyle(.secondary)
            }
            Text(session.startedAt.formatted(.dateTime.month().day().hour().minute()))
                .font(.caption).foregroundStyle(.secondary)
            if let note = session.progressNote, !note.isEmpty {
                Text(note).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(RecordLabels.labels(for: session).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct SessionRowPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("분야 이름과 제목").font(.body)
            Text("00월 00일 00:00").font(.caption)
            Text("앱 촬영 첨부").font(.caption2)
        }
        .skeleton(true)
    }
}

struct RecordErrorRow: View {
    let code: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Text(code == "network" || code == "timeout" ? "연결이 불안정해요." : "기록을 불러오지 못했어요.")
            Button("다시 시도", action: retry).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

struct HeatmapView: View {
    let columns: [[Heatmap.Cell]]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                VStack(spacing: 3) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(cell.day == nil ? Color.clear : color(cell.level))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("최근 \(columns.count)주 중 기록이 남은 날 \(columns.flatMap { $0 }.filter { $0.level > 0 }.count)일")
    }

    private func color(_ level: Int) -> Color {
        switch level {
        case 0: return Color.gray.opacity(0.18)
        case 1: return Color.green.opacity(0.35)
        case 2: return Color.green.opacity(0.65)
        default: return Color.green.opacity(0.95)
        }
    }
}

enum RecordStyle {
    static func name(_ raw: String) -> String { Category(rawValue: raw)?.displayName ?? raw }
    static func color(_ raw: String) -> Color { Category(rawValue: raw)?.color ?? .gray }
}
