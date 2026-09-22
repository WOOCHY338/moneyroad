-- 머니로드 2.6 — 직원 업무
-- 직원은 3분마다 업무를 처리해야 제 몫을 합니다.
-- 처리하면 급여의 절반이 성과급으로 나가고, 손 놓으면 생산성이 떨어집니다.

alter table employments add column if not exists worked_at timestamptz;
alter table employments add column if not exists shifts    int not null default 0;

-- 반환 칼럼이 늘어나므로 먼저 지웁니다
drop function if exists app_jobs(text,text);
create or replace function app_jobs(p_user text, p_token text)
returns table(id bigint, land_id text, boss_name text, worker_name text, wage numeric,
              status text, role text, worked_at timestamptz, shifts int)
language plpgsql security definer as $fn$
declare me text;
begin
  me := app_auth(p_user,p_token);
  if me is null then return; end if;
  return query
    select e.id, e.land_id, e.boss_name, e.worker_name, e.wage, e.status,
           case when e.boss_lc = me then 'boss' else 'worker' end,
           e.worked_at, e.shifts
      from employments e
     where (e.boss_lc = me or e.worker_lc = me) and e.status in ('pending','active')
     order by e.id desc;
end $fn$;

create or replace function app_job_work(p_user text, p_token text, p_id bigint)
returns json language plpgsql security definer as $fn$
declare me text; e employments%rowtype; bonus int; wait int;
begin
  me := app_auth(p_user,p_token);
  if me is null then return json_build_object('ok',false,'err','인증 실패'); end if;
  select * into e from employments where id = p_id for update;
  if not found or e.worker_lc is distinct from me or e.status <> 'active' then
    return json_build_object('ok',false,'err','근무 중인 일자리가 아닙니다');
  end if;
  if e.worked_at is not null and e.worked_at > now() - interval '3 minutes' then
    wait := ceil(extract(epoch from (e.worked_at + interval '3 minutes' - now())));
    return json_build_object('ok',false,'err','아직 쉬는 시간입니다','wait',wait);
  end if;
  bonus := greatest(100, floor(e.wage * 0.5));
  update employments set worked_at = now(), shifts = shifts + 1 where id = p_id;
  insert into transfers(from_lc, from_name, to_lc, amount)
    values (e.boss_lc, e.boss_name || ' (성과급)', me, bonus);
  return json_build_object('ok',true,'bonus',bonus,'shifts',e.shifts+1);
end $fn$;

grant execute on function app_jobs(text,text)            to anon;
grant execute on function app_job_work(text,text,bigint) to anon;

-- 테스트로 만들었던 계정 정리
delete from employments where worker_lc in ('채용8930','랭킹테스트','폴백테스트','공사테스트','기기a8661','purgetest')
                           or boss_lc   in ('채용8930','랭킹테스트','폴백테스트','공사테스트','기기a8661','purgetest');
delete from players where username in ('채용8930','랭킹테스트','폴백테스트','공사테스트','기기A8661','purgetest');
