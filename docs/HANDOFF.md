# 인계 안내 — Mac과 실제 서비스가 필요한 작업

이 저장소의 코드는 리눅스 컨테이너에서 만들어졌다. 서버 DB 함수는 일반 Postgres에서 테스트로 확인했지만(`[로컬]`), 아래 네 가지는 Mac, 실제 Supabase 프로젝트, 실제 API 키가 있어야 해서 한 번도 해 보지 못했다. 이 문서는 그 작업을 이어받는 에이전트(Codex 등)나 사람이 순서대로 따라 하도록 쓴 것이다.

먼저 `AGENTS.md`를 읽는다. 특히 3절(확인한 수준을 섞어 말하지 않는다)과 "지어내지 않는다"를 지킨다. 각 작업이 끝나면 `PROGRESS.md`의 해당 줄에 날짜, 확인 수준, 한 줄 결과를 적는다.

작업 순서는 4 → 2 → 3 → 1을 권한다. 학과 목록과 Supabase가 먼저 있어야 앱이 가입 화면을 지나갈 수 있다.

---

## 1. Mac: iOS 첫 빌드와 시뮬레이터 실행

**상태**: Swift 파일 90여 개가 `ios/`에 있다. 네 작업 흐름이 서로의 코드를 보지 않고 썼고, 컴파일된 적이 없다. 컴파일 오류가 날 것으로 보고 시작한다.

**준비**: Xcode 26 이상, Homebrew. 절차는 `ios/README.md`의 "Mac에서 처음 여는 방법".

**할 일**

1. `cd ios && brew install xcodegen && cp App/Config/Secrets.example.xcconfig App/Config/Secrets.xcconfig`, 2번에서 만든 프로젝트 주소와 공개용 키를 넣고 `xcodegen generate`.
2. 패키지부터 빌드한다: `cd ios/PonduKit && xcodebuild -scheme PonduKit-Package -destination 'platform=iOS Simulator,name=iPhone 16' build`. 오류를 타깃 순서대로 고친다: `PonduCore` → `FeatureAuth` → `FeatureSession` → `FeatureRecord` → `FeatureTogether` → `FeatureToday` → 앱.
3. 고칠 때의 기준:
   - `PonduCore`의 공개 API가 기준이다. 기능 타깃을 거기에 맞춘다. `PonduCore`를 바꿔야 하면 `docs/specs/CONTRACT.md` 5절도 같이 고친다.
   - 함께 탭(`FeatureTogether`)과 오늘 탭(`FeatureToday`)은 공용 모델 대신 자기 폴더에 같은 모양의 모델을 따로 뒀다. 컴파일이 되면 그대로 두고, 정리는 별도 변경으로 한다.
   - 서버가 주는 JSON 모양은 `docs/specs/CONTRACT.md` 3절과 `CONTRACT-ADDENDUM.md`가 기준이다. 추측하지 말고 `supabase/migrations/`의 함수를 읽는다.
4. 테스트를 돌린다: `xcodebuild test -scheme PonduKit-Package -destination 'platform=iOS Simulator,name=iPhone 16'`. 실패는 고치되, 테스트를 지우거나 건너뛰게 만들지 않는다.
5. 시뮬레이터에서 앱을 띄워 `docs/specs/M0.md` 5.2절의 1~5번을 확인한다. 시뮬레이터는 카메라가 없으므로 사진은 `사진 없는 기록` 경로로만 확인한다.

**확인하지 못한 라이브러리 호출** (첫 실행에서 문제가 날 가능성이 높은 곳, `ios/PonduKit/Sources/PonduCore/`)

- RPC 오류에서 코드를 꺼내는 방식(PostgREST 오류의 `message`를 읽는다)
- 로그인 오류의 구분(코드 만료, 틀린 코드, 도메인 거절)
- 오프라인에서 로그아웃했을 때 세션이 지워지는지
- 사진 저장소의 서명 주소 응답 필드와 업로드 경로
- 서버 함수, 스트리밍, 사진 업로드는 SDK가 아니라 `URLSession`으로 직접 호출한다

**정적 대조에서 의심으로 남은 곳** (컴파일러로 확인할 것)

