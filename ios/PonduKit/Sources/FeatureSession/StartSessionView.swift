import SwiftUI
import PonduCore

/// 시작 화면: 분야, 이어가는 일, 공개 대상, 사진 찍기 또는 건너뛰기.
struct StartSessionView: View {
    let controller: SessionController
    let draft: StartDraft

    var body: some View {
        @Bindable var d = draft
        NavigationStack {
            Form {
                if let title = d.displayTitle, !title.isEmpty {
                    Section("할 일") { Text(title) }
                }
                if let name = d.joinedWithName {
                    Section { Label("\(name)과 함께", systemImage: "person.2.fill") }
                }
                Section("분야") {
                    ForEach(SessionRules.categories, id: \.self) { raw in
                        Button {
                            d.category = raw
                        } label: {
                            HStack {
                                Circle().fill(CategoryStyle.color(raw)).frame(width: 10, height: 10)
                                Text(CategoryStyle.name(raw)).foregroundStyle(.primary)
                                Spacer()
                                if d.category == raw { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }
                Section("이어가는 일") {
                    if d.threadsLoading {
                        Text("불러오는 중").foregroundStyle(.secondary).skeleton(true)
                    } else if d.threadsFailed {
                        Text("이어가는 일을 불러오지 못했어요. 선택 없이 시작할 수 있어요.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("이어가는 일", selection: Binding(get: { d.threadID }, set: { d.selectThread($0) })) {
                            Text("선택 안 함").tag(UUID?.none)
                            ForEach(d.threads) { t in Text(t.title).tag(Optional(t.id)) }
                        }
                    }
                }
                Section("공개 대상") {
                    Picker("공개 대상", selection: $d.visibility) {
                        ForEach(ShareTarget.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if d.visibility != .private {
                        TextField("친구에게 보일 제목(선택)", text: $d.shareTitle)
                    }
                }
                Section("사진") {
                    photoRow(d)
                    Text("사진은 지금 앱에서 찍은 것만 붙일 수 있어요. 건너뛰면 `사진 없는 기록`으로 남아요.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("세션 시작")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { controller.cancelStart() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("시작") { controller.commitStart() }.disabled(!d.canStart).bold()
                }
            }
            #if canImport(UIKit) && canImport(AVFoundation)
            .fullScreenCover(isPresented: $d.isCameraPresented) {
                CameraView(onCapture: { data in
                    d.isCameraPresented = false
                    controller.capturePhoto(data)
                }, onCancel: { d.isCameraPresented = false })
            }
            #endif
        }
    }

    @ViewBuilder
    private func photoRow(_ d: StartDraft) -> some View {
        if d.isProcessingPhoto {
            HStack { ProgressView(); Text("사진을 줄이는 중") }
        } else if d.photo != nil {
            HStack {
                Label("앱 촬영 첨부", systemImage: "camera.fill")
                Spacer()
                Button("다시 찍기") { d.isCameraPresented = true }
                Button("빼기", role: .destructive) { d.removePhoto() }
            }
            .buttonStyle(.borderless)
        } else {
            Button { d.isCameraPresented = true } label: { Label("사진 찍기", systemImage: "camera") }
            if d.photoFailed {
                Text("사진을 저장하지 못했어요. 다시 찍거나 건너뛰어 주세요.").font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

enum CategoryStyle {
    static func name(_ raw: String) -> String { ActivityCategory(serverKey: raw)?.displayName ?? raw }
    static func color(_ raw: String) -> Color { ActivityCategory(serverKey: raw)?.color ?? .gray }
}
