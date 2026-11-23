# 비서: 핵심 코드와 시험 세트

비서의 프롬프트, 출력 형식, 규칙 검사와 이를 재는 시험 세트다. 앱이나 서버 없이 혼자 돌아간다.
나중에 서버 함수(`assistant`)가 `core/`를 그대로 가져다 쓴다. 시험한 코드와 서비스하는 코드가 같아야 점수를 믿을 수 있다.

```
core/schema.mjs     비서가 돌려주는 제안의 형식
core/prompt.mjs     시스템 프롬프트, 요청을 메시지로 바꾸는 함수
core/validate.mjs   규칙 검사(겹침, 마감, 시간대 등). 걸리면 저장하지 않는다
core/propose.mjs    진입점. Claude API를 한 번 부른다(스트리밍, 클라이언트 주입 가능). 시험 세트가 쓴다
core/run.mjs        서버가 쓰는 전체 흐름: 호출 → 규칙 위반이면 한 번 재요청 → 그래도 걸린 블록은 빼기
core/drop.mjs       걸린 블록(과 없는 할 일을 가리키는 항목)만 제안에서 빼기
core/stream-message.mjs  스트리밍 부분 JSON에서 message 글만 먼저 뽑기
core/estimate.mjs   예상 시간 보정 배수를 곱한 planning_min 붙이기
eval/cases.mjs      시험 사례 48개(입력, 기대, 모범 답)
eval/CASES.md       사례를 사람이 읽기 좋게 풀어 쓴 목록(자동 생성)
eval/grade.mjs      채점기(코드로만 채점)
eval/selftest.mjs   시험 세트 자체 점검(비용 없음)
eval/run-eval.mjs   실행기
```

## 비용 없이 점검하기

```bash
cd assistant && npm install && npm run selftest
```

모범 답은 전부 통과하고, 빈 답과 일부러 틀린 답은 떨어지는지 확인한다. 사례나 채점기를 고친 뒤에는 항상 먼저 돌린다.

## 실제 모델로 돌리기

API 키가 필요하고 요금이 든다. 저장소 루트에서 실행한다.

```bash
export ANTHROPIC_API_KEY=...
```

```bash
node assistant/eval/run-eval.mjs --flow .claude/hillclimb/assistant --variant baseline --model claude-opus-5-5 --reps 2 --approve-harness
```

- `--approve-harness`는 처음 한 번, 그리고 `core/`나 사례·채점기를 고친 뒤에 붙인다. 고친 내용을 확인했다는 뜻이다. 붙이지 않으면 실행기가 멈춘다.
- 결과는 `.claude/hillclimb/assistant/baseline/`에 쌓인다. `results.jsonl`이 사례별 점수, `traces/`가 주고받은 전문, `errors.jsonl`이 호출 자체가 실패한 건이다.
- 중간에 끊겨도 같은 명령을 다시 실행하면 남은 사례만 돈다.
- 다른 모델과 비교하려면 `--variant v1 --model claude-sonnet-5-5`처럼 이름과 모델을 바꿔 한 번 더 돌린다.
- 전체를 돌리기 전에 사례 몇 개로 먼저 돌려 한 건당 토큰 수와 시간을 확인하면 전체 비용을 계산할 수 있다.

## 서버 함수와 같이 쓰기

`supabase/functions/_shared/core/`는 `assistant/core/`의 사본이다(Edge Function 배포가 폴더 밖 파일을 묶지 않아서). `core/`를 고치면 `npm run sync`로 복사하고, `npm test`가 두 벌이 같은지 확인한다.

```bash
cd assistant && npm install && npm run selftest && npm test
```

## 지표와 통과 기준

| 지표 | 뜻 | 기준 |
|---|---|---|
| `pass` | 규칙과 기대를 모두 만족 | 90% 이상 |
| `rules_ok` | 규칙 검사 위반 없음 | 100% |
| `no_invented_due` | 말하지 않은 기한을 만들지 않음 | 100% |
| `no_false_done` | 끝냈다고 하지 않은 일을 완료 처리하지 않음 | 100% |

48개를 2번씩 돌릴 때 통과율 오차는 약 ±10%p다. 그보다 작은 차이로 프롬프트나 모델의 우열을 가리지 않는다.

## 알아 둘 한계