- `async let`으로 `@MainActor` 메서드를 부르는 곳: `RecordModel.refresh`, `FriendsModel.load`, `FeedModel.reload`
- 테스트용 가짜 Backend가 async 함수 안에서 `NSLock.lock()`을 직접 부른다
- `JSONValue`의 정적 함수 `uuid`, `date`, `int`가 `PonduCore`(비옵셔널 인자)와 `FeatureToday`(옵셔널 인자) 두 곳에 있어 오버로드가 모호할 수 있다
- 이번에 추가된 코드: `SessionDTO`의 `init(from:)`, 세션 시작 화면의 크루 선택(`Picker`의 태그 타입), `AppEnvironment`의 알림 delegate 연결
- 앱을 완전히 껐다가 예정 시각 알림으로 켜면 시작 화면에 할 일과 예정 시간만 넘어가고 분야·제목이 채워지지 않는다. 실물 기기에서 확인하고 필요하면 `TodayModel`을 거치게 바꾼다
- 오늘 탭의 "…는 평소 N배 걸려서" 문구에 받침에 따른 조사 처리가 없다

**끝났다고 말할 조건**: 패키지와 앱이 경고가 아닌 오류 없이 빌드되고, 테스트가 통과하고, 시뮬레이터에서 가입 → 프로필 → 홈 → 세션 시작·종료 → 기록 탭에 표시까지 된다. 시뮬레이터 확인은 `[실기기]`가 아니다. `PROGRESS.md`에는 `[로컬]`로 적고, 실물 기기 항목(V2~V10)은 그대로 남긴다.

## 2. Supabase 프로젝트: 실제 환경 적용

**상태**: 마이그레이션 6개와 서버 함수 4개가 있다. 실제 Supabase에는 올려 본 적이 없다. `supabase/config.toml`이 없다.

**할 일**

1. 서울 리전에 프로젝트를 만든다. `supabase init`으로 `config.toml`을 만들고 `supabase link`.
2. `supabase db push`로 마이그레이션을 적용한다. `supabase/tests/shim.sql`은 적용하지 않는다(일반 Postgres용 흉내다).
3. 초기 데이터 `supabase/seed/01_school_korea.sql`을 적용한다.
4. **인증 훅**: 대시보드의 Authentication → Hooks에서 "Before User Created"에 `public.hook_before_user_created`를 등록한다. `config.toml`에도 같은 설정을 넣는다. 이 훅이 실제 인증 서비스에서 어떤 응답 형식을 요구하는지는 확인되지 않았다. 공식 문서와 대조하고, 다르면 `supabase/migrations/0100_auth_profile.sql`을 고친다.
5. **메일**: 발송 서비스(SMTP)를 연결하고 발송 도메인의 SPF·DKIM을 확인한다. 메일 템플릿(Magic Link와 Confirm signup)에 `{{ .Token }}`을 넣어 6자리 코드가 오게 한다. 코드 유효 시간 10분, 재전송 간격 60초.
6. **저장소**: 비공개 버킷 `session-photos`와 `storage.objects` 정책이 만들어졌는지 확인한다(`0300_sessions.sql` 끝부분. 정책 소유자 권한 때문에 실패했을 수 있다).
7. **예약 작업**: `pg_cron`을 켜고 `sweep_stale_sessions`가 10분마다 등록됐는지 확인한다. 알림 발송 함수 `notify`를 1분마다 부르는 예약(`pg_cron` + `pg_net`, 헤더 `x-notify-secret`)을 만든다.
8. **서버 함수**: `supabase functions deploy assistant import-extract delete-account notify`. `notify`는 `verify_jwt = false`. 비밀 값: `ANTHROPIC_API_KEY`, `ASSISTANT_MODEL`, `NOTIFY_SECRET`, `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_ENV`.

**확인할 것** (실제 프로젝트에서, 가짜 계정으로)

- @korea.ac.kr이 아닌 주소는 가입이 거절되고, 맞는 주소는 인증 코드가 받은편지함에 온다(주소 3개 이상. `PROGRESS.md`의 V1).
- 로그인한 사용자가 `profiles`, `sessions` 등 테이블을 직접 읽거나 쓸 수 없다(REST로 직접 시도).
- 사용자 B가 A의 비공개 세션 사진 경로로 서명 주소를 요청하면 거절된다.
- 내부 함수(`can_view_session`, `profile_card`, `session_json`, `assistant_context`)를 앱 권한으로 부를 수 없다.
- `supabase/tests/z_integration/01_end_to_end.sql`의 흐름을 실제 API로 한 번 따라 한다.

