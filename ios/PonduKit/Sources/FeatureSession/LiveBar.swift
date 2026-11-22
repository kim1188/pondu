import SwiftUI

/// 경과 시간 글자. 이 글자만 1초마다 다시 그린다.
struct ElapsedLabel: View {
    let clock: SessionClock
    var body: some View {
        if clock.running {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(ElapsedFormat.clock(clock.elapsed())).monospacedDigit()
            }
        } else {
            Text(ElapsedFormat.clock(clock.elapsed())).monospacedDigit()
        }
    }
}

/// 진행 중 막대. 시작·정지·끝내기는 누르는 즉시 바뀐다.
struct LiveBar: View {
    let controller: SessionController
    let live: SessionController.LiveState

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(CategoryStyle.color(live.category)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(live.shareTitle ?? CategoryStyle.name(live.category)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let name = live.joinedWithName { Text("\(name)과 함께").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 6) {
                    Text(live.phase == .paused ? "일시 정지" : "세션 시작 후").font(.caption).foregroundStyle(.secondary)
                    ElapsedLabel(clock: live.clock).font(.caption.weight(.medium))
                    if live.isOfflineStart { Text("오프라인 시작").font(.caption2).foregroundStyle(.orange) }
                    else if live.captureMode == "in_app_photo" { Text("앱 촬영 첨부").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 8)
            if live.phase == .needsConfirmation {
                Button("종료 확인") { controller.route = .confirmEnd }.buttonStyle(.borderedProminent)
            } else {
                Button { controller.togglePause() } label: {
                    Image(systemName: live.phase == .paused ? "play.fill" : "pause.fill").frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .disabled(controller.isBusy)
                .accessibilityLabel(live.phase == .paused ? "다시 시작" : "일시 정지")
                Button("끝내기") { controller.presentEnd() }.buttonStyle(.borderedProminent).disabled(controller.isBusy)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial)
    }
}
