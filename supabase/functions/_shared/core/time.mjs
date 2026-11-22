// 모든 시각은 한국 시간(+09:00) 기준으로 다룬다.
const KST_MS = 9 * 3600 * 1000;

export const ms = iso => {
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : null;
};
const shifted = t => new Date(t + KST_MS).toISOString();
export const localDate = t => shifted(t).slice(0, 10); // YYYY-MM-DD
export const localHM = t => shifted(t).slice(11, 16); // HH:MM
export const at = (date, hm) => `${date}T${hm}:00+09:00`;
export const overlaps = (aStart, aEnd, bStart, bEnd) => aStart < bEnd && bStart < aEnd;
export const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
export const HM_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

/** 할 일의 마감 시각(ms). 시각이 없으면 그날의 끝. 마감이 없으면 null. */
export function dueMs(todo) {
  if (!todo?.due_date || !DATE_RE.test(todo.due_date)) return null;
  const hm = todo.due_time && HM_RE.test(todo.due_time) ? todo.due_time : '23:59';
  return ms(at(todo.due_date, hm));
}
