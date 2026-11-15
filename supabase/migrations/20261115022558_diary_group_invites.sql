alter table public.diary_groups
  add column created_by uuid references auth.users (id) on delete set null;
create index diary_groups_created_by on public.diary_groups (created_by)
  where created_by is not null;

create table diary_private.diary_invites (
  token_hash bytea primary key,
  group_id uuid not null references public.diary_groups (id) on delete cascade,
  expires_at timestamptz not null,
  accepted_by uuid references auth.users (id) on delete cascade
);
create index diary_invites_group_id on diary_private.diary_invites (group_id);
create index diary_invites_accepted_by on diary_private.diary_invites (accepted_by)
  where accepted_by is not null;
alter table diary_private.diary_invites enable row level security;
revoke all on diary_private.diary_invites from public, anon, authenticated;

-- Retain an existing display name, including when profile creation races.
create function diary_private.ensure_diary_profile(user_id uuid, display_name text)
returns void
language plpgsql security invoker set search_path = ''
as $$
declare
  clean_name text := regexp_replace(display_name, '^[[:space:]　]+|[[:space:]　]+$', '', 'g');
begin
  if exists (select 1 from public.profiles p where p.id = user_id) then
    return;
  end if;
  if clean_name is null or char_length(clean_name) not between 1 and 80 then
    raise exception using errcode = '22023', message = 'Enter a display name.';
  end if;
  insert into public.profiles (id, display_name)
  values (user_id, clean_name)
  on conflict (id) do nothing;
end;
$$;
revoke all on function diary_private.ensure_diary_profile(uuid, text)
  from public, anon, authenticated;

