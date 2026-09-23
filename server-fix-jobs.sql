-- 머니로드 3.2 — 일자리 관련 버그 수정

-- ① app_jobs 가 worker_lc 를 내려주지 않아, 클라이언트가 급여를 보낼 때
--    worker_name 을 소문자로 바꿔 아이디로 쓰고 있었습니다. 이름과 아이디가
--    다르면 엉뚱한 사람에게 돈이 갑니다.
drop function if exists app_jobs(text,text);
create or replace function app_jobs(p_user text, p_token text)
returns table(id bigint, land_id text, boss_name text, worker_name text, worker_lc text,
              wage numeric, status text, role text, worked_at timestamptz, shifts int)
language plpgsql security definer as $fn$
declare me text;
begin
  me := app_auth(p_user,p_token);
  if me is null then return; end if;
  return query
    select e.id, e.land_id, e.boss_name, e.worker_name, e.worker_lc, e.wage, e.status,
           case when e.boss_lc = me then 'boss' else 'worker' end,
           e.worked_at, e.shifts
      from employments e
     where (e.boss_lc = me or e.worker_lc = me) and e.status in ('pending','active')
     order by e.id desc;
end $fn$;
grant execute on function app_jobs(text,text) to anon;

-- ② 땅이나 광산을 팔면 그 자리의 직원 계약이 그대로 남아 유령 일자리가 됐습니다.
--    새 주인은 모르는 직원이고, 전 주인은 급여를 주지 않으니 영영 돈을 못 받습니다.
--    주인이 바뀌는 순간 계약을 종료합니다.
create or replace function app_land_buy(p_user text, p_token text, p_id text)
returns json language plpgsql security definer as $fn$
declare me text; myname text; l lands%rowtype;
begin
  if now() < timestamptz '2026-09-22 05:30:00+00' then
    return json_build_object('ok',false,'err','오후 2시 30분부터 살 수 있습니다');
  end if;
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','인증에 실패했습니다'); end if;
  select * into l from lands where id = p_id for update;
  if not found then return json_build_object('ok',false,'err','없는 매물입니다'); end if;
  if not l.for_sale then return json_build_object('ok',false,'err','매물로 나와 있지 않습니다'); end if;
  if l.owner_lc = me then return json_build_object('ok',false,'err','이미 내 땅입니다'); end if;
  select username into myname from accounts where username_lc = me;
  if myname is null then return json_build_object('ok',false,'err','계정을 찾을 수 없습니다'); end if;
  if l.owner_lc is not null then
    insert into transfers(from_lc, from_name, to_lc, amount)
      values (me, myname || ' (토지 매각대금)', l.owner_lc, l.price);
  end if;
  update employments set status = 'ended'
   where land_id = p_id and status in ('pending','active');
  update lands set owner_lc = me, owner_name = myname, for_sale = false, updated_at = now() where id = p_id;
  return json_build_object('ok',true,'price',l.price,'name',l.name,'prev',l.owner_name);
end $fn$;
grant execute on function app_land_buy(text,text,text) to anon;

create or replace function app_mine_buy(p_user text, p_token text, p_id text)
returns json language plpgsql security definer as $fn$
declare me text; myname text; m mines%rowtype;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','인증에 실패했습니다'); end if;
  select * into m from mines where id = p_id for update;
  if not found then return json_build_object('ok',false,'err','없는 광구입니다'); end if;
  if not m.for_sale then return json_build_object('ok',false,'err','매물로 나와 있지 않습니다'); end if;
  if m.owner_lc = me then return json_build_object('ok',false,'err','이미 내 광산입니다'); end if;
  select username into myname from accounts where username_lc = me;
  if myname is null then return json_build_object('ok',false,'err','계정을 찾을 수 없습니다'); end if;
  if m.owner_lc is not null then
    insert into transfers(from_lc, from_name, to_lc, amount)
      values (me, myname || ' (광구 매각대금)', m.owner_lc, m.price);
  end if;
  update employments set status = 'ended'
   where land_id = p_id and status in ('pending','active');
  update mines set owner_lc = me, owner_name = myname, for_sale = false, updated_at = now()
   where id = p_id;
  return json_build_object('ok',true,'price',m.price,'name',m.name,'prev',m.owner_name);
end $fn$;
grant execute on function app_mine_buy(text,text,text) to anon;

-- ③ 이미 유령이 된 계약 정리 — 주인이 없거나 회사가 아닌 자리의 계약
update employments e set status = 'ended'
 where e.status in ('pending','active')
   and not exists (
     select 1 from lands l where l.id = e.land_id and l.owner_lc = e.boss_lc and l.bld_type = 'corp'
     union all
     select 1 from mines m where m.id = e.land_id and m.owner_lc = e.boss_lc);

select (select count(*) from employments where status in ('pending','active')) as 살아있는계약;
