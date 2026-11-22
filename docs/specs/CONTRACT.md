# 공통 계약 — 병렬 구현용

여러 작업 흐름이 동시에 구현할 때 서로 맞물리는 지점을 여기서 고정한다. 이 문서와 `supabase/migrations/0001_schema.sql`이 기준이고, 흐름은 자기 소유 경로만 고친다. 계약을 바꿔야 하면 고치지 말고 최종 보고에 "계약 변경 제안"으로 적는다.

상위 문서: [PRD](../PRD.md), [SRD](../SRD.md), [M0 명세](./M0.md)

---

## 1. 작업 흐름과 소유 경로

| 흐름 | 브랜치 | 소유 경로 | 내용 |
|---|---|---|---|
| A auth-profile | `ws/a-auth-profile` | `supabase/migrations/01*.sql`, `supabase/tests/a_auth/`, `supabase/seed/` | 가입 도메인 제한, 프로필, 학과, 기기 토큰, 프로필 검색 |
| B sessions | `ws/b-sessions` | `supabase/migrations/03*.sql`, `supabase/tests/b_sessions/` | 세션 상태 전이, 사진 저장소 규칙, 누적 집계, 종료 확인 처리 |
| C social | `ws/c-social` | `supabase/migrations/02*.sql`, `supabase/tests/c_social/` | 친구, 크루, 피드, 반응, 한마디, 차단, 신고, `can_view_session` |
| D plan | `ws/d-plan` | `supabase/migrations/04*.sql`, `supabase/tests/d_plan/` | 이어가는 일, 할 일, 예정 시간, 오늘 조회, 제안 적용, 예상 시간 보정 |
| E functions | `ws/e-functions` | `supabase/functions/`, `supabase/migrations/05*.sql`, `supabase/tests/e_functions/`, `assistant/` | 서버 함수 4개(assistant, import-extract, notify, delete-account), 비서 핵심 코드 보강 |
| F ios-foundation | `ws/f-ios-foundation` | `ios/project.yml`, `ios/App/`, `ios/PonduKit/Package.swift`, `ios/PonduKit/Sources/PonduCore/`, `ios/PonduKit/Sources/FeatureAuth/`, 해당 `Tests/` | 프로젝트 뼈대, 공용 코드, 가입·프로필 화면, 탭, 설정 |
| G ios-session | `ws/g-ios-session` | `ios/PonduKit/Sources/FeatureSession/`, `ios/PonduKit/Sources/FeatureRecord/`, 해당 `Tests/` | 세션 시작·종료, 인앱 카메라, 사진 올리기, 기록 탭 |
| H ios-together | `ws/h-ios-together` | `ios/PonduKit/Sources/FeatureTogether/`, 해당 `Tests/` | 친구, 크루, 피드, 반응, 같이 하기, 차단·신고 |
| I ios-today | `ws/i-ios-today` | `ios/PonduKit/Sources/FeatureToday/`, 해당 `Tests/` | 오늘 탭, 할 일, 예정 시간, 캘린더 읽기, 알림, 비서 화면, 가져오기 |

마이그레이션 파일 이름은 `NNNN_설명.sql`이고 각 흐름은 자기 번호대(예: B는 0300~0399)만 쓴다. `0001_schema.sql`은 아무도 고치지 않는다. 열이 더 필요하면 자기 번호대에서 `alter table`로 추가하고 보고에 적는다.

## 2. 서버 공통 규칙

