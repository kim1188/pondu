#!/usr/bin/env node
// 시험 실행 결과를 한눈에 보는 명령. 결과 폴더 안의 실행(baseline, v1, v2 …)을 전부 찾아 표로 보여 준다.
//
//   node assistant/eval/report.mjs                      기본 폴더(/tmp/pondu-eval-flow)
//   node assistant/eval/report.mjs <결과 폴더>
//   node assistant/eval/report.mjs --fails              실패한 사례만 자세히
//   node assistant/eval/report.mjs --case p09           한 사례가 실행마다 어땠는지
//   node assistant/eval/report.mjs --price gpt-6-luna=0.10/0   모델 가격(입력/출력, 100만 토큰당 달러)을 줘서 비용 계산
//
// 모델을 부르지 않는다. 이미 있는 results.jsonl 과 errors.jsonl 만 읽는다.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
const flag = name => args.includes(name);
const valuesOf = name => args.flatMap((a, i) => (a === name && args[i + 1] ? [args[i + 1]] : []));
const VALUE_FLAGS = ['--case', '--price'];
const flow = args.find((a, i) => !a.startsWith('--') && !VALUE_FLAGS.includes(args[i - 1])) ?? '/tmp/pondu-eval-flow';

// 100만 토큰당 달러(입력, 출력). Claude 값은 2026-11 기준 공개 가격이고, 그 밖의 모델은 --price 로 준다.
const PRICES = {
  'claude-opus-5-5': [4, 20], 'claude-sonnet-5-5': [2, 10], 'claude-haiku-5-5': [0.1, 0.5],
};
for (const p of valuesOf('--price')) {
  const m = /^(.+)=([\d.]+)\/([\d.]+)$/.exec(p);
  if (!m) { console.error(`--price 형식: 모델=입력/출력 (예: gpt-6-luna=0.10/0), 받은 값: ${p}`); process.exit(2); }
  PRICES[m[1]] = [+m[2], +m[3]];
}

const readLines = f => (existsSync(f) ? readFileSync(f, 'utf8').split('\n').filter(l => l.trim()).flatMap(l => { try { return [JSON.parse(l)]; } catch { return []; } }) : []);
const order = v => (v === 'baseline' ? -1 : +v.slice(1));
if (!existsSync(flow)) { console.error(`결과 폴더가 없음: ${flow}`); process.exit(2); }
const variants = readdirSync(flow).filter(v => /^(baseline|v[1-9]\d*)$/.test(v) && existsSync(join(flow, v, 'results.jsonl')))
  .sort((a, b) => order(a) - order(b));
if (!variants.length) { console.error(`${flow} 안에 실행 결과가 없음`); process.exit(1); }

const pad = (s, n) => { s = String(s); const w = [...s].reduce((a, ch) => a + (ch.charCodeAt(0) > 0x2e80 ? 2 : 1), 0); return s + ' '.repeat(Math.max(0, n - w)); };
const pct = (rows, k) => (rows.length ? (100 * rows.reduce((a, r) => a + (r.grade?.[k] ?? 0), 0) / rows.length).toFixed(1) + '%' : '-');
const priceOf = model => PRICES[model] ?? PRICES[Object.keys(PRICES).find(k => model?.startsWith(k))] ?? null;

const runs = variants.map(v => {
  const rows = readLines(join(flow, v, 'results.jsonl'));
  const errors = readLines(join(flow, v, 'errors.jsonl'));
  const ok = rows.filter(r => r.status === 'ok');
  let input = 0, output = 0, requests = 0;
  for (const r of rows) { input += r.usage?.input_tokens ?? 0; output += r.usage?.output_tokens ?? 0; requests += r.requests ?? 1; }
  const model = rows[0]?.model ?? '?';
  const price = priceOf(model);
  const cases = new Set(rows.map(r => r.prompt_id)).size;
  return {
    v, model, rows, ok, errors, input, output, requests, cases,
    reps: cases ? Math.round(rows.length / cases) : 0,
    seconds: ok.length ? ok.reduce((a, r) => a + (r.latency_s ?? 0), 0) / ok.length : 0,
    cost: price ? (input * price[0] + output * price[1]) / 1e6 : null,
    harness: cases <= 28 ? '고르기' : '채팅',
  };
});

