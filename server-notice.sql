-- 머니로드 4.2 — 공지를 서버로, 운영자는 square15678 한 사람만

-- ── ① 운영자 판정
-- 운영자는 계정 하나로 고정합니다. 비밀번호를 따로 두지 않고,
-- 그 계정으로 로그인했는지를 서버에서 확인합니다.
create or replace function app_is_admin(p_user text, p_token text)
returns boolean language sql security definer as $fn$
  select app_auth(p_user, p_token) = 'square15678';
$fn$;
grant execute on function app_is_admin(text,text) to anon;

-- ── ② 공지
create table if not exists notices (
  id         int primary key default 1,
  text       text not null default '',
  kind       text not null default 'info',   -- info / warn / event
  on_air     boolean not null default false,
  ver        bigint not null default 0,      -- 바뀔 때마다 올라갑니다 (읽은 공지 판별용)
  by_name    text,
  updated_at timestamptz default now(),
  constraint one_row check (id = 1)
);
alter table notices enable row level security;
-- 정책 없음 = 공개 키로 직접 수정 불가. 아래 함수로만 다룹니다.

insert into notices(id) values (1) on conflict (id) do nothing;

-- 누구나 읽습니다
create or replace function app_notice()
returns json language sql security definer as $fn$
  select json_build_object('text', text, 'kind', kind, 'on', on_air,
                           'ver', ver, 'by', by_name)
    from notices where id = 1;
$fn$;
grant execute on function app_notice() to anon;

-- 운영자만 씁니다
create or replace function app_notice_set(p_user text, p_token text,
                                          p_text text, p_kind text, p_on boolean)
returns json language plpgsql security definer as $fn$
declare me text; nm text;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','로그인이 필요합니다'); end if;
  if me <> 'square15678' then return json_build_object('ok',false,'err','운영자만 쓸 수 있습니다'); end if;
  if length(coalesce(p_text,'')) > 160 then return json_build_object('ok',false,'err','160자를 넘을 수 없습니다'); end if;
  if p_kind not in ('info','warn','event') then return json_build_object('ok',false,'err','알 수 없는 종류입니다'); end if;

  select username into nm from accounts where username_lc = me;
  update notices
     set text = coalesce(p_text,''), kind = p_kind, on_air = coalesce(p_on,false),
         ver = ver + 1, by_name = nm, updated_at = now()
   where id = 1;
  return json_build_object('ok',true,'ver',(select ver from notices where id=1));
end $fn$;
grant execute on function app_notice_set(text,text,text,text,boolean) to anon;

select app_notice() as 현재공지, app_is_admin('square15678','없는토큰') as 토큰없을때;
