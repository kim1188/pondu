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