- 앱은 테이블을 직접 읽거나 쓰지 않는다. 모든 접근은 `public` 스키마의 함수(RPC)로 한다. 함수는 `security definer`, `set search_path = public`으로 만들고 `authenticated`에만 실행 권한을 준다. 내부용 함수는 권한을 주지 않는다.
- 함수는 첫 줄에서 `auth.uid()`가 null이면 `not_authenticated` 오류를 낸다.
- 반환은 `jsonb`. 필드 이름은 snake_case, 시각은 ISO 8601(UTC), id는 uuid 문자열.
- 오류는 `raise exception using errcode = 'P0001', message = '<코드>'`로 낸다. 코드는 4절 목록의 값만 쓴다.
- 시각은 서버가 정한다. 클라이언트가 보낸 시각을 기록 시각으로 쓰는 것은 계약에 명시된 인자(`p_offline_started_at`, `confirm_end`의 `p_ended_at`)뿐이다.
- 목록은 커서 방식. `p_cursor`는 서버가 준 불투명 문자열, `p_limit`은 1~50.
- 차단 관계(어느 방향이든)인 사용자의 데이터는 어떤 함수에서도 보이지 않는다.
- 테스트는 `supabase/tests/run.sh <폴더>`로 돈다(일반 Postgres + `tests/shim.sql`). 테스트 파일은 실패하면 예외를 던지는 SQL이다. `test_login(uuid)`로 사용자를 바꾸고 `reset role;`로 관리자로 돌아온다.
- Supabase에만 있는 기능(`pg_cron`, `storage` 정책, 인증 훅)은 일반 Postgres에서도 마이그레이션이 실패하지 않게 조건부로 쓴다(확장이 없으면 건너뛰기).

## 3. 서버 함수 목록

### 공용 JSON 모양

```
ProfileCard  {id, handle, display_name, avatar_path, department_name}
Profile      ProfileCard + {school_id, department_id}
Session      {id, user_id, thread_id, todo_id, plan_block_id, joined_session_id, primary_category, tags[],
              started_at, ended_at, paused_at, paused_seconds, duration_seconds, status, outcome,
              capture_mode, photo_path, photo_thumb_path, share_title, progress_note, visibility,
              end_corrected, offline_started_at}
Thread       {id, title, share_title, primary_category, default_visibility, archived_at}
Todo         {id, thread_id, title, due_at, due_has_time, estimate_min, status, completed_at,
              completion_source, source, source_ref, created_at}
PlanBlock    {id, todo_id, thread_id, start_at, end_at, locked, origin, status}
Crew         {id, name, invite_code, member_count, role}
Comment      {id, author: ProfileCard, body, created_at}
FeedCard     {session_id, author: ProfileCard, thread_id, share_title, primary_category, started_at, ended_at,
              status, duration_seconds, progress_note, photo_path, photo_thumb_path, capture_mode,
              end_corrected, offline_started, joined_with: ProfileCard|null,
              reaction_count, my_reaction, comment_count}
Page<T>      {items: [T], next_cursor: text|null}
```

`duration_seconds`는 진행 중이면 지금까지, 끝났으면 `ended_at - started_at - paused_seconds`.
`FeedCard`에는 개인 제목, 할 일, 예정 시간이 들어가지 않는다. `share_title`이 없으면 분야 이름으로 대신한다.

### A auth-profile

| 함수 | 인자 | 반환 |
|---|---|---|
| `get_my_profile` | — | Profile 또는 null |
| `is_handle_available` | `p_handle text` | boolean |
| `upsert_my_profile` | `p_handle text, p_display_name text, p_department_id uuid` | Profile |
| `list_departments` | — | `[{id, name}]` |
| `search_profiles` | `p_query text, p_limit int` | `[ProfileCard]` 같은 학교, 아이디 앞부분 또는 이름 일치, 본인·차단 제외 |
| `register_device_token` | `p_token text` | null |
| `profile_card` (내부) | `p_user uuid` | ProfileCard. 다른 흐름이 쓴다 |

가입 도메인 제한과 초기 데이터(고려대, 학과 목록)는 [M0 명세](./M0.md)를 따른다.

### B sessions

