import SwiftUI
import PonduCore

struct AssistantView: View {
    @State private var model: AssistantModel
    let today: TodayModel
    @Environment(\.dismiss) private var dismiss
    @State private var manual = TodayModel.TodoDraft()

    init(kind: AssistantKind, text: String, signal: SessionEndSignal?, today: TodayModel) {
        self.today = today
        _model = State(initialValue: AssistantModel(kind: kind, text: text, today: today, consent: UserDefaultsConsent(), signal: signal))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .needsConsent: ConsentView(onAccept: { model.acceptConsent(); autoStart() }, onCancel: { dismiss() })
                case .idle: idleView
                case .streaming: streamingView
                case .proposal: proposalView
                case .applied: appliedView
                case .failed(let code): failedView(code)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { model.cancel(); dismiss() } } }
            .onAppear(perform: autoStart)
        }
    }

    private var title: String {
        switch model.kind { case .capture: return "한 줄 입력"; case .planDay: return "하루 정리"; case .reschedule: return "남은 일 조정" }
    }

    private func autoStart() {
        // 한 줄 입력은 이미 문장이 있으니 바로 보낸다. 나머지는 사용자가 눌러서 시작한다.
        if model.phase == .idle, model.kind == .capture, model.canSend { model.send() }
    }

    // MARK: 상태별 화면

    private var idleView: some View {
        Form {
            Section(footer: Text("비서가 만든 것은 초안이에요. 적용하기 전에는 아무것도 저장되지 않아요.")) {
                if model.kind == .capture || model.kind == .planDay {
                    TextField(model.kind == .capture ? "해야 할 일을 적어 주세요" : "오늘 하고 싶은 일이 있으면 적어 주세요(선택)", text: $model.inputText, axis: .vertical)
                        .lineLimit(2...6)
                } else {
                    Text("못 끝낸 일과 놓친 일을 남은 시간에 다시 배치해 볼게요.")
                }
            }
            Section { Button("비서에게 보내기") { model.send() }.disabled(!model.canSend) }
        }
    }

    private var streamingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.message.isEmpty { ProgressView("정리하는 중…") } else { Text(model.message).frame(maxWidth: .infinity, alignment: .leading) }
            Spacer()
        }
        .padding()
    }

    private var proposalView: some View {
        let env = model.envelope
        return List {
            if !model.message.isEmpty { Section { Text(model.message) } }
            let notes = model.estimateNotes()
            if !notes.isEmpty { Section("예상 시간 보정") { ForEach(notes, id: \.self) { Text($0).font(.subheadline) } } }
            if let p = env?.proposal {
                if !p.todos.isEmpty {
                    Section("새 할 일") {
                        ForEach(Array(p.todos.enumerated()), id: \.offset) { i, t in
                            selectRow(selected: model.selection?.todoIndexes.contains(i) ?? false, toggle: { model.selection?.toggleTodo(i, in: p) }) {
                                VStack(alignment: .leading) {
                                    Text(t.title)
                                    Text(todoSubtitle(t)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !p.blocks.isEmpty {
                    Section("예정 시간") {
                        ForEach(Array(p.blocks.enumerated()), id: \.offset) { i, b in
                            selectRow(selected: model.selection?.blockIndexes.contains(i) ?? false, toggle: { model.selection?.toggleBlock(i, in: p) }) {
                                VStack(alignment: .leading) {
                                    Text(blockTitle(b, proposal: p))
                                    Text(blockTime(b)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !p.doneTodoIds.isEmpty {
                    Section("끝냈다고 말씀하신 일") {
                        selectRow(selected: model.selection?.applyDone ?? false, toggle: { model.selection?.applyDone.toggle() }) {
                            VStack(alignment: .leading) {
                                ForEach(p.doneTodoIds, id: \.self) { id in Text(today.snapshot?.todo(UUID(uuidString: id))?.title ?? "할 일") }
                                Text("완료로 표시해요(내가 한 말 기준)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !p.unscheduled.isEmpty {
                    Section("시간을 못 잡았어요") { ForEach(p.unscheduled, id: \.todoRef) { Text($0.reason).font(.subheadline) } }
                }
                if !p.questions.isEmpty {
                    Section("확인할 것") { ForEach(p.questions, id: \.self) { Text($0) } }
                }
                if let dropped = env?.dropped, !dropped.isEmpty {
                    Section(footer: Text("규칙에 맞지 않아 뺀 항목이에요.")) { ForEach(Array(dropped.enumerated()), id: \.offset) { _, d in Text(d.detail).font(.caption) } }
                }
            }
            if let e = model.applyError { Section { Text(e).foregroundStyle(.red) } }
            Section {
                Button("전부 적용") {
                    if let p = env?.proposal { model.selection = ProposalSelection(for: p) }
                    Task { await model.apply() }
                }.disabled(model.isApplying || (env?.proposal.isEmpty ?? true))
                Button("고른 것만 적용") { Task { await model.apply() } }.disabled(model.isApplying || (model.selection?.isEmpty ?? true))
                Button("적용하지 않고 닫기", role: .cancel) { dismiss() }
            }
        }
    }

    private var appliedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            Text("적용했어요").font(.headline)
            Button("닫기") { dismiss() }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 실패하면 직접 입력으로 넘어간다.
    private func failedView(_ code: String) -> some View {
        Form {
            Section { Text(AssistantModel.failureText(code: code)).foregroundStyle(.secondary) }
            Section("직접 입력") {
                TextField("할 일", text: $manual.title)
                Button("할 일로 추가") {
                    Task { if await today.addTodo(manual) { dismiss() } }
                }.disabled(!manual.isValid)
            }
            if code != "quota_exceeded" { Section { Button("다시 시도") { model.send() } } }
        }
        .onAppear { if manual.title.isEmpty { manual = model.manualDraft() } }
    }

    // MARK: 도우미

    private func selectRow<Content: View>(selected: Bool, toggle: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: toggle) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
                content().foregroundStyle(.primary)
                Spacer()
            }
        }.buttonStyle(.plain)
    }

    private func todoSubtitle(_ t: ProposalTodo) -> String {
        var parts: [String] = []
        if let d = t.dueDate { parts.append(t.dueTime.map { "\(d) \($0) 마감" } ?? "\(d) 마감") }
        if let m = t.estimateMin { parts.append("\(m)분") }
        if let c = t.category.flatMap({ Category(rawValue: $0) }) { parts.append(c.displayName) }
        return parts.isEmpty ? "기한 없음" : parts.joined(separator: " · ")
    }

    private func blockTitle(_ b: ProposalBlock, proposal: AssistantProposal) -> String {
        if let n = b.newTodoIndex, proposal.todos.indices.contains(n) { return proposal.todos[n].title }
        return today.snapshot?.todo(UUID(uuidString: b.todoRef))?.title ?? "할 일"
    }

    private func blockTime(_ b: ProposalBlock) -> String {
        guard let s = b.startDate, let e = b.endDate else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR"); f.timeZone = today.timeZone; f.dateFormat = "M월 d일 HH:mm"
        let g = DateFormatter()
        g.locale = f.locale; g.timeZone = today.timeZone; g.dateFormat = "HH:mm"
        return "\(f.string(from: s))~\(g.string(from: e))"
    }
}

/// 첫 사용 전 동의: 무엇이 서버와 AI로 가는지.
struct ConsentView: View {
    let onAccept: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("비서를 쓰기 전에").font(.title2.bold())
            Text("비서가 계획을 만들려고 아래 내용을 서버와 AI에 보내요.")
            VStack(alignment: .leading, spacing: 10) {
                Label("내가 입력한 문장", systemImage: "text.cursor")
                Label("선택한 할 일의 제목", systemImage: "checklist")
                Label("캘린더의 바쁜 시간 구간(시작과 끝만)", systemImage: "calendar")
            }
            Text("캘린더 일정의 제목과 메모는 기기 밖으로 나가지 않아요. 비서는 초안만 만들고, 내가 적용해야 저장돼요.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("동의하고 시작", action: onAccept).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            Button("취소", action: onCancel).frame(maxWidth: .infinity)
        }
        .padding()
    }
}
