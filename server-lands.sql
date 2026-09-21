-- 머니로드 · 부동산 + 계정 단위 해금
-- Supabase → SQL Editor 에 붙여넣고 Run 하세요. 여러 번 실행해도 안전합니다.

-- ── 1) 계정에 계정 단위 정보(해금 등)를 담을 칸 추가
alter table accounts add column if not exists meta jsonb;

-- 로그인 시 meta 도 함께 내려준다
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
  return json_build_object('ok',true,'username',r.username,'token',tk,'slots',r.slots,'meta',r.meta);
end $fn$;

create or replace function app_save_meta(p_user text, p_token text, p_meta jsonb)
returns json language plpgsql security definer as $fn$
declare me text;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','인증에 실패했습니다'); end if;
  update accounts set meta = p_meta, updated_at = now() where username_lc = me;
  return json_build_object('ok',true);
end $fn$;

create or replace function app_load_meta(p_user text, p_token text)
returns json language plpgsql security definer as $fn$
declare me text; mt jsonb;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','인증에 실패했습니다'); end if;
  select meta into mt from accounts where username_lc = me;
  return json_build_object('ok',true,'meta',mt);
end $fn$;

-- ── 2) 땅
create table if not exists lands (
  id          text primary key,
  name        text not null,
  region      text not null,
  tier        int  not null,
  base_price  numeric not null,
  price       numeric not null,        -- 지금 살 수 있는 값
  owner_lc    text,
  owner_name  text,
  for_sale    boolean default true,    -- 주인이 없거나, 주인이 내놓은 상태
  updated_at  timestamptz default now()
);
alter table lands enable row level security;
-- 정책 없음 = 공개 키로 직접 수정 불가. 아래 함수로만 다룬다.

-- 목록 조회 (누구나)
create or replace function app_lands()
returns table(id text, name text, region text, tier int,
              base_price numeric, price numeric,
              owner_lc text, owner_name text, for_sale boolean)
language sql security definer as $fn$
  select l.id, l.name, l.region, l.tier, l.base_price, l.price,
         l.owner_lc, l.owner_name, l.for_sale
    from lands l order by l.tier, l.base_price desc, l.name;
$fn$;

-- 구매: 소유권을 넘기고, 이전 주인에게는 기존 송금 구조로 대금을 넣어준다
create or replace function app_land_buy(p_user text, p_token text, p_id text)
returns json language plpgsql security definer as $fn$
declare me text; myname text; l lands%rowtype;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','인증에 실패했습니다'); end if;
  select * into l from lands where id = p_id for update;
  if not found then return json_build_object('ok',false,'err','없는 매물입니다'); end if;
  if not l.for_sale then return json_build_object('ok',false,'err','매물로 나와 있지 않습니다'); end if;
  if l.owner_lc = me then return json_build_object('ok',false,'err','이미 내 땅입니다'); end if;

  select username into myname from accounts where username_lc = me;
  if myname is null then return json_build_object('ok',false,'err','계정을 찾을 수 없습니다'); end if;

  if l.owner_lc is not null then                       -- 이전 주인에게 대금 지급
    insert into transfers(from_lc, from_name, to_lc, amount)
      values (me, myname || ' (토지 매각대금)', l.owner_lc, l.price);
  end if;

  update lands
     set owner_lc = me, owner_name = myname,
         for_sale = false, updated_at = now()
   where id = p_id;

  return json_build_object('ok',true,'price',l.price,'name',l.name,'prev',l.owner_name);
end $fn$;

-- 매물로 내놓기 / 거두기
create or replace function app_land_sell(p_user text, p_token text, p_id text, p_price numeric, p_on boolean)
returns json language plpgsql security definer as $fn$
declare me text; l lands%rowtype; np numeric;
begin
  me := app_auth(p_user, p_token);
  if me is null then return json_build_object('ok',false,'err','인증에 실패했습니다'); end if;
  select * into l from lands where id = p_id for update;
  if not found then return json_build_object('ok',false,'err','없는 매물입니다'); end if;
  if l.owner_lc is distinct from me then return json_build_object('ok',false,'err','내 땅이 아닙니다'); end if;

  if p_on then
    np := floor(p_price);
    if np < 1000 then return json_build_object('ok',false,'err','1,000원 이상으로 내놓아야 합니다'); end if;
    if np > 100000000000 then return json_build_object('ok',false,'err','값이 너무 큽니다'); end if;
    update lands set price = np, for_sale = true, updated_at = now() where id = p_id;
  else
    update lands set for_sale = false, updated_at = now() where id = p_id;
  end if;
  return json_build_object('ok',true);
end $fn$;

