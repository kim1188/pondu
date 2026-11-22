\ir 00_helpers.sql
-- 사진 경로 규칙과 session-photos 버킷 정책
select tt_b.mk_user('가') as ua \gset
select tt_b.mk_user('나') as ub \gset
select tt_b.mk_user('다') as uc \gset
select set_config('t.ua', :'ua', false), set_config('t.ub', :'ub', false), set_config('t.uc', :'uc', false) \gset
select tt_b.befriend(:'ua', :'ub');

do $$
begin
  perform tt_b.assert((select public from storage.buckets where id = 'session-photos') = false, '버킷은 비공개');
end $$;

select test_login(:'ua');
select start_session(gen_random_uuid(), 'study', 'in_app_photo', 'friends') ->> 'id' as sa \gset
select set_config('t.sa', :'sa', false) \gset
select start_session(gen_random_uuid(), 'study', 'no_photo', 'friends') ->> 'id' is not null as dummy where false;

do $$
declare
  ua text := current_setting('t.ua'); sa text := current_setting('t.sa');
  s jsonb;
begin
  -- 경로 규칙 위반
  perform tt_b.expect_err(format('select attach_session_photo(%L, %L, null)', sa, ua || '/' || gen_random_uuid() || '/full.heic'), 'invalid_input');
  perform tt_b.expect_err(format('select attach_session_photo(%L, %L, null)', sa, gen_random_uuid() || '/' || sa || '/full.heic'), 'invalid_input');
  perform tt_b.expect_err(format('select attach_session_photo(%L, %L, null)', sa, ua || '/' || sa || '/thumb.heic'), 'invalid_input');
  perform tt_b.expect_err(format('select attach_session_photo(%L, %L, %L)', sa, ua || '/' || sa || '/full.heic', ua || '/' || sa || '/full.heic'), 'invalid_input');
  perform tt_b.expect_err(format('select attach_session_photo(%L, %L, null)', sa, '../' || ua || '/' || sa || '/full.heic'), 'invalid_input');
  perform tt_b.expect_err(format('select attach_session_photo(%L, null, null)', sa), 'invalid_input');
  s := attach_session_photo(sa::uuid, ua || '/' || sa || '/full.heic', ua || '/' || sa || '/thumb.heic');
  perform tt_b.assert(s->>'photo_path' = ua || '/' || sa || '/full.heic' and s->>'photo_thumb_path' = ua || '/' || sa || '/thumb.heic', '정상 첨부');
  -- 같은 경로 다시 붙이기는 그대로 성공(재시도 안전)
  s := attach_session_photo(sa::uuid, ua || '/' || sa || '/full.heic', ua || '/' || sa || '/thumb.heic');
  perform tt_b.assert(s->>'photo_path' is not null, '재시도');
end $$;

-- 사진 없는 기록(no_photo) 세션에는 사진을 붙일 수 없다
select end_session(:'sa', 'done');
select start_session(gen_random_uuid(), 'coding', 'no_photo', 'friends') ->> 'id' as sn \gset
do $$
declare ua text := current_setting('t.ua');
begin
  perform tt_b.expect_err(format('select attach_session_photo(%L, %L, null)', current_setting('t.sn', true), ua || '/x/full.heic'), 'not_found');
end $$;
select set_config('t.sn', :'sn', false) \gset
select tt_b.expect_err(format('select attach_session_photo(%L, %L, null)', :'sn', :'ua' || '/' || :'sn' || '/full.heic'), 'invalid_input');
select end_session(:'sn', 'done');

-- 끝난 지 24시간이 지난 세션에는 붙일 수 없다
reset role;
select tt_b.backdate(:'sn', interval '30 hours');
select test_login(:'ua');
select tt_b.expect_err(format('select attach_session_photo(%L, %L, null)', :'sn', :'ua' || '/' || :'sn' || '/full.heic'), 'invalid_input');
reset role;
update sessions set capture_mode = 'in_app_photo' where id = :'sn';
select test_login(:'ua');
select tt_b.expect_err(format('select attach_session_photo(%L, %L, null)', :'sn', :'ua' || '/' || :'sn' || '/full.heic'), 'session_not_active');
reset role;

