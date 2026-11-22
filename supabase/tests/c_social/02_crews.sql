-- 크루 생성·입장·내보내기·정원
do $$
declare sc uuid := c_t_school(); sc2 uuid := c_t_school(); o uuid := c_t_user('owner', sc); m uuid := c_t_user('mem', sc);
  x uuid := c_t_user('x', sc); out uuid := c_t_user('out', sc2); crew jsonb; gid uuid; code text; i int; u uuid; r jsonb;
begin
  perform test_login(o);
  perform c_t_err($q$select create_crew('')$q$, 'invalid_input');
  perform c_t_err(format('select create_crew(%L)', repeat('가', 31)), 'invalid_input');
  crew := create_crew('  스터디  ');
  gid := (crew ->> 'id')::uuid; code := crew ->> 'invite_code';
  assert crew ->> 'name' = '스터디' and crew ->> 'role' = 'owner' and (crew ->> 'member_count')::int = 1, '크루 모양';
  assert char_length(code) >= 8, '초대 코드 길이';
  assert code <> (create_crew('다른') ->> 'invite_code'), '초대 코드 무작위';

  -- 입장
  perform test_login(m);
  perform c_t_err($q$select join_crew('NOPE')$q$, 'invite_invalid');
  perform c_t_err($q$select join_crew(null)$q$, 'invite_invalid');
  r := join_crew(lower(code));      -- 대소문자 무관
  assert r ->> 'role' = 'member' and (r ->> 'member_count')::int = 2, '입장';
  assert (join_crew(code) ->> 'member_count')::int = 2, '다시 입장해도 그대로';
  assert jsonb_array_length(list_my_crews()) = 1;
  -- 다른 학교는 못 들어옴
  perform test_login(out);
  perform c_t_err(format('select join_crew(%L)', code), 'invite_invalid');
  perform c_t_err(format('select list_crew_members(%L)', gid), 'forbidden');
  assert list_my_crews() = '[]'::jsonb;
  -- 구성원 목록: 구성원만
  perform test_login(x);
  perform c_t_err(format('select list_crew_members(%L)', gid), 'forbidden');
  perform test_login(m);
  r := list_crew_members(gid);
  assert jsonb_array_length(r) = 2 and r -> 0 ->> 'role' = 'owner', '구성원 목록, 운영자 먼저';

  -- 내보내기: 일반 구성원은 못 함, 운영자는 할 수 있음
  perform c_t_err(format('select remove_crew_member(%L, %L)', gid, o), 'forbidden');
  perform test_login(x);
  perform c_t_err(format('select remove_crew_member(%L, %L)', gid, m), 'forbidden');
  perform test_login(o);
  perform c_t_err(format('select remove_crew_member(%L, %L)', gid, o), 'invalid_input');
  perform c_t_err(format('select remove_crew_member(%L, %L)', gid, x), 'not_found');
  perform remove_crew_member(gid, m);
  perform test_login(m);
  assert list_my_crews() = '[]'::jsonb, '내보내진 사람의 크루 목록';
  perform c_t_err(format('select list_crew_members(%L)', gid), 'forbidden');
  perform c_t_err(format('select join_crew(%L)', code), 'forbidden');   -- 다시 못 들어옴

  -- 정원 50
  reset role;
  for i in 1..48 loop
    u := c_t_user('f' || i, sc);
    insert into group_members (group_id, user_id) values (gid, u);
  end loop;
  assert (select count(*) from group_members where group_id = gid and status = 'active') = 49, '운영자 포함 49';
  perform test_login(x);
  assert (join_crew(code) ->> 'member_count')::int = 50, '50번째 입장';
  reset role;
  u := c_t_user('over', sc);
  perform test_login(u);
  perform c_t_err(format('select join_crew(%L)', code), 'crew_full');
  -- 나가면 자리가 난다
  perform test_login(x);
  perform leave_crew(gid);
  perform test_login(u);
  assert (join_crew(code) ->> 'member_count')::int = 50, '자리 남';

  -- 정원이 찬 크루에서 나가기
  perform leave_crew(gid);
  reset role;
  assert (select count(*) from group_members where group_id = gid and status = 'active') = 49;
end $$;

do $$
declare sc uuid := c_t_school(); o uuid := c_t_user('o', sc); a uuid := c_t_user('a', sc); b uuid := c_t_user('b', sc);
  gid uuid; code text; r jsonb;
begin
  perform test_login(o);
  r := create_crew('승계');  gid := (r ->> 'id')::uuid; code := r ->> 'invite_code';
  perform c_t_err(format('select leave_crew(%L)', gen_random_uuid()), 'not_found');
  perform test_login(a); perform join_crew(code);
  perform test_login(b); perform join_crew(code);
  reset role;   -- 같은 트랜잭션이라 시각이 같으니 순서를 명시
  update group_members set joined_at = now() - interval '2 hours' where group_id = gid and user_id = a;
  update group_members set joined_at = now() - interval '1 hour' where group_id = gid and user_id = b;
  perform test_login(o);
  perform leave_crew(gid);
  perform test_login(a);
  r := list_my_crews();
  assert r -> 0 ->> 'role' = 'owner', '가장 먼저 들어온 사람이 운영자가 됨';
  perform test_login(b);
  perform c_t_err(format('select remove_crew_member(%L, %L)', gid, a), 'forbidden');
  perform test_login(a); perform leave_crew(gid);
  perform test_login(b); perform leave_crew(gid);
  reset role;
  assert not exists (select 1 from groups where id = gid), '마지막 사람이 나가면 크루가 사라짐';
  -- 프로필 없는 로그인 사용자
  declare ghost uuid := gen_random_uuid();
  begin
    insert into auth.users (id, email) values (ghost, ghost || '@x.test');
    perform test_login(ghost);
    perform c_t_err($q$select create_crew('가')$q$, 'profile_required');
    perform c_t_err($q$select join_crew('ABCDEFGH')$q$, 'profile_required');
    reset role;
  end;
end $$;