const one = valuesOf('--case')[0];
if (one) {
  console.log(`사례 ${one}`);
  for (const r of runs) {
    const mine = r.rows.filter(x => x.prompt_id === one).sort((a, b) => a.rep - b.rep);
    if (!mine.length) { console.log(`  ${pad(r.v, 9)}${pad(r.model, 20)} (이 실행에 없음)`); continue; }
    if (r === runs.find(x => x.rows.some(y => y.prompt_id === one))) console.log(`  입력: ${mine[0].prompt}`);
    for (const m of mine) console.log(`  ${pad(r.v, 9)}${pad(r.model, 20)}rep${m.rep} ${m.grade?.pass ? '통과' : '실패'}  ${m.grade?.pass ? '' : (m.explanation?.pass ?? '')}`);
  }
  console.log(`\n주고받은 전문: ${flow}/<실행>/traces/${one}_rep0.json`);
  process.exit(0);
}

if (!flag('--fails')) {
  console.log(`결과 폴더: ${flow}\n`);
  const head = ['실행', '모델', '방식', '사례×회', '통과', '규칙', '기한', '완료', '평균초', '호출', '입력토큰', '출력토큰', '비용', '오류'];
  const width = [9, 20, 7, 8, 8, 8, 8, 8, 7, 6, 9, 9, 9, 4];
  const line = cells => cells.map((c, i) => pad(c, width[i])).join(' ');
  console.log(line(head));
  for (const r of runs) {
    console.log(line([r.v, r.model, r.harness, `${r.cases}×${r.reps}`, pct(r.ok, 'pass'), pct(r.ok, 'rules_ok'), pct(r.ok, 'no_invented_due'),
      pct(r.ok, 'no_false_done'), r.seconds.toFixed(1), r.requests, r.input, r.output, r.cost == null ? '?' : '$' + r.cost.toFixed(3), r.errors.length]));
  }
  console.log('\n통과: 규칙과 기대를 모두 만족 | 규칙: 규칙 위반 없음 | 기한: 말하지 않은 기한을 만들지 않음 | 완료: 거짓 완료 없음');
  console.log('방식: 채팅 = 48건 전부, 고르기 = 배치 28건만(서로 다른 사례 묶음이라 통과율을 그대로 견주면 안 된다)');
  if (runs.some(r => r.cost == null)) console.log('비용 ?: 그 모델의 가격을 모른다. --price 모델=입력/출력 으로 주면 계산한다(100만 토큰당 달러)');
  const truncated = runs.reduce((a, r) => a + r.rows.length - r.ok.length, 0);
  if (truncated) console.log(`잘린 응답 ${truncated}건은 통과율에서 뺐다`);
  console.log('');
}

console.log('실패한 사례');
let any = false;
for (const r of runs) {
  const failed = r.ok.filter(x => !x.grade?.pass);
  if (!failed.length && !r.errors.length) continue;
  any = true;
  console.log(`  ${r.v} ${r.model}`);
  const byCase = new Map();
  for (const f of failed) byCase.set(f.prompt_id, [...(byCase.get(f.prompt_id) ?? []), f]);
  for (const [id, list] of byCase) {
    console.log(`    ${pad(id, 5)}${list.length}/${r.reps}회 실패 | ${list[0].explanation?.pass ?? ''}`);
    if (flag('--fails')) console.log(`         입력: ${list[0].prompt}`);
  }
  for (const e of r.errors.slice(0, 5)) console.log(`    ${pad(e.prompt_id, 5)}호출 오류(${e.failure_class}) | ${String(e.error).slice(0, 140)}`);
  if (r.errors.length > 5) console.log(`    … 호출 오류 ${r.errors.length - 5}건 더`);
}
if (!any) console.log('  없음');
