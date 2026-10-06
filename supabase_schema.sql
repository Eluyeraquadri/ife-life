-- Ife Life: Supabase schema. Run this once in the Supabase SQL editor.
-- All money logic runs in SECURITY DEFINER functions. Clients cannot write to tables directly.

create table if not exists profiles (
  id uuid primary key,
  username text not null,
  female boolean not null default false,
  cls text not null,
  cash bigint not null default 0,
  assets bigint not null default 0,
  aura int not null default 0,
  cgpa numeric(3,2) not null default 3.5,
  weekly_base bigint not null default 0,
  weekly_key text not null default '',
  save jsonb,
  created_at timestamptz not null default now()
);
create unique index if not exists profiles_username_lower on profiles (lower(username));

create table if not exists ledger_log (
  id bigserial primary key, uid uuid not null, kind text not null, amt bigint not null, at timestamptz not null default now()
);
create index if not exists ledger_log_uid_kind_at on ledger_log (uid, kind, at);

create table if not exists messages (
  id bigserial primary key, from_id uuid not null, to_id uuid not null, body text not null,
  at timestamptz not null default now(), read boolean not null default false
);
create index if not exists messages_pair on messages (from_id, to_id, at);
create index if not exists messages_to on messages (to_id, read);
create table if not exists blocks (blocker uuid not null, blocked uuid not null, primary key (blocker, blocked));
create table if not exists reports (
  id bigserial primary key, reporter uuid not null, reported uuid not null, msg_id bigint, reason text, at timestamptz not null default now()
);
create table if not exists sug_candidates (
  wk text not null, uid uuid not null, policy text not null, pledge text, primary key (wk, uid)
);
create table if not exists sug_votes (wk text not null, voter uuid not null, cand uuid not null, primary key (wk, voter));
create table if not exists sug_results (wk text primary key, winner uuid, policy text not null);

alter table profiles enable row level security;
alter table ledger_log enable row level security;
alter table messages enable row level security;
alter table blocks enable row level security;
alter table reports enable row level security;
alter table sug_candidates enable row level security;
alter table sug_votes enable row level security;
alter table sug_results enable row level security;
-- players may read only their own profile and their own messages; everything else goes through functions
drop policy if exists p_self on profiles; create policy p_self on profiles for select using (id = auth.uid());
drop policy if exists m_own on messages; create policy m_own on messages for select using (from_id = auth.uid() or to_id = auth.uid());
drop policy if exists b_own on blocks; create policy b_own on blocks for select using (blocker = auth.uid());

create or replace function ife_week() returns text language sql stable as $$ select to_char(now(), 'IYYY-"W"IW') $$;

-- ---------- profile ----------
create or replace function create_profile(p_username text, p_female boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); u text := lower(coalesce(p_username, '')); r numeric; c text; cash0 bigint; aura0 int; cg numeric := 3.5;
begin
  if uid is null then raise exception 'not signed in'; end if;
  if exists (select 1 from profiles where id = uid) then
    return (select jsonb_build_object('ok', true, 'cls', cls, 'cash', cash, 'username', username, 'existing', true) from profiles where id = uid);
  end if;
  if u !~ '^[a-z0-9_]{3,16}$' then return jsonb_build_object('ok', false, 'error', 'Use 3 to 16 letters, numbers or underscores.'); end if;
  if u = any (array['admin','sug','moderator','support','ifelife','oau','system','null','undefined','owner','official']) then
    return jsonb_build_object('ok', false, 'error', 'That name is reserved.'); end if;
  if exists (select 1 from profiles where lower(username) = u) then return jsonb_build_object('ok', false, 'error', 'Username taken.'); end if;
  r := random() * 100;
  if r < 8 then c := 'ajebutter'; cash0 := 35000; aura0 := 60;
  elsif r < 25 then c := 'daddys'; cash0 := 14000; aura0 := 25;
  elsif r < 63 then c := 'regular'; cash0 := 4000; aura0 := 0;
  elsif r < 78 then c := 'scholar'; cash0 := 2000; aura0 := 10; cg := 4.2;
  else c := 'lapo'; cash0 := 600; aura0 := 0; end if;
  insert into profiles (id, username, female, cls, cash, aura, cgpa) values (uid, u, coalesce(p_female, false), c, cash0, aura0, cg);
  return jsonb_build_object('ok', true, 'cls', c, 'cash', cash0, 'username', u, 'aura', aura0, 'cgpa', cg);
end $$;

