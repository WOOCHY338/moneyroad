-- 머니로드 5.0 — 1:1 대결 도박
-- 같은 금액을 걸고 둘이 붙습니다. 먼저 끝낸 사람이 판돈을 다 가져갑니다.

create table if not exists duels (
  id          bigint generated always as identity primary key,
  bet         numeric not null,
  mode        text,                               -- jump / memory
  seed        bigint not null,                    -- 두 사람이 같은 판을 보게 하는 씨앗
  p1_lc       text not null, p1_name text not null,
  p2_lc       text,          p2_name text,
  p1_vote     text, p2_vote text,
  status      text not null default 'waiting',    -- waiting / picking / playing / done / cancelled
  started_at  timestamptz,
  winner_lc   text, winner_name text,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);
alter table duels enable row level security;
create index if not exists duels_wait on duels(status, bet) where status = 'waiting';

-- ── 매칭: 같은 금액으로 기다리는 방이 있으면 들어가고, 없으면 방을 만듭니다
create or replace function app_duel_join(p_user text, p_token text, p_bet numeric)
returns json language plpgsql security definer as $fn$
declare me text; myname text; d duels%rowtype; b numeric;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','로그인이 필요합니다'); end if;
  b := floor(p_bet);
  if b < 1000 then return json_build_object('ok',false,'err','최소 1,000원부터 걸 수 있습니다'); end if;
  if b > 100000000000000 then return json_build_object('ok',false,'err','판돈이 너무 큽니다'); end if;
  select username into myname from accounts where username_lc = me;

  -- 오래 방치된 대기방은 치웁니다
  update duels set status = 'cancelled', updated_at = now()
   where status = 'waiting' and created_at < now() - interval '3 minutes';

  -- 이미 참가 중인 방이 있으면 그걸 돌려줍니다
  select * into d from duels
   where (p1_lc = me or p2_lc = me) and status in ('waiting','picking','playing')
   order by id desc limit 1;
  if found then return json_build_object('ok',true,'id',d.id,'status',d.status); end if;

  -- 같은 금액으로 기다리는 남의 방
  select * into d from duels
   where status = 'waiting' and bet = b and p1_lc <> me
   order by id limit 1 for update skip locked;
  if found then
    update duels set p2_lc = me, p2_name = myname, status = 'picking', updated_at = now()
     where id = d.id;
    return json_build_object('ok',true,'id',d.id,'status','picking','matched',true);
  end if;

  insert into duels(bet, seed, p1_lc, p1_name)
    values (b, floor(random()*2000000000)::bigint, me, myname)
    returning * into d;
  return json_build_object('ok',true,'id',d.id,'status','waiting','matched',false);
end $fn$;

-- ── 방 상태
create or replace function app_duel_state(p_user text, p_token text, p_id bigint)
returns json language plpgsql security definer as $fn$
declare me text; d duels%rowtype;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','로그인이 필요합니다'); end if;
  select * into d from duels where id = p_id;
  if not found then return json_build_object('ok',false,'err','없는 방입니다'); end if;
  if d.p1_lc <> me and coalesce(d.p2_lc,'') <> me then
    return json_build_object('ok',false,'err','내 방이 아닙니다'); end if;
  return json_build_object('ok',true,'id',d.id,'bet',d.bet,'mode',d.mode,'seed',d.seed,
    'status',d.status,'me', case when d.p1_lc = me then 1 else 2 end,
    'p1',d.p1_name,'p2',d.p2_name,'p1_vote',d.p1_vote,'p2_vote',d.p2_vote,
    'winner',d.winner_name,'winner_lc',d.winner_lc,
    'started_at',d.started_at);
end $fn$;

