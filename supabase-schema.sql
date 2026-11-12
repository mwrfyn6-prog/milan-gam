create table if not exists public.milan_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 24),
  xp integer not null default 0 check (xp >= 0),
  avatar_url text,
  created_at timestamptz not null default now()
);

alter table public.milan_profiles add column if not exists avatar_url text;

create table if not exists public.milan_rooms (
  room_id uuid primary key default gen_random_uuid(),
  room_code text not null unique check (room_code ~ '^[A-F0-9]{6}$'),
  game_id text not null check (game_id in ('mafia', 'outsider', 'codenames', 'guess')),
  host_id uuid not null references auth.users(id),
  max_players integer not null check (max_players between 2 and 12),
  status text not null default 'lobby' check (status in ('lobby', 'playing', 'finished')),
  state jsonb not null default '{"public":{"phase":"lobby"},"private":{}}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.milan_room_players (
  room_id uuid not null references public.milan_rooms(room_id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 24),
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

alter table public.milan_profiles enable row level security;
alter table public.milan_rooms enable row level security;
alter table public.milan_room_players enable row level security;

drop policy if exists "Authenticated users can view profiles" on public.milan_profiles;
create policy "Authenticated users can view profiles"
  on public.milan_profiles for select to authenticated using (true);

revoke all on public.milan_profiles, public.milan_rooms, public.milan_room_players from anon, authenticated;
grant select on public.milan_profiles to authenticated;

create or replace function public.milan_create_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
  v_avatar text;
begin
  v_name := coalesce(
    nullif(new.raw_user_meta_data ->> 'global_name', ''),
    nullif(new.raw_user_meta_data #>> '{custom_claims,global_name}', ''),
    nullif(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(new.raw_user_meta_data ->> 'name', ''),
    nullif(new.raw_user_meta_data ->> 'nickname', ''),
    nullif(new.raw_user_meta_data ->> 'user_name', ''),
    nullif(new.raw_user_meta_data ->> 'username', ''),
    'لاعب ميلان'
  );
  v_avatar := coalesce(
    nullif(new.raw_user_meta_data ->> 'avatar_url', ''),
    nullif(new.raw_user_meta_data ->> 'picture', ''),
    nullif(new.raw_user_meta_data #>> '{custom_claims,avatar_url}', '')
  );
  insert into public.milan_profiles (user_id, display_name, avatar_url)
  values (new.id, left(v_name, 24), v_avatar)
  on conflict (user_id) do update
  set display_name = excluded.display_name,
      avatar_url = excluded.avatar_url;
  return new;
end;
$$;

drop trigger if exists milan_user_profile on auth.users;
create trigger milan_user_profile
  after insert on auth.users
  for each row execute function public.milan_create_profile();

insert into public.milan_profiles (user_id, display_name, avatar_url)
select id, left(coalesce(
  nullif(raw_user_meta_data ->> 'global_name', ''),
  nullif(raw_user_meta_data #>> '{custom_claims,global_name}', ''),
  nullif(raw_user_meta_data ->> 'full_name', ''),
  nullif(raw_user_meta_data ->> 'name', ''),
  nullif(raw_user_meta_data ->> 'nickname', ''),
  nullif(raw_user_meta_data ->> 'user_name', ''),
  nullif(raw_user_meta_data ->> 'username', ''),
  'لاعب ميلان'
), 24),
coalesce(
  nullif(raw_user_meta_data ->> 'avatar_url', ''),
  nullif(raw_user_meta_data ->> 'picture', ''),
  nullif(raw_user_meta_data #>> '{custom_claims,avatar_url}', '')
)
from auth.users
on conflict (user_id) do update
set display_name = excluded.display_name,
    avatar_url = excluded.avatar_url;

update public.milan_room_players as room_player
set display_name = profile.display_name
from public.milan_profiles as profile
where profile.user_id = room_player.user_id;

create or replace function public.milan_normalize_answer(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when char_length(normalized.value) > 5 and left(normalized.value, 2) = 'ال'
      then substr(normalized.value, 3)
    else normalized.value
  end
  from (
    select regexp_replace(
      translate(lower(coalesce(p_text, '')), 'أإآٱىةؤئءًٌٍَُِّْٰـ‌‍', 'اااايهويء'),
      '[[:space:][:punct:][:cntrl:]،؛؟٫٬…]+',
      '',
      'g'
    ) as value
  ) as normalized;
$$;

create or replace function public.milan_edit_distance(p_left text, p_right text)
returns integer
language plpgsql
immutable
strict
set search_path = ''
as $$
declare
  v_left text := p_left;
  v_right text := p_right;
  v_left_length integer;
  v_right_length integer;
  v_previous integer[];
  v_current integer[];
  v_i integer;
  v_j integer;
  v_cost integer;
begin
  if char_length(v_left) > char_length(v_right) then
    v_left := p_right;
    v_right := p_left;
  end if;
  v_left_length := char_length(v_left);
  v_right_length := char_length(v_right);
  v_previous := array(select generate_series(0, v_right_length));

  for v_i in 1..v_left_length loop
    v_current := array_fill(0, array[v_right_length + 1]);
    v_current[1] := v_i;
    for v_j in 1..v_right_length loop
      v_cost := case when substr(v_left, v_i, 1) = substr(v_right, v_j, 1) then 0 else 1 end;
      v_current[v_j + 1] := least(
        v_current[v_j] + 1,
        v_previous[v_j + 1] + 1,
        v_previous[v_j] + v_cost
      );
    end loop;
    v_previous := v_current;
  end loop;
  return v_previous[v_right_length + 1];
end;
$$;

create or replace function public.milan_answer_matches(p_answer text, p_aliases jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_answer text := public.milan_normalize_answer(p_answer);
  v_alias text;
  v_length integer;
  v_distance integer;
begin
  if v_answer = '' or jsonb_typeof(p_aliases) <> 'array' then return false; end if;
  for v_alias in select value from jsonb_array_elements_text(p_aliases) as aliases(value) loop
    v_alias := public.milan_normalize_answer(v_alias);
    if v_alias = v_answer then return true; end if;
    v_length := greatest(char_length(v_answer), char_length(v_alias));
    if v_length >= 5 then
      v_distance := public.milan_edit_distance(v_answer, v_alias);
      if v_distance <= 1 or (v_length >= 10 and v_distance <= 2) then return true; end if;
    end if;
  end loop;
  return false;
end;
$$;

create or replace function public.milan_finish_room(p_room_id uuid, p_winner text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.milan_rooms%rowtype;
  v_player record;
  v_private jsonb;
  v_won boolean;
  v_roles jsonb;
begin
  select * into v_room from public.milan_rooms where room_id = p_room_id for update;
  if v_room.status = 'finished' then return; end if;

  if v_room.game_id = 'mafia' then
    select coalesce(jsonb_object_agg(member.key, member.value -> 'role'), '{}'::jsonb)
    into v_roles
    from jsonb_each(coalesce(v_room.state -> 'private', '{}'::jsonb)) as member
    where member.key not in ('_meta', '_night') and member.value ? 'role';
  end if;

  update public.milan_rooms
  set status = 'finished',
      state = jsonb_set(
        jsonb_set(
          jsonb_set(state, '{public,phase}', '"result"'::jsonb, true),
          '{public,winner}', to_jsonb(p_winner), true
        ),
        '{public,roles}', coalesce(v_roles, '{}'::jsonb), true
      ),
      updated_at = now()
  where room_id = p_room_id;

  for v_player in
    select user_id from public.milan_room_players where room_id = p_room_id
  loop
    v_private := v_room.state -> 'private' -> v_player.user_id::text;
    v_won := case v_room.game_id
      when 'mafia' then
        case when p_winner = 'mafia'
          then coalesce(v_private ->> 'role', '') = 'mafia'
          else coalesce(v_private ->> 'role', '') <> 'mafia'
        end
      when 'outsider' then
        case when p_winner = 'spy' then coalesce((v_private ->> 'spy')::boolean, false)
             else not coalesce((v_private ->> 'spy')::boolean, false) end
      when 'codenames' then coalesce(v_private ->> 'team', '') = p_winner
      when 'guess' then coalesce((v_room.state -> 'public' -> 'winners') ? v_player.user_id::text, false)
      else false
    end;
    update public.milan_profiles
    set xp = xp + case when v_won then 25 else 5 end
    where user_id = v_player.user_id;
  end loop;
end;
$$;

create or replace function public.milan_room_snapshot(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.milan_rooms%rowtype;
  v_public jsonb;
  v_me jsonb;
  v_cards jsonb;
  v_teammates jsonb;
begin
  if auth.uid() is null then raise exception 'سجّل الدخول أولاً'; end if;
  select r.* into v_room
  from public.milan_rooms r
  join public.milan_room_players p on p.room_id = r.room_id
  where r.room_code = upper(trim(p_code)) and p.user_id = auth.uid();
  if not found then raise exception 'الغرفة غير موجودة أو لست عضواً فيها'; end if;

  v_public := v_room.state -> 'public';
  v_me := coalesce(v_room.state -> 'private' -> auth.uid()::text, '{}'::jsonb);

  if v_room.game_id = 'mafia' and v_me ->> 'role' = 'mafia' and v_room.status <> 'finished' then
    select coalesce(jsonb_agg(member.key), '[]'::jsonb)
    into v_teammates
    from jsonb_each(coalesce(v_room.state -> 'private', '{}'::jsonb)) as member
    where member.value ->> 'role' = 'mafia' and member.key <> auth.uid()::text;
    v_me := jsonb_set(v_me, '{teammates}', v_teammates, true);
  end if;

  if v_room.game_id = 'codenames' and v_room.status <> 'finished' and jsonb_typeof(v_public -> 'cards') = 'array' then
    select jsonb_agg(
      case
        when coalesce((v_me ->> 'spymaster')::boolean, false) or coalesce((card ->> 'revealed')::boolean, false)
          then card
        else card - 'color'
      end order by (item.ordinality)
    ) into v_cards
    from jsonb_array_elements(v_public -> 'cards') with ordinality as item(card, ordinality);
    v_public := jsonb_set(v_public, '{cards}', coalesce(v_cards, '[]'::jsonb), true);
  end if;

  return jsonb_build_object(
    'code', v_room.room_code,
    'game', v_room.game_id,
    'status', v_room.status,
    'hostId', v_room.host_id,
    'maxPlayers', v_room.max_players,
    'public', v_public,
    'me', v_me,
    'players', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.user_id,
        'name', p.display_name,
        'avatarUrl', profile.avatar_url,
        'isHost', p.user_id = v_room.host_id,
        'xp', coalesce(profile.xp, 0)
      ) order by p.joined_at), '[]'::jsonb)
      from public.milan_room_players p
      left join public.milan_profiles profile on profile.user_id = p.user_id
      where p.room_id = v_room.room_id
    )
  );
end;
$$;

create or replace function public.milan_room_command(
  p_action text,
  p_code text default null,
  p_game text default null,
  p_max_players integer default null,
  p_display_name text default null,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_room public.milan_rooms%rowtype;
  v_state jsonb;
  v_public jsonb;
  v_private jsonb;
  v_player record;
  v_id uuid;
  v_spymaster boolean;
  v_code text;
  v_name text;
  v_count integer;
  v_active integer;
  v_target uuid;
  v_votes jsonb;
  v_counts jsonb;
  v_top uuid;
  v_top_count integer;
  v_tie boolean;
  v_words text[];
  v_colors text[];
  v_questions jsonb;
  v_index integer;
  v_card jsonb;
  v_color text;
  v_correct integer;
  v_score integer;
  v_spy_count integer;
  v_spy_ids uuid[];
  v_key text;
  v_secret jsonb;
  v_roles text[];
  v_role text;
  v_night jsonb;
  v_mafia_votes jsonb;
  v_mafia_count integer;
  v_doctor_count integer;
  v_detective_count integer;
  v_active_count integer;
  v_ready boolean;
  v_winner text;
  v_aliases jsonb;
  v_answer text;
  v_series_number integer;
  v_series_limit integer;
  v_command_payload jsonb;
begin
  if v_uid is null then raise exception 'سجّل الدخول عبر Discord أولاً'; end if;
  v_name := left(trim(coalesce(p_display_name, '')), 24);

  if p_action = 'create' then
    if p_game not in ('mafia', 'outsider', 'codenames', 'guess') then raise exception 'اللعبة غير مدعومة'; end if;
    if char_length(v_name) < 1 then raise exception 'اكتب اسمك في اللعبة'; end if;
    if p_max_players < 2 or p_max_players > 12 then raise exception 'عدد اللاعبين غير صالح'; end if;
    if not exists (select 1 from public.milan_profiles where user_id = v_uid) then
      raise exception 'الملف الشخصي غير جاهز، أعد تسجيل الدخول';
    end if;
    loop
      v_id := null;
      v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
      insert into public.milan_rooms (room_code, game_id, host_id, max_players)
      values (v_code, p_game, v_uid, p_max_players)
      on conflict (room_code) do nothing
      returning room_id into v_id;
      exit when v_id is not null;
    end loop;
    insert into public.milan_room_players (room_id, user_id, display_name)
    values (v_id, v_uid, v_name);
    return public.milan_room_snapshot(v_code);
  end if;

  if p_action = 'join' then
    if char_length(v_name) < 1 then raise exception 'اكتب اسمك في اللعبة'; end if;
    select * into v_room from public.milan_rooms
    where room_code = upper(trim(p_code)) for update;
    if not found then raise exception 'الغرفة غير موجودة'; end if;
    if not exists (select 1 from public.milan_room_players where room_id = v_room.room_id and user_id = v_uid) then
      if v_room.status <> 'lobby' then raise exception 'الغرفة بدأت بالفعل ولا تقبل لاعبين جدد'; end if;
      select count(*) into v_count from public.milan_room_players where room_id = v_room.room_id;
      if v_count >= v_room.max_players then raise exception 'الغرفة ممتلئة'; end if;
      insert into public.milan_room_players (room_id, user_id, display_name)
      values (v_room.room_id, v_uid, v_name);
    end if;
    return public.milan_room_snapshot(v_room.room_code);
  end if;

  select r.* into v_room
  from public.milan_rooms r
  join public.milan_room_players p on p.room_id = r.room_id
  where r.room_code = upper(trim(p_code)) and p.user_id = v_uid
  for update of r;
  if not found then raise exception 'الغرفة غير موجودة أو لست عضواً فيها'; end if;
  v_state := v_room.state;
  v_public := v_state -> 'public';
  v_private := v_state -> 'private';
  v_secret := coalesce(v_private -> v_uid::text, '{}'::jsonb);

  if p_action = 'leave' then
    delete from public.milan_room_players where room_id = v_room.room_id and user_id = v_uid;
    if v_room.host_id = v_uid then
      select user_id into v_id from public.milan_room_players where room_id = v_room.room_id order by joined_at limit 1;
      if v_id is null then delete from public.milan_rooms where room_id = v_room.room_id;
      else update public.milan_rooms set host_id = v_id where room_id = v_room.room_id; end if;
    end if;
    return jsonb_build_object('left', true);
  end if;

  if p_action = 'next_round' then
    if v_uid <> v_room.host_id or v_room.status <> 'finished' then
      raise exception 'صاحب الغرفة فقط يبدأ الجولة الجديدة بعد انتهائها';
    end if;
    v_series_number := coalesce((v_public ->> 'matchNumber')::integer, 1);
    v_series_limit := coalesce((v_public ->> 'matchLimit')::integer, v_series_number);
    if v_series_number >= v_series_limit then raise exception 'اكتملت الجولات المحددة لهذه الغرفة'; end if;
    select count(*) into v_count from public.milan_room_players where room_id = v_room.room_id;
    if (v_room.game_id = 'mafia' and v_count < 5)
      or (v_room.game_id = 'outsider' and v_count < 3)
      or (v_room.game_id = 'codenames' and v_count < 4)
      or (v_room.game_id = 'guess' and v_count < 2) then
      raise exception 'عدد اللاعبين أقل من الحد الأدنى لهذه اللعبة';
    end if;
    v_command_payload := jsonb_build_object('seriesRounds', v_series_limit);
    if v_room.game_id = 'outsider' then
      v_command_payload := v_command_payload || jsonb_build_object('spyCount', coalesce(v_public -> 'spyCount', '1'::jsonb));
    end if;
    v_public := jsonb_build_object(
      'phase', 'lobby',
      'matchNumber', v_series_number + 1,
      'matchLimit', v_series_limit
    );
    update public.milan_rooms
    set status = 'lobby',
        state = jsonb_build_object('public', v_public, 'private', '{}'::jsonb),
        updated_at = now()
    where room_id = v_room.room_id;
    return public.milan_room_command(
      'start',
      v_room.room_code,
      v_room.game_id,
      null,
      p_display_name,
      v_command_payload
    );
  end if;

  if p_action = 'start' then
    if v_uid <> v_room.host_id then raise exception 'صاحب الغرفة فقط يبدأ الجولة'; end if;
    if v_room.status <> 'lobby' then raise exception 'الجولة بدأت بالفعل'; end if;
    select count(*) into v_count from public.milan_room_players where room_id = v_room.room_id;
    if (v_room.game_id = 'mafia' and v_count < 5)
      or (v_room.game_id = 'outsider' and v_count < 3)
      or (v_room.game_id = 'codenames' and v_count < 4)
      or (v_room.game_id = 'guess' and v_count < 2) then
      raise exception 'عدد اللاعبين أقل من الحد الأدنى لهذه اللعبة';
    end if;
    if coalesce(p_payload ->> 'seriesRounds', coalesce(v_public ->> 'matchLimit', '3')) !~ '^([1-9]|10)$' then
      raise exception 'عدد الجولات يجب أن يكون بين ١ و١٠';
    end if;
    v_series_number := coalesce((v_public ->> 'matchNumber')::integer, 1);
    v_series_limit := coalesce((v_public ->> 'matchLimit')::integer, (p_payload ->> 'seriesRounds')::integer, 3);
    if v_series_number > v_series_limit then raise exception 'تجاوزت عدد الجولات المحدد'; end if;
    if v_room.game_id = 'outsider' then
      if coalesce(p_payload ->> 'spyCount', '1') !~ '^[1-4]$' then raise exception 'عدد اللاعبين خارج السالفة غير صالح'; end if;
      v_spy_count := coalesce((p_payload ->> 'spyCount')::integer, 1);
      if v_spy_count > greatest(1, v_count / 3) then raise exception 'عدد اللاعبين خارج السالفة كبير على عدد المشاركين'; end if;
    end if;
    v_public := jsonb_build_object(
      'phase', case when v_room.game_id = 'mafia' then 'night' when v_room.game_id = 'outsider' then 'discussion' when v_room.game_id = 'codenames' then 'clue' else 'question' end,
      'round', 1,
      'matchNumber', v_series_number,
      'matchLimit', v_series_limit
    );
    v_private := '{}'::jsonb;

    if v_room.game_id = 'mafia' then
      v_mafia_count := greatest(1, v_count / 4);
      v_roles := array_fill('mafia'::text, array[v_mafia_count])
        || array['doctor', 'detective']
        || array_fill('town'::text, array[v_count - v_mafia_count - 2]);
      select array_agg(role order by random()) into v_roles
      from unnest(v_roles) as roles(role);
      v_index := 0;
      for v_player in select user_id from public.milan_room_players where room_id = v_room.room_id order by random() loop
        v_index := v_index + 1;
        v_private := jsonb_set(v_private, array[v_player.user_id::text], jsonb_build_object('role', v_roles[v_index]), true);
      end loop;
      v_public := v_public || jsonb_build_object('phase', 'night', 'eliminated', '[]'::jsonb, 'roleReveals', '{}'::jsonb, 'votes', '{}'::jsonb);
    elsif v_room.game_id = 'outsider' then
      v_words := array['قهوة','مطار','بحر','مدرسة','بيتزا','مكتبة','مطر','كرة قدم','سينما','نخلة','ساعة','قطار','مستشفى','حديقة','جبل','سوق','مسبح','طائرة','شاورما','قمر'];
      v_key := v_words[1 + floor(random() * array_length(v_words, 1))::integer];
      select array_agg(selected.user_id) into v_spy_ids
      from (
        select user_id from public.milan_room_players
        where room_id = v_room.room_id
        order by random()
        limit v_spy_count
      ) as selected;
      for v_player in select user_id from public.milan_room_players where room_id = v_room.room_id loop
        v_private := jsonb_set(v_private, array[v_player.user_id::text], jsonb_build_object(
          'spy', v_player.user_id = any(v_spy_ids),
          'word', case when v_player.user_id = any(v_spy_ids) then null else v_key end
        ), true);
      end loop;
      v_private := v_private || jsonb_build_object('_meta',jsonb_build_object('word',v_key));
      v_public := v_public || jsonb_build_object('phase','discussion','votes','{}'::jsonb,'spyCount',v_spy_count);
    elsif v_room.game_id = 'codenames' then
      v_words := array['قمر','بحر','عين','ورق','مفتاح','نجم','ملعب','سحاب','نار','كتاب','حصان','تفاح','مدينة','جسر','مطر','ذهب','باب','نهر','ساعة','صوت','سيف','ظل','ورد','بيت','حوت','طريق','ثلج','ملك','كرسي','ريشة','موج','نخلة'];
      select array_agg(word order by random()) into v_words from unnest(v_words) as words(word);
      v_colors := array['red','red','red','red','red','red','blue','blue','blue','blue','blue','blue','neutral','neutral','neutral','assassin'];
      select array_agg(color order by random()) into v_colors from unnest(v_colors) as colors(color);
      v_public := v_public || jsonb_build_object('phase','clue','turn','red','clue',null,'guessesLeft',0,'cards','[]'::jsonb);
      for v_index in 0..15 loop
        v_color := v_colors[v_index + 1];
        v_public := jsonb_set(v_public, array['cards'], (v_public -> 'cards') || jsonb_build_array(jsonb_build_object('word', v_words[v_index + 1], 'color', v_color, 'revealed', false)), true);
      end loop;
      v_index := 0;
      for v_player in select user_id from public.milan_room_players where room_id = v_room.room_id order by joined_at loop
        v_index := v_index + 1;
        v_color := case when v_index % 2 = 1 then 'red' else 'blue' end;
        v_spymaster := v_index <= 2;
        v_private := jsonb_set(v_private, array[v_player.user_id::text], jsonb_build_object(
          'team', v_color,
          'spymaster', v_spymaster,
          'key', case when v_spymaster then v_public -> 'cards' else null end
        ), true);
      end loop;
      v_public := jsonb_set(v_public, '{redRemaining}', '6'::jsonb, true);
      v_public := jsonb_set(v_public, '{blueRemaining}', '6'::jsonb, true);
    elsif v_room.game_id = 'guess' then
      v_questions := '[
        {"q":"ما الجهاز الذي تشاهد عليه القنوات؟","answers":["تلفزيون","تلفاز","شاشة","tv","تي في","television","screen","television screen"]},
        {"q":"ما عاصمة اليابان؟","answers":["طوكيو","tokyo"]},
        {"q":"كم عدد أضلاع الشكل السداسي؟","answers":["ستة","٦","6","six"]},
        {"q":"ما الحيوان الملقب بسفينة الصحراء؟","answers":["الجمل","camel"]},
        {"q":"كم دقيقة في الساعة؟","answers":["60","٦٠","ستون","ستين"]},
        {"q":"ما لون الزمرد؟","answers":["أخضر","اخضر","green"]},
        {"q":"ما أقرب كوكب إلى الشمس؟","answers":["عطارد","mercury"]},
        {"q":"كم عدد أيام السنة الكبيسة؟","answers":["366","٣٦٦","ثلاثمئة وستة وستون","ثلاثمائه وستة وستون"]},
        {"q":"كم عدد قارات العالم؟","answers":["7","٧","سبع","سبعة"]},
        {"q":"ما الكوكب المعروف بالكوكب الأحمر؟","answers":["المريخ","mars"]},
        {"q":"ما اسم النجم الأقرب إلى الأرض؟","answers":["الشمس","sun"]},
        {"q":"ما الغاز الذي تحتاجه النار للاشتعال؟","answers":["الأكسجين","اكسجين","oxygen"]},
        {"q":"كم عدد أيام الأسبوع؟","answers":["7","٧","سبعة","سبع"]},
        {"q":"ما عاصمة السعودية؟","answers":["الرياض","riyadh"]},
        {"q":"ما أكبر محيط في العالم؟","answers":["الهادي","المحيط الهادي","pacific"]}
      ]'::jsonb;
      v_index := floor(random() * jsonb_array_length(v_questions))::integer;
      v_public := v_public || jsonb_build_object(
        'phase','question',
        'round',1,
        'roundLimit',v_count - 1,
        'question',(v_questions -> v_index) - 'answers',
        'qualified','[]'::jsonb,
        'skipped','[]'::jsonb,
        'eliminated','[]'::jsonb,
        'winners','[]'::jsonb
      );
      v_private := jsonb_build_object(
        'questions', v_questions,
        'remaining', v_questions - v_index,
        'answerAliases', (v_questions -> v_index) -> 'answers'
      );
    end if;
    update public.milan_rooms set status='playing', state=jsonb_build_object('public',v_public,'private',v_private), updated_at=now() where room_id=v_room.room_id;
    return public.milan_room_snapshot(v_room.room_code);
  end if;

  if v_room.status <> 'playing' then raise exception 'لا توجد جولة قيد اللعب'; end if;

  if p_action = 'night_action' then
    if v_room.game_id <> 'mafia' or v_public ->> 'phase' <> 'night' then raise exception 'لا توجد مرحلة ليلية مفتوحة'; end if;
    if coalesce(v_public -> 'eliminated', '[]'::jsonb) ? v_uid::text then raise exception 'اللاعب المقصى لا يشارك في الليل'; end if;
    v_role := v_secret ->> 'role';
    if v_role not in ('mafia', 'doctor', 'detective') then raise exception 'ليس لديك إجراء ليلي'; end if;
    if v_secret ->> 'actedRound' = v_public ->> 'round' then raise exception 'سجلت إجراءك لهذه الليلة بالفعل'; end if;
    begin v_target := (p_payload ->> 'target')::uuid; exception when others then raise exception 'اللاعب المحدد غير صالح'; end;
    if not exists (
      select 1 from public.milan_room_players p
      where p.room_id = v_room.room_id
        and p.user_id = v_target
        and not (coalesce(v_public -> 'eliminated', '[]'::jsonb) ? p.user_id::text)
    ) then raise exception 'اختر لاعبًا موجودًا وما زال في الجولة'; end if;
    if v_role = 'mafia' and (
      v_target = v_uid or v_private -> v_target::text ->> 'role' = 'mafia'
    ) then raise exception 'المافيا تختار لاعبًا من أهل المدينة'; end if;
    if v_role = 'detective' and v_target = v_uid then raise exception 'اختر لاعبًا آخر للتحقق منه'; end if;

    v_night := coalesce(v_private -> '_night', '{}'::jsonb);
    if v_role = 'mafia' then
      v_mafia_votes := coalesce(v_night -> 'mafiaVotes', '{}'::jsonb);
      if v_mafia_votes ? v_uid::text then raise exception 'صوت المافيا مسجل بالفعل'; end if;
      v_mafia_votes := v_mafia_votes || jsonb_build_object(v_uid::text, v_target::text);
      v_night := jsonb_set(v_night, '{mafiaVotes}', v_mafia_votes, true);
    elsif v_role = 'doctor' then
      if v_night ? 'doctorTarget' then raise exception 'اختيار الطبيب مسجل بالفعل'; end if;
      v_night := jsonb_set(v_night, '{doctorTarget}', to_jsonb(v_target::text), true);
    else
      if v_night ? 'detectiveTarget' then raise exception 'تحقيق المحقق مسجل بالفعل'; end if;
      v_night := jsonb_set(v_night, '{detectiveTarget}', to_jsonb(v_target::text), true);
      v_secret := jsonb_set(v_secret, '{lastInvestigation}', jsonb_build_object(
        'round', (v_public ->> 'round')::integer,
        'target', v_target::text,
        'isMafia', v_private -> v_target::text ->> 'role' = 'mafia'
      ), true);
    end if;
    v_secret := jsonb_set(v_secret, '{actedRound}', to_jsonb((v_public ->> 'round')::integer), true);
    v_secret := jsonb_set(v_secret, '{nightAction}', to_jsonb(v_role), true);
    v_private := jsonb_set(v_private, array[v_uid::text], v_secret, true);
    v_private := jsonb_set(v_private, '{_night}', v_night, true);

    select count(*) into v_mafia_count
    from public.milan_room_players p
    where p.room_id = v_room.room_id
      and not (coalesce(v_public -> 'eliminated', '[]'::jsonb) ? p.user_id::text)
      and v_private -> p.user_id::text ->> 'role' = 'mafia';
    select count(*) into v_doctor_count
    from public.milan_room_players p
    where p.room_id = v_room.room_id
      and not (coalesce(v_public -> 'eliminated', '[]'::jsonb) ? p.user_id::text)
      and v_private -> p.user_id::text ->> 'role' = 'doctor';
    select count(*) into v_detective_count
    from public.milan_room_players p
    where p.room_id = v_room.room_id
      and not (coalesce(v_public -> 'eliminated', '[]'::jsonb) ? p.user_id::text)
      and v_private -> p.user_id::text ->> 'role' = 'detective';
    v_mafia_votes := coalesce(v_night -> 'mafiaVotes', '{}'::jsonb);
    v_ready := jsonb_object_length(v_mafia_votes) >= v_mafia_count
      and (v_doctor_count = 0 or v_night ? 'doctorTarget')
      and (v_detective_count = 0 or v_night ? 'detectiveTarget');

    if v_ready then
      select vote_target::uuid, count(*)::integer into v_top, v_top_count
      from jsonb_each_text(v_mafia_votes) as vote(voter, vote_target)
      group by vote_target
      order by count(*) desc
      limit 1;
      select count(*) > 1 into v_tie
      from (
        select count(*) as votes
        from jsonb_each_text(v_mafia_votes)
        group by value
        having count(*) = v_top_count
      ) as tied_targets;

      v_target := null;
      if not coalesce(v_tie, false) and v_night ->> 'doctorTarget' is distinct from v_top::text then
        v_target := v_top;
        v_public := jsonb_set(
          v_public,
          '{eliminated}',
          coalesce(v_public -> 'eliminated', '[]'::jsonb) || to_jsonb(v_target::text),
          true
        );
        v_public := jsonb_set(
          v_public,
          array['roleReveals', v_target::text],
          to_jsonb(v_private -> v_target::text ->> 'role'),
          true
        );
      end if;
      v_public := jsonb_set(v_public, '{nightEliminated}', coalesce(to_jsonb(v_target::text), 'null'::jsonb), true);
      v_public := jsonb_set(v_public, '{phase}', '"day"'::jsonb, true);
      v_public := jsonb_set(v_public, '{votes}', '{}'::jsonb, true);
      v_private := v_private - '_night';

      select count(*) into v_count
      from public.milan_room_players p
      where p.room_id = v_room.room_id
        and not (coalesce(v_public -> 'eliminated', '[]'::jsonb) ? p.user_id::text);
      select count(*) into v_active
      from public.milan_room_players p
      where p.room_id = v_room.room_id
        and not (coalesce(v_public -> 'eliminated', '[]'::jsonb) ? p.user_id::text)
        and v_private -> p.user_id::text ->> 'role' = 'mafia';
      if v_active = 0 then v_winner := 'town';
      elsif v_active >= v_count - v_active then v_winner := 'mafia';
      end if;
    end if;

  elsif p_action = 'begin_vote' then
    if v_uid <> v_room.host_id then raise exception 'صاحب الغرفة فقط يبدأ التصويت'; end if;
    if (v_room.game_id = 'mafia' and v_public ->> 'phase' <> 'day')
      or (v_room.game_id = 'outsider' and v_public ->> 'phase' <> 'discussion')
      or v_room.game_id not in ('mafia', 'outsider') then
      raise exception 'لا يمكن بدء التصويت الآن';
    end if;
    v_public := jsonb_set(jsonb_set(v_public,'{phase}','"vote"'::jsonb,true),'{votes}','{}'::jsonb,true);
    if v_room.game_id = 'mafia' then v_public := v_public - 'dayEliminated'; end if;

  elsif p_action = 'vote' then
    if v_public ->> 'phase' <> 'vote' then raise exception 'التصويت غير مفتوح'; end if;
    begin v_target := (p_payload ->> 'target')::uuid; exception when others then raise exception 'اللاعب المحدد غير صالح'; end;
    if not exists (select 1 from public.milan_room_players where room_id=v_room.room_id and user_id=v_target) or v_target=v_uid then raise exception 'اختر لاعباً آخر في الغرفة'; end if;
    if v_room.game_id = 'mafia' and (
      coalesce(v_public -> 'eliminated','[]'::jsonb) ? v_uid::text
      or coalesce(v_public -> 'eliminated','[]'::jsonb) ? v_target::text
    ) then raise exception 'اللاعب المقصي لا يصوت ولا يمكن التصويت عليه'; end if;
    if v_public -> 'votes' ? v_uid::text then raise exception 'لقد صوّت بالفعل'; end if;
    v_votes := coalesce(v_public -> 'votes','{}'::jsonb) || jsonb_build_object(v_uid::text,v_target::text);
    v_public := jsonb_set(v_public,'{votes}',v_votes,true);
    select count(*) into v_count from public.milan_room_players p
    where p.room_id=v_room.room_id and (v_room.game_id <> 'mafia' or not (coalesce(v_public -> 'eliminated','[]'::jsonb) ? p.user_id::text));
    if jsonb_object_length(v_votes) >= v_count then
      select vote_target::uuid, count(*)::integer into v_top,v_top_count
      from jsonb_each_text(v_votes) e(voter,vote_target) group by vote_target order by count(*) desc limit 1;
      select count(*) > 1 into v_tie
      from (select count(*) as votes from jsonb_each_text(v_votes) group by value having count(*) = v_top_count) t;
      if v_room.game_id = 'outsider' then
        if v_tie then
          v_public := jsonb_set(jsonb_set(v_public,'{phase}','"discussion"'::jsonb,true),'{votes}','{}'::jsonb,true);
          v_public := jsonb_set(v_public,'{round}',to_jsonb(coalesce((v_public ->> 'round')::integer,1)+1),true);
        elsif exists (
          select 1 from jsonb_each(v_private) member
          where member.key = v_top::text and coalesce((member.value ->> 'spy')::boolean,false)
        ) then
          v_public := jsonb_set(v_public,'{phase}','"spy_guess"'::jsonb,true);
          v_public := jsonb_set(v_public,'{guessingSpy}',to_jsonb(v_top::text),true);
        else
          v_winner := 'spy';
        end if;
      elsif v_room.game_id = 'mafia' then
        if v_tie then
          v_public := jsonb_set(jsonb_set(v_public,'{phase}','"day"'::jsonb,true),'{votes}','{}'::jsonb,true);
        else
          v_public := jsonb_set(v_public,'{eliminated}',coalesce(v_public -> 'eliminated','[]'::jsonb) || to_jsonb(v_top::text),true);
          v_public := jsonb_set(
            v_public,
            array['roleReveals', v_top::text],
            to_jsonb(v_private -> v_top::text ->> 'role'),
            true
          );
          v_public := jsonb_set(v_public, '{dayEliminated}', to_jsonb(v_top::text), true);
          select count(*) into v_count from public.milan_room_players p
          where p.room_id=v_room.room_id and not (coalesce(v_public -> 'eliminated','[]'::jsonb) ? p.user_id::text);
          select count(*) into v_active from public.milan_room_players p
          where p.room_id=v_room.room_id and not (coalesce(v_public -> 'eliminated','[]'::jsonb) ? p.user_id::text)
            and v_private -> p.user_id::text ->> 'role' = 'mafia';
          if v_active = 0 then
            v_winner := 'town';
          elsif v_active >= v_count - v_active then
            v_winner := 'mafia';
          else
            v_public := jsonb_set(v_public,'{phase}','"night"'::jsonb,true);
            v_public := jsonb_set(v_public,'{round}',to_jsonb(coalesce((v_public ->> 'round')::integer,1)+1),true);
            v_public := jsonb_set(v_public,'{votes}','{}'::jsonb,true);
            v_public := jsonb_set(v_public,'{nightEliminated}','null'::jsonb,true);
            v_private := v_private - '_night';
          end if;
        end if;
      end if;
    end if;

  elsif p_action = 'guess_word' then
    if v_room.game_id <> 'outsider'
      or v_public ->> 'phase' <> 'spy_guess'
      or v_public ->> 'guessingSpy' <> v_uid::text
      or not coalesce((v_secret ->> 'spy')::boolean,false) then
      raise exception 'اللاعب المخوّل فقط يخمن الكلمة';
    end if;
    v_key := v_private -> '_meta' ->> 'word';
    if lower(trim(coalesce(p_payload ->> 'word',''))) = lower(trim(coalesce(v_key,''))) then
      v_winner := 'spy';
    else
      v_winner := 'crew';
    end if;

  elsif p_action = 'clue' then
    if v_room.game_id <> 'codenames' or v_public ->> 'phase' <> 'clue' or not coalesce((v_secret ->> 'spymaster')::boolean,false) or v_secret ->> 'team' <> v_public ->> 'turn' then raise exception 'الدور ليس لك لإعطاء تلميح'; end if;
    v_count := (p_payload ->> 'count')::integer;
    if char_length(trim(coalesce(p_payload ->> 'text',''))) < 1 or v_count < 1 or v_count > 4 then raise exception 'التلميح أو العدد غير صالح'; end if;
    v_public := jsonb_set(jsonb_set(jsonb_set(v_public,'{phase}','"guess"'::jsonb,true),'{clue}',jsonb_build_object('text',left(trim(p_payload ->> 'text'),40),'count',v_count),true),'{guessesLeft}',to_jsonb(v_count+1),true);

  elsif p_action = 'guess_card' then
    if v_room.game_id <> 'codenames' or v_public ->> 'phase' <> 'guess' or coalesce((v_secret ->> 'spymaster')::boolean,false) or v_secret ->> 'team' <> v_public ->> 'turn' then raise exception 'ليس دور فريقك في التخمين'; end if;
    v_index := (p_payload ->> 'index')::integer;
    if v_index < 0 or v_index >= jsonb_array_length(v_public -> 'cards') then raise exception 'الكلمة المحددة غير صالحة'; end if;
    v_card := v_public -> 'cards' -> v_index;
    if coalesce((v_card ->> 'revealed')::boolean,false) then raise exception 'تم كشف هذه الكلمة سابقاً'; end if;
    v_color := v_card ->> 'color';
    v_public := jsonb_set(v_public,array['cards',v_index::text,'revealed'],'true'::jsonb,true);
    if v_color = 'assassin' then
      v_winner := case when v_public ->> 'turn'='red' then 'blue' else 'red' end;
    elsif v_color in ('red','blue') then
      v_key := case when v_color='red' then 'redRemaining' else 'blueRemaining' end;
      v_count := greatest(0,(v_public ->> v_key)::integer - 1);
      v_public := jsonb_set(v_public,array[v_key],to_jsonb(v_count),true);
      if v_count=0 then
        v_winner := v_color;
      elsif v_color <> v_public ->> 'turn' then
        v_public := jsonb_set(jsonb_set(v_public,'{turn}',to_jsonb(v_color),true),'{phase}','"clue"'::jsonb,true);
      else
        v_count := (v_public ->> 'guessesLeft')::integer - 1;
        v_public := jsonb_set(v_public,'{guessesLeft}',to_jsonb(v_count),true);
        if v_count <= 0 then v_public := jsonb_set(jsonb_set(v_public,'{turn}',to_jsonb(case when v_color='red' then 'blue' else 'red' end),true),'{phase}','"clue"'::jsonb,true); end if;
      end if;
    else
      v_public := jsonb_set(jsonb_set(v_public,'{turn}',to_jsonb(case when v_color='red' then 'blue' else 'red' end),true),'{phase}','"clue"'::jsonb,true);
    end if;

  elsif p_action = 'answer' then
    if v_room.game_id <> 'guess' or v_public ->> 'phase' <> 'question' then raise exception 'لا يوجد سؤال مفتوح'; end if;
    if coalesce(v_public -> 'eliminated','[]'::jsonb) ? v_uid::text then raise exception 'خرجت من المنافسة ويمكنك متابعة الجولة كمشاهد'; end if;
    if coalesce(v_public -> 'qualified','[]'::jsonb) ? v_uid::text then raise exception 'تأهلت بالفعل وتتابع الجولة كمشاهد'; end if;
    if coalesce(v_public -> 'skipped','[]'::jsonb) ? v_uid::text then raise exception 'تخطيت هذا السؤال بالفعل'; end if;
    v_answer := trim(coalesce(p_payload ->> 'answer', ''));
    v_aliases := v_private -> 'answerAliases';
    if not public.milan_answer_matches(v_answer, v_aliases) then raise exception 'الإجابة غير صحيحة، حاول مرة أخرى'; end if;

    v_public := jsonb_set(
      v_public,
      '{qualified}',
      coalesce(v_public -> 'qualified', '[]'::jsonb) || to_jsonb(v_uid::text),
      true
    );
    select count(*) into v_active_count
    from public.milan_room_players p
    where p.room_id = v_room.room_id
      and not (coalesce(v_public -> 'eliminated', '[]'::jsonb) ? p.user_id::text);
    if jsonb_array_length(v_public -> 'qualified') >= v_active_count - 1 then
      select p.user_id into v_target
      from public.milan_room_players p
      where p.room_id = v_room.room_id
        and not (coalesce(v_public -> 'eliminated', '[]'::jsonb) ? p.user_id::text)
        and not (coalesce(v_public -> 'qualified', '[]'::jsonb) ? p.user_id::text)
      order by p.joined_at
      limit 1;
      if v_target is null then raise exception 'تعذر تحديد اللاعب الأخير في هذه الجولة'; end if;
      v_public := jsonb_set(
        v_public,
        '{eliminated}',
        coalesce(v_public -> 'eliminated', '[]'::jsonb) || to_jsonb(v_target::text),
        true
      );
      v_public := jsonb_set(v_public, '{lastEliminated}', to_jsonb(v_target::text), true);
      if v_active_count <= 2 then
        select p.user_id into v_target
        from public.milan_room_players p
        where p.room_id = v_room.room_id
          and not (coalesce(v_public -> 'eliminated', '[]'::jsonb) ? p.user_id::text)
        limit 1;
        v_public := jsonb_set(v_public, '{winners}', jsonb_build_array(v_target::text), true);
        v_public := jsonb_set(v_public, '{phase}', '"result"'::jsonb, true);
        v_winner := 'quiz';
      else
        v_public := jsonb_set(v_public, '{phase}', '"round_result"'::jsonb, true);
      end if;
    end if;

  elsif p_action = 'skip_answer' then
    if v_room.game_id <> 'guess' or v_public ->> 'phase' <> 'question' then raise exception 'لا يوجد سؤال مفتوح لتخطيه'; end if;
    if coalesce(v_public -> 'eliminated','[]'::jsonb) ? v_uid::text then raise exception 'خرجت من المنافسة'; end if;
    if coalesce(v_public -> 'qualified','[]'::jsonb) ? v_uid::text then raise exception 'تأهلت بالفعل لهذا السؤال'; end if;
    if coalesce(v_public -> 'skipped','[]'::jsonb) ? v_uid::text then raise exception 'تخطيت هذا السؤال بالفعل'; end if;
    v_public := jsonb_set(
      v_public,
      '{skipped}',
      coalesce(v_public -> 'skipped', '[]'::jsonb) || to_jsonb(v_uid::text),
      true
    );

  elsif p_action = 'resolve_quiz_round' then
    if v_uid <> v_room.host_id or v_room.game_id <> 'guess' or v_public ->> 'phase' <> 'question' then
      raise exception 'صاحب الغرفة فقط يحسم السؤال المفتوح';
    end if;
    begin v_target := (p_payload ->> 'target')::uuid; exception when others then raise exception 'اللاعب المحدد غير صالح'; end;
    if not exists (
      select 1 from public.milan_room_players p
      where p.room_id = v_room.room_id
        and p.user_id = v_target
        and not (coalesce(v_public -> 'eliminated', '[]'::jsonb) ? p.user_id::text)
        and not (coalesce(v_public -> 'qualified', '[]'::jsonb) ? p.user_id::text)
    ) then raise exception 'اختر لاعبًا نشطًا لم يتأهل'; end if;
    select count(*) into v_active_count
    from public.milan_room_players p
    where p.room_id = v_room.room_id
      and not (coalesce(v_public -> 'eliminated', '[]'::jsonb) ? p.user_id::text);
    v_public := jsonb_set(
      v_public,
      '{eliminated}',
      coalesce(v_public -> 'eliminated', '[]'::jsonb) || to_jsonb(v_target::text),
      true
    );
    v_public := jsonb_set(v_public, '{lastEliminated}', to_jsonb(v_target::text), true);
    if v_active_count <= 2 then
      select p.user_id into v_target
      from public.milan_room_players p
      where p.room_id = v_room.room_id
        and not (coalesce(v_public -> 'eliminated', '[]'::jsonb) ? p.user_id::text)
      limit 1;
      v_public := jsonb_set(v_public, '{winners}', jsonb_build_array(v_target::text), true);
      v_public := jsonb_set(v_public, '{phase}', '"result"'::jsonb, true);
      v_winner := 'quiz';
    else
      v_public := jsonb_set(v_public, '{phase}', '"round_result"'::jsonb, true);
    end if;

  elsif p_action = 'next_question' then
    if v_uid <> v_room.host_id or v_room.game_id <> 'guess' or v_public ->> 'phase' <> 'round_result' then raise exception 'صاحب الغرفة فقط ينتقل للجولة التالية'; end if;
    v_count := (v_public ->> 'round')::integer + 1;
    v_questions := v_private -> 'remaining';
    if jsonb_array_length(v_questions) = 0 then raise exception 'نفدت الأسئلة المتاحة لهذه الجولة'; end if;
    v_index := floor(random() * jsonb_array_length(v_questions))::integer;
    v_public := jsonb_set(v_public, '{round}', to_jsonb(v_count), true);
    v_public := jsonb_set(v_public, '{question}', (v_questions -> v_index) - 'answers', true);
    v_public := jsonb_set(v_public, '{qualified}', '[]'::jsonb, true);
    v_public := jsonb_set(v_public, '{skipped}', '[]'::jsonb, true);
    v_public := jsonb_set(v_public, '{phase}', '"question"'::jsonb, true);
    v_public := v_public - 'lastEliminated';
    v_private := jsonb_set(v_private,'{remaining}',v_questions - v_index,true);
    v_private := jsonb_set(v_private,'{answerAliases}',(v_questions -> v_index) -> 'answers',true);
  else
    raise exception 'الأمر غير معروف';
  end if;

  if exists (select 1 from public.milan_rooms where room_id=v_room.room_id and status='playing') then
    update public.milan_rooms
    set state=jsonb_build_object('public',v_public,'private',v_private),
        updated_at=now()
    where room_id=v_room.room_id;
  end if;
  if v_winner is not null then
    perform public.milan_finish_room(v_room.room_id, v_winner);
  end if;
  return public.milan_room_snapshot(v_room.room_code);
end;
$$;

revoke all on function public.milan_create_profile() from public, anon, authenticated;
revoke all on function public.milan_normalize_answer(text) from public, anon, authenticated;
revoke all on function public.milan_edit_distance(text,text) from public, anon, authenticated;
revoke all on function public.milan_answer_matches(text,jsonb) from public, anon, authenticated;
revoke all on function public.milan_finish_room(uuid,text) from public, anon, authenticated;
revoke all on function public.milan_room_snapshot(text) from public, anon;
revoke all on function public.milan_room_command(text,text,text,integer,text,jsonb) from public, anon;
grant execute on function public.milan_room_snapshot(text) to authenticated;
grant execute on function public.milan_room_command(text,text,text,integer,text,jsonb) to authenticated;
