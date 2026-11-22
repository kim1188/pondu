-- 스키마가 적용됐고, 로그인한 사용자도 테이블을 직접 읽을 수 없는지(기본 거부) 확인한다.
do $$
declare n int; u uuid := gen_random_uuid();
begin
  select count(*) into n from pg_tables where schemaname = 'public';
  assert n >= 20, format('테이블 수 %s', n);
  select count(*) into n from pg_tables where schemaname = 'public' and not rowsecurity;
  assert n = 0, '접근 규칙이 꺼진 테이블이 있음';
  perform test_login(u);
  begin
    perform 1 from public.profiles;
    raise exception '직접 읽기가 허용됨';
  exception when insufficient_privilege then null;
  end;
  reset role;
end $$;
