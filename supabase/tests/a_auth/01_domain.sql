-- M0 5.1 테스트 1~3: 가입 도메인 제한
\ir 00_helpers.sql
delete from auth.users where email ilike '%korea.ac.kr%' or email ilike '%@gmail.com' or email ilike '%evil.com';

do $$
declare e text; n int; r jsonb;
begin
  -- 1. 받아들여짐
  insert into auth.users (email) values ('a@korea.ac.kr');
  -- 3. 대소문자 혼합도 받아들여짐
  insert into auth.users (email) values ('A@Korea.AC.kr');
  insert into auth.users (email) values ('b@KOREA.AC.KR');

  -- 2. 거절
  foreach e in array array[
    'a@gmail.com', 'a@korea.ac.kr.evil.com', 'a@xkorea.ac.kr', 'a@KOREA.AC.KR.evil.com',
    'a@sub.korea.ac.kr', 'a@korea.ac.kr.', 'a@korea.ac.kr@evil.com', 'a@evil.com@korea.ac.kr',
    'korea.ac.kr', '@korea.ac.kr', 'a@', '', ' a@korea.ac.kr'
  ] loop
    begin
      insert into auth.users (email) values (e);
      raise exception '거절되어야 하는 주소가 통과함: [%]', e;
    exception when sqlstate 'P0001' then
      assert sqlerrm = 'email_domain_not_allowed', format('거절 코드 [%s]: %s', e, sqlerrm);
    end;
  end loop;
  -- 메일이 없는 사용자 생성도 거절
  begin
    insert into auth.users (email) values (null);
    raise exception '메일 없는 가입이 통과함';
  exception when sqlstate 'P0001' then null;
  end;
  -- 수정으로 우회하는 것도 막는다
  begin
    update auth.users set email = 'a@gmail.com' where email = 'a@korea.ac.kr';
    raise exception '메일을 다른 도메인으로 바꾸는 것이 통과함';
  exception when sqlstate 'P0001' then null;
  end;

  select count(*) into n from auth.users where email ilike '%korea.ac.kr';
  assert n = 3, format('받아들여진 사용자 수 %s', n);

  -- 인증 서비스 "사용자 생성 전" 훅 함수
  r := public.hook_before_user_created(jsonb_build_object('user', jsonb_build_object('email', 'Z@Korea.ac.kr')));
  assert r = '{}'::jsonb, format('훅 통과 응답 %s', r);
  r := public.hook_before_user_created(jsonb_build_object('user', jsonb_build_object('email', 'z@korea.ac.kr.evil.com')));
  assert r #>> '{error,message}' = '고려대학교 메일(@korea.ac.kr)만 가입할 수 있어요.', format('훅 거절 메시지 %s', r);
  assert (r #>> '{error,http_code}')::int = 400;
  r := public.hook_before_user_created(jsonb_build_object('user', jsonb_build_object('email', 'z@gmail.com')));
  assert r #> '{error,message}' is not null;
  r := public.hook_before_user_created('{}'::jsonb);
  assert r #> '{error,message}' is not null, '메일 없는 훅 요청은 거절';
end $$;

-- 훅·검사 함수는 앱(로그인 사용자·비로그인)이 부를 수 없다
select test_login(gen_random_uuid());
select public.a_expect_denied($q$select public.hook_before_user_created('{}'::jsonb)$q$);
reset role;
select test_anon();
select public.a_expect_denied($q$select public.hook_before_user_created('{}'::jsonb)$q$);
reset role;
