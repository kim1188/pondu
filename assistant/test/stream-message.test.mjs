import test from 'node:test';
import assert from 'node:assert/strict';
import { MessageExtractor } from '../core/stream-message.mjs';

const feed = (json, size) => {
  const ex = new MessageExtractor();
  const parts = [];
  for (let i = 0; i < json.length; i += size) parts.push(ex.push(json.slice(i, i + size)));
  return { text: ex.text, parts, done: ex.done };
};

const doc = {
  message: '안녕 "하세요"\n줄바꿈 \\ 슬래시 😀 끝',
  todos: [{ title: 'x', message: '이건 아님' }],
  blocks: [], done_todo_ids: [], unscheduled: [], questions: [],
};

test('조각 크기와 상관없이 message만 정확히 뽑는다', () => {
  const json = JSON.stringify(doc);
  for (const size of [1, 2, 3, 5, 7, 100000]) {
    assert.equal(feed(json, size).text, doc.message, `size=${size}`);
  }
});

test('\\u 이스케이프와 서로게이트 쌍을 조각 경계에서도 푼다', () => {
  const json = '{"message":"a\\u00e9\\ud83d\\ude00b","todos":[]}';
  for (const size of [1, 2, 4, 6, 50]) assert.equal(feed(json, size).text, 'aé😀b', `size=${size}`);
});

test('message가 뒤에 있어도, 중첩된 같은 이름 키는 무시한다', () => {
  const json = JSON.stringify({ todos: [{ message: 'no' }], message: '뒤' });
  assert.equal(feed(json, 3).text, '뒤');
});

test('값이 끝나기 전에도 확정된 글자는 먼저 나온다', () => {
  const ex = new MessageExtractor();
  assert.equal(ex.push('{"message":"안'), '안');
  assert.equal(ex.push('녕'), '녕');
  assert.equal(ex.done, false);
  assert.equal(ex.push('","todos":[]}'), '');
  assert.equal(ex.done, true);
});

test('message 키가 없거나 문자열이 아니면 아무것도 내지 않는다', () => {
  assert.equal(feed('{"todos":[],"message":null}', 2).text, '');
  assert.equal(feed('{"todos":[]}', 2).text, '');
});
