-- 고슴도쿠 리더보드 설정
-- Supabase 대시보드 → SQL Editor → New query 에 이 파일 전체를 붙여 넣고 Run 하세요.
-- 여러 번 실행해도 안전해요.
--
-- 구조
--   players      : 브라우저마다 만든 플레이어 ID, 비밀값의 해시, 닉네임
--   scores       : 플레이어 × 난이도별 최고 기록 하나
--   leaderboard  : 누구나 읽을 수 있는 공개 뷰 (비밀값 해시는 노출하지 않음)
--   submit_score / set_nickname : 기록·닉네임은 이 함수로만 쓸 수 있음 (비밀값 확인)

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.players (
  id          uuid primary key,
  secret_hash text not null,
  nickname    text not null check (char_length(nickname) between 1 and 12),
  created_at  timestamptz not null default now()
);

create table if not exists public.scores (
  player_id  uuid not null references public.players(id) on delete cascade,
  diff       text not null check (diff in ('easy', 'normal', 'hard', 'expert')),
  levels     integer not null check (levels between 1 and 100000),
  time_ms    bigint not null check (time_ms >= 0),
  updated_at timestamptz not null default now(),
  primary key (player_id, diff)
);
create index if not exists scores_rank_idx on public.scores (diff, levels desc, time_ms asc);

-- 테이블은 직접 읽거나 쓸 수 없게 잠가요. (정책을 만들지 않으면 anon은 아무것도 못 해요.)
alter table public.players enable row level security;
alter table public.scores  enable row level security;
revoke all on public.players, public.scores from anon, authenticated;

-- 공개 리더보드 뷰: 뷰 소유자 권한으로 실행돼서 잠긴 테이블을 읽을 수 있어요.
create or replace view public.leaderboard as
  select s.player_id, p.nickname, s.diff, s.levels, s.time_ms, s.updated_at
  from public.scores s
  join public.players p on p.id = s.player_id;
revoke all on public.leaderboard from anon, authenticated;
grant select on public.leaderboard to anon, authenticated;

-- 공통 검증
create or replace function public._hedgedoku_check_player(p_player uuid, p_secret text, p_nickname text, p_create boolean)
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
revoke all on function public._hedgedoku_check_player(uuid, text, text, boolean) from public, anon, authenticated;

-- 기록 등록: 그 난이도의 개인 최고 기록보다 좋을 때만 바뀌어요.
create or replace function public.submit_score(
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

  perform public._hedgedoku_check_player(p_player, p_secret, p_nickname, true);

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
revoke all on function public.submit_score(uuid, text, text, text, integer, bigint) from public;
grant execute on function public.submit_score(uuid, text, text, text, integer, bigint) to anon, authenticated;

-- 닉네임 변경: 이미 기록이 있는 플레이어만 바뀌어요. (기록이 없으면 아무 일도 없음)
create or replace function public.set_nickname(p_player uuid, p_secret text, p_nickname text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._hedgedoku_check_player(p_player, p_secret, p_nickname, false);
  return jsonb_build_object('status', 'ok');
end;
$$;
revoke all on function public.set_nickname(uuid, text, text) from public;
grant execute on function public.set_nickname(uuid, text, text) to anon, authenticated;

-- PostgREST가 새 함수·뷰를 바로 알아보도록 스키마 캐시를 새로 고쳐요.
notify pgrst, 'reload schema';