-- ── 모드 투표. 둘 다 고르면 시작합니다 (갈리면 방을 연 사람 쪽)
create or replace function app_duel_vote(p_user text, p_token text, p_id bigint, p_mode text)
returns json language plpgsql security definer as $fn$
declare me text; d duels%rowtype; pick text;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','로그인이 필요합니다'); end if;
  if p_mode not in ('jump','memory') then return json_build_object('ok',false,'err','없는 모드입니다'); end if;
  select * into d from duels where id = p_id for update;
  if not found then return json_build_object('ok',false,'err','없는 방입니다'); end if;
  if d.status <> 'picking' then return json_build_object('ok',false,'err','지금은 고를 수 없습니다'); end if;

  if d.p1_lc = me then update duels set p1_vote = p_mode, updated_at = now() where id = p_id;
  elsif d.p2_lc = me then update duels set p2_vote = p_mode, updated_at = now() where id = p_id;
  else return json_build_object('ok',false,'err','내 방이 아닙니다'); end if;

  select * into d from duels where id = p_id;
  if d.p1_vote is not null and d.p2_vote is not null then
    pick := case when d.p1_vote = d.p2_vote then d.p1_vote else d.p1_vote end;
    update duels set mode = pick, status = 'playing', started_at = now(), updated_at = now()
     where id = p_id;
    return json_build_object('ok',true,'started',true,'mode',pick);
  end if;
  return json_build_object('ok',true,'started',false);
end $fn$;

-- ── 완주 보고. 먼저 부른 쪽이 이깁니다.
create or replace function app_duel_finish(p_user text, p_token text, p_id bigint)
returns json language plpgsql security definer as $fn$
declare me text; myname text; d duels%rowtype; loser text;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','로그인이 필요합니다'); end if;
  select * into d from duels where id = p_id for update;
  if not found then return json_build_object('ok',false,'err','없는 방입니다'); end if;
  if d.p1_lc <> me and coalesce(d.p2_lc,'') <> me then
    return json_build_object('ok',false,'err','내 방이 아닙니다'); end if;
  if d.status = 'done' then
    return json_build_object('ok',true,'winner',d.winner_name,'mine', d.winner_lc = me);
  end if;
  if d.status <> 'playing' then return json_build_object('ok',false,'err','아직 시작하지 않았습니다'); end if;
  -- 너무 빠른 완주는 받지 않습니다
  if d.started_at > now() - interval '4 seconds' then
    return json_build_object('ok',false,'err','너무 빠릅니다');
  end if;

  select username into myname from accounts where username_lc = me;
  loser := case when d.p1_lc = me then d.p2_lc else d.p1_lc end;
  update duels set status = 'done', winner_lc = me, winner_name = myname, updated_at = now()
   where id = p_id;
  -- 판돈 두 배를 승자에게 보냅니다 (양쪽 모두 시작할 때 자기 몫을 걸었습니다)
  insert into transfers(from_lc, from_name, to_lc, amount)
    values (loser, '대결 판돈', me, d.bet * 2);
  return json_build_object('ok',true,'winner',myname,'mine',true,'prize',d.bet*2);
end $fn$;

-- ── 대기 취소
create or replace function app_duel_cancel(p_user text, p_token text, p_id bigint)
returns json language plpgsql security definer as $fn$
declare me text; d duels%rowtype;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','로그인이 필요합니다'); end if;
  select * into d from duels where id = p_id for update;
  if not found then return json_build_object('ok',false,'err','없는 방입니다'); end if;
  if d.p1_lc <> me and coalesce(d.p2_lc,'') <> me then
    return json_build_object('ok',false,'err','내 방이 아닙니다'); end if;
  if d.status not in ('waiting','picking') then
    return json_build_object('ok',false,'err','이미 시작한 판입니다'); end if;
  update duels set status = 'cancelled', updated_at = now() where id = p_id;
  return json_build_object('ok',true);
end $fn$;

grant execute on function app_duel_join(text,text,numeric)  to anon;
grant execute on function app_duel_state(text,text,bigint)  to anon;
grant execute on function app_duel_vote(text,text,bigint,text) to anon;
grant execute on function app_duel_finish(text,text,bigint) to anon;
grant execute on function app_duel_cancel(text,text,bigint) to anon;

select count(*) as 대결방 from duels;
