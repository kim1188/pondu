import SwiftUI

/// 종료 화면: 끝냈어요 / 더 해야 해요 / 오늘은 여기까지 + 선택 메모.
struct EndSessionView: View {
    let controller: SessionController

    var body: some View {
        @Bindable var c = controller
        NavigationStack {
            Form {
                Section("어떻게 됐나요?") {
                    ForEach(EndChoice.allCases) { choice in
                        Button { c.endDraft.choice = choice } label: {
                            HStack {
                                Text(choice.title).foregroundStyle(.primary)
                                Spacer()
                                if c.endDraft.choice == choice { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                                else { Image(systemName: "circle").foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Section("어디까지 했나요? (선택)") {
                    TextField("메모", text: $c.endDraft.note, axis: .vertical).lineLimit(2...6)
                }
                Section {
                    Text("종료 시각은 서버가 기록해요.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("세션 종료")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { c.dismissEnd() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { c.commitEnd() }.disabled(c.endDraft.choice == nil).bold()
                }
            }
        }
    }
}

/// 종료 확인 필요: 한도를 넘긴 세션의 실제 종료 시각을 고른다.
struct ConfirmEndView: View {
    let controller: SessionController

    var body: some View {
        @Bindable var c = controller
        NavigationStack {
            Form {
                Section {
                    Text("오래 끝내지 않아서 종료 확인이 필요해요. 실제로 끝낸 시각을 골라 주세요. 확인하기 전에는 기록 시간에 들어가지 않아요.")
                        .font(.subheadline)
                }
                if let l = c.live, let started = l.startedAt {
                    let upper = c.confirmUpperBound(for: l) ?? started.addingTimeInterval(3600)
                    Section("종료 시각") {
                        DatePicker("종료 시각", selection: $c.confirmDate,
                                   in: started.addingTimeInterval(60)...max(upper, started.addingTimeInterval(120)),
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                    Section { Text("저장하면 `나중에 정정함`으로 표시돼요.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("종료 확인")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("나중에") { c.route = .none } }
                ToolbarItem(placement: .confirmationAction) { Button("이 시각으로 종료") { c.commitConfirmEnd() }.bold() }
            }
        }
    }
}