-- 저장소 정책
-- 올리기: 내 폴더 + 내 세션 + 정해진 파일 이름만
select test_login(:'ua');
insert into storage.objects (bucket_id, name, owner) values ('session-photos', :'ua' || '/' || :'sa' || '/full.heic', :'ua');
insert into storage.objects (bucket_id, name, owner) values ('session-photos', :'ua' || '/' || :'sa' || '/thumb.heic', :'ua');
select tt_b.expect_denied(format('insert into storage.objects (bucket_id, name) values (''session-photos'', %L)', :'ub' || '/' || :'sa' || '/full.heic'));
select tt_b.expect_denied(format('insert into storage.objects (bucket_id, name) values (''session-photos'', %L)', :'ua' || '/' || gen_random_uuid() || '/full.heic'));
select tt_b.expect_denied(format('insert into storage.objects (bucket_id, name) values (''session-photos'', %L)', :'ua' || '/' || :'sa' || '/other.jpg'));
select tt_b.expect_denied(format('insert into storage.objects (bucket_id, name) values (''session-photos'', %L)', :'ua' || '/' || :'sa' || '/../x/full.heic'));
select tt_b.expect_denied(format('insert into storage.objects (bucket_id, name) values (''session-photos'', %L)', 'full.heic'));
select tt_b.expect_denied(format('insert into storage.objects (bucket_id, name) values (''other-bucket'', %L)', :'ua' || '/' || :'sa' || '/full.heic'));
-- 다른 사람은 내 폴더에 못 올린다. 남의 세션 폴더(내 uid)도 못 쓴다
select test_login(:'ub');
select tt_b.expect_denied(format('insert into storage.objects (bucket_id, name) values (''session-photos'', %L)', :'ua' || '/' || :'sa' || '/full.heic'));
select tt_b.expect_denied(format('insert into storage.objects (bucket_id, name) values (''session-photos'', %L)', :'ub' || '/' || :'sa' || '/full.heic'));

-- 읽기: 본인, 볼 수 있는 친구만. 친구가 아니면 안 보인다. 비공개로 돌리면 친구도 못 본다
select test_login(:'ub');
do $$ begin perform tt_b.assert((select count(*) from storage.objects where bucket_id = 'session-photos' and name like current_setting('t.ua') || '/%') = 2, '친구는 공개 세션의 사진을 본다'); end $$;
select test_login(:'uc');
do $$ begin perform tt_b.assert((select count(*) from storage.objects where bucket_id = 'session-photos' and name like current_setting('t.ua') || '/%') = 0, '모르는 사람은 못 본다'); end $$;
select test_login(:'ua');
do $$ begin perform tt_b.assert((select count(*) from storage.objects where bucket_id = 'session-photos' and name like current_setting('t.ua') || '/%') = 2, '본인은 본다'); end $$;
select update_session_share(:'sa', 'private', null, null);
select test_login(:'ub');
do $$ begin perform tt_b.assert((select count(*) from storage.objects where bucket_id = 'session-photos' and name like current_setting('t.ua') || '/%') = 0, '비공개로 돌리면 친구도 못 본다'); end $$;

-- 지우기: 본인 폴더만
select tt_b.expect_denied('delete from storage.objects where bucket_id = ''session-photos''') where false;
do $$ declare n int; begin
  delete from storage.objects where bucket_id = 'session-photos'; get diagnostics n = row_count;
  perform tt_b.assert(n = 0, '남의 사진은 못 지운다');
end $$;
select test_login(:'ua');
do $$ declare n int; begin
  delete from storage.objects where bucket_id = 'session-photos' and name like '%/thumb.heic'; get diagnostics n = row_count;
  perform tt_b.assert(n = 1, '내 사진은 지운다');
end $$;
-- 고치기(update)는 정책이 없어 막힌다
do $$ declare n int; begin
  update storage.objects set name = name where bucket_id = 'session-photos'; get diagnostics n = row_count;
  perform tt_b.assert(n = 0, '덮어쓰기(update) 불가');
end $$;
reset role;