| 함수 | 인자 | 반환 |
|---|---|---|
| `start_session` | `p_client_id uuid, p_primary_category category, p_capture_mode capture_mode, p_visibility visibility, p_thread_id uuid, p_todo_id uuid, p_plan_block_id uuid, p_tags text[], p_share_title text, p_joined_session_id uuid, p_offline_started_at timestamptz` | Session |
| `pause_session`, `resume_session` | `p_session_id uuid` | Session |
| `end_session` | `p_session_id uuid, p_outcome session_outcome, p_progress_note text` | Session |
| `confirm_end` | `p_session_id uuid, p_ended_at timestamptz` | Session |
| `attach_session_photo` | `p_session_id uuid, p_photo_path text, p_thumb_path text` | Session |
| `update_session_share` | `p_session_id uuid, p_visibility visibility, p_share_title text, p_progress_note text` | Session |
| `get_my_live_session` | — | Session 또는 null |
| `list_my_sessions` | `p_cursor text, p_limit int, p_thread_id uuid` | Page\<Session\> |
| `get_record_summary` | `p_from date, p_to date, p_tz text` | `{days: [{day, seconds, session_count, by_category}], by_category: [{category, seconds}], threads: [{thread_id, title, seconds, last_at}]}` |
| `session_json` (내부) | `p_session sessions` | Session |
| `sweep_stale_sessions` (내부, 예약 작업) | — | 바뀐 행 수 |

- `start_session`: 같은 `p_client_id`로 다시 부르면 기존 세션을 돌려준다(중복 방지). 진행 중 세션이 있으면 `session_already_active`. `p_visibility`가 `department`나 `school`이면 `visibility_not_available`. `p_joined_session_id`가 있으면 `can_view_session`으로 확인하고, 볼 수 없거나 진행 중이 아니면 `join_not_allowed`.
- `p_offline_started_at`은 과거 12시간 이내만 받고, 받은 경우 `offline_started_at`에 기록한다. `started_at`은 그 값으로 하되 `created_at`은 서버 시각 그대로 둔다.
- 분야별 한도(시간): study 4, coding 4, exercise 3, project 4, venture_research_intern 10, parttime 10. 넘기면 `sweep_stale_sessions`가 `needs_confirmation`으로 바꾼다.
- `needs_confirmation` 세션은 누적(`daily_stats`)에 들어가지 않는다. `confirm_end` 후에 들어가고 `end_corrected = true`가 된다. `p_ended_at`은 `started_at` 이후, 한도 시각 이전이어야 한다.
- 세션이 끝나면 연결된 `plan_blocks.status`는 `started`가 되고, 할 일의 상태는 바꾸지 않는다(세션 종료와 할 일 완료는 별개). 단 `open`이던 할 일은 `in_progress`로 바꾼다.
- 모든 전이는 `session_events`에 남긴다.
- 사진 경로 규칙: 저장소 버킷 `session-photos`(비공개), `{user_id}/{session_id}/full.heic`, `{user_id}/{session_id}/thumb.heic`. 올리기는 본인 폴더에만, 읽기는 `can_view_session`이 참일 때만.

### C social

| 함수 | 인자 | 반환 |
|---|---|---|
| `send_friend_request`, `remove_friend`, `block_user`, `unblock_user` | `p_user_id uuid` | null |
| `respond_friend_request` | `p_user_id uuid, p_accept boolean` | null |
| `list_friends` | — | `[ProfileCard]` |
| `list_friend_requests` | — | `{incoming: [ProfileCard], outgoing: [ProfileCard]}` |
| `create_crew` | `p_name text` | Crew |
| `join_crew` | `p_invite_code text` | Crew |
| `leave_crew` | `p_group_id uuid` | null |
| `remove_crew_member` | `p_group_id uuid, p_user_id uuid` | null |
| `list_my_crews` | — | `[Crew]` |
| `list_crew_members` | `p_group_id uuid` | `[ProfileCard + {role}]` |
| `get_feed` | `p_cursor text, p_limit int, p_group_id uuid` | Page\<FeedCard\> |
| `get_thread_history` | `p_session_id uuid, p_limit int` | `[FeedCard]` 같은 작성자의 같은 이어가는 일 중 내가 볼 수 있는 것 |
| `set_reaction` | `p_session_id uuid, p_kind text` | null. `p_kind`가 null이면 취소 |
| `add_comment` | `p_session_id uuid, p_body text` | Comment |
| `list_comments` | `p_session_id uuid` | `[Comment]` |
| `delete_comment` | `p_comment_id uuid` | null |
| `report_session` | `p_session_id uuid, p_reason text` | null |
| `can_view_session` (내부) | `p_viewer uuid, p_session_id uuid` | boolean |

