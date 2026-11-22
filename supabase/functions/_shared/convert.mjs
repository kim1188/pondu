// 서버의 Todo/PlanBlock(UTC 시각)와 비서 core 입력(한국 시간 날짜·시각) 사이의 변환.
// core는 모든 시각을 한국 시간(+09:00)으로 다룬다. 서버는 due_at(timestamptz)과 due_has_time을 쓴다.
import { DATE_RE, HM_RE, at, localDate, localHM, ms } from './core/time.mjs';

/** 서버 Todo → core 할 일. 시각이 없는(due_has_time=false) 마감은 due_time이 null이다. */
export function todoToCore(todo, extra = {}) {
  const t = todo.due_at ? ms(todo.due_at) : null;
  return {
    id: todo.id,
    title: todo.title,
    due_date: t == null ? null : localDate(t),
    due_time: t == null || !todo.due_has_time ? null : localHM(t),
    estimate_min: todo.estimate_min ?? null,
    status: todo.status,
    ...extra,
  };
}

/** 서버 PlanBlock → core 블록. 취소·옮긴 블록은 겹침 검사에 쓰지 않으므로 호출 쪽에서 거른다. */
export function blockToCore(b) {
  return { id: b.id, todo_ref: b.todo_id ?? null, start: toKst(b.start_at), end: toKst(b.end_at), locked: !!b.locked, status: b.status };
}

/** ISO 시각 → 한국 시간 표기(+09:00, 초 포함). 못 읽으면 null. */
export function toKst(iso) {
  const t = ms(iso);
  if (t == null) return null;
  return new Date(t + 9 * 3600 * 1000).toISOString().slice(0, 19) + '+09:00';
}

/** core 할 일 후보 → 서버 Todo 필드. */
export function coreTodoToServer(t) {
  let due_at = null;
  let due_has_time = false;
  if (t.due_date && DATE_RE.test(t.due_date)) {
    const hasTime = !!t.due_time && HM_RE.test(t.due_time);
    // 시각이 없으면 그날 23:59(한국 시간)를 마감으로 둔다. due_has_time=false라서 화면에는 날짜만 보인다.
    due_at = new Date(ms(at(t.due_date, hasTime ? t.due_time : '23:59'))).toISOString();
    due_has_time = hasTime;
  }
  return { title: t.title, due_at, due_has_time, estimate_min: t.estimate_min ?? null, category: t.category ?? null };
}
