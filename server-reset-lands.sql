-- 머니로드 2.7 — 부동산 전체 재분양
-- ① 땅·건물에 쓴 돈을 전액 환불하고 ② 모든 필지를 초기 상태로 되돌린 뒤
-- ③ 한국시간 9월 22일 오후 2시 30분(= 05:30 UTC)부터 다시 살 수 있게 합니다.

-- ── ① 환불 (땅값 + 건축비 + 증축비 + 신제품 개발비 + 진행 중인 연구비)
with calc as (
  select owner_lc, owner_name,
         base_price
       + case when coalesce(bld_level,0) > 0
              then round(base_price * case bld_type when 'apt'  then 0.60
                                                    when 'shop' then 0.35
                                                    when 'corp' then 1.00
                                                    else 0 end)
              else 0 end
       + case when coalesce(bld_level,0) > 1
              then round(base_price * case bld_type when 'apt'  then 0.60
                                                    when 'shop' then 0.35
                                                    when 'corp' then 1.00
                                                    else 0 end
                         * 0.8 * (bld_level - 1) * bld_level / 2.0)
              else 0 end
       + case when bld_type = 'corp'
              then round(base_price * 0.15 * (coalesce(bld_plv,1) - 1) * coalesce(bld_plv,1) / 2.0)
              else 0 end
       + coalesce(bld_rnd, 0) as refund
    from lands
   where owner_lc is not null
), sums as (
  select owner_lc, max(owner_name) owner_name, sum(refund) total
    from calc group by owner_lc
)
insert into transfers(from_lc, from_name, to_lc, amount)
select '운영자', '운영자 (부동산 재분양 환불)', owner_lc, total from sums;

-- ── ② 모든 필지를 초기 상태로
update lands
   set owner_lc   = null,
       owner_name = null,
       for_sale   = true,
       price      = base_price,
       bld_type   = null,
       bld_level  = 0,
       bld_sector = null,
       bld_stock  = 0,
       bld_emp    = 0,
       bld_rnd    = 0,
       bld_plv    = 1,
       bld_name   = null,
       updated_at = now();

-- ── ③ 직원 계약 종료 (회사가 사라졌으므로)
update employments set status = 'ended' where status in ('pending','active');

-- ── ④ 분양 개시 시각을 서버에서도 막습니다
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
  update lands set owner_lc = me, owner_name = myname, for_sale = false, updated_at = now() where id = p_id;
  return json_build_object('ok',true,'price',l.price,'name',l.name,'prev',l.owner_name);
end $fn$;
grant execute on function app_land_buy(text,text,text) to anon;

-- 확인
select t.to_lc, t.amount from transfers t where t.from_lc = '운영자' order by t.id desc limit 10;
