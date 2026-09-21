-- 머니로드 유저 시스템 (친구 / 귓속말 / 송금)
-- Supabase → SQL Editor 에 통째로 붙여넣고 Run 하세요.
--
-- 아이디와 비밀번호는 서버에 저장하지 않습니다. 계정은 지금처럼 브라우저 안에만
-- 있고, 서버에는 "누가 누구에게 무엇을 보냈는지"만 기록됩니다.
-- 사용자 검색은 이미 만들어 둔 players 테이블(랭킹용)을 그대로 씁니다.

create table if not exists friends (
  user_lc    text not null,
  friend_lc  text not null,
  friend_name text not null,
  created_at timestamptz default now(),
  primary key (user_lc, friend_lc)
);

create table if not exists whispers (
  id         bigint generated always as identity primary key,
  from_lc    text not null,
  from_name  text not null,
  to_lc      text not null,
  body       text not null,
  created_at timestamptz default now()
);

create table if not exists transfers (
  id         bigint generated always as identity primary key,
  from_lc    text not null,
  from_name  text not null,
  to_lc      text not null,
  amount     numeric not null,
  claimed    boolean default false,
  created_at timestamptz default now()
);

alter table friends   enable row level security;
alter table whispers  enable row level security;
alter table transfers enable row level security;

create policy "f_read"   on friends   for select using (true);
create policy "f_write"  on friends   for insert with check (true);
create policy "f_del"    on friends   for delete using (true);

create policy "w_read"   on whispers  for select using (true);
create policy "w_write"  on whispers  for insert with check (true);

create policy "t_read"   on transfers for select using (true);
create policy "t_write"  on transfers for insert with check (true);
create policy "t_claim"  on transfers for update using (true) with check (true);

create index if not exists whispers_to_idx   on whispers(to_lc, id desc);
create index if not exists whispers_from_idx on whispers(from_lc, id desc);
create index if not exists transfers_to_idx  on transfers(to_lc, claimed);
