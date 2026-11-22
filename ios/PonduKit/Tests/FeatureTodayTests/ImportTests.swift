import XCTest
import PonduCore
@testable import FeatureToday

final class ImportTests: XCTestCase {
    func cand(_ title: String, ref: String, date: String? = nil, time: String? = nil, uncertain: Bool = false, done: Bool = false) -> ImportCandidate {
        ImportCandidate(title: title, dueDate: date, dueTime: time, estimateMin: nil, done: done, sourceRef: ref, uncertain: uncertain)
    }

    func testRowsMarkExistingAndRepeatedAsDuplicateAndUnselected() {
        let rows = ImportLogic.rows(from: [cand("A", ref: "r1"), cand("B", ref: "r2"), cand("A 또", ref: "r1")], existingRefs: ["r2"])
        XCTAssertEqual(rows.map(\.isDuplicate), [false, true, true])
        XCTAssertEqual(rows.map(\.isSelected), [true, false, false])
    }

    func testPayloadContainsOnlySelectedWithDueRules() {
        var rows = ImportLogic.rows(from: [
            cand("날짜만", ref: "r1", date: "2026-11-25"),
            cand("시각까지", ref: "r2", date: "2026-11-25", time: "14:30", done: true),
            cand("뺄 것", ref: "r3"),
        ], existingRefs: [])
        rows[2].isSelected = false
        guard case .array(let items) = ImportLogic.payload(rows: rows, timeZone: Fixture.tz) else { return XCTFail() }
        XCTAssertEqual(items.count, 2)
        guard case .object(let a) = items[0], case .object(let b) = items[1] else { return XCTFail() }
        XCTAssertEqual(a["due_has_time"], .bool(false))
        XCTAssertEqual(b["due_has_time"], .bool(true))
        XCTAssertEqual(b["done"], .bool(true))
        XCTAssertEqual(b["due_at"], .string("2026-11-25T05:30:00Z"))     // 14:30 KST
        XCTAssertEqual(a["source_ref"], .string("r1"))
    }

    @MainActor func testExtractTextMarksDuplicatesAgainstExistingTodos() async {
        let backend = StubBackend()
        backend.callResponses["import-extract"] = """
        {"items":[{"title":"운동","due_date":null,"due_time":null,"estimate_min":null,"done":false,"source_ref":"ref-dup","uncertain":false},
                  {"title":"새 과제","due_date":"2026-11-26","due_time":null,"estimate_min":60,"done":false,"source_ref":"ref-new","uncertain":true}]}
        """
        let today = Fixture.makeModel(backend: backend)
        await today.load()                       // todoB의 source_ref = ref-dup
        let model = ImportModel(today: today)
        model.pastedText = "운동\n새 과제 11/26"
        await model.extractText()
        XCTAssertEqual(model.phase, .preview)
        XCTAssertEqual(model.rows.map(\.isDuplicate), [true, false])
        XCTAssertEqual(model.selectedCount, 1)
        XCTAssertTrue(model.rows[1].candidate.uncertain)
    }

    @MainActor func testSaveSendsOnlySelectedItems() async {
        let backend = StubBackend()
        backend.callResponses["import-extract"] = """
        {"items":[{"title":"A","due_date":null,"due_time":null,"estimate_min":null,"done":false,"source_ref":"r1","uncertain":false},
                  {"title":"B","due_date":null,"due_time":null,"estimate_min":null,"done":false,"source_ref":"r2","uncertain":false}]}
        """
        backend.responses["import_todos"] = #"{"created":[],"skipped":1}"#
        let today = Fixture.makeModel(backend: backend)
        let model = ImportModel(today: today)
        model.pastedText = "x"
        await model.extractText()
        model.toggle("r2")
        await model.save()
        XCTAssertEqual(model.phase, .done(created: 0, skipped: 1))
        let call = backend.calls(named: "import_todos").first
        XCTAssertEqual(call?.params["p_source"], .string("text"))
        guard case .array(let items)? = call?.params["p_items"] else { return XCTFail() }
        XCTAssertEqual(items.count, 1)
    }
}