- 볼 수 있는 조건: 본인 것이거나, `friends` 이상이고 친구 사이이거나, `crew`이고 같은 크루의 활동 중인 구성원. 차단 관계면 항상 거짓. `needs_confirmation` 세션은 본인만 본다. 신고한 세션은 신고자에게 보이지 않는다.
- `get_feed`: 진행 중인 세션이 위, 그다음 최근 시작 순. `p_group_id`가 있으면 그 크루 구성원의 `crew` 공개 세션만.
- 크루는 같은 학교끼리만. 인원 상한 50. 초대 코드는 8자 이상 무작위.
- 반응, 한마디, 친구 요청이 생기면 `notification_outbox`에 `{kind, payload}`를 넣는다. kind: `reaction`, `comment`, `friend_request`, `friend_accepted`, `joined`.

### D plan

| 함수 | 인자 | 반환 |
|---|---|---|
| `create_thread` | `p_title text, p_primary_category category, p_share_title text, p_default_visibility visibility` | Thread |
| `update_thread` | `p_thread_id uuid, p_patch jsonb` | Thread |
| `archive_thread` | `p_thread_id uuid` | null |
| `list_threads` | — | `[Thread]` |
| `create_todo` | `p_title text, p_thread_id uuid, p_due_at timestamptz, p_due_has_time boolean, p_estimate_min int` | Todo |
| `update_todo` | `p_todo_id uuid, p_patch jsonb` | Todo |
| `set_todo_status` | `p_todo_id uuid, p_status todo_status` | Todo. `done`이면 `completion_source = user_action` |
| `delete_todo` | `p_todo_id uuid` | null |
| `import_todos` | `p_source text, p_items jsonb` | `{created: [Todo], skipped: int}` |
| `create_plan_block` | `p_todo_id uuid, p_thread_id uuid, p_start_at timestamptz, p_end_at timestamptz, p_locked boolean` | PlanBlock |
| `update_plan_block` | `p_block_id uuid, p_patch jsonb` | PlanBlock |
| `delete_plan_block` | `p_block_id uuid` | null |
| `get_today` | `p_day date, p_tz text` | `{todos: [Todo], blocks: [PlanBlock], threads: [Thread], live_session: Session|null, estimate_factors: {category: number}}` |
| `apply_proposal` | `p_proposal_id uuid, p_todo_indexes int[], p_block_indexes int[], p_apply_done boolean` | `{todos: [Todo], blocks: [PlanBlock]}` |
| `assistant_context` (내부, 서버 함수가 호출) | `p_user uuid, p_now timestamptz` | `{todos, blocks, estimate_factors}` |

- `p_patch`에 넣을 수 있는 키는 해당 모양의 수정 가능한 필드뿐이다. 모르는 키는 `invalid_input`.
- `import_todos`의 항목: `{title, due_at, due_has_time, estimate_min, source_ref, done}`. 같은 `(source, source_ref)`는 건너뛴다. `done`인 항목은 `completion_source = imported`로 들어가고 세션을 만들지 않는다.
- `get_today`의 `todos`는 열린 할 일 전부와 그날 끝낸 할 일, `blocks`는 그날과 겹치는 예정 시간.
- `apply_proposal`: `assistant_proposals`에 저장된 본인의 제안만, 한 번만 적용한다. 인덱스 배열이 null이면 전부. `kind`가 `reschedule`이면 잠기지 않은 앞으로의 `planned` 블록을 `moved`로 바꾸고 제안의 블록을 넣는다. 제안의 `todo_ref`가 `new:N`이면 방금 만든 할 일에 연결한다. 만든 블록은 `origin = assistant`. `p_apply_done`이 참이면 `done_todo_ids`를 `completion_source = user_statement`로 완료 처리한다.
- 예상 시간 보정: 할 일이 `done`이 될 때, 예상 시간이 있고 연결된 세션 시간 합이 있으면 그 분야의 최근 20개에서 (실제 ÷ 예상) 중앙값을 구해 `estimate_stats`에 넣는다. 표본 5개 미만이면 넣지 않는다. 0.5~3.0으로 자른다.

