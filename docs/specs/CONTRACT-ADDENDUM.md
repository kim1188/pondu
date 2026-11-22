# 공통 계약 보정 1 (2026-11-22)

맥락 없는 리뷰어 두 명(설계 비평, 구현 준비도)이 `CONTRACT.md`를 검토해 찾은 구멍과 빈칸에 대한 결정이다. `CONTRACT.md`와 다르면 이 문서가 우선한다. 병렬 구현이 이미 진행 중일 때 나온 것이라, 끝난 흐름(A, C, D, H, I)에 해당하는 항목은 통합 담당이 병합할 때 고친다.

확인 수준: 전부 `[코드]`(문서와 스키마를 읽고 판단, 실행하지 않음).

## 조작 방지와 권한 (설계 비평)

| # | 문제 | 결정 | 담당 |
|---|---|---|---|
| S1 | 오프라인 시작으로 12시간 전까지 소급할 수 있고 세션 구간이 겹칠 수 있다 | `p_offline_started_at`은 그 사용자의 마지막 `ended_at` 이후여야 한다. 겹치면 `invalid_input` | B |
| S2 | `start_session`, `create_todo`, `create_plan_block`에 남의 thread·todo·block id를 넣을 수 있다 | id 인자는 전부 본인 소유를 확인한다. 아니면 `not_found` | B, D(통합 때 확인) |
| S3 | `joined_with`로 상대 세션이 볼 권한 없는 사람에게 보인다 | 카드를 만들 때마다 `can_view_session`이 참일 때만 채운다 | C(구현됨, 통합 때 확인) |
| S4 | 사진 경로와 첨부 시점을 서버가 믿는다 | 경로는 `{본인 id}/{세션 id}/full.heic`·`thumb.heic`만. 진행 중이거나 종료 후 10분 이내만 | B |
| S5 | `end_session`이 한도를 보지 않고, 재전송하면 오류가 난다 | `end_session`도 한도를 검사해 넘기면 `needs_confirmation`. 같은 전이를 다시 보내면 현재 Session을 돌려준다 | B |
| S6 | sweep과 사용자 전이가 겹치면 누적이 두 번 들어간다 | 모든 전이는 행 잠금 또는 조건부 갱신. 누적은 상태가 실제로 바뀔 때만 | B |
| S7 | `department`/`school` 차단이 `start_session`에만 있다 | 공개 범위를 받는 모든 함수가 `private`/`friends`/`crew` 외에는 `visibility_not_available` | B, D(구현됨) |
| S8 | 초대 코드를 바꿀 수 없다 | `rotate_invite_code(p_group_id)`(운영자 전용)를 추가한다. 내보낸 사람의 재입장은 거절(구현됨) | 통합 뒤 |
| S9 | 알림 남용(반응 반복, 재요청 반복), 차단 직전 알림 | `notify`가 보내기 직전 차단을 다시 확인한다. 같은 (받는 사람, 행위자, 종류, 대상)은 10분에 한 번. 친구 요청은 거절 후 7일 재요청 불가 | E, 통합 뒤 |
| S10 | reschedule을 일부만 적용하면 고르지 않은 기존 계획이 사라진다 | reschedule 제안은 블록 전부 적용 또는 적용 안 함. 일부 선택은 `invalid_input` | 통합 때 D·I |
| S11 | 제안에 유효 기간이 없고 `now`를 앱이 보낸다 | 비서는 서버 시각을 쓴다. 제안은 만든 지 24시간이 지나면 `proposal_not_found` | E, 통합 때 D |
| S12 | 한도가 동시 요청으로 넘칠 수 있고 가져오기에는 한도가 없다 | 한도는 원자적으로 센다. 가져오기도 하루 20회 | E |
| S13 | 비서에 열린 할 일 전부가 간다(SRD는 "선택한 할 일"이라고 적음) | 열린 할 일 전부를 보내는 것이 맞다. SRD 7절과 동의 화면 문구를 "열린 할 일의 제목"으로 고친다 | 통합 때 문서 |

## 흐름 사이의 빈칸 (구현 준비도)

