# 외부 구성요소

새 라이브러리, 모델, 글꼴, 외부 서비스를 쓰면 여기에 추가한다(`AGENTS.md`). 버전은 각 잠금 파일이 기준이다.

## 라이브러리

| 이름 | 쓰는 곳 | 라이선스 | 출처 |
|---|---|---|---|
| `@anthropic-ai/sdk` | `assistant/`, `supabase/functions/` | Apache-2.0 | https://github.com/anthropics/anthropic-sdk-typescript |
| `openai` | `assistant/` (시험 세트의 모델 비교용. 서버 함수에는 들어가지 않는다) | Apache-2.0 | https://github.com/openai/openai-node |
| `supabase-swift` | `ios/PonduKit` | MIT (저장소의 LICENSE로 다시 확인할 것) | https://github.com/supabase/supabase-swift |

## 설계를 참고한 것

| 이름 | 무엇을 | 라이선스 |
|---|---|---|
| osolmaz/switch | 결정 모델용 실행 고리의 구조(`assistant/decide/`). 코드는 가져오지 않고 다시 썼다 | MIT |

## 외부 서비스

Supabase(DB, 인증, 저장소, 서버 함수), Claude API(비서), OpenAI API(시험 세트의 모델 비교), Apple Push Notification service.
