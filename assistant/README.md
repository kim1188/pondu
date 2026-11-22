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