| # | 빈칸 | 결정 |
|---|---|---|
| R1 | 내부 함수의 실행 권한 | 만든 직후 `revoke execute … from public, anon, authenticated`. 서버 함수가 부르는 것은 만든 흐름이 `service_role`에 준다 |
| R2 | 병합 후 테스트가 서로 간섭 | 테스트 사용자 메일은 `@korea.ac.kr`, id는 흐름마다 다른 값 또는 무작위. 학교 행은 테스트 안에서 넣는다. 개수 단언은 자기 사용자로 좁힌다 |
| R3 | `joined` 알림 담당 | B의 `start_session`이 넣는다. payload는 C 형식 `{session_id, user_id}` |
| R4 | 생략한 인자 | 필수가 아닌 인자는 `default null`. 기본값: `p_tags` → `{}`, `p_visibility` → 이어가는 일의 기본값, 없으면 `private`, `p_capture_mode` → `no_photo`, `p_limit` → 20. 범위를 벗어난 `p_limit`은 `invalid_input` |
| R5 | 오류가 앱까지 오는 형식 | RPC 오류 코드는 응답의 `message`에 있다(`code`는 항상 `P0001`). 서버 함수는 4xx/5xx와 `{"code": "…"}` 본문. 가입 훅의 메시지도 코드(`email_domain_not_allowed`)이고 한국어 문구는 앱이 붙인다 |
| R6 | 시각과 날짜의 JSON 형식 | 서버는 Postgres 기본 형식 그대로 낸다. 앱의 디코더가 소수 초 유무와 `Z`/`+00:00`을 모두 받는다. 날짜만 있는 값(`day`)은 앱에서 문자열로 받는다 |
| R7 | 분야를 키로 쓰는 객체 | `estimate_factors`처럼 분야가 키인 객체는 앱에서 키 변환의 영향을 받는다. 앱은 snake_case와 camelCase 키를 모두 받아 분야로 바꾼다 |
| R8 | `FeedCard`의 세부 | `offline_started`는 boolean. `share_title`이 없으면 서버는 null을 주고 앱이 분야 이름으로 채운다 |
| R9 | Swift 공개 타입 | `PonduCore`의 모든 public struct는 모든 인자에 기본값을 둔 `public init`을 갖는다. 열거형 이름은 `ActivityCategory`, `ShareVisibility`(SwiftUI·ObjC의 같은 이름과 충돌을 피한다) |
| R10 | 비서 스트림 형식 | `text/event-stream`. 이벤트마다 `event: <이름>` 줄과 `data: <json>` 줄. 한도·인증 오류도 200 스트림 안의 `error {code}`로 준다 |
| R11 | 시간대와 날짜 경계 | 항상 Asia/Seoul. `p_tz`는 `Asia/Seoul`만 받는다. 자정을 넘는 세션은 날짜별로 나눠 누적한다. 날짜만 있는 기한은 그날 23:59 KST, `due_has_time = false` |
| R12 | 열린 할 일과 예정 시간 상태 | 열린 할 일은 `open`과 `in_progress`. 블록은 세션을 시작할 때 `started`. 끝 시각이 지난 `planned` 블록은 `sweep_stale_sessions`가 `missed`로 바꾼다 |
| R13 | 종료 확인이 필요한 세션 | `get_my_live_session`은 `live`·`paused`·`needs_confirmation` 중 하나를 준다. `needs_confirmation`이 있으면 새 세션은 `session_already_active`. 한도는 `started_at`부터의 실제 경과 시간. `duration_seconds`는 정지 중이면 정지 시점까지, `needs_confirmation`이면 null |
| R14 | 사진 경로 | 버킷 `session-photos` 안의 경로만 저장한다(버킷 이름을 붙이지 않는다). 프로필 사진은 이번 범위에 없고 `avatar_path`는 항상 null |
| R15 | 할 일의 분야 | 연결된 끝난 세션 중 가장 긴 세션의 분야, 없으면 이어가는 일의 분야. 보정 배수가 없는 분야는 1.0으로 본다 |
| R16 | 오류 코드 기준 | 남의 것이거나 볼 수 없는 id는 `not_found`. `forbidden`은 역할이 모자랄 때만. patch의 null은 값을 지운다. `status`는 patch로 바꾸지 않는다 |
| R17 | 세션 종료 신호(앱) | 세션 화면이 `end_session` 성공 뒤 `Notification.Name("pondu.session.ended")`를 보낸다. userInfo: `todo_id`, `outcome`, `note` |

## 제품 결정이 필요한 것