-- ---------- money ----------
-- entries: [{"k":"job","a":1500}, ...]. Earn kinds are capped per call and per hour. Spend kinds can never take cash below zero.
create or replace function apply_ledger(entries jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me_id uuid := auth.uid(); p profiles%rowtype; e jsonb; k text; a bigint; used bigint; capcall bigint; caphour bigint; ok_amt bigint; clipped boolean := false;
        n int := 0; sums jsonb := '{}'::jsonb; sofar bigint;
begin
  if me_id is null then raise exception 'not signed in'; end if;
  select * into p from profiles where id = me_id for update;
  if not found then raise exception 'no profile'; end if;
  if jsonb_typeof(entries) <> 'array' then return jsonb_build_object('ok', false); end if;
  for e in select * from jsonb_array_elements(entries) loop
    n := n + 1; exit when n > 200;
    k := e->>'k'; begin a := (e->>'a')::bigint; exception when others then a := 0; end;
    if a is null or a <= 0 or a > 1000000 then clipped := true; continue; end if;
    if k in ('job','quest','coin','allowance','event','sale','streak','misc') then
      capcall := case k when 'job' then 6000 when 'quest' then 5000 when 'coin' then 2000 when 'allowance' then 10000 when 'event' then 5000 when 'sale' then 100000 when 'streak' then 2000 else 1000 end;
      caphour := case k when 'job' then 30000 when 'quest' then 20000 when 'coin' then 10000 when 'allowance' then 10000 when 'event' then 20000 when 'sale' then 200000 when 'streak' then 4000 else 2000 end;
      select coalesce(sum(amt), 0) into used from ledger_log where uid = p.id and kind = k and at > now() - interval '1 hour';
      sofar := coalesce((sums->>k)::bigint, 0);
      ok_amt := least(a, greatest(0, capcall - sofar), greatest(0, caphour - used - sofar));
      if k = 'sale' then ok_amt := least(ok_amt, (p.assets * 6) / 10); end if;
      if ok_amt < a then clipped := true; end if;
      if ok_amt > 0 then
        p.cash := p.cash + ok_amt; sums := jsonb_set(sums, array[k], to_jsonb(sofar + ok_amt));
        if k = 'sale' then p.assets := greatest(0, p.assets - (ok_amt * 10) / 6); end if;
        insert into ledger_log (uid, kind, amt) values (p.id, k, ok_amt);
      end if;
    elsif k in ('food','rent','furniture','shop','fine','fee','gift') then
      ok_amt := least(a, p.cash); if ok_amt < a then clipped := true; end if;
      if ok_amt > 0 then
        p.cash := p.cash - ok_amt; if k = 'furniture' then p.assets := p.assets + ok_amt; end if;
        insert into ledger_log (uid, kind, amt) values (p.id, k, -ok_amt);
      end if;
    else clipped := true; end if;
  end loop;
  update profiles set cash = p.cash, assets = p.assets where id = p.id;
  return jsonb_build_object('ok', true, 'cash', p.cash, 'assets', p.assets, 'clipped', clipped);
end $$;

create or replace function sync_profile(p_aura int, p_cgpa numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); p profiles%rowtype; mins numeric;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select * into p from profiles where id = uid for update; if not found then return jsonb_build_object('ok', false); end if;
  mins := greatest(1, extract(epoch from (now() - p.created_at)) / 60);
  -- aura can rise by at most 6 points per real minute of account life (plus the class bonus); it can always go down
  update profiles set aura = least(greatest(0, coalesce(p_aura, aura)), 100 + (mins * 6)::int),
    cgpa = least(5, greatest(0, coalesce(p_cgpa, cgpa))) where id = uid;
  if p.weekly_key <> ife_week() then update profiles set weekly_key = ife_week(), weekly_base = p.cash + p.assets where id = uid; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function leaderboard(kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare out jsonb;
begin
  if kind not in ('worth','aura','weekly') then kind := 'worth'; end if;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into out from (
    select username as name, cls, female,
      case kind when 'worth' then cash + assets when 'aura' then aura::bigint else greatest(0, cash + assets - weekly_base) end as value,
      (id = auth.uid()) as me
    from profiles order by 4 desc, created_at limit 25) x;
  return out;
end $$;

create or replace function put_save(p_save jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if length(p_save::text) > 30000 then return jsonb_build_object('ok', false, 'error', 'Save too large'); end if;
  update profiles set save = p_save where id = auth.uid(); return jsonb_build_object('ok', true);
end $$;

-- ---------- chat ----------
create or replace function send_message(p_to text, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); me profiles%rowtype; t profiles%rowtype; b text := btrim(coalesce(p_body, '')); n int; mid bigint;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select * into me from profiles where id = uid; if not found then return jsonb_build_object('ok', false, 'error', 'Create a profile first.'); end if;
  select * into t from profiles where lower(username) = lower(coalesce(p_to, '')); if not found then return jsonb_build_object('ok', false, 'error', 'No such username.'); end if;
  if t.id = uid then return jsonb_build_object('ok', false, 'error', 'You cannot message yourself.'); end if;
  if now() - me.created_at < interval '10 minutes' then return jsonb_build_object('ok', false, 'error', 'New accounts can chat after 10 minutes.'); end if;
  if length(b) < 1 or length(b) > 280 then return jsonb_build_object('ok', false, 'error', 'Messages are 1 to 280 characters.'); end if;
  if b ~* '(https?://|www\.|[a-z0-9-]+\.(com|net|org|ng|io|me|co|xyz|link)\b)' then return jsonb_build_object('ok', false, 'error', 'Links are not allowed.'); end if;
  if b ~* '\m(fuck|bitch|nigga|rape|whore|slut|cunt|pussy)\M' then return jsonb_build_object('ok', false, 'error', 'Watch your language.'); end if;
  if exists (select 1 from blocks where (blocker = t.id and blocked = uid) or (blocker = uid and blocked = t.id)) then
    return jsonb_build_object('ok', false, 'error', 'You cannot message this user.'); end if;
  select count(*) into n from messages where from_id = uid and at > now() - interval '1 minute';
  if n >= 10 then return jsonb_build_object('ok', false, 'error', 'Slow down. Try again in a minute.'); end if;
  insert into messages (from_id, to_id, body) values (uid, t.id, b) returning id into mid;
  return jsonb_build_object('ok', true, 'id', mid);
end $$;

create or replace function get_threads() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); out jsonb;
begin
  select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb) into out from (
    select pr.username as name, pr.cls, last.body, last.at,
      (select count(*) from messages m2 where m2.from_id = pr.id and m2.to_id = uid and not m2.read) as unread
    from (select distinct on (case when from_id = uid then to_id else from_id end) case when from_id = uid then to_id else from_id end as other, body, at
          from messages where from_id = uid or to_id = uid order by case when from_id = uid then to_id else from_id end, at desc) last
    join profiles pr on pr.id = last.other
    where not exists (select 1 from blocks b where b.blocker = uid and b.blocked = pr.id)) x;
  return out;
end $$;

create or replace function get_thread(p_with text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); o uuid; out jsonb;
begin
  select id into o from profiles where lower(username) = lower(coalesce(p_with, '')); if o is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'mine', from_id = uid, 'body', body, 'at', at) order by at), '[]'::jsonb) into out
  from (select * from messages where (from_id = uid and to_id = o) or (from_id = o and to_id = uid) order by at desc limit 100) z;
  return out;
