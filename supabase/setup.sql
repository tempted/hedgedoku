-- 고슴도쿠 리더보드 설정
-- Supabase 대시보드 → SQL Editor → New query 에 이 파일 전체를 붙여 넣고 Run 하세요.
-- 여러 번 실행해도 안전해요.
--
-- 구조
--   players      : 브라우저마다 만든 플레이어 ID, 비밀값의 해시, 닉네임, 프로필 이모지
--   scores       : 플레이어 × 난이도별 최고 기록 하나
--   leaderboard  : 누구나 읽을 수 있는 공개 뷰 (비밀값 해시는 노출하지 않음)
--   submit_score / set_nickname : 기록·닉네임은 이 함수로만 쓸 수 있음 (비밀값 확인)
--                                실제 검사·저장은 private 스키마 함수가 맡음

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.players (
  id          uuid primary key,
  secret_hash text not null,
  nickname    text not null check (char_length(nickname) between 1 and 12),
  avatar      text,
  created_at  timestamptz not null default now()
);
alter table public.players add column if not exists avatar text;
alter table public.players drop constraint if exists players_avatar_check;
alter table public.players add constraint players_avatar_check
  check (avatar is null or avatar in ('🦔','🐰','🐻','🐼','🦊','🐸','🐧','🐹','🐨','🦉','🐢','🐙'));

create table if not exists public.scores (
  player_id  uuid not null references public.players(id) on delete cascade,
  diff       text not null check (diff in ('easy', 'normal', 'hard', 'expert')),
  levels     integer not null check (levels between 1 and 100000),
  time_ms    bigint not null check (time_ms >= 0),
  updated_at timestamptz not null default now(),
  primary key (player_id, diff)
);
create index if not exists scores_rank_idx on public.scores (diff, levels desc, time_ms asc);

-- 테이블은 직접 쓸 수 없게 잠그고, 순위표에 필요한 칸만 읽을 수 있게 해요.
-- (players.secret_hash 는 읽기 권한을 주지 않아요.)
alter table public.players enable row level security;
alter table public.scores  enable row level security;
revoke all on public.players, public.scores from anon, authenticated;
grant select (id, nickname, avatar) on public.players to anon, authenticated;
grant select (player_id, diff, levels, time_ms, updated_at) on public.scores to anon, authenticated;
drop policy if exists "leaderboard read" on public.players;
create policy "leaderboard read" on public.players for select to anon, authenticated using (true);
drop policy if exists "leaderboard read" on public.scores;
create policy "leaderboard read" on public.scores for select to anon, authenticated using (true);

-- 공개 리더보드 뷰: 조회하는 사람 권한(security_invoker)으로 실행돼요.
create or replace view public.leaderboard with (security_invoker = true) as
  select s.player_id, p.nickname, s.diff, s.levels, s.time_ms, s.updated_at, p.avatar
  from public.scores s
  join public.players p on p.id = s.player_id;
revoke all on public.leaderboard from anon, authenticated;
grant select on public.leaderboard to anon, authenticated;

-- 쓰기 함수 구조
--   실제 검사·저장은 API로 공개되지 않는 private 스키마의 함수(security definer)가 맡고,
--   public 스키마에는 그 함수를 불러주기만 하는 얇은 창구(security invoker)만 둬요.
--   (Security Advisor의 "Public Can Execute SECURITY DEFINER Function" 경고가 나지 않는 구조예요.)
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to anon, authenticated;

-- 출처 확인: 허용 목록의 주소(내 게임 페이지)에서 온 요청만 저장해요. ★ 아래 주소를 내 GitHub Pages 주소로 바꾸세요.
create table if not exists private.allowed_origins (
  origin text primary key
);
alter table private.allowed_origins enable row level security;  -- 정책 없음: API로는 아무도 못 읽고 못 써요
revoke all on private.allowed_origins from public, anon, authenticated;

insert into private.allowed_origins (origin) values
  ('https://<GitHub아이디>.github.io')   -- ← 여기를 바꾸세요
on conflict do nothing;

-- 요청의 Origin 헤더가 허용 목록에 없으면 거부해요.
-- (SQL Editor처럼 API를 거치지 않는 관리자 실행에는 헤더가 없어서 검사하지 않아요.)
create or replace function private.check_origin()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_headers text := current_setting('request.headers', true);
  v_origin text;
begin
  if v_headers is null or v_headers = '' then
    return;
  end if;
  v_origin := lower(rtrim(coalesce(v_headers::json ->> 'origin', ''), '/'));
  if v_origin ~ '^http://(localhost|127\.0\.0\.1)(:[0-9]+)?$' then
    return;
  end if;
  if v_origin = '' or not exists (select 1 from private.allowed_origins a where lower(a.origin) = v_origin) then
    raise exception 'bad_origin';
  end if;
end;
$$;
revoke all on function private.check_origin() from public, anon, authenticated;

-- 공통 검증: 비밀값 확인, 닉네임 검사, 처음이면 플레이어 등록
create or replace function private.check_player(p_player uuid, p_secret text, p_nickname text, p_create boolean)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_nick text := btrim(coalesce(p_nickname, ''));
  v_existing public.players%rowtype;
