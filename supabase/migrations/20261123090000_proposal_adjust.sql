-- 제안 고치기(비서 adjust 요청)에 쓰는 내부 읽기 함수.
-- 사용자의 답("이 일은 50분 걸려요", "오늘 들어가는 만큼만")으로 제안을 고칠 때 Edge Function이 저장된 제안을 읽는다.
-- 고친 결과는 assistant_proposal_save 로 새 제안이 된다. 원래 제안은 건드리지 않는다.
-- 적용했거나 24시간이 지난 제안은 없는 것과 같다(apply_proposal 과 같은 기준).
create or replace function assistant_proposal_get(p_user uuid, p_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('kind', kind, 'proposal', proposal)
    from assistant_proposals
   where id = p_id and user_id = p_user and applied_at is null and created_at >= now() - interval '24 hours';
$$;
revoke all on function assistant_proposal_get(uuid, uuid) from public, anon, authenticated;
grant execute on function assistant_proposal_get(uuid, uuid) to service_role;
