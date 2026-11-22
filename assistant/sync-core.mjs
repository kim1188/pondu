// assistant/core 를 supabase/functions/_shared/core 로 복사한다.
// Edge Function 배포는 functions 폴더 밖의 파일을 묶어 주지 않으므로 같은 파일을 한 벌 더 둔다.
// 테스트(test/vendored.test.mjs)가 두 벌이 같은지 확인한다. 고칠 때는 assistant/core만 고치고 이 스크립트를 돌린다.
import { cpSync, mkdirSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const dst = join(here, '..', 'supabase', 'functions', '_shared', 'core');
mkdirSync(dst, { recursive: true });
for (const f of readdirSync(join(here, 'core'))) cpSync(join(here, 'core', f), join(dst, f));
console.log('synced ->', dst);