create function diary_private.create_diary_group(group_name text, display_name text, creation_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  reader_id uuid := auth.uid();
  clean_name text := regexp_replace(group_name, '^[[:space:]　]+|[[:space:]　]+$', '', 'g');
  new_group_id uuid := coalesce(creation_id, gen_random_uuid());
begin
  if reader_id is null then
    raise exception using errcode = '42501', message = 'Sign in first.';
  end if;
  if clean_name is null or char_length(clean_name) not between 1 and 100 then
    raise exception using errcode = '22023', message = 'Enter a group name.';
  end if;

  perform diary_private.ensure_diary_profile(reader_id, display_name);
  insert into public.diary_groups (id, name, created_by)
  values (new_group_id, clean_name, reader_id)
  on conflict (id) do nothing;

  if not found then
    if exists (
      select 1 from public.diary_groups g where g.id = new_group_id and g.created_by = reader_id
    ) then
      return new_group_id;
    end if;
    raise exception using errcode = '23505', message = 'Unable to create the group.';
  end if;

  insert into public.group_members (group_id, user_id, turn_position)
  values (new_group_id, reader_id, 1);
  return new_group_id;
end;
$$;

create function diary_private.create_diary_invite(target_group uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  reader_id uuid := auth.uid();
  token text;
begin
  perform 1
  from public.diary_groups g
  join public.group_members m on m.group_id = g.id and m.user_id = reader_id
  where g.id = target_group and g.created_by = reader_id and m.left_at is null
  for update of g;

  if not found then
    raise exception using errcode = '42501', message = 'Only the group creator can invite.';
  end if;
  if (select count(*) from public.group_members m
      where m.group_id = target_group and m.left_at is null) >= 5 then
    raise exception using errcode = '23514', message = 'The group is full.';
  end if;

  token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into diary_private.diary_invites (token_hash, group_id, expires_at)
  values (sha256(convert_to(token, 'UTF8')), target_group, clock_timestamp() + interval '7 days');
  return token;
end;
$$;

create function diary_private.accept_diary_invite(invite_token text, display_name text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  reader_id uuid := auth.uid();
  digest bytea;
  target_group uuid;
  invite diary_private.diary_invites%rowtype;
  already_member boolean;
  active_count integer;
  next_position smallint;
begin
  if reader_id is null then
    raise exception using errcode = '42501', message = 'Sign in first.';
  end if;
  if invite_token is null or length(invite_token) <> 64 or invite_token !~ '^[0-9a-f]+$' then
    raise exception using errcode = 'P0002', message = 'The invitation is unavailable.';
  end if;

  digest := sha256(convert_to(invite_token, 'UTF8'));

  -- The group row serializes seat assignment, even across different links.
  select g.id into target_group
  from diary_private.diary_invites i
  join public.diary_groups g on g.id = i.group_id
  where i.token_hash = digest
  for update of g;

  if found then
    select i.* into invite from diary_private.diary_invites i
    where i.token_hash = digest for update;
  end if;
  if invite.group_id is null then
    raise exception using errcode = 'P0002', message = 'The invitation is unavailable.';
  end if;

  select exists (
    select 1 from public.group_members m
    where m.group_id = target_group and m.user_id = reader_id and m.left_at is null
  ) into already_member;

  -- An authenticated retry can recover the result of a successful request.
  if invite.accepted_by = reader_id and already_member then
    return target_group;
  end if;
  if invite.accepted_by is not null or invite.expires_at <= clock_timestamp() then
    raise exception using errcode = 'P0002', message = 'The invitation is unavailable.';
  end if;
  if already_member then
    raise exception using errcode = '23505', message = 'You are already a member.';
  end if;

  select count(*) into active_count
  from public.group_members m where m.group_id = target_group and m.left_at is null;
  if active_count >= 5 then
    raise exception using errcode = '23514', message = 'The group is full.';
  end if;

  -- Prefer the position after all active members. Fall back to an empty slot
  -- when the available positions contain gaps.
  select slot into next_position
  from generate_series(1, 5) as available(slot)
  where not exists (
    select 1 from public.group_members m
    where m.group_id = target_group and m.left_at is null and m.turn_position = slot
  )
  order by (slot <= (
    select coalesce(max(m.turn_position), 0) from public.group_members m
    where m.group_id = target_group and m.left_at is null
  )), slot
  limit 1;

  perform diary_private.ensure_diary_profile(reader_id, display_name);
  insert into public.group_members (group_id, user_id, turn_position, joined_at)
  values (target_group, reader_id, next_position, clock_timestamp());
  update diary_private.diary_invites set accepted_by = reader_id where token_hash = digest;

  if active_count = 2 then
    update public.diary_groups
      set current_member_id = (
        select m.id from public.group_members m
        where m.group_id = target_group and m.left_at is null
        order by m.turn_position limit 1
      )
    where id = target_group and current_member_id is null;
  end if;
  return target_group;
end;
$$;

-- Exposed RPCs run as the caller. Only the checked implementations in
-- diary_private cross RLS to create the group's initial membership and invitees.
create function public.create_diary_group(group_name text, display_name text, creation_id uuid default null)
returns uuid
language sql security invoker set search_path = ''
as $$
  select diary_private.create_diary_group(group_name, display_name, creation_id);
$$;

create function public.create_diary_invite(target_group uuid)
returns text
language sql security invoker set search_path = ''
as $$
  select diary_private.create_diary_invite(target_group);
$$;

create function public.accept_diary_invite(invite_token text, display_name text)
returns uuid
language sql security invoker set search_path = ''
as $$
  select diary_private.accept_diary_invite(invite_token, display_name);
$$;

revoke all on function diary_private.create_diary_group(text, text, uuid),
  diary_private.create_diary_invite(uuid), diary_private.accept_diary_invite(text, text),
  public.create_diary_group(text, text, uuid), public.create_diary_invite(uuid),
  public.accept_diary_invite(text, text) from public, anon, authenticated;
grant execute on function diary_private.create_diary_group(text, text, uuid),
  diary_private.create_diary_invite(uuid), diary_private.accept_diary_invite(text, text),
  public.create_diary_group(text, text, uuid), public.create_diary_invite(uuid),
  public.accept_diary_invite(text, text) to authenticated;
