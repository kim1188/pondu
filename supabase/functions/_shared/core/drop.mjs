// 규칙 검사에 걸린 부분을 제안에서 빼낸다. 블록은 걸린 것만 뺀다.
// 블록이 아닌 곳(할 일 형식 오류 등)은 고칠 수 없으므로 remaining에 남긴다.
import { validate } from './validate.mjs';

/**
 * @returns {{proposal: object, dropped: {rule: string, detail: string}[], remaining: {rule: string, detail: string}[]}}
 */
export function dropViolations(input, proposal) {
  let p = {
    ...proposal,
    blocks: [...proposal.blocks],
    done_todo_ids: [...proposal.done_todo_ids],
    unscheduled: [...proposal.unscheduled],
  };
  const dropped = [];
  for (let round = 0; round < 25; round++) {
    const vs = validate(input, p);
    if (!vs.length) return { proposal: p, dropped, remaining: [] };
    const dropBlocks = new Set();
    const dropDone = new Set();
    const dropUnsched = new Set();
    let changed = false;
    for (const v of vs) {
      if (v.rule === 'capture_no_blocks') {
        for (let i = 0; i < p.blocks.length; i++) dropBlocks.add(i);
        dropped.push({ rule: v.rule, detail: v.detail });
      } else if (v.block !== undefined) {
        if (!dropBlocks.has(v.block)) {
          const b = p.blocks[v.block];
          dropped.push({ rule: v.rule, detail: `${v.detail} [${b.todo_ref} ${b.start}~${b.end}]` });
        }
        dropBlocks.add(v.block);
      } else if (v.done_id !== undefined) {
        dropDone.add(v.done_id);
        dropped.push({ rule: v.rule, detail: v.detail });
      } else if (v.unscheduled !== undefined) {
        dropUnsched.add(v.unscheduled);
        dropped.push({ rule: v.rule, detail: v.detail });
      }
    }
    if (dropBlocks.size) { p.blocks = p.blocks.filter((_, i) => !dropBlocks.has(i)); changed = true; }
    if (dropDone.size) { p.done_todo_ids = p.done_todo_ids.filter(id => !dropDone.has(id)); changed = true; }
    if (dropUnsched.size) { p.unscheduled = p.unscheduled.filter((_, i) => !dropUnsched.has(i)); changed = true; }
    if (!changed) return { proposal: p, dropped, remaining: vs };
  }
  return { proposal: p, dropped, remaining: validate(input, p) };
}