### E functions (HTTP, 로그인 토큰 필수)

| 경로 | 요청 | 응답 |
|---|---|---|
| `POST /functions/v1/assistant` | `{kind, text, pasted, now, tz, busy: [{start, end}], session: {todo_id, outcome, note}|null}` | 이벤트 스트림. `message_delta {text}` 여러 번 → `proposal {proposal_id, proposal, dropped: [{rule, detail}]}` 한 번. 실패 시 `error {code}` |
| `POST /functions/v1/import-extract` | `{text}` 또는 `{image_base64, media_type}` | `{items: [{title, due_date, due_time, estimate_min, done, source_ref, uncertain}]}` |
| `POST /functions/v1/delete-account` | `{}` | `{ok: true}` |
| `notify` | 예약 호출 | `notification_outbox`의 미발송 건을 APNs로 보낸다 |

- `assistant`는 `assistant/core/`를 그대로 가져다 쓴다. 입력의 `todos`, `blocks`, 보정 배수는 `assistant_context`로 서버가 채운다(클라이언트가 보낸 목록을 믿지 않는다). 규칙 검사에 걸리면 한 번 다시 요청하고, 그래도 걸린 블록은 빼서 `dropped`에 담는다. 통과한 제안을 `assistant_proposals`에 저장하고 그 id를 준다.
- 하루 호출 한도는 사용자당 30회(`assistant_runs` 기준, 환경 변수로 조절). 넘으면 `quota_exceeded`. 요청당 시간 제한 20초.
- 모든 호출을 `assistant_runs`에 남긴다. 대화 원문은 저장하지 않는다(`assistant_proposals.input`에는 `kind`와 `now`만).
- `import-extract`의 `source_ref`는 정규화한 제목과 날짜의 해시. 이미지는 저장하지 않는다.
- 키(`ANTHROPIC_API_KEY`, APNs 키, 관리자 키)는 환경 변수로만 읽는다.

## 4. 오류 코드

`not_authenticated`, `not_found`, `forbidden`, `invalid_input`, `email_domain_not_allowed`, `handle_taken`, `handle_invalid`, `profile_required`, `session_already_active`, `session_not_active`, `visibility_not_available`, `join_not_allowed`, `already_friends`, `request_not_found`, `blocked`, `crew_full`, `invite_invalid`, `proposal_not_found`, `proposal_already_applied`, `quota_exceeded`, `assistant_unavailable`, `rate_limited`

## 5. iOS 공통 규칙

구조는 XcodeGen 프로젝트(`ios/project.yml`) 하나와 Swift 패키지(`ios/PonduKit`) 하나다. 최소 iOS 17, Swift 5.9 이상, 외부 의존성은 `supabase-swift`뿐이다.

```
ios/PonduKit/Package.swift           (F 소유. 아래 타깃을 전부 선언한다)
ios/PonduKit/Sources/PonduCore/      공용. 다른 타깃은 PonduCore에만 의존한다
ios/PonduKit/Sources/FeatureAuth/
ios/PonduKit/Sources/FeatureSession/
ios/PonduKit/Sources/FeatureRecord/
ios/PonduKit/Sources/FeatureTogether/
ios/PonduKit/Sources/FeatureToday/
ios/PonduKit/Tests/<타깃>Tests/
ios/App/                             앱 진입점, 탭, 설정, Info.plist
```

기능 타깃끼리는 서로 가져오지 않는다. 필요한 연결은 `PonduCore`의 프로토콜을 거친다.