- 사례는 전부 지어낸 문장이다. 실제 사용자의 입력이 모이면 교체하고 늘린다.
- 실제 API 호출 경로는 키가 없는 환경에서 만들어져 아직 한 번도 실행되지 않았다. 배관은 가짜 답을 흘려보내는 방식(`ASSISTANT_EVAL_MOCK=oracle`)으로만 확인했다.
- 규칙 위반 시 재요청·블록 제외(`run.mjs`)와 예상 시간 보정(`estimate.mjs`)은 가짜 클라이언트로만 시험했다. 시험 세트(`run-eval.mjs`)는 `propose`(한 번 호출, 재요청 없음)를 써서 모델 자체의 위반율을 잰다.
- 구조화 출력의 `message`를 스키마 맨 앞으로 옮겼다(먼저 흘려보내기 위해). 이 순서가 제안 품질에 미치는 영향은 실제 모델로 시험 세트를 돌려 확인해야 한다.

## 다른 회사 모델로 돌리기 (OpenAI)

실행기는 `--model` 이름으로 경로를 고른다. 프롬프트, 출력 형식, 규칙 검사, 채점기는 같다.

| 모델 이름 | 경로 | 돌리는 사례 |
|---|---|---|
| `claude-*` | `core/propose.mjs` (Anthropic) | 48건 전부 |
| OpenAI 채팅 모델 | `providers/openai.mjs` (Responses API, 구조화 출력) | 48건 전부 |
| `gpt-6-luna` 같은 결정 모델 | `decide/` 고르기 방식 + Decisions API | 배치 28건(plan_day, reschedule) |
| OpenAI 채팅 모델 + `ASSISTANT_HARNESS=decide` | `decide/` 고르기 방식을 채팅 모델에게 | 배치 28건 |

`OPENAI_API_KEY`가 필요하다. 모델 이름은 추측하지 말고 계정에서 쓸 수 있는 목록을 먼저 확인한다.

```bash
curl -s https://api.openai.com/v1/models -H "Authorization: Bearer $OPENAI_API_KEY" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).data.map(m=>m.id).sort().join("\n")))'
```

```bash
node assistant/eval/run-eval.mjs --flow /tmp/pondu-eval-flow --variant v3 --model <채팅 모델 이름> --reps 2 --concurrency 4 --approve-harness
```

OpenAI 경로와 Decisions API 경로는 실제 서버에 호출해 보지 못한 채 쓰였다. 첫 실행은 `--reps 1`로 하고, 400 오류가 나면 문구를 보고 요청 모양을 고친다.

## 결정 모델과 고르기 방식 (`decide/`)

결정 모델은 글을 쓰지 않고, 코드가 낸 질문(참/거짓, 여럿 중 하나)에 확률로 답한다. `decide/`는 [osolmaz/switch](https://github.com/osolmaz/switch)(MIT)의 구조를 이 앱에 필요한 만큼만 줄여 다시 쓴 것이다. 코드를 가져오지는 않았다.

- **가져온 생각**: 상태 기계(처음 상태, 질문 함수, 전이 함수, 보기 함수), 고르기와 건너뛰기 선택지, 단계 상한, 모든 단계의 기록, 시험용 가짜 결정기.
- **뺀 것**: 케이스 폴더, 명령줄, 뷰어, 기록에서 다시 실행하기, 토큰 예산에 맞춘 보기 줄이기.

일정 배치(`decide/schedule.mjs`)는 이렇게 푼다.

1. 사용자의 말이 있으면, 열린 할 일마다 "끝냈다고 분명히 말했는가"를 참/거짓으로 묻는다. 확률 0.8 이상만 완료로 본다.
2. 할 일을 마감이 가까운 순서로 하나씩 꺼내, 코드가 만든 자리 중 하나를 고르게 한다. 자리는 고정 일정, 잠긴 계획, 이미 놓은 블록, 활동 시간대, 마감을 모두 지키는 것만 낸다.

그래서 이 방식에서는 규칙 위반이 구조상 나오지 않는다(`test/decide.test.mjs`가 어떤 선택을 해도 위반이 없음을 확인한다). 모델에게 남는 일은 사용자의 말을 읽고 알맞은 자리를 고르는 것뿐이다.

한계도 분명하다. 새 할 일의 제목은 쓸 수 없어서 말을 할 일로 정리하는 일(capture)과, 배치 중에 새 할 일이 생기는 경우(p13)는 다루지 못한다. 안내 문장도 코드가 정해진 틀로 만든다.
