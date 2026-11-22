import SwiftUI
import PhotosUI
import PonduCore

/// 텍스트 붙여넣기 / 스크린샷 한 장 → 후보 미리보기 → 고른 것만 저장.
/// PhotosPicker는 시스템 선택 화면이라 사진 보관함 권한이 필요 없다.
struct ImportView: View {
    @State private var model: ImportModel
    @State private var pickedItem: PhotosPickerItem?
    @Environment(\.dismiss) private var dismiss

    init(today: TodayModel) { _model = State(initialValue: ImportModel(today: today)) }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .input: inputForm
                case .extracting, .saving: ProgressView("잠시만요…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .preview: preview
                case .done(let created, let skipped): doneView(created: created, skipped: skipped)
                case .failed(let message): failedView(message)
                }
            }
            .navigationTitle("가져오기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { await model.extractImage(data: data) }
                    pickedItem = nil
                }
            }
        }
    }

    private var inputForm: some View {
        Form {
            Section(header: Text("글 붙여넣기"), footer: Text("투두 앱이나 시간표에서 복사한 글을 붙여 넣어 보세요.")) {
                TextEditor(text: $model.pastedText).frame(minHeight: 140)
                Button("후보 뽑기") { Task { await model.extractText() } }.disabled(!model.canExtract)
            }
            Section(header: Text("스크린샷"), footer: Text("한 장만 올릴 수 있어요. 이미지는 읽은 뒤 저장하지 않아요.")) {
                PhotosPicker(selection: $pickedItem, matching: .images) { Label("스크린샷 고르기", systemImage: "photo") }
            }
        }
    }

    private var preview: some View {
        List {
            Section(footer: Text("체크한 항목만 저장돼요. 가져온 완료 표시는 기록(세션)이 되지 않아요.")) {
                ForEach(model.rows) { row in
                    Button { model.toggle(row.id) } label: {
                        HStack(alignment: .top) {
                            Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(row.isSelected ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.candidate.title).foregroundStyle(.primary)
                                Text(subtitle(row.candidate)).font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 6) {
                                    if row.isDuplicate { tag("이미 있어요") }
                                    if row.candidate.uncertain { tag("확인이 필요해요") }
                                    if row.candidate.done { tag("끝낸 일로 가져와요") }
                                }
                            }
                            Spacer()
                        }
                    }.buttonStyle(.plain)
                }
            }
            Section {
                Button("\(model.selectedCount)개 저장") { Task { await model.save() } }.disabled(model.selectedCount == 0)
                Button("다시 하기", role: .cancel) { model.reset() }
            }
        }
    }

    private func doneView(created: Int, skipped: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            Text("\(created)개를 가져왔어요").font(.headline)
            if skipped > 0 { Text("이미 있던 \(skipped)개는 건너뛰었어요").font(.subheadline).foregroundStyle(.secondary) }
            Button("닫기") { dismiss() }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).multilineTextAlignment(.center)
            Button("처음으로") { model.reset() }.buttonStyle(.bordered)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func subtitle(_ c: ImportCandidate) -> String {
        var parts: [String] = []
        if let d = c.dueDate { parts.append(c.dueTime.map { "\(d) \($0)" } ?? d) }
        if let m = c.estimateMin { parts.append("\(m)분") }
        return parts.isEmpty ? "기한 없음" : parts.joined(separator: " · ")
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
    }
}
