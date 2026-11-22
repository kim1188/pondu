import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, '..', 'core');
const dst = join(here, '..', '..', 'supabase', 'functions', '_shared', 'core');

test('서버 함수가 쓰는 core 사본이 assistant/core와 같다(고쳤다면 npm run sync)', () => {
  const a = readdirSync(src).sort();
  const b = readdirSync(dst).sort();
  assert.deepEqual(b, a);
  for (const f of a) assert.equal(readFileSync(join(dst, f), 'utf8'), readFileSync(join(src, f), 'utf8'), f);
});

test('core는 SDK를 정적으로 가져오지 않는다(Deno에서도 같은 파일이 돈다)', () => {
  for (const f of readdirSync(src)) assert.doesNotMatch(readFileSync(join(src, f), 'utf8'), /^import .*@anthropic-ai/m, f);
});