**주의**: 관리자 키(`service_role`)와 발송 서비스 키는 저장소에 넣지 않는다. 커밋 전에 저장소 전체에서 검색한다.

## 3. Claude API 키: 비서 시험 세트 실제 실행

**상태**: 시험 사례 48개와 실행기가 있다. 실제 API 호출은 0회다. 지금까지의 결과는 가짜 응답으로 배관만 확인한 것이다.

**할 일**: `assistant/README.md`의 "실제 모델로 돌리기"를 따른다.

1. 먼저 사례 3~5개만 돌려 한 건당 토큰 수와 시간을 본다. 호출이 형식 오류(400)로 실패하면 `assistant/core/propose.mjs`의 요청 모양을 공식 문서와 대조해 고친다. 출력 형식 지정과 대체 모델 설정이 실제 서버에서 받아들여지는지 확인된 적이 없다.
2. 전체 비용을 계산해 사용자에게 알리고 승인을 받은 뒤 전체를 돌린다(`--reps 2`).
3. 기준선은 `claude-opus-5-5`. 통과 기준은 `rules_ok`, `no_invented_due`, `no_false_done` 100%, `pass` 90% 이상.
4. 기준을 넘으면 같은 세트를 `claude-sonnet-5-5`, `claude-haiku-5-5`로 돌려 통과가 유지되는 가장 싼 모델을 찾는다. 48개를 2번 돌릴 때 오차가 약 ±10%p이므로 그보다 작은 차이로 우열을 가리지 않는다.
5. 기준에 못 미치면 실패한 사례의 주고받은 내용(`traces/`)을 읽고 `assistant/core/prompt.mjs`를 고친다. 사례의 문장을 프롬프트에 그대로 넣지 않는다(답을 알려 주는 것이 된다). 고친 뒤 `npm run selftest`, `npm run sync`, 그리고 다시 실행.

**알아 둘 것**: 사례는 전부 지어낸 문장이다. 실제 사용자가 쓸 법한 문장 5~10개를 받아 추가하면 결과를 더 믿을 수 있다.

## 4. 학과 목록 확인

**상태**: `supabase/seed/01_school_korea.sql`에 학과 29개가 들어 있다. 에이전트가 확실히 아는 것만 넣은 것이고 공식 목록이 아니다. 빠진 학과와 바뀐 이름이 있을 수 있다.

**할 일**

1. 고려대학교 공식 사이트의 대학·학과 안내에서 서울캠퍼스 학부 학과 목록을 가져온다. 출처 주소와 확인 날짜를 seed 파일 상단 주석에 적는다.
2. 파일 상단 주석의 형식대로 목록을 고친다. 공식 출처에서 확인하지 못한 학과는 넣지 않는다.
3. 세종캠퍼스, 대학원, 연계전공을 넣을지는 사용자에게 묻는다.
4. 이미 적용된 DB의 학과 이름을 바꿀 때는 seed가 아니라 마이그레이션의 `update`로 한다(seed는 새 행을 만든다).

---

## 작업 뒤에 남길 것

- `PROGRESS.md`: 통합 관문 G4(iOS 첫 빌드), G5(실제 서버 연결), 사전 검증 3줄, 배포 기록.
- 고친 내용은 기능 단위로 나눠 올리고, 본문에 "직접 확인한 방법"과 "확인하지 못한 것"을 적는다.
- 계약(`docs/specs/CONTRACT.md`)과 다르게 고쳐야 했던 곳은 계약도 같이 고친다.

## 2026-11-23 추가: 예상 시간 묻기와 가용 시간

실제 환경에 반영하려면 두 가지가 필요하다.

1. 마이그레이션 `supabase/migrations/20261123090000_proposal_adjust.sql` 적용(읽기 함수 하나).
2. Edge Function `assistant` 다시 배포(`_shared/core/availability.mjs`가 새로 들어간다).

앱 쪽 변경(`ios/PonduKit/Sources/FeatureToday/AssistantModel.swift`, `AssistantView.swift`)은 Mac에서 빌드와 `xcodebuild test`로 확인해야 한다. Linux에서는 컴파일하지 못했다.
