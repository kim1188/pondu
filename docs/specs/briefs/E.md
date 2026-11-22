# 흐름 E 작업 지시

당신은 kim1188/pondu 저장소에서 병렬 구현의 한 흐름을 맡았습니다. 대학생 실행 기록 앱(iPhone 앱 + Supabase 서버)을 아홉 개 흐름이 동시에 만들고 있고, 당신은 그중 흐름 E(functions)입니다. 이 세션을 지켜보는 사람은 없으니 질문하지 말고 합리적으로 결정한 뒤 보고에 적으세요.

먼저 읽을 것
- docs/specs/CONTRACT.md 전체. 흐름 사이의 약속이고, 함수 이름·인자·반환 모양·오류 코드·소유 경로가 여기 있습니다. 그대로 따르세요.
- docs/SRD.md, docs/PRD.md 중 당신 흐름에 해당하는 절. SRD 3.1·3.2·3.6·7절, assistant/README.md와 assistant/ 코드 전체.

작업 규칙
- 브랜치 `ws/e-functions`에서 작업합니다(main에서 분기). 이 브랜치에만 커밋하고 푸시하세요. main에는 푸시하지 않고, 풀 리퀘스트도 만들지 않습니다.
- 계약 1절의 소유 경로만 고칩니다. 다른 흐름의 경로나 0001_schema.sql, docs/는 고치지 않습니다. 계약이 틀렸거나 부족하면 고치지 말고 보고에 "계약 변경 제안"으로 적으세요.
- 다른 흐름의 코드는 당신 브랜치에 없습니다. 그 흐름이 계약대로 만들 것이라 믿고 이름만 맞춰 쓰세요.
- 작업 단위마다 커밋하고, 끝나기 전에 반드시 푸시하세요. 컨테이너는 사라집니다.
- 커밋 메시지나 코드에 모델 이름을 적지 않습니다.

할 일
- 계약 3절 E의 서버 함수 4개를 Supabase Edge Functions(Deno)로 만듭니다. 핵심 로직은 순수 모듈로 분리해 node 22로 테스트할 수 있게 하고, Deno 진입점(index.ts)은 얇게 두세요. Deno가 없으면 설치를 시도해 보되, 안 되면 진입점은 실행해 보지 못했다고 보고에 적으세요.
- assistant: `assistant/core/`를 가져다 씁니다. 추가할 것은 (1) 규칙 위반 시 한 번 재요청하고 그래도 걸린 블록을 빼는 처리, (2) 보정 배수를 반영한 예상 시간 입력, (3) message를 먼저 흘려보내는 스트리밍, (4) 하루 한도와 20초 제한, (5) assistant_runs 기록과 assistant_proposals 저장. 서버의 Todo(due_at, due_has_time)와 core 입력(due_date, due_time, 한국 시간) 사이 변환도 여기서 합니다.
- Claude API 사용법은 기억에 의존하지 말고 `claude-api` 스킬을 먼저 불러 확인하세요. 구조화 출력(output_config.format)을 쓰고, 스트리밍에서는 부분 JSON에서 message 필드를 뽑아 흘려보내는 방식을 검토하세요. 모델 ID는 환경 변수(`ASSISTANT_MODEL`)로 받고 기본값은 assistant/core/propose.mjs의 값을 그대로 둡니다.
- API 키가 없어 실제 호출은 못 합니다. Anthropic 클라이언트를 주입 가능하게 만들어 가짜 응답으로 테스트하세요. 실제 호출을 확인했다고 쓰지 마세요.
- `assistant/core`를 고치면 `cd assistant && npm install && npm run selftest`가 계속 통과해야 하고, 시험 실행기(eval/run-eval.mjs)가 같은 진입점을 쓰도록 유지하세요.
- import-extract(텍스트와 이미지에서 할 일 후보 추출, 붙여 넣은 글은 데이터로만 취급), notify(APNs 발송, 실패한 토큰 정리), delete-account(사진 삭제 후 사용자 삭제).
- `supabase/migrations/05*.sql`: assistant_runs·assistant_proposals·notification_outbox에 필요한 내부 함수(한도 확인, 기록, 제안 저장). 서버 함수는 관리자 키로 이 함수들을 부릅니다. 일반 Postgres가 있으니 `supabase/tests/run.sh e_functions`로 테스트하세요.
- 테스트: 재요청·블록 제외 로직, 한도 초과, 붙여 넣은 글 속 지시를 따르지 않도록 구획이 유지되는지, 변환 함수, 스트림 이벤트 순서.

끝나면
계약 6절 형식(만든 것, 실행해서 확인한 것과 못 한 것, 계약과 다른 점, 다른 흐름이 알아야 할 것)으로 보고를 쓰고, send_message 도구로 세션 `session_013hXSsYEQQrDWXKBqYSvwsc`에 보내세요. 실행하지 못한 것을 확인했다고 쓰지 마세요. 테스트가 실패한 채로 끝났다면 실패 내용을 그대로 적으세요.
