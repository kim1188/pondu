import SwiftUI
import PonduCore

/// 할 일 추가·수정. 이어가는 일을 고르거나 그 자리에서 만들 수 있다.
struct TodoEditView: View {
    let model: TodayModel
    let todo: TodayTodo?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TodayModel.TodoDraft()
    @State private var hasDue = false
    @State private var hasTime = false
    @State private var dueDate = Date()
    @State private var hasEstimate = false
    @State private var estimate = 30
    @State private var creatingThread = false
    @State private var newThreadTitle = ""
    @State private var newThreadCategory: Category?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("할 일") {
                    TextField("무엇을 해야 하나요?", text: $draft.title)
                }
                Section("이어가는 일") {
                    Picker("이어가는 일", selection: $draft.threadID) {
                        Text("없음").tag(UUID?.none)
                        ForEach(model.threads) { Text($0.title).tag(Optional($0.id)) }
                    }
                    Button("새 이어가는 일 만들기") { creatingThread = true }
                }
                Section("마감") {
                    Toggle("마감이 있어요", isOn: $hasDue)
                    if hasDue {
                        Toggle("시각도 정해요", isOn: $hasTime)
                        DatePicker("마감", selection: $dueDate, displayedComponents: hasTime ? [.date, .hourAndMinute] : [.date])
                    }
                }
                Section("예상 시간") {
                    Toggle("예상 시간을 적을게요", isOn: $hasEstimate)
                    if hasEstimate { Stepper("\(estimate)분", value: $estimate, in: 5...600, step: 5) }
                }
            }
            .navigationTitle(todo == nil ? "할 일 추가" : "할 일 고치기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }.disabled(!draft.isValid || saving)
                }
            }
            .alert("이어가는 일 만들기", isPresented: $creatingThread) {
                TextField("이름", text: $newThreadTitle)
                Button("만들기") { createThread() }
                Button("취소", role: .cancel) {}
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let todo else { return }
        draft = TodayModel.TodoDraft(title: todo.title, threadID: todo.threadId, due: todo.dueAt, dueHasTime: todo.dueHasTime, estimateMin: todo.estimateMin)
        if let due = todo.dueAt { hasDue = true; dueDate = due; hasTime = todo.dueHasTime }
        if let m = todo.estimateMin { hasEstimate = true; estimate = m }
    }

    private func save() {
        draft.due = hasDue ? dueDate : nil
        draft.dueHasTime = hasDue && hasTime
        draft.estimateMin = hasEstimate ? estimate : nil
        saving = true
        Task {
            let ok: Bool
            if let todo { ok = await model.updateTodo(todo, draft: draft) } else { ok = await model.addTodo(draft) }
            saving = false
            if ok { dismiss() }
        }
    }

    private func createThread() {
        let title = newThreadTitle
        newThreadTitle = ""
        Task {
            if let t = await model.createThread(title: title, category: newThreadCategory, shareTitle: nil) { draft.threadID = t.id }
        }
    }
}

/// 예정 시간 만들기·옮기기·고정하기.
struct BlockEditView: View {
    let model: TodayModel
    let todo: TodayTodo?
    let block: TodayBlock?
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var minutes = 60
    @State private var locked = false
    @State private var saving = false

    private var end: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }
    private var conflicts: [BusyInterval] { model.conflicts(start: start, end: end) }

    var body: some View {
        NavigationStack {
            Form {
                if let todo { Section("할 일") { Text(todo.title) } }
                Section("시간") {
                    DatePicker("시작", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    Stepper("\(minutes)분", value: $minutes, in: 5...480, step: 5)
                    Toggle("고정하기", isOn: $locked)
                    if !conflicts.isEmpty {
                        Label("캘린더의 바쁜 시간과 겹쳐요", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                if let block {
                    Section { Button("예정 시간 지우기", role: .destructive) { model.deleteBlock(block); dismiss() } }
                }
            }
            .navigationTitle(block == nil ? "시간 잡기" : "예정 시간")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { save() }.disabled(saving || (todo == nil && block == nil)) }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        if let block {
            start = block.startAt; minutes = max(5, Int(block.endAt.timeIntervalSince(block.startAt) / 60)); locked = block.locked
        } else {
            // 다음 정각 이후 30분 단위로 올린 시각을 기본으로.
            let cal = model.cal
            let now = model.now
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
            var next = cal.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: ((c.minute ?? 0) / 30 + 1) * 30)) ?? now
            if next <= now { next = now.addingTimeInterval(1800) }
            start = next
            if let m = todo?.estimateMin { minutes = max(5, m) }
        }
    }

    private func save() {
        saving = true
        Task {
            var ok = false
            if let block {
                ok = await model.moveBlock(block, start: start, end: end)
                if ok, locked != block.locked { model.setLocked(block, locked: locked) }
            } else if let todo {
                ok = await model.createBlock(todo: todo, start: start, end: end, locked: locked)
            }
            saving = false
            if ok { dismiss() }
        }
    }
}

/// 읽을 캘린더를 고른다. 원본은 수정하지 않는다.
struct CalendarPickerView: View {
    let model: TodayModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var calendars: [CalendarInfo] = []

    var body: some View {
        NavigationStack {
            Form {
                switch model.calendarAccess {
                case .granted:
                    Section(footer: Text("고른 캘린더의 일정은 이 기기에서만 읽어요. 일정 제목은 서버와 비서로 보내지 않고, 비서에게는 바쁜 시간 구간(시작·끝)만 보내요. 캘린더에는 아무것도 쓰지 않아요.")) {
                        ForEach(calendars) { c in
                            Toggle(isOn: Binding(get: { chosen.contains(c.id) }, set: { on in if on { chosen.insert(c.id) } else { chosen.remove(c.id) } })) {
                                VStack(alignment: .leading) { Text(c.title); if !c.sourceTitle.isEmpty { Text(c.sourceTitle).font(.caption).foregroundStyle(.secondary) } }
                            }
                        }
                    }
                case .notDetermined:
                    Section { Button("캘린더 접근 허용하기") { Task { await model.requestCalendarAccess(); reload() } } }
                case .denied:
                    Section(footer: Text("설정 앱에서 캘린더 접근을 허용하면 바쁜 시간을 함께 볼 수 있어요.")) { Text("캘린더 접근이 꺼져 있어요.") }
                }
            }
            .navigationTitle("읽을 캘린더")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { Task { await model.setSelectedCalendars(chosen); dismiss() } }.disabled(model.calendarAccess != .granted)
                }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        calendars = model.calendar.availableCalendars()
        chosen = model.calendar.selectedCalendarIDs ?? []
    }
}
