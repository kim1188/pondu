// 결정 모델용 실행 고리. github.com/osolmaz/switch 의 구조를 이 앱에 필요한 만큼만 줄여 옮겼다.
//
// 결정 모델은 글을 쓰지 않는다. 코드가 상태를 보고 "유한한 질문"을 만들고, 모델은 그중 하나를 고른다.
//   상태(state)  → 질문 함수(questions) → 모델의 답 → 전이 함수(transition) → 다음 상태
// 질문이 더 없으면 끝난다. 모든 단계의 보기·질문·답은 기록(trace)에 남아 모델 없이 다시 볼 수 있다.
//
// switch에서 가져온 것: 상태 기계(initial, questions, transition, view), 고르기(pick)와 건너뛰기 선택지,
//   단계 상한, 기록, 시험용 가짜 결정기.
// 가져오지 않은 것: 케이스 폴더, 명령줄, 뷰어, 재실행 분기, 토큰 예산에 맞춘 보기 줄이기.

/**
 * @typedef {{type: 'bool', instructions: string} |
 *           {type: 'choice', instructions: string, choices: {value: string, description?: string}[]}} Question
 * @typedef {{type: 'bool', probability: number} |
 *           {type: 'choice', choice: string, confidence?: number, probabilities?: Record<string, number>}} Answer
 * @typedef {(request: {view: object, questions: Record<string, Question>}) =>
 *           Promise<{answers: Record<string, Answer>, usage?: {input_tokens?: number}, model?: string}>} Decider
 */

/**
 * @param {{initial: () => object, questions: (s: object) => Record<string, Question>,
 *          transition: (s: object, a: Record<string, Answer>) => object, view: (s: object) => object}} machine
 * @param {Decider} decider
 */
export async function run(machine, decider, { maxSteps = 40 } = {}) {
  let state = machine.initial();
  const trace = [];
  const usage = { input_tokens: 0, output_tokens: 0, requests: 0 };
  let model = null;
  for (let step = 0; step < maxSteps; step++) {
    const questions = machine.questions(state);
    if (Object.keys(questions).length === 0) return { state, trace, usage, model, ended: 'done' };
    const view = machine.view(state);
    const result = await decider({ view, questions });
    checkAnswers(questions, result.answers);
    usage.input_tokens += result.usage?.input_tokens ?? 0;
    usage.output_tokens += result.usage?.output_tokens ?? 0;
    usage.requests += 1;
    model = result.model ?? model;
    trace.push({ step, view, questions, answers: result.answers });
    state = machine.transition(state, result.answers);
  }
  return { state, trace, usage, model, ended: 'step limit' };
}

/** 모델의 답이 질문이 허용한 값 안에 있는지 확인한다. 어긋나면 그 단계에서 멈춘다. */
function checkAnswers(questions, answers) {
  for (const [id, q] of Object.entries(questions)) {
    const a = answers?.[id];
    if (!a) throw new Error(`결정 모델이 질문 ${id} 에 답하지 않음`);
    if (q.type === 'bool' && !(typeof a.probability === 'number' && a.probability >= 0 && a.probability <= 1)) {
      throw new Error(`질문 ${id}: 확률이 0~1 이 아님`);
    }
    if (q.type === 'choice' && !q.choices.some(c => c.value === a.choice)) {
      throw new Error(`질문 ${id}: 허용하지 않은 선택 ${a.choice}`);
    }
  }
}

/**
 * 고르기 도우미. 상태에서 선택지 목록을 만들고, 고른 선택지를 전이에 넘긴다.
 * 선택지는 {key, text, ...나머지} 이고 나머지 필드는 모델에 보이지 않고 전이만 본다.
 */
export function picking({ id = 'pick', instructions, choices, transition }) {
  return {
    questions(state) {
      const list = choices(state);
      return { [id]: { type: 'choice', instructions: instructions(state), choices: list.map(c => ({ value: c.key, description: c.text })) } };
    },
    transition(state, answers) {
      const picked = choices(state).find(c => c.key === answers[id].choice);
      return transition(state, picked, answers[id]);
    },
  };
}
