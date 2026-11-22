// 예상 시간 보정: 사용자가 정한 estimate_min은 그대로 두고, 과거 기록 배수를 곱한 planning_min을 덧붙인다.
// 배수는 서버(assistant_context)가 분야별로 준다. 분야를 모르는 할 일이나 예상이 없는 할 일에는 붙이지 않는다.

const clampFactor = f => Math.min(3, Math.max(0.5, Number(f)));

/**
 * @param {object[]} todos  core 입력 형식의 할 일. category(또는 thread_category)가 있으면 그 분야의 배수를 쓴다.
 * @param {Record<string, number>} [factors]
 */
export function withPlanningMinutes(todos, factors) {
  return (todos ?? []).map(t => {
    const cat = t.category ?? t.thread_category ?? null;
    const f = cat && factors ? factors[cat] : null;
    if (t.estimate_min == null || f == null || !Number.isFinite(Number(f))) return t;
    const factor = clampFactor(f);
    const planning_min = Math.min(1440, Math.max(1, Math.round(t.estimate_min * factor)));
    return { ...t, planning_min, estimate_factor: Math.round(factor * 100) / 100 };
  });
}
