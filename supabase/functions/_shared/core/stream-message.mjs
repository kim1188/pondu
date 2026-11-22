// 스트리밍으로 들어오는 부분 JSON에서 최상위 문자열 필드(기본 message)의 내용만 뽑아낸다.
// 구조화 출력은 속성을 스키마 순서대로 쓰므로, message를 맨 앞에 두면 나머지가 끝나기 전에 흘려보낼 수 있다.
// 한 글자씩 읽는 작은 상태 기계다. 깊이 2 이상(todos 안의 같은 이름 키)은 무시한다.

const ESC = { n: '\n', t: '\t', r: '\r', b: '\b', f: '\f', '"': '"', '\\': '\\', '/': '/' };

export class MessageExtractor {
  constructor(field = 'message') {
    this.field = field;
    this.depth = 0;
    this.inStr = false;
    this.esc = false;
    this.uniLeft = 0;
    this.uniBuf = '';
    this.hi = null; // 앞쪽 서로게이트
    this.isKey = false;
    this.keyBuf = '';
    this.lastKey = null;
    this.expectKey = false;
    this.afterColon = false;
    this.capture = false;
    this.done = false;
    this.text = '';
  }

  /** 조각 하나를 먹이고, 이번에 새로 확정된 message 글자를 돌려준다(없으면 ''). */
  push(chunk) {
    let out = '';
    const emit = ch => { if (this.capture) out += ch; else if (this.isKey) this.keyBuf += ch; };
    for (const c of chunk) {
      if (this.inStr) {
        if (this.uniLeft > 0) {
          this.uniBuf += c;
          if (--this.uniLeft === 0) {
            const code = parseInt(this.uniBuf, 16);
            this.uniBuf = '';
            if (Number.isNaN(code)) continue;
            if (code >= 0xd800 && code <= 0xdbff) { this.hi = code; continue; }
            if (this.hi != null && code >= 0xdc00 && code <= 0xdfff) {
              emit(String.fromCodePoint(((this.hi - 0xd800) << 10) + (code - 0xdc00) + 0x10000));
            } else emit(String.fromCharCode(code));
            this.hi = null;
          }
        } else if (this.esc) {
          this.esc = false;
          if (c === 'u') this.uniLeft = 4;
          else emit(ESC[c] ?? c);
        } else if (c === '\\') this.esc = true;
        else if (c === '"') {
          this.inStr = false;
          if (this.isKey) { this.lastKey = this.keyBuf; this.isKey = false; }
          else if (this.capture) { this.capture = false; this.done = true; }
        } else emit(c);
        continue;
      }
      if (c === '"') {
        this.inStr = true;
        if (this.depth === 1 && this.expectKey) { this.isKey = true; this.keyBuf = ''; this.expectKey = false; }
        else if (this.depth === 1 && this.afterColon && this.lastKey === this.field && !this.done) this.capture = true;
        this.afterColon = false;
      } else if (c === '{' || c === '[') {
        this.depth++;
        if (c === '{' && this.depth === 1) this.expectKey = true;
        this.afterColon = false;
      } else if (c === '}' || c === ']') this.depth--;
      else if (c === ',' && this.depth === 1) this.expectKey = true;
      else if (c === ':' && this.depth === 1) this.afterColon = true;
      else if (!/\s/.test(c)) this.afterColon = false;
    }
    this.text += out;
    return out;
  }
}