### PonduCore가 제공하는 것 (F가 구현, 나머지는 이 이름으로 사용)

```swift
public protocol Backend: Sendable {
    var currentUserID: UUID? { get }
    /// 서버 함수 호출. params의 키는 p_ 접두사를 포함한 서버 인자 이름 그대로.
    func rpc<T: Decodable>(_ name: String, _ params: [String: JSONValue]) async throws -> T
    func rpcVoid(_ name: String, _ params: [String: JSONValue]) async throws
    func call<T: Decodable>(function: String, body: JSONValue) async throws -> T
    func stream(function: String, body: JSONValue) -> AsyncThrowingStream<ServerEvent, Error>
    func upload(path: String, fileURL: URL, contentType: String) async throws   // 백그라운드 전송
    func signedURL(path: String) async throws -> URL
}
public enum JSONValue: Codable, Sendable, Hashable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }
public struct ServerEvent: Sendable { public let name: String; public let data: Data }
public struct BackendError: Error, Equatable { public let code: String }   // 4절의 코드, 또는 "network", "timeout", "unknown"

public struct AppDependencies {
    public let backend: Backend
    public let sessions: SessionControlling      // G가 구현, F가 주입
    public let now: @Sendable () -> Date
}
public protocol SessionControlling: AnyObject {
    /// 시작 화면을 띄운다. 오늘 탭의 `지금 시작`, 함께 탭의 `같이 하기`가 부른다.
    @MainActor func presentStart(_ request: StartSessionRequest)
    @MainActor var liveSession: SessionDTO? { get }
}
public struct StartSessionRequest {
    public var category: Category?; public var threadID: UUID?; public var todoID: UUID?; public var planBlockID: UUID?
    public var title: String?; public var joinedSessionID: UUID?; public var joinedWithName: String?
}
```

- 모델: `Profile`, `ProfileCard`, `SessionDTO`, `ThreadDTO`, `TodoDTO`, `PlanBlockDTO`, `CrewDTO`, `CommentDTO`, `FeedCardDTO`, `Page<T>`, 그리고 열거형 `Category`, `Visibility`, `SessionStatus`, `SessionOutcome`, `CaptureMode`, `TodoStatus`. 3절의 JSON 모양과 필드가 일대일이고 Swift 쪽은 camelCase다(디코더가 snake_case를 변환한다).
- 화면 부품: `RemoteImage(path:)`(서명 주소 발급, 디스크 캐시, 화면에 들어올 때 받고 벗어나면 취소), `.skeleton(_ isLoading: Bool)`, `ErrorRetryView`, `Theme`(색, 간격, 글자 크기. 시스템 글꼴만), `Category.displayName`, `Category.color`.
- 도구: `Debouncer`(0.3초), `InFlight`(같은 요청 합치기), `DiskCache`, `Signpost`(구간 측정).

### 기능 타깃이 내놓는 것

| 타깃 | 공개 뷰 | 비고 |
|---|---|---|
| FeatureAuth | `AuthFlowView(deps:onSignedIn:)`, `ProfileEditView(deps:)` | |
| FeatureSession | `SessionController`(SessionControlling 구현, `init(backend:)`), `SessionHostView(controller:)`(진행 중 막대와 시작·종료 화면을 얹는 겉 뷰) | |
| FeatureRecord | `RecordRootView(deps:)` | |
| FeatureTogether | `TogetherRootView(deps:)` | |
| FeatureToday | `TodayRootView(deps:)` | |

### 성능 규칙 (SRD 4절)

- 목록은 `List` 또는 `LazyVStack`, 20개씩 커서로 더 받는다.
- 화면 하나는 서버 함수 하나로 그린다. 행마다 추가 요청을 보내지 않는다.
- 누르는 즉시 화면을 바꾸고 서버 전송은 뒤에서 한다. 실패하면 되돌리고 알린다.
- 서로 무관한 요청은 `async let`으로 동시에. 요청 시간 제한은 일반 10초, 비서 20초, 사진 60초.
- 사진은 촬영 직후 긴 변 1600px와 480px 두 장의 HEIC로 줄인다. 피드는 작은 것만 받는다.
- 오늘·기록 화면은 기기에 저장한 값으로 먼저 그리고 서버 값으로 갱신한다.
- 사진 보관함 권한은 요청하지 않는다. 세션 사진은 인앱 카메라로만 찍는다.

