import XCTest
@testable import PonduCore

final class CodecTests: XCTestCase {
    private let sessionJSON = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "user_id": "22222222-2222-2222-2222-222222222222",
      "thread_id": null, "todo_id": null, "plan_block_id": null, "joined_session_id": null,
      "primary_category": "venture_research_intern",
      "tags": ["a", "b"],
      "started_at": "2026-11-22T10:15:30.123456+00:00",
      "ended_at": null, "paused_at": null,
      "paused_seconds": 0, "duration_seconds": 125,
      "status": "needs_confirmation", "outcome": null,
      "capture_mode": "in_app_photo",
      "photo_path": "u/s/full.heic", "photo_thumb_path": "u/s/thumb.heic",
      "share_title": null, "progress_note": "원인은 찾았어요", "visibility": "friends",
      "end_corrected": true, "offline_started_at": "2026-11-22T10:00:00Z"
    }
    """

    func testSessionDecodesSnakeCaseEnumsAndMicrosecondDates() throws {
        let session = try PonduJSON.makeDecoder().decode(SessionDTO.self, from: Data(sessionJSON.utf8))
        XCTAssertEqual(session.primaryCategory, .ventureResearchIntern)
        XCTAssertEqual(session.status, .needsConfirmation)
        XCTAssertEqual(session.captureMode, .inAppPhoto)
        XCTAssertEqual(session.visibility, .friends)
        XCTAssertEqual(session.durationSeconds, 125)
        XCTAssertTrue(session.endCorrected)
        XCTAssertNil(session.endedAt)
        XCTAssertEqual(session.photoThumbPath, "u/s/thumb.heic")
        let expected = ISO8601DateFormatter().date(from: "2026-11-22T10:15:30Z")!
        XCTAssertEqual(session.startedAt.timeIntervalSince1970, expected.timeIntervalSince1970 + 0.123, accuracy: 0.01)
        XCTAssertNotNil(session.offlineStartedAt)
        XCTAssertEqual(session.recordBadges, ["앱 촬영 첨부", "나중에 정정함", "오프라인 시작"])
    }

    func testPageOfFeedCards() throws {
        let json = """
        {"items": [{
          "session_id": "11111111-1111-1111-1111-111111111111",
          "author": {"id": "22222222-2222-2222-2222-222222222222", "handle": "kim", "display_name": "김", "avatar_path": null, "department_name": null},
          "thread_id": null, "share_title": "로그인 문제", "primary_category": "coding",
          "started_at": "2026-11-22T10:15:30Z", "ended_at": null, "status": "live", "duration_seconds": 10,
          "progress_note": null, "photo_path": null, "photo_thumb_path": null, "capture_mode": "no_photo",
          "end_corrected": false, "offline_started": false, "joined_with": null,
          "reaction_count": 2, "my_reaction": null, "comment_count": 0
        }], "next_cursor": "abc"}
        """
        let page = try PonduJSON.makeDecoder().decode(Page<FeedCardDTO>.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.nextCursor, "abc")
        XCTAssertEqual(page.items[0].author.displayName, "김")
        XCTAssertEqual(page.items[0].recordBadges, ["사진 없는 기록"])
        XCTAssertTrue(page.items[0].isLive)
    }

    func testCategoryKeyedDictionaryKeepsSnakeCaseKeys() throws {
        let json = #"{"estimate_factors": {"study": 1.5, "venture_research_intern": 2.0}}"#
        struct Holder: Decodable { let estimateFactors: [String: Double] }
        let holder = try PonduJSON.makeDecoder().decode(Holder.self, from: Data(json.utf8))
        XCTAssertEqual(holder.estimateFactors["venture_research_intern"], 2.0)
        XCTAssertEqual(holder.estimateFactors["study"], 1.5)
    }

    func testEncodeThenDecodeRoundTrip() throws {
        let profile = Profile(id: UUID(), handle: "kim_1", displayName: "김", schoolId: UUID())
        let json = try PonduJSON.jsonValue(profile)
        XCTAssertEqual(json["display_name"]?.stringValue, "김")
        XCTAssertNil(json["department_id"])   // nil 값은 인코딩에서 빠진다
        let data = try JSONEncoder().encode(json)
        let decoded = try PonduJSON.makeDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testJSONValueLiteralsAndRoundTrip() throws {
        let value: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": 2.5]
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testDateFormatting() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        XCTAssertEqual(PonduJSON.parseDate(PonduJSON.formatDate(date))?.timeIntervalSince1970 ?? 0, 1_700_000_000.5, accuracy: 0.001)
        XCTAssertNotNil(PonduJSON.parseDate("2026-11-22T10:15:30Z"))
        XCTAssertNotNil(PonduJSON.parseDate("2026-11-22T10:15:30.5+09:00"))
        XCTAssertNil(PonduJSON.parseDate("어제"))
    }

    func testRecordBadgesNeverSayCertified() {
        let all = RecordBadge.labels(captureMode: .inAppPhoto, endCorrected: true, offlineStarted: true)
            + RecordBadge.labels(captureMode: .noPhoto, endCorrected: false, offlineStarted: false)
        XCTAssertFalse(all.contains { $0.contains("인증") })
    }
}

