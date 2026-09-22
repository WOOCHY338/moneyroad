-- 머니로드 — 남은 계정 정리
-- Supabase 대시보드 → SQL Editor 에 붙여넣고 Run 하시면 됩니다.
-- players 행은 지워도 그 사람이 다시 접속하면 새로 만들어집니다.
-- 다만 누적 접속 시간(play_secs)은 0부터 다시 시작합니다.

-- ① 게스트 기록 (익명, 랭킹에는 원래 안 잡힘)
delete from players where is_guest = true;

-- ② shangus 계열 4개
delete from players where username in ('shangus','shangus11','shangus111','shangus1212');

-- 확인
select username, net_worth, play_secs, to_char(last_seen,'MM-DD HH24:MI') last_seen
  from players order by last_seen desc;
