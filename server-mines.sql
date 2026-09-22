-- 머니로드 2.8 — 광산
-- 전국 6개 광구뿐입니다. 갱도를 파 내려갈수록 많이 캐지만 붕괴 위험도 같이 오릅니다.

create table if not exists mines (
  id          text primary key,
  name        text not null,
  region      text not null,
  ore         text not null,          -- 캐는 광물
  ore_ico     text not null,
  ore_base    numeric not null,       -- 광물 1개 기준가
  rate        numeric not null,       -- 광부 1인이 3분에 캐는 양
  base_price  numeric not null,
  price       numeric not null,
  owner_lc    text,
  owner_name  text,
  for_sale    boolean default true,
  depth       int not null default 1,        -- 갱도 심도 1~10
  npc         int not null default 0,        -- NPC 광부
  safety      int not null default 0,        -- 안전 설비 0~5
  stock       numeric not null default 0,    -- 창고에 쌓인 광물
  collapsed   timestamptz,                   -- 붕괴 복구 완료 시각
  paid_at     timestamptz,
  updated_at  timestamptz default now()
);
alter table mines enable row level security;
-- 정책 없음 = 공개 키로 직접 수정 불가. 아래 함수로만 다룹니다.

drop function if exists app_mines();
create or replace function app_mines()
returns table(id text, name text, region text, ore text, ore_ico text,
              ore_base numeric, rate numeric, base_price numeric, price numeric,
              owner_lc text, owner_name text, for_sale boolean,
              depth int, npc int, safety int, stock numeric,
              collapsed timestamptz, paid_at timestamptz)
language sql security definer as $fn$
  select id, name, region, ore, ore_ico, ore_base, rate, base_price, price,
         owner_lc, owner_name, for_sale, depth, npc, safety, stock, collapsed, paid_at
    from mines order by base_price;
$fn$;

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
  update mines set owner_lc = me, owner_name = myname, for_sale = false, updated_at = now()
   where id = p_id;
  return json_build_object('ok',true,'price',m.price,'name',m.name,'prev',m.owner_name);
end $fn$;

create or replace function app_mine_sell(p_user text, p_token text, p_id text, p_price numeric, p_on boolean)
returns json language plpgsql security definer as $fn$
declare me text; m mines%rowtype; np numeric;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','인증에 실패했습니다'); end if;
  select * into m from mines where id = p_id for update;
  if not found then return json_build_object('ok',false,'err','없는 광구입니다'); end if;
  if m.owner_lc is distinct from me then return json_build_object('ok',false,'err','내 광산이 아닙니다'); end if;
  if p_on then
    np := floor(p_price);
    if np < 1000 then return json_build_object('ok',false,'err','1,000원 이상으로 내놓아야 합니다'); end if;
    if np > 100000000000 then return json_build_object('ok',false,'err','값이 너무 큽니다'); end if;
    update mines set price = np, for_sale = true, updated_at = now() where id = p_id;
  else
    update mines set for_sale = false, updated_at = now() where id = p_id;
  end if;
  return json_build_object('ok',true);
end $fn$;

-- 심도 / 광부 / 안전설비 / 창고 / 붕괴 상태를 한 번에 고칩니다
create or replace function app_mine_set(p_user text, p_token text, p_id text, p_patch jsonb)
returns json language plpgsql security definer as $fn$
declare me text; m mines%rowtype;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','인증에 실패했습니다'); end if;
  select * into m from mines where id = p_id for update;
  if not found then return json_build_object('ok',false,'err','없는 광구입니다'); end if;
  if m.owner_lc is distinct from me then return json_build_object('ok',false,'err','내 광산이 아닙니다'); end if;

  update mines set
    depth     = least(10, greatest(1, coalesce((p_patch->>'depth')::int,  m.depth))),
    npc       = least(40, greatest(0, coalesce((p_patch->>'npc')::int,    m.npc))),
    safety    = least(5,  greatest(0, coalesce((p_patch->>'safety')::int, m.safety))),
    stock     = greatest(0, coalesce((p_patch->>'stock')::numeric, m.stock)),
    collapsed = case when p_patch ? 'collapsed'
                     then (case when p_patch->>'collapsed' is null then null
                                else (p_patch->>'collapsed')::timestamptz end)
                     else m.collapsed end,
    paid_at   = case when p_patch ? 'paid' then now() else m.paid_at end,
    updated_at = now()
  where id = p_id;
  return json_build_object('ok',true);
