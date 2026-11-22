-- 알림 예약 작업은 Supabase의 pg_net으로 Edge Function을 호출한다.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net with schema extensions;
  end if;
end;
$$;