end $$;

create or replace function mark_read(p_with text) returns void
language sql security definer set search_path = public as $$
  update messages set read = true where to_id = auth.uid() and from_id = (select id from profiles where lower(username) = lower(coalesce(p_with, '')));
$$;

create or replace function block_user(p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o uuid;
begin
  select id into o from profiles where lower(username) = lower(coalesce(p_name, '')); if o is null or o = auth.uid() then return jsonb_build_object('ok', false); end if;
  insert into blocks values (auth.uid(), o) on conflict do nothing; return jsonb_build_object('ok', true);
end $$;
create or replace function unblock_user(p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin delete from blocks where blocker = auth.uid() and blocked = (select id from profiles where lower(username) = lower(coalesce(p_name, ''))); return jsonb_build_object('ok', true); end $$;

create or replace function report_user(p_name text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o uuid;
begin
  select id into o from profiles where lower(username) = lower(coalesce(p_name, '')); if o is null then return jsonb_build_object('ok', false); end if;
  insert into reports (reporter, reported, reason, msg_id) values (auth.uid(), o, left(coalesce(p_reason, ''), 300), (select max(id) from messages where from_id = o and to_id = auth.uid()));
  return jsonb_build_object('ok', true);
end $$;

-- ---------- SUG election (weekly, on real ISO weeks; tallied lazily) ----------
create or replace function sug_tally() returns void
language plpgsql security definer set search_path = public as $$
declare w record; win uuid; pol text;
begin
  for w in select distinct wk from sug_candidates where wk < ife_week() and wk not in (select wk from sug_results) loop
    select c.uid, c.policy into win, pol from sug_candidates c left join sug_votes v on v.wk = c.wk and v.cand = c.uid
      where c.wk = w.wk group by c.uid, c.policy order by count(v.voter) desc, c.uid limit 1;
    insert into sug_results (wk, winner, policy) values (w.wk, win, coalesce(pol, 'none')) on conflict do nothing;
  end loop;
end $$;

create or replace function sug_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me_id uuid := auth.uid(); cur text := ife_week(); active text := 'none'; wname text; cands jsonb; myvote uuid;
begin
  perform sug_tally();
  select policy into active from sug_results where wk < cur order by wk desc limit 1; active := coalesce(active, 'none');
  select pr.username into wname from sug_results r join profiles pr on pr.id = r.winner where r.wk < cur order by r.wk desc limit 1;
  select cand into myvote from sug_votes where wk = cur and voter = me_id;
  select coalesce(jsonb_agg(jsonb_build_object('id', c.uid, 'name', pr.username, 'policy', c.policy, 'pledge', c.pledge,
         'votes', (select count(*) from sug_votes v where v.wk = cur and v.cand = c.uid), 'me', c.uid = me_id) order by pr.username), '[]'::jsonb) into cands
    from sug_candidates c join profiles pr on pr.id = c.uid where c.wk = cur;
  return jsonb_build_object('week', cur, 'policy', active, 'sug', wname, 'candidates', cands, 'myvote', myvote);
end $$;

create or replace function run_for_sug(p_policy text, p_pledge text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me_id uuid := auth.uid(); p profiles%rowtype; cur text := ife_week();
begin
  select * into p from profiles where id = me_id for update; if not found then return jsonb_build_object('ok', false, 'error', 'Create a profile first.'); end if;
  if p_policy not in ('rent_cut','food_cut','shuttle','coin_boost') then return jsonb_build_object('ok', false, 'error', 'Pick a policy.'); end if;
  if exists (select 1 from sug_candidates where wk = cur and uid = p.id) then return jsonb_build_object('ok', false, 'error', 'You are already running this week.'); end if;
  if p.cash < 50000 then return jsonb_build_object('ok', false, 'error', 'Campaign fee is ₦50,000.'); end if;
  update profiles set cash = cash - 50000 where id = p.id; insert into ledger_log (uid, kind, amt) values (p.id, 'fee', -50000);
  insert into sug_candidates values (cur, p.id, p_policy, left(coalesce(p_pledge, ''), 120));
  return jsonb_build_object('ok', true, 'cash', p.cash - 50000);
end $$;

create or replace function vote_sug(p_cand uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cur text := ife_week();
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from sug_candidates where wk = cur and uid = p_cand) then return jsonb_build_object('ok', false, 'error', 'Not a candidate.'); end if;
  if exists (select 1 from sug_votes where wk = cur and voter = auth.uid()) then return jsonb_build_object('ok', false, 'error', 'You already voted this week.'); end if;
  insert into sug_votes values (cur, auth.uid(), p_cand); return jsonb_build_object('ok', true);
end $$;

-- ---------- level, live presence, hostel room claims ----------
alter table profiles add column if not exists level int not null default 100;
create table if not exists presence (
  id uuid primary key references profiles(id) on delete cascade,
  username text not null, level int not null default 100, female boolean not null default false,
  x real not null default 0, z real not null default 0, rot real not null default 0,
  act text not null default '', room text, say text not null default '', say_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists presence_updated on presence (updated_at);
create table if not exists room_claims (
  id uuid primary key references profiles(id) on delete cascade,
  hall text not null, block text not null, floor int not null, num int not null, bed int not null,
  username text not null, level int not null default 100, at timestamptz not null default now(),
  unique (hall, block, floor, num, bed)
);
alter table presence enable row level security;
alter table room_claims enable row level security;

create or replace function set_level(p_level int) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_level not in (100, 200, 300, 400, 500) then return jsonb_build_object('ok', false, 'error', 'Bad level.'); end if;
  update profiles set level = p_level where id = auth.uid();
  return jsonb_build_object('ok', true);
end $$;

-- one call per player every ~1.4 s: writes my position, returns the people near me (or in my room)
create or replace function presence_tick(p_x real, p_z real, p_rot real, p_act text, p_room text, p_level int, p_say text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); me profiles%rowtype; sy text := left(btrim(coalesce(p_say, '')), 90); old presence%rowtype; act text := left(coalesce(p_act, ''), 20);
begin
  if uid is null then raise exception 'not signed in'; end if;
  select * into me from profiles where id = uid; if not found then return '[]'::jsonb; end if;
  if abs(p_x) > 30000 or abs(p_z) > 30000 or p_x <> p_x or p_z <> p_z then return '[]'::jsonb; end if;
  if sy ~* '(https?://|www\.|[a-z0-9-]+\.(com|net|org|ng|io|me|co|xyz|link)\b)' or sy ~* '\m(fuck|bitch|nigga|rape|whore|slut|cunt|pussy)\M' then sy := ''; end if;
  if act !~ '^(e:[a-z]{2,12})?$' then act := ''; end if;
  select * into old from presence where id = uid;
  insert into presence (id, username, level, female, x, z, rot, act, room, say, say_at, updated_at)
  values (uid, me.username, case when p_level in (100,200,300,400,500) then p_level else me.level end, me.female, p_x, p_z, coalesce(p_rot, 0), act, left(p_room, 40), sy,
          case when sy <> '' then now() end, now())
  on conflict (id) do update set level = excluded.level, x = excluded.x, z = excluded.z, rot = excluded.rot, act = excluded.act, room = excluded.room,
    say = case when excluded.say <> '' then excluded.say else presence.say end,
    say_at = case when excluded.say <> '' and excluded.say is distinct from presence.say then now() else presence.say_at end,
    updated_at = now();
  delete from presence where updated_at < now() - interval '2 minutes';
  return coalesce((select jsonb_agg(jsonb_build_object('u', q.username, 'lv', q.level, 'f', q.female, 'x', q.x, 'z', q.z, 'r', q.rot, 'a', q.act, 'rm', q.room,
      'say', case when q.say_at > now() - interval '7 seconds' then q.say else '' end))
    from (select * from presence o where o.id <> uid and o.updated_at > now() - interval '8 seconds'
      and ((p_room is null and o.room is null and (o.x - p_x) ^ 2 + (o.z - p_z) ^ 2 < 160 ^ 2) or (p_room is not null and o.room = left(p_room, 40)))
      and not exists (select 1 from blocks b where (b.blocker = o.id and b.blocked = uid) or (b.blocker = uid and b.blocked = o.id))
      order by (o.x - p_x) ^ 2 + (o.z - p_z) ^ 2 limit 30) q), '[]'::jsonb);
end $$;

-- hostel rooms: each bed belongs to one real player. A player holds one bed.
create or replace function claim_room(p_hall text, p_block text, p_floor int, p_num int, p_bed int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); me profiles%rowtype;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select * into me from profiles where id = uid; if not found then return jsonb_build_object('ok', false, 'error', 'Create a profile first.'); end if;
  if p_hall !~ '^[a-z_]{2,20}$' or p_block !~ '^[A-Za-z0-9]{1,3}$' or p_floor not between 0 and 12 or p_num not between 1 and 99 or p_bed not between 1 and 6 then
    return jsonb_build_object('ok', false, 'error', 'Bad room.'); end if;
  delete from room_claims where id = uid;
  begin
    insert into room_claims (id, hall, block, floor, num, bed, username, level) values (uid, p_hall, p_block, p_floor, p_num, p_bed, me.username, me.level);
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'That bed is taken.');
  end;
  return jsonb_build_object('ok', true);
end $$;

create or replace function release_room() returns jsonb
language plpgsql security definer set search_path = public as $$
begin if auth.uid() is null then raise exception 'not signed in'; end if; delete from room_claims where id = auth.uid(); return jsonb_build_object('ok', true); end $$;

create or replace function room_occupants(p_hall text, p_block text, p_floor int) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('n', num, 'bed', bed, 'u', username, 'lv', level, 'me', id = auth.uid()))
    from room_claims where hall = p_hall and block = p_block and floor = p_floor), '[]'::jsonb);
end $$;

revoke all on all tables in schema public from anon, authenticated;
grant execute on function create_profile(text, boolean), apply_ledger(jsonb), sync_profile(int, numeric), put_save(jsonb), leaderboard(text), send_message(text, text),
  get_threads(), get_thread(text), mark_read(text), block_user(text), unblock_user(text), report_user(text, text), sug_state(), run_for_sug(text, text), vote_sug(uuid)
  to authenticated;
grant execute on function set_level(int), presence_tick(real, real, real, text, text, int, text), claim_room(text, text, int, int, int), release_room(), room_occupants(text, text, int) to authenticated;
grant select on profiles, messages, blocks to authenticated;

-- =====================================================================================
-- MONEY TRANSFERS, ITEM TRADES, HOUSE VISITS, ONLINE LIST  (run the whole file again; it is safe)
-- Only players with a CONFIRMED EMAIL can send or receive money and trade. Daily send limit: 5,000,000 (rolling 24 hours).
-- =====================================================================================
create or replace function is_email_user(u uuid) returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (select 1 from auth.users x where x.id = u and x.email is not null and x.email_confirmed_at is not null)
$$;

create table if not exists transfers (
  id bigserial primary key, from_id uuid not null, to_id uuid not null, from_name text not null, to_name text not null,
  amount bigint not null check (amount > 0), kind text not null default 'send', note text not null default '',
  at timestamptz not null default now(), seen boolean not null default false
);
create index if not exists transfers_from_at on transfers (from_id, at);
create index if not exists transfers_to_seen on transfers (to_id, seen);
create table if not exists offers (
  id bigserial primary key, from_id uuid not null, to_id uuid not null, from_name text not null, to_name text not null,
  item text not null, qty int not null, price bigint not null, status text not null default 'open',
  delivered boolean not null default false, returned boolean not null default false, at timestamptz not null default now()
);
create index if not exists offers_to on offers (to_id, status);
create index if not exists offers_from on offers (from_id, status);
create table if not exists visits (
  id bigserial primary key, from_id uuid not null, to_id uuid not null, from_name text not null, to_name text not null,
  status text not null default 'pending', at timestamptz not null default now()
);
create index if not exists visits_to on visits (to_id, status, at);
create index if not exists visits_from on visits (from_id, at);
alter table transfers enable row level security;
alter table offers enable row level security;
alter table visits enable row level security;

create or replace function clean_note(t text) returns text language sql immutable as $$
  select case when t ~* '(https?://|www\.|[a-z0-9-]+\.(com|net|org|ng|io|me|co|xyz|link)\b)' or t ~* '\m(fuck|bitch|nigga|rape|whore|slut|cunt|pussy)\M' then '' else t end
$$;

create or replace function send_money(p_to text, p_amount bigint, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); a profiles%rowtype; b profiles%rowtype; amt bigint := p_amount; used bigint; nt text := clean_note(left(btrim(coalesce(p_note, '')), 40)); n int;
        lim constant bigint := 5000000;
begin
  if me is null then raise exception 'not signed in'; end if;
  if not is_email_user(me) then return jsonb_build_object('ok', false, 'error', 'Only accounts with a confirmed email can send money. Save your account with an email first (Account tab) and confirm it.'); end if;
  select * into b from profiles where lower(username) = lower(btrim(coalesce(p_to, '')));
  if not found then return jsonb_build_object('ok', false, 'error', 'No player with that username.'); end if;
  if b.id = me then return jsonb_build_object('ok', false, 'error', 'You cannot send money to yourself.'); end if;
  if not is_email_user(b.id) then return jsonb_build_object('ok', false, 'error', 'That player has no confirmed email yet, so they cannot receive money.'); end if;
  if amt is null or amt < 1 or amt > lim then return jsonb_build_object('ok', false, 'error', 'Amount must be from 1 to 5,000,000.'); end if;
  if exists (select 1 from blocks where (blocker = b.id and blocked = me) or (blocker = me and blocked = b.id)) then
    return jsonb_build_object('ok', false, 'error', 'You cannot send money to this player.'); end if;
  select count(*) into n from transfers where from_id = me and at > now() - interval '1 hour';
  if n >= 30 then return jsonb_build_object('ok', false, 'error', 'Too many transfers this hour. Try later.'); end if;
  perform 1 from profiles where id in (me, b.id) order by id for update;
  select * into a from profiles where id = me;
  select coalesce(sum(amount), 0) into used from transfers where from_id = me and kind in ('send', 'trade') and at > now() - interval '24 hours';
  if used + amt > lim then return jsonb_build_object('ok', false, 'error', 'Daily limit is 5,000,000. You can still send ' || greatest(0, lim - used) || ' today.'); end if;
  if a.cash < amt then return jsonb_build_object('ok', false, 'error', 'You do not have that much cash.'); end if;
  update profiles set cash = cash - amt where id = me; update profiles set cash = cash + amt where id = b.id;
  insert into transfers (from_id, to_id, from_name, to_name, amount, kind, note) values (me, b.id, a.username, b.username, amt, 'send', nt);
  return jsonb_build_object('ok', true, 'cash', a.cash - amt, 'left', lim - used - amt, 'to', b.username);
end $$;

-- ---------- item offers: the seller's game removes the item first (held in escrow by the offer), the buyer pays on accept ----------
create or replace function make_offer(p_to text, p_item text, p_qty int, p_price bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); a profiles%rowtype; b profiles%rowtype; n int; oid bigint;
begin
  if me is null then raise exception 'not signed in'; end if;
  if not is_email_user(me) then return jsonb_build_object('ok', false, 'error', 'Only accounts with a confirmed email can trade.'); end if;
  select * into a from profiles where id = me; select * into b from profiles where lower(username) = lower(btrim(coalesce(p_to, '')));
  if not found then return jsonb_build_object('ok', false, 'error', 'No player with that username.'); end if;
  if b.id = me then return jsonb_build_object('ok', false, 'error', 'You cannot trade with yourself.'); end if;
  if not is_email_user(b.id) then return jsonb_build_object('ok', false, 'error', 'That player has no confirmed email, so they cannot trade.'); end if;
  if p_item is null or p_item !~ '^[a-z_]{2,24}$' or p_qty is null or p_qty < 1 or p_qty > 20 or p_price is null or p_price < 0 or p_price > 5000000 then
    return jsonb_build_object('ok', false, 'error', 'Bad offer.'); end if;
  if exists (select 1 from blocks where (blocker = b.id and blocked = me) or (blocker = me and blocked = b.id)) then
    return jsonb_build_object('ok', false, 'error', 'You cannot trade with this player.'); end if;
  update offers set status = 'expired' where status = 'open' and at < now() - interval '24 hours';
  select count(*) into n from offers where from_id = me and status = 'open';
  if n >= 10 then return jsonb_build_object('ok', false, 'error', 'You already have 10 open offers.'); end if;
  insert into offers (from_id, to_id, from_name, to_name, item, qty, price) values (me, b.id, a.username, b.username, p_item, p_qty, p_price) returning id into oid;
  return jsonb_build_object('ok', true, 'id', oid);
end $$;

create or replace function answer_offer(p_id bigint, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o offers%rowtype; a profiles%rowtype; used bigint; lim constant bigint := 5000000;
begin
  if me is null then raise exception 'not signed in'; end if;
  select * into o from offers where id = p_id for update;
  if not found or o.to_id <> me then return jsonb_build_object('ok', false, 'error', 'Offer not found.'); end if;
  if o.status = 'open' and o.at < now() - interval '24 hours' then update offers set status = 'expired' where id = o.id; return jsonb_build_object('ok', false, 'error', 'That offer expired.'); end if;
  if o.status <> 'open' then return jsonb_build_object('ok', false, 'error', 'That offer is no longer open.'); end if;
  if not p_accept then update offers set status = 'declined' where id = o.id; return jsonb_build_object('ok', true, 'declined', true); end if;
  if not is_email_user(me) then return jsonb_build_object('ok', false, 'error', 'Only accounts with a confirmed email can trade.'); end if;
  perform 1 from profiles where id in (me, o.from_id) order by id for update;
  select * into a from profiles where id = me;
  select coalesce(sum(amount), 0) into used from transfers where from_id = me and kind in ('send', 'trade') and at > now() - interval '24 hours';
  if used + o.price > lim then return jsonb_build_object('ok', false, 'error', 'This would pass your daily limit of 5,000,000.'); end if;
  if a.cash < o.price then return jsonb_build_object('ok', false, 'error', 'You do not have enough cash.'); end if;
  if o.price > 0 then
    update profiles set cash = cash - o.price where id = me; update profiles set cash = cash + o.price where id = o.from_id;
    insert into transfers (from_id, to_id, from_name, to_name, amount, kind, note) values (me, o.from_id, a.username, o.from_name, o.price, 'trade', left(o.qty || ' x ' || o.item, 40));
  end if;
  update offers set status = 'accepted' where id = o.id;
  return jsonb_build_object('ok', true, 'cash', a.cash - o.price, 'id', o.id);
end $$;

create or replace function cancel_offer(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  update offers set status = 'cancelled' where id = p_id and from_id = auth.uid() and status = 'open';
  return jsonb_build_object('ok', found);
end $$;

-- the buyer collects a paid item, or the seller collects the item back from a declined, cancelled or expired offer. Once only.
create or replace function claim_offer(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o offers%rowtype;
begin
  if me is null then raise exception 'not signed in'; end if;
  select * into o from offers where id = p_id for update; if not found then return jsonb_build_object('ok', false); end if;
  if o.status = 'open' and o.at < now() - interval '24 hours' then update offers set status = 'expired' where id = o.id; o.status := 'expired'; end if;
  if o.to_id = me and o.status = 'accepted' and not o.delivered then
    update offers set delivered = true where id = o.id; return jsonb_build_object('ok', true, 'item', o.item, 'qty', o.qty, 'who', o.from_name, 'back', false);
  elsif o.from_id = me and o.status in ('declined', 'cancelled', 'expired') and not o.returned then
    update offers set returned = true where id = o.id; return jsonb_build_object('ok', true, 'item', o.item, 'qty', o.qty, 'who', o.to_name, 'back', true);
  end if;
  return jsonb_build_object('ok', false);
end $$;

-- ---------- house visits ----------
create or replace function request_visit(p_to text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); a profiles%rowtype; b profiles%rowtype; n int; vid bigint;
begin
  if me is null then raise exception 'not signed in'; end if;
  select * into a from profiles where id = me; select * into b from profiles where lower(username) = lower(btrim(coalesce(p_to, '')));
  if not found then return jsonb_build_object('ok', false, 'error', 'No player with that username.'); end if;
  if b.id = me then return jsonb_build_object('ok', false, 'error', 'That is your own room.'); end if;
  if exists (select 1 from blocks where (blocker = b.id and blocked = me) or (blocker = me and blocked = b.id)) then
    return jsonb_build_object('ok', false, 'error', 'You cannot visit this player.'); end if;
  if not exists (select 1 from presence where id = b.id and updated_at > now() - interval '30 seconds') then
    return jsonb_build_object('ok', false, 'error', b.username || ' is not online right now.'); end if;
  select count(*) into n from visits where from_id = me and at > now() - interval '1 hour';
  if n >= 12 then return jsonb_build_object('ok', false, 'error', 'Too many knocks this hour.'); end if;
  if exists (select 1 from visits where from_id = me and to_id = b.id and status = 'pending' and at > now() - interval '2 minutes') then
    return jsonb_build_object('ok', false, 'error', 'You already knocked. Wait for an answer.'); end if;
  insert into visits (from_id, to_id, from_name, to_name) values (me, b.id, a.username, b.username) returning id into vid;
  return jsonb_build_object('ok', true, 'id', vid);
end $$;

create or replace function answer_visit(p_id bigint, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  update visits set status = case when p_accept then 'accepted' else 'declined' end
    where id = p_id and to_id = auth.uid() and status = 'pending' and at > now() - interval '3 minutes';
  return jsonb_build_object('ok', found);
end $$;

-- the host's room, only for a visitor whose knock was accepted in the last hour
create or replace function peek_room(p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); b profiles%rowtype;
begin
  if me is null then raise exception 'not signed in'; end if;
  select * into b from profiles where lower(username) = lower(btrim(coalesce(p_name, ''))); if not found then return jsonb_build_object('ok', false); end if;
  if not exists (select 1 from visits where from_id = me and to_id = b.id and status = 'accepted' and at > now() - interval '60 minutes') then
    return jsonb_build_object('ok', false, 'error', 'No invitation.'); end if;
  if b.save is null then return jsonb_build_object('ok', false, 'error', 'Their room is not ready yet.'); end if;
  return jsonb_build_object('ok', true, 'name', b.username, 'level', b.level, 'home', b.save->'home', 'placed', coalesce(b.save->'placed', '[]'::jsonb), 'inv', coalesce(b.save->'inv', '{}'::jsonb));
end $$;

-- ---------- who is online (everyone sees everyone's username) ----------
create or replace function online_players() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('u', q.username, 'lv', q.level, 'x', q.x, 'z', q.z, 'in', q.room is not null, 'em', is_email_user(q.id)))
    from (select * from presence p where p.id <> me and p.updated_at > now() - interval '30 seconds'
      and not exists (select 1 from blocks b where (b.blocker = p.id and b.blocked = me) or (b.blocker = me and b.blocked = p.id))
      order by p.username limit 150) q), '[]'::jsonb);
end $$;

-- ---------- one cheap call the game makes every few seconds ----------
create or replace function social_poll() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cash_now bigint; tin jsonb; oin jsonb; oret jsonb; vin jsonb; vout jsonb; used bigint;
begin
  if me is null then raise exception 'not signed in'; end if;
  select cash into cash_now from profiles where id = me; if not found then return jsonb_build_object('ok', false); end if;
  with s as (update transfers set seen = true where to_id = me and not seen returning from_name, amount, kind, note)
    select coalesce(jsonb_agg(jsonb_build_object('from', from_name, 'amt', amount, 'kind', kind, 'note', note)), '[]'::jsonb) into tin from s;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'from', from_name, 'item', item, 'qty', qty, 'price', price, 'at', extract(epoch from at))), '[]'::jsonb) into oin
    from offers where to_id = me and status = 'open' and at > now() - interval '24 hours';
  select coalesce(jsonb_agg(id), '[]'::jsonb) into oret from offers
    where (to_id = me and status = 'accepted' and not delivered) or (from_id = me and status in ('declined', 'cancelled', 'expired') and not returned);
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'from', from_name)), '[]'::jsonb) into vin from visits where to_id = me and status = 'pending' and at > now() - interval '3 minutes';
  select jsonb_build_object('id', id, 'to', to_name, 'status', case when status = 'pending' and at < now() - interval '3 minutes' then 'expired' else status end) into vout
    from visits where from_id = me and at > now() - interval '5 minutes' order by id desc limit 1;
  select coalesce(sum(amount), 0) into used from transfers where from_id = me and kind in ('send', 'trade') and at > now() - interval '24 hours';
  return jsonb_build_object('ok', true, 'cash', cash_now, 'em', is_email_user(me), 'left', greatest(0, 5000000 - used), 'tin', tin, 'oin', oin, 'oret', oret, 'vin', vin, 'vout', vout);
end $$;

create or replace function transfer_log() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('out', t.from_id = me, 'who', case when t.from_id = me then t.to_name else t.from_name end, 'amt', t.amount, 'kind', t.kind, 'note', t.note, 'at', extract(epoch from t.at)) order by t.id desc)
    from (select * from transfers where from_id = me or to_id = me order by id desc limit 15) t), '[]'::jsonb);
end $$;

revoke all on all tables in schema public from anon, authenticated;
grant select on profiles, messages, blocks to authenticated;
grant execute on function send_money(text, bigint, text), make_offer(text, text, int, bigint), answer_offer(bigint, boolean), cancel_offer(bigint), claim_offer(bigint),
  request_visit(text), answer_visit(bigint, boolean), peek_room(text), online_players(), social_poll(), transfer_log() to authenticated;