grant execute on function app_save_meta(text,text,jsonb) to anon;
grant execute on function app_load_meta(text,text)       to anon;
grant execute on function app_lands()                    to anon;
grant execute on function app_land_buy(text,text,text)    to anon;
grant execute on function app_land_sell(text,text,text,numeric,boolean) to anon;

-- ── 3) 초기 필지 60개 (이미 있으면 건너뜀)
insert into lands(id, name, region, tier, base_price, price) values
 ('t1-01','강남역 대로변','서울',1,3000000,3000000),
 ('t1-02','명동 중심가','서울',1,3000000,3000000),
 ('t1-03','여의도 금융가','서울',1,2800000,2800000),
 ('t1-04','성수동 카페거리','서울',1,2600000,2600000),
 ('t2-01','홍대 놀이터 앞','서울',2,800000,800000),
 ('t2-02','판교 테크노밸리','경기',2,900000,900000),
 ('t2-03','해운대 해변로','부산',2,850000,850000),
 ('t2-04','잠실 롯데월드 옆','서울',2,880000,880000),
 ('t2-05','이태원 메인거리','서울',2,760000,760000),
 ('t2-06','송도 국제도시','인천',2,720000,720000),
 ('t2-07','동성로 중심','대구',2,700000,700000),
 ('t2-08','상무지구','광주',2,680000,680000),
 ('t2-09','둔산동 중심','대전',2,660000,660000),
 ('t2-10','제주 애월 해안','제주',2,900000,900000),
 ('t3-01','수원 행궁동','경기',3,200000,200000),
 ('t3-02','일산 라페스타','경기',3,190000,190000),
 ('t3-03','부천 상동','경기',3,185000,185000),
 ('t3-04','안양 평촌','경기',3,180000,180000),
 ('t3-05','용인 수지','경기',3,210000,210000),
 ('t3-06','청주 성안길','충북',3,150000,150000),
 ('t3-07','천안 신부동','충남',3,155000,155000),
 ('t3-08','전주 한옥마을','전북',3,175000,175000),
 ('t3-09','여수 낭만포차','전남',3,170000,170000),
 ('t3-10','창원 상남동','경남',3,165000,165000),
 ('t3-11','포항 영일대','경북',3,150000,150000),
 ('t3-12','강릉 안목해변','강원',3,195000,195000),
 ('t3-13','속초 중앙시장','강원',3,160000,160000),
 ('t3-14','춘천 명동','강원',3,145000,145000),
 ('t3-15','원주 단계동','강원',3,140000,140000),
 ('t3-16','군산 근대거리','전북',3,135000,135000),
 ('t3-17','목포 근대역사관','전남',3,130000,130000),
 ('t3-18','김해 내외동','경남',3,150000,150000),
 ('t3-19','진주 중앙시장','경남',3,140000,140000),
 ('t3-20','서귀포 올레시장','제주',3,200000,200000),
 ('t4-01','파주 헤이리','경기',4,50000,50000),
 ('t4-02','양평 두물머리','경기',4,55000,55000),
 ('t4-03','가평 청평호','경기',4,48000,48000),
 ('t4-04','이천 도자마을','경기',4,46000,46000),
 ('t4-05','안성 팜랜드','경기',4,44000,44000),
 ('t4-06','충주 탄금대','충북',4,42000,42000),
 ('t4-07','제천 청풍호','충북',4,43000,43000),
 ('t4-08','공주 한옥마을','충남',4,45000,45000),
 ('t4-09','부여 궁남지','충남',4,41000,41000),
 ('t4-10','보령 대천해변','충남',4,52000,52000),
 ('t4-11','태안 안면도','충남',4,54000,54000),
 ('t4-12','정읍 내장산','전북',4,40000,40000),
 ('t4-13','남원 광한루','전북',4,41000,41000),
 ('t4-14','순천 갈대밭','전남',4,47000,47000),
 ('t4-15','담양 죽녹원','전남',4,46000,46000),
 ('t4-16','보성 녹차밭','전남',4,45000,45000),
 ('t4-17','경주 황리단길','경북',4,58000,58000),
 ('t4-18','안동 하회마을','경북',4,44000,44000),
 ('t4-19','영덕 강구항','경북',4,42000,42000),
 ('t4-20','통영 동피랑','경남',4,50000,50000),
 ('t4-21','거제 외도','경남',4,49000,49000),
 ('t4-22','남해 독일마을','경남',4,47000,47000),
 ('t4-23','울릉 도동항','경북',4,53000,53000),
 ('t4-24','정선 아우라지','강원',4,40000,40000),
 ('t4-25','평창 대관령','강원',4,51000,51000),
 ('t4-26','삼척 장호항','강원',4,43000,43000)
on conflict (id) do nothing;