- 크루 공개 세션은 지금 내가 속한 모든 크루에 보인다. 크루별로 나누려면 세션에 크루 id 열이 필요하다.
- 세션 주인이 자기 카드에 달린 남의 한마디를 지울 수 있게 할지.

## 보정 2 (2026-11-22)

보정 1의 "제품 결정이 필요한 것" 두 건이 정해졌고, 보정 1 중 코드에 아직 없던 항목(S8, S9의 재요청 제한, S10, S11, R8)을 반영했다. 이 절과 `CONTRACT.md`·보정 1이 다르면 이 절이 우선한다. iOS는 이 절에 맞춘다.

확인 수준: `[로컬]` 일반 Postgres 16에서 `supabase/tests/run.sh`로 실행해 통과. 실기기·Supabase 운영 환경 확인은 하지 않았다.

### 제품 결정

| 결정 | 내용 |
|---|---|
| 크루를 골라서 공개 | `crew` 공개 세션은 세션마다 크루 하나(`group_id`)에 묶인다. 작성자와 친구이거나, 보는 사람과 작성자가 둘 다 그 크루의 활동 중인 구성원이면 보인다. |
| 한마디 삭제 | 세션 주인이 자기 카드에 달린 남의 한마디를 지울 수 없다(`delete_comment`는 쓴 사람만, 그 밖은 `forbidden`). 바뀐 것 없음. 테스트 추가. |

### 바뀐 함수 인자

새 인자는 모두 맨 끝에 `default null`로 붙였다. 기존 호출은 그대로 동작한다.

| 함수 | 새 인자 | 규칙 |
|---|---|---|
| `start_session` | `p_group_id uuid default null` | 공개 범위가 `crew`일 때만 쓴다. (1) `p_group_id`가 있으면 호출자가 그 크루의 활동 중인 구성원이어야 하고 아니면 `not_found`. (2) 없으면 이어가는 일의 `default_group_id`(호출자가 아직 구성원일 때). (3) 그것도 없고 호출자가 속한 크루가 정확히 하나면 그 크루. (4) 그 밖에는 `invalid_input`. `crew`가 아닌 공개 범위에서는 `p_group_id`를 무시하고 `group_id`는 null. |
| `update_session_share` | `p_group_id uuid default null` | `start_session`과 같은 규칙. 단 `p_group_id`가 없으면 지금 묶인 크루가 아직 유효할 때 그것을 먼저 유지한다. 공개 범위를 `crew`가 아닌 값으로 바꾸면 `group_id`는 null. `p_visibility`가 null이면 지금 공개 범위로 판단한다. |
| `create_thread` | `p_default_group_id uuid default null` | 호출자가 활동 중인 구성원인 크루만. 아니면 `not_found`. |
| `update_thread` | patch 키 `default_group_id` | uuid 문자열 또는 null(지움). 구성원이 아닌 크루면 `not_found`, 다른 형식이면 `invalid_input`. |
| `get_feed` | (인자 없음, 동작 변경) | `p_group_id`가 있으면 `group_id`가 그 크루인 `crew` 공개 세션만(작성자가 지금도 그 크루 구성원일 때). 기본 피드에서 친구가 아닌 크루원의 `crew` 세션은 내가 그 세션의 크루 구성원일 때만 나온다. 친구의 `crew` 세션은 크루와 상관없이 나온다. |
| `get_thread_history` | (동작 변경) | 각 세션을 `can_view_session`으로 거른다. |
| `apply_proposal` | (동작 변경) | 아래 "새 규칙". |
| `import_todos` | 항목 키 추가 | 아래 "새 규칙". |
| `send_friend_request` | (동작 변경) | 아래 "새 규칙". |

### 새 함수

| 함수 | 인자 | 반환 | 규칙 |
|---|---|---|---|
| `rotate_invite_code` | `p_group_id uuid` | Crew(새 `invite_code` 포함) | 크루 운영자(`role = owner`)만. 운영자가 아니거나(구성원 아님, 없는 크루 포함) 아니면 `forbidden`, `p_group_id`가 null이면 `invalid_input`. 새 코드는 16자 무작위이고 예전 코드는 즉시 `invite_invalid`. 이미 들어온 구성원은 그대로이고, 내보낸 사람은 새 코드로도 `forbidden`(보정 1 S8). |

### JSON 필드

