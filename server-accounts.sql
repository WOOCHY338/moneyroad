-- 머니로드 · 서버 계정 (어느 기기에서든 같은 계정으로 접속)
-- Supabase → SQL Editor 에 통째로 붙여넣고 Run 하세요.
--
-- 보안 설계
--  · accounts 테이블은 RLS를 켜되 정책을 하나도 만들지 않습니다.
--    → 공개 키(anon)로는 테이블을 직접 읽거나 쓸 수 없습니다.
--  · 아래 함수들만 security definer 로 동작하며, 비밀번호 해시는 절대 밖으로 나가지 않습니다.
--  · 비밀번호는 bcrypt(pgcrypto)로 해시해 저장합니다. 원문은 저장되지 않습니다.

create extension if not exists pgcrypto;

create table if not exists accounts (
  username_lc text primary key,
  username    text not null,
  pass_hash   text not null,
  token       text,
  slots       jsonb,                 -- 저장 슬롯 6칸
  updated_at  timestamptz default now(),
  created_at  timestamptz default now()
);

alter table accounts enable row level security;
-- 정책 없음 = 공개 키로는 직접 접근 불가

-- ── 회원가입
create or replace function app_signup(p_user text, p_pass text, p_slots jsonb default null)
returns json language plpgsql security definer as $fn$
declare nm text; lc text; tk text;
begin
  nm := trim(p_user); lc := lower(nm);
  if length(nm) < 2  then return json_build_object('ok',false,'err','아이디는 2자 이상이어야 합니다'); end if;
  if length(nm) > 12 then return json_build_object('ok',false,'err','아이디는 12자 이하여야 합니다'); end if;
  if nm ~ '[<>&"''[:space:]]' then return json_build_object('ok',false,'err','아이디에 공백이나 특수문자는 쓸 수 없습니다'); end if;
  if length(p_pass) < 4 then return json_build_object('ok',false,'err','비밀번호는 4자 이상이어야 합니다'); end if;
  if exists(select 1 from accounts where username_lc = lc) then
    return json_build_object('ok',false,'err','이미 있는 아이디입니다');
  end if;
  tk := encode(gen_random_bytes(18),'hex');
  insert into accounts(username_lc, username, pass_hash, token, slots)
    values (lc, nm, crypt(p_pass, gen_salt('bf')), tk, p_slots);
  return json_build_object('ok',true,'username',nm,'token',tk,'slots',p_slots);
end $fn$;

-- ── 로그인 (성공하면 저장 슬롯까지 함께 돌려줍니다)
create or replace function app_login(p_user text, p_pass text)
returns json language plpgsql security definer as $fn$
declare r accounts%rowtype; tk text;
begin
  select * into r from accounts where username_lc = lower(trim(p_user));
  if not found then
    return json_build_object('ok',false,'nouser',true,'err','없는 아이디입니다');
  end if;
  if r.pass_hash <> crypt(p_pass, r.pass_hash) then
    return json_build_object('ok',false,'err','비밀번호가 틀렸습니다');
  end if;
  tk := encode(gen_random_bytes(18),'hex');
  update accounts set token = tk where username_lc = r.username_lc;
  return json_build_object('ok',true,'username',r.username,'token',tk,'slots',r.slots);
end $fn$;

-- ── 내부용: 토큰 검증
create or replace function app_auth(p_user text, p_token text)
returns text language sql security definer as $fn$
  select username_lc from accounts
   where username_lc = lower(trim(p_user)) and token = p_token and p_token is not null;
$fn$;

-- ── 저장 슬롯 올리기
create or replace function app_save_slots(p_user text, p_token text, p_slots jsonb)
returns json language plpgsql security definer as $fn$
declare me text;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','인증에 실패했습니다'); end if;
  update accounts set slots = p_slots, updated_at = now() where username_lc = me;
  return json_build_object('ok',true);
end $fn$;

-- ── 저장 슬롯 내려받기
create or replace function app_load_slots(p_user text, p_token text)
returns json language plpgsql security definer as $fn$
declare me text; sl jsonb;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','인증에 실패했습니다'); end if;
  select slots into sl from accounts where username_lc = me;
  return json_build_object('ok',true,'slots',sl);
end $fn$;

-- ── 비밀번호 변경
create or replace function app_change_pw(p_user text, p_token text, p_old text, p_new text)
returns json language plpgsql security definer as $fn$
declare r accounts%rowtype;
begin
  select * into r from accounts where username_lc = lower(trim(p_user)) and token = p_token;
  if not found then return json_build_object('ok',false,'err','인증에 실패했습니다'); end if;
  if r.pass_hash <> crypt(p_old, r.pass_hash) then
    return json_build_object('ok',false,'err','현재 비밀번호가 틀렸습니다');
  end if;
  if length(p_new) < 4 then return json_build_object('ok',false,'err','새 비밀번호는 4자 이상이어야 합니다'); end if;
  update accounts set pass_hash = crypt(p_new, gen_salt('bf')) where username_lc = r.username_lc;
  return json_build_object('ok',true);
end $fn$;

grant execute on function app_signup(text,text,jsonb)      to anon;
grant execute on function app_login(text,text)             to anon;
grant execute on function app_save_slots(text,text,jsonb)  to anon;
grant execute on function app_load_slots(text,text)        to anon;
grant execute on function app_change_pw(text,text,text,text) to anon;
revoke execute on function app_auth(text,text) from anon;
