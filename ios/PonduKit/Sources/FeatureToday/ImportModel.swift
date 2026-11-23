import Foundation
import Observation
import PonduCore
#if canImport(UIKit)
import UIKit
#endif

/// `import-extract` 가 돌려주는 후보 한 건.
struct ImportCandidate: Codable, Identifiable, Hashable, Sendable {
    var title: String
    var dueDate: String?        // yyyy-MM-dd
    var dueTime: String?        // HH:mm
    var estimateMin: Int?
    var done: Bool
    var sourceRef: String
    var uncertain: Bool

    var id: String { sourceRef }
}

struct ImportExtractResponse: Decodable, Sendable { var items: [ImportCandidate] }
struct ImportCreateResult: Decodable, Sendable {
    var created: [TodayTodo]
    var skipped: Int
}

/// 후보 목록에 붙는 표시. 이미 가진 항목(같은 source_ref)이거나 같은 묶음 안의 중복이면 `isDuplicate`.
struct ImportRow: Identifiable, Hashable, Sendable {
    var candidate: ImportCandidate
    var isDuplicate: Bool
    var isSelected: Bool
    var id: String { candidate.sourceRef }
}

enum ImportLogic {
    /// 중복 표시와 기본 선택. 중복은 기본으로 고르지 않고, 애매한 항목은 고르되 표시만 한다(사용자가 확인).
    static func rows(from items: [ImportCandidate], existingRefs: Set<String>) -> [ImportRow] {
        var seen = existingRefs
        return items.map { item in
            let dup = seen.contains(item.sourceRef)
            seen.insert(item.sourceRef)
            return ImportRow(candidate: item, isDuplicate: dup, isSelected: !dup)
        }
    }

    /// `import_todos`의 `p_items`. import-extract가 준 `due_date`("YYYY-MM-DD")와 `due_time`("HH:MM" 또는 null)을
    /// 그대로 보낸다. 시각을 앱이 만들어 보내지 않는다(날짜만 있을 때의 기본 시각과 시간대 처리는 서버가 한다).
    static func payload(rows: [ImportRow]) -> JSONValue {
        let items: [JSONValue] = rows.filter(\.isSelected).map { r in
            let c = r.candidate
            return .object([
                "title": .string(c.title),
                "due_date": .text(c.dueDate),
                "due_time": .text(c.dueTime),
                "estimate_min": .int(c.estimateMin),
                "source_ref": .string(c.sourceRef),
                "done": .bool(c.done),
            ])
        }
        return .array(items)
    }
}

@MainActor @Observable
final class ImportModel {
    enum Phase: Equatable { case input, extracting, preview, saving, done(created: Int, skipped: Int), failed(String) }

    var pastedText = ""
    private(set) var phase: Phase = .input
    private(set) var rows: [ImportRow] = []
    private(set) var source = "text"

    @ObservationIgnored private let today: TodayModel

    init(today: TodayModel) { self.today = today }

    var canExtract: Bool { !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (phase == .input || isFailed) }
    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }
    var selectedCount: Int { rows.filter(\.isSelected).count }

    func extractText() async {
        let text = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        source = "text"
        await extract(body: .object(["text": .string(text)]))
    }

    /// 사진 보관함 권한 없이 `PhotosPicker`가 준 이미지 한 장.
    func extractImage(data: Data) async {
        source = "image"
        guard let jpeg = Self.downscaledJPEG(data) else { phase = .failed("이미지를 읽지 못했어요."); return }
        await extract(body: .object(["image_base64": .string(jpeg.base64EncodedString()), "media_type": .string("image/jpeg")]))
    }

    private func extract(body: JSONValue) async {
        phase = .extracting
        do {
            let res: ImportExtractResponse = try await today.backend.call(function: "import-extract", body: body)
            let existing = Set((today.snapshot?.todos ?? []).compactMap(\.sourceRef))
            rows = ImportLogic.rows(from: res.items, existingRefs: existing)
            phase = rows.isEmpty ? .failed("가져올 항목을 찾지 못했어요. 내용을 확인하고 다시 해 보세요.") : .preview
        } catch {
            phase = .failed(TodayModel.message(for: error, action: "항목을 읽지"))
        }
    }

    func toggle(_ id: String) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].isSelected.toggle() }
    }

    /// 고른 것만 저장한다. 서버도 같은 `(source, source_ref)`를 건너뛴다.
    func save() async {
        guard selectedCount > 0 else { return }
        phase = .saving
        do {
            let res: ImportCreateResult = try await today.backend.rpc("import_todos", [
                "p_source": .string(source), "p_items": ImportLogic.payload(rows: rows),
            ])
            phase = .done(created: res.created.count, skipped: res.skipped)
            await today.load()
        } catch {
            phase = .failed(TodayModel.message(for: error, action: "저장하지"))
        }
    }

    func reset() { pastedText = ""; rows = []; phase = .input }

    /// 긴 변 1600px 이하 JPEG. 스크린샷 한 장이 서버 요청 크기를 넘지 않게 한다.
    nonisolated static func downscaledJPEG(_ data: Data, maxSide: CGFloat = 1600) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)
        #else
        return nil
        #endif
    }
}
