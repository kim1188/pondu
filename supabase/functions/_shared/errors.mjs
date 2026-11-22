// 서버 함수 공통: 오류 코드(계약 4절)와 HTTP 응답 도우미.
export class FnError extends Error {
  constructor(code, status = 400, detail) { super(detail ?? code); this.code = code; this.status = status; }
}

export const STATUS = {
  not_authenticated: 401, forbidden: 403, not_found: 404, invalid_input: 400,
  quota_exceeded: 429, rate_limited: 429, assistant_unavailable: 503,
};

/** Postgres 함수가 낸 오류(message가 계약 코드)를 FnError로 바꾼다. */
export function fromDbError(e) {
  const code = e?.message && /^[a-z_]+$/.test(e.message) ? e.message : null;
  if (code) return new FnError(code, STATUS[code] ?? 400);
  return new FnError('assistant_unavailable', 503, 'db error');
}

export const jsonResponse = (body, status = 200, headers = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } });

export const errorResponse = e => {
  const code = e instanceof FnError ? e.code : 'unknown';
  return jsonResponse({ error: { code } }, e instanceof FnError ? e.status : 500);
};

export const sse = (event, data) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
