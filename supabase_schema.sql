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