end $fn$;

grant execute on function app_mines()                                   to anon;
grant execute on function app_mine_buy(text,text,text)                  to anon;
grant execute on function app_mine_sell(text,text,text,numeric,boolean) to anon;
grant execute on function app_mine_set(text,text,text,jsonb)            to anon;

-- 유저 광부도 고용할 수 있게, 채용 제안이 광산도 받아들이도록 고칩니다
create or replace function app_job_offer(p_user text, p_token text, p_land text, p_worker text, p_wage numeric)
returns json language plpgsql security definer as $fn$
declare me text; myname text; w text; wname text; n int;
        o_owner text; o_ok boolean := false; o_cap int := 5;
begin
  me := app_auth(p_user,p_token);
  if me is null then return json_build_object('ok',false,'err','인증 실패'); end if;

  -- 회사이거나 광산이어야 합니다
  select owner_lc into o_owner from lands where id = p_land and bld_type = 'corp';
  if o_owner is not null then o_ok := true; end if;
  if not o_ok then
    select owner_lc into o_owner from mines where id = p_land;
    if o_owner is not null then o_ok := true; o_cap := 10; end if;
  end if;
  if not o_ok or o_owner is distinct from me then
    return json_build_object('ok',false,'err','내 회사나 광산이 아닙니다');
  end if;

  w := lower(trim(p_worker));
  if w = me then return json_build_object('ok',false,'err','자기 자신은 고용할 수 없습니다'); end if;
  select username into wname from accounts where username_lc = w;
  if wname is null then
    select p.username into wname from players p where p.id = 'u_' || w and p.is_guest = false limit 1;
    if wname is null then return json_build_object('ok',false,'err','없는 아이디입니다'); end if;
  end if;
  if floor(p_wage) < 100 then return json_build_object('ok',false,'err','급여는 100원 이상이어야 합니다'); end if;
  if exists(select 1 from employments where land_id=p_land and worker_lc=w and status in ('pending','active')) then
    return json_build_object('ok',false,'err','이미 제안했거나 근무 중입니다'); end if;
  select count(*) into n from employments where land_id=p_land and status='active';
  if n >= o_cap then return json_build_object('ok',false,'err','직원은 ' || o_cap || '명까지입니다'); end if;
  select username into myname from accounts where username_lc = me;
  insert into employments(land_id,boss_lc,boss_name,worker_lc,worker_name,wage)
    values (p_land, me, myname, w, wname, floor(p_wage));
  return json_build_object('ok',true,'worker',wname,
    'pending_login', not exists(select 1 from accounts where username_lc = w));
end $fn$;
grant execute on function app_job_offer(text,text,text,text,numeric) to anon;

-- 광구 6곳
insert into mines(id, name, region, ore, ore_ico, ore_base, rate, base_price, price) values
 ('M1','태백 탄광',        '강원', '석탄',    '🪨', 1200,  19, 60000000,  60000000),
 ('M2','단양 석회석 광산',  '충북', '석회석',  '🧱', 900,   19, 45000000,  45000000),
 ('M3','울진 은광',        '경북', '은',      '🥈', 4800,  9, 120000000, 120000000),
 ('M4','홍천 희토류 광산',  '강원', '희토류',  '💎', 9500,  8, 200000000, 200000000),
 ('M5','무극 금광',        '충북', '금',      '🥇', 21000, 5.2, 300000000, 300000000),
 ('M6','동해 심해 광구',    '동해', '망간단괴','🔮', 34000, 4.5, 400000000, 400000000)
on conflict (id) do update set rate = excluded.rate;

select id, name, ore, base_price from mines order by base_price;
