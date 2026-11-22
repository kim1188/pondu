import SwiftUI
import PonduCore

enum TodaySheet: Identifiable {
    case newTodo
    case editTodo(TodayTodo)
    case newBlock(TodayTodo)
    case editBlock(TodayBlock)
    case assistant(AssistantKind, text: String, signal: SessionEndSignal?)
    case importer
    case calendars

    var id: String {
        switch self {
        case .newTodo: return "newTodo"
        case .editTodo(let t): return "editTodo-\(t.id)"
        case .newBlock(let t): return "newBlock-\(t.id)"
        case .editBlock(let b): return "editBlock-\(b.id)"
        case .assistant(let k, _, _): return "assistant-\(k.rawValue)"
        case .importer: return "importer"
        case .calendars: return "calendars"
        }
    }
}

struct TodayView: View {
    @Bindable var model: TodayModel
    @State private var sheet: TodaySheet?
    @State private var quickText = ""

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.snapshot == nil {
                    TodaySkeleton()
                } else if model.loadFailed {
                    VStack(spacing: 12) {
                        Text("오늘 정보를 불러오지 못했어요.").font(.headline)
                        Button("다시 시도") { Task { await model.load() } }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .navigationTitle("오늘")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("할 일 추가", systemImage: "plus") { sheet = .newTodo }
                        Button("가져오기", systemImage: "square.and.arrow.down") { sheet = .importer }
                        Button("읽을 캘린더 고르기", systemImage: "calendar") { sheet = .calendars }
                    } label: { Image(systemName: "plus.circle") }
                    .accessibilityLabel("더 보기")
                }
            }
            .safeAreaInset(edge: .bottom) { quickInput }
            .refreshable { await model.load() }
            .sheet(item: $sheet) { sheetContent($0) }
            .alert("알림", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("확인", role: .cancel) {}
            } message: { Text(model.errorMessage ?? "") }
        }
    }

    // MARK: 본문

    private var content: some View {
        List {
            if let hint = model.rescheduleHint { rescheduleBanner(hint) }
            liveSection
            fixedSection
            startableSection
            assistantSection
            upcomingSection
            remainingSection
            doneSection
        }
        .listStyle(.insetGrouped)
    }

    private func rescheduleBanner(_ hint: SessionEndSignal) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("더 해야 하는 일이 남았어요").font(.headline)
                Text("남은 시간에 이어서 할 수 있게 다시 잡아 볼까요?").font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button("남은 일 조정") { sheet = .assistant(.reschedule, text: "", signal: hint); model.dismissRescheduleHint() }
                        .buttonStyle(.borderedProminent)
                    Button("나중에") { model.dismissRescheduleHint() }.buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder private var liveSection: some View {
        if let live = model.live {
            Section("진행 중") {
                HStack {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(live.shareTitle ?? model.snapshot?.thread(live.threadId)?.title ?? "세션 진행 중")
                    Spacer()
                    Text(live.status == "paused" ? "일시 정지" : "진행 중").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var fixedSection: some View {
        switch model.calendarAccess {
        case .granted:
            if !model.events.isEmpty {
                Section("고정 일정") {
                    ForEach(model.events) { e in
                        HStack {
                            Text(timeRange(e.start, e.end, allDay: e.isAllDay)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            Text(e.title)
                        }
                    }
                }
            }
        case .notDetermined:
            Section("고정 일정") {
                Button("캘린더의 바쁜 시간 함께 보기") { Task { await model.requestCalendarAccess(); if model.calendarAccess == .granted { sheet = .calendars } } }
                Text("일정 제목은 이 기기 밖으로 나가지 않아요.").font(.caption).foregroundStyle(.secondary)
            }
        case .denied:
            EmptyView()
        }
    }

    @ViewBuilder private var startableSection: some View {
        let blocks = model.startable
        if !blocks.isEmpty {
            Section("지금 시작할 수 있어요") {
                ForEach(blocks) { b in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(for: b)).font(.headline)
                            Text(timeRange(b.startAt, b.endAt, allDay: false)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("지금 시작") { model.start(block: b) }.buttonStyle(.borderedProminent)
                    }
                    .swipeActions { blockSwipe(b) }
                }
            }
        }
    }

    private var assistantSection: some View {
        Section("비서") {
            HStack {
                Button { sheet = .assistant(.planDay, text: "", signal: nil) } label: { Label("하루 정리", systemImage: "sparkles") }
                    .buttonStyle(.bordered)
                Button { sheet = .assistant(.reschedule, text: "", signal: nil) } label: { Label("남은 일 조정", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder private var upcomingSection: some View {
        let blocks = model.upcoming
        if !blocks.isEmpty {
            Section("오늘의 예정 시간") {
                ForEach(blocks) { b in
                    HStack {
                        Text(timeRange(b.startAt, b.endAt, allDay: false)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        Text(title(for: b))
                        Spacer()
                        if b.locked { Image(systemName: "pin.fill").foregroundStyle(.secondary).accessibilityLabel("고정됨") }
                        if b.origin == "assistant" { Text("비서").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { sheet = .editBlock(b) }
                    .swipeActions { blockSwipe(b) }
                }
            }
        }
    }

    @ViewBuilder private var remainingSection: some View {
        let todos = model.remaining
        Section("남은 할 일") {
            if todos.isEmpty {
                Text("남은 할 일이 없어요. 아래 입력창에 적어 보세요.").foregroundStyle(.secondary)
            }
            ForEach(todos) { t in
                TodoRow(todo: t, thread: model.snapshot?.thread(t.threadId),
                        due: TodayLogic.dueText(t, now: model.now, timeZone: model.timeZone),
                        onToggle: { model.toggleDone(t) })
                    .contentShape(Rectangle())
                    .onTapGesture { sheet = .editTodo(t) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { model.deleteTodo(t) } label: { Label("삭제", systemImage: "trash") }
                        Button { sheet = .newBlock(t) } label: { Label("시간 잡기", systemImage: "clock") }.tint(.blue)
                    }
                    .swipeActions(edge: .leading) {
                        Button { model.start(todo: t) } label: { Label("지금 시작", systemImage: "play.fill") }.tint(.green)
                    }
            }
        }
    }

    @ViewBuilder private var doneSection: some View {
        let done = model.doneToday
        if !done.isEmpty {
            Section("오늘 끝낸 일") {
                ForEach(done) { t in
                    TodoRow(todo: t, thread: model.snapshot?.thread(t.threadId), due: nil, onToggle: { model.toggleDone(t) })
                }
            }
        }
    }

    @ViewBuilder private func blockSwipe(_ b: TodayBlock) -> some View {
        Button(role: .destructive) { model.deleteBlock(b) } label: { Label("삭제", systemImage: "trash") }
        Button { model.setLocked(b, locked: !b.locked) } label: { Label(b.locked ? "고정 풀기" : "고정", systemImage: b.locked ? "pin.slash" : "pin") }.tint(.orange)
    }

    // MARK: 한 줄 입력

    private var quickInput: some View {
        HStack(spacing: 8) {
            TextField("해야 할 일을 한 줄로 적어 보세요", text: $quickText)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(submitQuick)
            Button(action: submitQuick) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .disabled(quickText.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("비서에게 보내기")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private func submitQuick() {
        let text = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        quickText = ""
        sheet = .assistant(.capture, text: text, signal: nil)
    }

    // MARK: 시트

    @ViewBuilder private func sheetContent(_ s: TodaySheet) -> some View {
        switch s {
        case .newTodo: TodoEditView(model: model, todo: nil)
        case .editTodo(let t): TodoEditView(model: model, todo: t)
        case .newBlock(let t): BlockEditView(model: model, todo: t, block: nil)
        case .editBlock(let b): BlockEditView(model: model, todo: model.snapshot?.todo(b.todoId), block: b)
        case .assistant(let kind, let text, let signal):
            AssistantView(model: AssistantModel(kind: kind, text: text, today: model, consent: UserDefaultsConsent(), signal: signal), today: model, autoSend: kind == .capture)
        case .importer: ImportView(model: ImportModel(today: model))
        case .calendars: CalendarPickerView(model: model)
        }
    }

    // MARK: 표시 도우미

    private func title(for b: TodayBlock) -> String {
        model.snapshot?.todo(b.todoId)?.title ?? model.snapshot?.thread(b.threadId)?.title ?? "예정한 일"
    }

    private func timeRange(_ s: Date, _ e: Date, allDay: Bool) -> String {
        if allDay { return "하루 종일" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR"); f.timeZone = model.timeZone; f.dateFormat = "HH:mm"
        return "\(f.string(from: s))~\(f.string(from: e))"
    }
}

struct TodoRow: View {
    let todo: TodayTodo
    let thread: TodayThread?
    let due: String?
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(todo.isDone ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.isDone ? "완료 취소" : "완료로 표시")
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title).strikethrough(todo.isDone)
                HStack(spacing: 6) {
                    if let thread { Text(thread.title) }
                    if let due { Text(due) }
                    if let m = todo.estimateMin { Text("\(m)분") }
                    if todo.source != nil && todo.source != "manual" { Text("가져옴") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 처음 열 때(저장분도 없을 때) 보여 주는 뼈대.
struct TodaySkeleton: View {
    var body: some View {
        List {
            ForEach(0..<6, id: \.self) { _ in
                HStack {
                    Circle().frame(width: 22, height: 22)
                    VStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).frame(height: 14)
                        RoundedRectangle(cornerRadius: 4).frame(width: 90, height: 10)
                    }
                }
                .foregroundStyle(.quaternary)
            }
        }
        .listStyle(.insetGrouped)
        .skeleton(true)
        .allowsHitTesting(false)
    }
}
