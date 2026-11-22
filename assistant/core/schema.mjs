// 비서가 돌려주는 제안의 형식. 모델 출력은 이 형식으로만 받는다.
// 세션을 만들거나 세션 시각·공개 범위를 바꾸는 항목은 형식에 아예 없다.

export const CATEGORIES = [
  'study', 'coding', 'exercise', 'project', 'venture_research_intern', 'parttime',
];

export const PROPOSAL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['todos', 'blocks', 'done_todo_ids', 'unscheduled', 'questions', 'message'],
  properties: {
    todos: {
      type: 'array',
      description: '새로 만들 할 일 후보. 이미 있는 할 일은 다시 넣지 않는다.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'due_date', 'due_time', 'estimate_min', 'category'],
        properties: {
          title: { type: 'string' },
          due_date: { type: ['string', 'null'], description: 'YYYY-MM-DD. 사용자가 기한을 말하지 않았으면 null.' },
          due_time: { type: ['string', 'null'], description: 'HH:MM (24시간). 시각을 말하지 않았으면 null.' },
          estimate_min: { type: ['integer', 'null'], description: '예상 소요 분. 모르면 null.' },
          category: { anyOf: [{ type: 'string', enum: CATEGORIES }, { type: 'null' }] },
        },
      },
    },
    blocks: {
      type: 'array',
      description: '예정 시간. capture 요청에서는 항상 빈 배열.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['todo_ref', 'start', 'end'],
        properties: {
          todo_ref: { type: 'string', description: '기존 할 일의 id, 또는 이번에 제안한 todos의 순번을 가리키는 "new:0", "new:1" ...' },
          start: { type: 'string', description: '예: 2026-11-23T15:00:00+09:00' },
          end: { type: 'string', description: '예: 2026-11-23T16:00:00+09:00' },
        },
      },
    },
    done_todo_ids: {
      type: 'array',
      description: '사용자가 이번 입력에서 끝냈다고 분명히 말한 기존 할 일의 id.',
      items: { type: 'string' },
    },
    unscheduled: {
      type: 'array',
      description: '시간이 모자라 배치하지 못한 할 일과 그 이유.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['todo_ref', 'reason'],
        properties: { todo_ref: { type: 'string' }, reason: { type: 'string' } },
      },
    },
    questions: {
      type: 'array',
      description: '진행하려면 꼭 확인해야 하는 것만. 없으면 빈 배열.',
      items: { type: 'string' },
    },
    message: { type: 'string', description: '사용자에게 보여 줄 한두 문장.' },
  },
};

export const EMPTY_PROPOSAL = Object.freeze({
  todos: [], blocks: [], done_todo_ids: [], unscheduled: [], questions: [], message: '',
});