begin
  perform private.check_origin();
  if p_player is null or p_secret is null or p_secret !~ '^[0-9a-f]{64}$' then
    raise exception 'bad_secret';
  end if;
  if char_length(v_nick) < 1 or char_length(v_nick) > 12 or v_nick ~ '[[:cntrl:]]' then
    raise exception 'bad_nickname';
  end if;
  v_hash := encode(digest(p_secret, 'sha256'), 'hex');

  select * into v_existing from public.players where id = p_player;
  if not found then
    if p_create then
      insert into public.players (id, secret_hash, nickname) values (p_player, v_hash, v_nick);
    end if;
  elsif v_existing.secret_hash <> v_hash then
    raise exception 'bad_secret';
  else
    update public.players set nickname = v_nick where id = p_player and nickname <> v_nick;
  end if;
  return v_nick;
end;
$$;
revoke all on function private.check_player(uuid, text, text, boolean) from public, anon, authenticated;

-- 기록 등록: 그 난이도의 개인 최고 기록보다 좋을 때만 바뀌어요.
create or replace function private.submit_score(
  p_player uuid, p_secret text, p_nickname text, p_diff text, p_levels integer, p_time_ms bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_prev public.scores%rowtype;
begin
  if p_diff is null or p_diff not in ('easy', 'normal', 'hard', 'expert') then
    raise exception 'bad_diff';
  end if;
  -- 한 레벨을 1초 안에 푸는 건 불가능하다고 보고 걸러요.
  if p_levels is null or p_time_ms is null or p_levels < 1 or p_levels > 100000
     or p_time_ms < p_levels * 1000::bigint or p_time_ms > 31536000000 then
    raise exception 'bad_score';
  end if;

  perform private.check_player(p_player, p_secret, p_nickname, true);

  select * into v_prev from public.scores where player_id = p_player and diff = p_diff for update;
  if found and not (p_levels > v_prev.levels or (p_levels = v_prev.levels and p_time_ms < v_prev.time_ms)) then
    return jsonb_build_object('status', 'not_better', 'levels', v_prev.levels, 'time_ms', v_prev.time_ms);
  end if;

  insert into public.scores (player_id, diff, levels, time_ms, updated_at)
  values (p_player, p_diff, p_levels, p_time_ms, now())
  on conflict (player_id, diff) do update
    set levels = excluded.levels, time_ms = excluded.time_ms, updated_at = now();
  return jsonb_build_object('status', 'new_best', 'levels', p_levels, 'time_ms', p_time_ms);
end;
$$;
revoke all on function private.submit_score(uuid, text, text, text, integer, bigint) from public;
grant execute on function private.submit_score(uuid, text, text, text, integer, bigint) to anon, authenticated;

-- 닉네임 변경: 이미 기록이 있는 플레이어만 바뀌어요. (기록이 없으면 아무 일도 없음)
create or replace function private.set_nickname(p_player uuid, p_secret text, p_nickname text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform private.check_player(p_player, p_secret, p_nickname, false);
  return jsonb_build_object('status', 'ok');
end;
$$;
revoke all on function private.set_nickname(uuid, text, text) from public;
grant execute on function private.set_nickname(uuid, text, text) to anon, authenticated;

-- 게임이 부르는 공개 창구 (/rest/v1/rpc/submit_score, /rest/v1/rpc/set_nickname)
create or replace function public.submit_score(
  p_player uuid, p_secret text, p_nickname text, p_diff text, p_levels integer, p_time_ms bigint
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.submit_score(p_player, p_secret, p_nickname, p_diff, p_levels, p_time_ms);
$$;
revoke all on function public.submit_score(uuid, text, text, text, integer, bigint) from public;
grant execute on function public.submit_score(uuid, text, text, text, integer, bigint) to anon, authenticated;

create or replace function public.set_nickname(p_player uuid, p_secret text, p_nickname text)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.set_nickname(p_player, p_secret, p_nickname);
$$;
revoke all on function public.set_nickname(uuid, text, text) from public;
grant execute on function public.set_nickname(uuid, text, text) to anon, authenticated;

-- 프로필 저장: 처음이면 플레이어를 만들고, 아니면 비밀값을 확인한 뒤 닉네임과 이모지를 바꿔요.
create or replace function private.save_profile(p_player uuid, p_secret text, p_nickname text, p_avatar text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if p_avatar is not null and p_avatar not in ('🦔','🐰','🐻','🐼','🦊','🐸','🐧','🐹','🐨','🦉','🐢','🐙') then
    raise exception 'bad_avatar';
  end if;
  perform private.check_player(p_player, p_secret, p_nickname, true);
  update public.players set avatar = p_avatar where id = p_player and avatar is distinct from p_avatar;
  return jsonb_build_object('status', 'ok');
end;
$$;
revoke all on function private.save_profile(uuid, text, text, text) from public;
grant execute on function private.save_profile(uuid, text, text, text) to anon, authenticated;

create or replace function public.save_profile(p_player uuid, p_secret text, p_nickname text, p_avatar text)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.save_profile(p_player, p_secret, p_nickname, p_avatar);
$$;
revoke all on function public.save_profile(uuid, text, text, text) from public;
grant execute on function public.save_profile(uuid, text, text, text) to anon, authenticated;

-- 예전 구조에서 쓰던 공용 검증 함수는 정리해요.
drop function if exists public._hedgedoku_check_player(uuid, text, text, boolean);

-- PostgREST가 새 함수·뷰를 바로 알아보도록 스키마 캐시를 새로 고쳐요.
notify pgrst, 'reload schema';
