create table if not exists public.milan_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 24),
  xp integer not null default 0 check (xp >= 0),
  created_at timestamptz not null default now()
);

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
begin
  v_name := coalesce(
    nullif(new.raw_user_meta_data ->> 'name', ''),
    nullif(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(new.raw_user_meta_data ->> 'user_name', ''),
    'لاعب ميلان'
  );
  insert into public.milan_profiles (user_id, display_name)
  values (new.id, left(v_name, 24))
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists milan_user_profile on auth.users;
create trigger milan_user_profile
  after insert on auth.users
  for each row execute function public.milan_create_profile();

insert into public.milan_profiles (user_id, display_name)
select id, left(coalesce(
  nullif(raw_user_meta_data ->> 'name', ''),
  nullif(raw_user_meta_data ->> 'full_name', ''),
  nullif(raw_user_meta_data ->> 'user_name', ''),
  'لاعب ميلان'
), 24)
from auth.users
on conflict (user_id) do nothing;

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
begin
  select * into v_room from public.milan_rooms where room_id = p_room_id for update;
  if v_room.status = 'finished' then return; end if;

  update public.milan_rooms
  set status = 'finished',
      state = jsonb_set(
        jsonb_set(state, '{public,phase}', '"result"'::jsonb, true),
        '{public,winner}', to_jsonb(p_winner), true
      ),
      updated_at = now()
  where room_id = p_room_id;

  for v_player in
    select user_id from public.milan_room_players where room_id = p_room_id
  loop
    v_private := v_room.state -> 'private' -> v_player.user_id::text;
    v_won := case v_room.game_id
      when 'mafia' then coalesce(v_private ->> 'role', '') = p_winner
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
begin
  if auth.uid() is null then raise exception 'سجّل الدخول أولاً'; end if;
  select r.* into v_room
  from public.milan_rooms r
  join public.milan_room_players p on p.room_id = r.room_id
  where r.room_code = upper(trim(p_code)) and p.user_id = auth.uid();
  if not found then raise exception 'الغرفة غير موجودة أو لست عضواً فيها'; end if;

  v_public := v_room.state -> 'public';
  v_me := coalesce(v_room.state -> 'private' -> auth.uid()::text, '{}'::jsonb);

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
        'isHost', p.user_id = v_room.host_id,
        'xp', profile.xp
      ) order by p.joined_at), '[]'::jsonb)
      from public.milan_room_players p
      join public.milan_profiles profile on profile.user_id = p.user_id
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
  v_key text;
  v_secret jsonb;
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

  if p_action = 'start' then
    if v_uid <> v_room.host_id then raise exception 'صاحب الغرفة فقط يبدأ الجولة'; end if;
    if v_room.status <> 'lobby' then raise exception 'الجولة بدأت بالفعل'; end if;
    select count(*) into v_count from public.milan_room_players where room_id = v_room.room_id;
    if (v_room.game_id = 'mafia' and v_count < 6)
      or (v_room.game_id = 'outsider' and v_count < 3)
      or (v_room.game_id = 'codenames' and v_count < 4)
      or (v_room.game_id = 'guess' and v_count < 2) then
      raise exception 'عدد اللاعبين أقل من الحد الأدنى لهذه اللعبة';
    end if;
    v_public := jsonb_build_object('phase', case when v_room.game_id in ('mafia','outsider') then 'discussion' when v_room.game_id = 'codenames' then 'clue' else 'question' end, 'round', 1);
    v_private := '{}'::jsonb;

    if v_room.game_id = 'mafia' then
      for v_player in select user_id from public.milan_room_players where room_id = v_room.room_id order by random() loop
        v_private := jsonb_set(v_private, array[v_player.user_id::text], jsonb_build_object('role', case when (select count(*) from jsonb_each(v_private) e where e.value ->> 'role' = 'mafia') < greatest(1, v_count / 4) then 'mafia' else 'town' end), true);
      end loop;
      v_public := v_public || jsonb_build_object('phase', 'discussion', 'eliminated', '[]'::jsonb, 'votes', '{}'::jsonb);
    elsif v_room.game_id = 'outsider' then
      v_words := array['قهوة','مطار','بحر','مدرسة','بيتزا','مكتبة','مطر','كرة قدم','سينما','نخلة','ساعة','قطار','مستشفى','حديقة','جبل','سوق','مسبح','طائرة','شاورما','قمر'];
      v_key := v_words[1 + floor(random() * array_length(v_words, 1))::integer];
      select user_id into v_target from public.milan_room_players where room_id = v_room.room_id order by random() limit 1;
      for v_player in select user_id from public.milan_room_players where room_id = v_room.room_id loop
        v_private := jsonb_set(v_private, array[v_player.user_id::text], jsonb_build_object('spy', v_player.user_id = v_target, 'word', case when v_player.user_id = v_target then null else v_key end), true);
      end loop;
      v_private := v_private || jsonb_build_object('_meta',jsonb_build_object('word',v_key));
      v_public := v_public || jsonb_build_object('phase','discussion','votes','{}'::jsonb);
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
        {"q":"ما عاصمة اليابان؟","options":["طوكيو","كيوتو","أوساكا","نارا"],"answer":0},
        {"q":"كم عدد أضلاع الشكل السداسي؟","options":["خمسة","ستة","سبعة","ثمانية"],"answer":1},
        {"q":"ما أكبر كوكب في المجموعة الشمسية؟","options":["الأرض","زحل","المشتري","المريخ"],"answer":2},
        {"q":"ما الحيوان الملقب بسفينة الصحراء؟","options":["الحصان","الجمل","الفيل","الغزال"],"answer":1},
        {"q":"كم دقيقة في الساعة؟","options":["30","45","60","90"],"answer":2},
        {"q":"ما لون الزمرد؟","options":["أزرق","أخضر","أحمر","أصفر"],"answer":1},
        {"q":"ما أقرب كوكب إلى الشمس؟","options":["عطارد","الزهرة","الأرض","المريخ"],"answer":0},
        {"q":"كم عدد أيام السنة الكبيسة؟","options":["364","365","366","367"],"answer":2}
      ]'::jsonb;
      v_index := 1 + floor(random() * jsonb_array_length(v_questions))::integer;
      v_public := v_public || jsonb_build_object('phase','question','round',1,'question',(v_questions -> (v_index - 1)) - 'answer','answers','{}'::jsonb,'scores','{}'::jsonb,'winners','[]'::jsonb);
      v_private := jsonb_build_object('questions', v_questions, 'answer', (v_questions -> (v_index - 1)) -> 'answer');
      v_counts := '{}'::jsonb;
      for v_player in select user_id from public.milan_room_players where room_id=v_room.room_id loop
        v_counts := jsonb_set(v_counts,array[v_player.user_id::text],'0'::jsonb,true);
      end loop;
      v_public := jsonb_set(v_public,'{scores}',v_counts,true);
    end if;
    update public.milan_rooms set status='playing', state=jsonb_build_object('public',v_public,'private',v_private), updated_at=now() where room_id=v_room.room_id;
    return public.milan_room_snapshot(v_room.room_code);
  end if;

  if v_room.status <> 'playing' then raise exception 'لا توجد جولة قيد اللعب'; end if;

  if p_action = 'begin_vote' then
    if v_uid <> v_room.host_id then raise exception 'صاحب الغرفة فقط يبدأ التصويت'; end if;
    if v_room.game_id not in ('mafia','outsider') or v_public ->> 'phase' <> 'discussion' then raise exception 'لا يمكن بدء التصويت الآن'; end if;
    v_public := jsonb_set(jsonb_set(v_public,'{phase}','"vote"'::jsonb,true),'{votes}','{}'::jsonb,true);

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
        v_target := null;
        for v_player in select user_id from public.milan_room_players loop
          if coalesce((v_private -> v_player.user_id::text ->> 'spy')::boolean,false) then v_target := v_player.user_id; exit; end if;
        end loop;
        if not v_tie and v_top = v_target then
          v_public := jsonb_set(v_public,'{phase}','"spy_guess"'::jsonb,true);
        else
          perform public.milan_finish_room(v_room.room_id,'spy');
          v_public := (select state -> 'public' from public.milan_rooms where room_id=v_room.room_id);
        end if;
      elsif v_room.game_id = 'mafia' then
        if v_tie then
          v_public := jsonb_set(jsonb_set(v_public,'{phase}','"discussion"'::jsonb,true),'{votes}','{}'::jsonb,true);
          v_public := jsonb_set(v_public,'{round}',to_jsonb(coalesce((v_public ->> 'round')::integer,1)+1),true);
        else
          v_public := jsonb_set(v_public,'{eliminated}',coalesce(v_public -> 'eliminated','[]'::jsonb) || to_jsonb(v_top::text),true);
          select count(*) into v_count from public.milan_room_players p
          where p.room_id=v_room.room_id and not (coalesce(v_public -> 'eliminated','[]'::jsonb) ? p.user_id::text);
          select count(*) into v_active from public.milan_room_players p
          where p.room_id=v_room.room_id and not (coalesce(v_public -> 'eliminated','[]'::jsonb) ? p.user_id::text)
            and v_private -> p.user_id::text ->> 'role' = 'mafia';
          if v_active = 0 then perform public.milan_finish_room(v_room.room_id,'town');
          elsif v_active >= v_count - v_active then perform public.milan_finish_room(v_room.room_id,'mafia');
          else v_public := jsonb_set(jsonb_set(v_public,'{phase}','"discussion"'::jsonb,true),'{votes}','{}'::jsonb,true); end if;
          if v_active = 0 or v_active >= v_count - v_active then v_public := (select state -> 'public' from public.milan_rooms where room_id=v_room.room_id); end if;
        end if;
      end if;
    end if;

  elsif p_action = 'guess_word' then
    if v_room.game_id <> 'outsider' or v_public ->> 'phase' <> 'spy_guess' or not coalesce((v_secret ->> 'spy')::boolean,false) then raise exception 'اللاعب المخوّل فقط يخمن الكلمة'; end if;
    v_key := v_private -> '_meta' ->> 'word';
    if lower(trim(coalesce(p_payload ->> 'word',''))) = lower(trim(coalesce(v_key,''))) then
      perform public.milan_finish_room(v_room.room_id,'spy');
    else
      perform public.milan_finish_room(v_room.room_id,'crew');
    end if;
    v_public := (select state -> 'public' from public.milan_rooms where room_id=v_room.room_id);

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
      perform public.milan_finish_room(v_room.room_id,case when v_public ->> 'turn'='red' then 'blue' else 'red' end);
      v_public := (select state -> 'public' from public.milan_rooms where room_id=v_room.room_id);
    elsif v_color in ('red','blue') then
      v_key := case when v_color='red' then 'redRemaining' else 'blueRemaining' end;
      v_count := greatest(0,(v_public ->> v_key)::integer - 1);
      v_public := jsonb_set(v_public,array[v_key],to_jsonb(v_count),true);
      if v_count=0 then
        perform public.milan_finish_room(v_room.room_id,v_color);
        v_public := (select state -> 'public' from public.milan_rooms where room_id=v_room.room_id);
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
    if v_public -> 'answers' ? v_uid::text then raise exception 'أجبت عن هذا السؤال بالفعل'; end if;
    if coalesce(p_payload ->> 'choice','') !~ '^[0-3]$' then raise exception 'الإجابة غير صالحة'; end if;
    v_index := (p_payload ->> 'choice')::integer;
    v_public := jsonb_set(v_public,array['answers',v_uid::text],to_jsonb(v_index),true);
    select count(*) into v_count from public.milan_room_players where room_id=v_room.room_id;
    if jsonb_object_length(v_public -> 'answers') >= v_count then
      v_correct := (v_private ->> 'answer')::integer;
      v_counts := coalesce(v_public -> 'scores','{}'::jsonb);
      for v_player in select user_id from public.milan_room_players where room_id=v_room.room_id loop
        if (v_public -> 'answers' ->> v_player.user_id::text)::integer = v_correct then
          v_score := coalesce((v_counts ->> v_player.user_id::text)::integer,0)+10;
          v_counts := jsonb_set(v_counts,array[v_player.user_id::text],to_jsonb(v_score),true);
        end if;
      end loop;
      v_public := jsonb_set(jsonb_set(v_public,'{scores}',v_counts,true),'{phase}','"reveal"'::jsonb,true);
      v_public := jsonb_set(v_public,'{correctAnswer}',to_jsonb(v_correct),true);
      if (v_public ->> 'round')::integer >= 5 then
        v_score := (select max(value::integer) from jsonb_each_text(v_counts));
        select coalesce(jsonb_agg(key),'[]'::jsonb) into v_questions from jsonb_each_text(v_counts) where value::integer=v_score;
        v_public := jsonb_set(v_public,'{winners}',v_questions,true);
        update public.milan_rooms set state=jsonb_set(state,'{public}',v_public,true) where room_id=v_room.room_id;
        perform public.milan_finish_room(v_room.room_id,'quiz');
        v_public := (select state -> 'public' from public.milan_rooms where room_id=v_room.room_id);
      end if;
    end if;

  elsif p_action = 'next_question' then
    if v_uid <> v_room.host_id or v_room.game_id <> 'guess' or v_public ->> 'phase' <> 'reveal' then raise exception 'صاحب الغرفة فقط ينتقل للسؤال التالي'; end if;
    v_count := (v_public ->> 'round')::integer + 1;
    v_questions := v_private -> 'questions';
    v_index := 1 + floor(random() * jsonb_array_length(v_questions))::integer;
    v_public := jsonb_set(jsonb_set(jsonb_set(v_public,'{round}',to_jsonb(v_count),true),'{question}',(v_questions -> (v_index-1)) - 'answer',true),'{correctAnswer}', 'null'::jsonb,true);
    v_public := jsonb_set(jsonb_set(v_public,'{answers}','{}'::jsonb,true),'{phase}','"question"'::jsonb,true);
    v_private := jsonb_set(v_private,'{answer}',(v_questions -> (v_index-1)) -> 'answer',true);
  else
    raise exception 'الأمر غير معروف';
  end if;

  if exists (select 1 from public.milan_rooms where room_id=v_room.room_id and status='playing') then
    update public.milan_rooms
    set state=jsonb_set(jsonb_set(state,'{public}',v_public,true),'{private}',v_private,true),
        updated_at=now()
    where room_id=v_room.room_id;
  end if;
  return public.milan_room_snapshot(v_room.room_code);
end;
$$;

revoke all on function public.milan_create_profile() from public, anon, authenticated;
revoke all on function public.milan_finish_room(uuid,text) from public, anon, authenticated;
revoke all on function public.milan_room_snapshot(text) from public, anon;
revoke all on function public.milan_room_command(text,text,text,integer,text,jsonb) from public, anon;
grant execute on function public.milan_room_snapshot(text) to authenticated;
grant execute on function public.milan_room_command(text,text,text,integer,text,jsonb) to authenticated;