| 모양 | 추가·변경 | 비고 |
|---|---|---|
| Session | `group_id` (uuid 또는 null) | `visibility`가 `crew`일 때만 값이 있다. 크루가 사라지면(`on delete set null`) null이 될 수 있다. |
| Thread | `default_group_id` (uuid 또는 null) | |
| FeedCard | `group_id`, `group_name` (uuid·text 또는 null) | **보는 사람이 그 크루의 활동 중인 구성원일 때만** 채운다. 구성원이 아닌 친구에게는 크루 이름이 드러나지 않도록 null. |
| FeedCard | `share_title` | 세션에 공유 제목이 없으면 **JSON null**. 앱이 분야 이름(`primary_category`의 표시 이름)으로 채운다(R8). `CONTRACT.md` 3절의 "분야 이름으로 대신한다"는 이 절로 대체. |

### 새 규칙

| 규칙 | 내용 | 오류 |
|---|---|---|
| 친구 요청 재요청 제한 | 상대가 내 요청을 거절(`respond_friend_request(p_accept = false)`)하면 같은 상대에게 7일 동안 다시 `send_friend_request`를 못 한다. 7일이 지나면 가능. 거절한 사람이 먼저 보내는 요청은 막지 않고, 서로 친구가 되면 기록은 지워진다. 기록은 새 표 `friend_request_rejections`(앱이 직접 접근 불가). | `rate_limited` |
| 차단과 친구 요청 | 내가 상대를 차단했으면 `blocked`. 상대가 나를 차단했으면 요청도 알림도 만들지 않고 **성공(null)**을 돌려준다. 차단당한 사실이 드러나지 않게 하려는 것이다. 앱은 성공으로 보이는 "요청 보냄" 상태를 보여 주되 `list_friend_requests`에는 나타나지 않는다. | `blocked`(내가 차단한 경우만) |
| 재배치 전부 적용 | 제안의 `kind`가 `reschedule`이면 `p_block_indexes`는 블록 전체(`0..n-1`, 순서·중복 무관)여야 한다. null이거나 일부면 거절하고 제안은 소비되지 않는다. 블록이 0개인 제안은 빈 배열을 준다. `p_todo_indexes`와 다른 `kind`는 전과 같다(null이면 전부). | `invalid_input` |
| 제안 유효 기간 | 만든 지 24시간이 지난 제안은 적용할 수 없다. 이미 적용한 제안의 재적용은 기간과 상관없이 `proposal_already_applied`. | `proposal_not_found` |
| 가져오기 기한 | `import_todos` 항목은 `due_at`(+`due_has_time`) 대신 `due_date`(`YYYY-MM-DD`)와 `due_time`(`HH:MM` 또는 null)을 줄 수 있다. 한국 시간 기준이고 `apply_proposal`과 같은 변환을 쓴다. 시각이 없으면 그날 23:59 KST와 `due_has_time = false`. `due_at` 방식도 계속 받는다. 한 항목에 둘을 같이 주거나(`due_date`와 `due_at`), `due_time`만 주거나, 형식이 틀리면 거절. | `invalid_input` |
| 크루 가시성 | `can_view_session`: `crew` 공개 세션은 (작성자와 친구) 또는 (보는 사람과 작성자가 둘 다 그 세션의 `group_id` 크루의 활동 중인 구성원). `group_id`가 null인 `crew` 세션(크루가 사라진 경우)은 친구만. 차단·신고·`needs_confirmation` 규칙은 그대로. 크루에서 나가거나 내보내지면 그 크루로 묶인 세션은 그 크루원에게 곧바로 안 보인다. | |

### 계약 문서와 다르게 정한 것

| 항목 | 정한 것 | 이유 |
|---|---|---|
| 이어가는 일의 기본 크루가 더는 유효하지 않을 때 | 에러 없이 다음 규칙(크루가 하나면 그 크루, 아니면 `invalid_input`)으로 넘어간다 | 크루를 나간 뒤 기본값 때문에 세션을 못 시작하면 안 된다 |
| `update_session_share`에서 `p_group_id`를 안 줄 때 | 지금 묶인 크루가 유효하면 유지 | 제목만 고쳐도 크루가 풀리거나 오류가 나면 안 된다 |
| FeedCard `group_id`·`group_name` | 구성원에게만 채움 | 친구에게 크루 이름이 새지 않게 |
| `rotate_invite_code`의 비운영자 | 구성원이든 아니든 모두 `forbidden` | `remove_crew_member`와 같은 기준 |