## 6. 완료 보고에 담을 것

1. 만든 것과 파일 위치
2. 실행해서 확인한 것(명령과 결과)과 실행하지 못해 확인하지 못한 것
3. 계약과 다르게 한 부분, 계약 변경 제안
4. 다른 흐름이 알아야 할 것

## 7. 신뢰 경계

이 문서는 앞선 프로젝트의 SSRD(서브시스템 분해와 인터페이스 계약)에 해당한다. 아래 세 절은 그 형식에서 빠져 있던 부분이다.

| 경계 | 믿는 것 | 믿지 않는 것 |
|---|---|---|
| 앱 → DB 함수 | 로그인 토큰의 사용자 id | 앱이 보낸 시각, 소유자 id, 상태 값, 제안 내용 |
| 앱 → 서버 함수(assistant) | 로그인 토큰, 사용자가 쓴 문장 | 앱이 보낸 할 일·예정 시간 목록(서버가 다시 읽는다) |
| 서버 함수 → Claude | 출력 형식에 맞는 값 | 값의 내용. 규칙 검사를 통과해야 저장된다 |
| 붙여 넣은 글, 가져온 일정, 할 일 제목, 세션 메모 | 없음. 전부 데이터 | 그 안의 지시문 |
| 다른 사용자 | `can_view_session`이 참인 세션의 공유용 필드 | 그 밖의 모든 것 |
| 기기 저장소 | 화면을 먼저 그리는 용도 | 기록의 원본(원본은 서버) |

## 8. 흐름 사이의 순서

**세션 시작과 같이 하기** (G: 앱, B·C: DB)

1. G가 `start_session(p_client_id, …, p_joined_session_id)`을 부른다. 화면은 먼저 바뀐다.
2. B가 `p_joined_session_id`가 있으면 C의 `can_view_session`으로 확인한다. 거짓이면 `join_not_allowed`.
3. B가 세션을 만들고 `session_events`에 남긴다. 같은 `p_client_id`면 기존 세션을 돌려준다.
4. C가 상대에게 `joined` 알림을 `notification_outbox`에 넣는다.
5. G가 사진을 올린 뒤 `attach_session_photo`를 부른다. 3번은 이것을 기다리지 않는다.

**비서 제안과 적용** (I: 앱, E: 서버 함수, D: DB)

1. I가 `assistant`에 문장과 바쁜 시간 구간을 보낸다.
2. E가 한도를 확인하고 D의 `assistant_context`로 할 일·예정 시간·보정 배수를 읽는다.
3. E가 Claude를 부르고 규칙 검사를 한다. 걸리면 한 번 다시 부르고, 그래도 걸린 블록은 뺀다.
4. E가 `assistant_proposals`에 저장하고 `proposal_id`를 준다. 이 시점까지 할 일과 예정 시간은 바뀌지 않는다.
5. 사용자가 고르면 I가 `apply_proposal`을 부른다. D가 소유와 겹침을 다시 확인하고 한 번만 적용한다.

**세션 종료 뒤 재배치** (G → I → E → D)

1. G가 `end_session(p_outcome = 'more')`를 부른다. B는 할 일을 완료 처리하지 않는다.
2. I가 `assistant`에 `kind = reschedule`과 `session`을 보낸다. 이후는 위와 같다.

## 9. 통합 관문

`PROGRESS.md`의 "통합 관문" 표(G1~G6)를 따른다. 흐름 하나가 끝났다는 것은 자기 테스트가 통과했다는 뜻이고, 관문을 지나야 연결됐다고 말한다.
