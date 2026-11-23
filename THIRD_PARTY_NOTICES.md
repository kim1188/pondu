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

## XU Wireflow Review (화면 흐름 점검 도구)

- 위치: `.agents/skills/wireflow-review/` (v0.5.5 기준 저장소 사본, 2026-11-23), 결과물 `design/pondu.html`에도 도구의 뷰어 코드와 글꼴이 들어간다
- 출처: https://github.com/JeongK7998/wireflow-review
- 라이선스: **저장소에 라이선스 파일이 없다.** README와 `release/APPLY.md`가 "프로젝트의 `.agents/skills/` 아래에 풀어 쓰라"고 안내하므로 그 안내대로 넣었다. 저장소를 공개하거나 결과물을 배포하기 전에 작성자에게 조건을 확인한다
- 앱과 서버에는 들어가지 않는다. 기획 점검용이다
- 함께 들어 있는 글꼴: Gaegu, Inter, Patrick Hand — SIL Open Font License 1.1 (`assets/paper/fonts/*-OFL.txt`)
