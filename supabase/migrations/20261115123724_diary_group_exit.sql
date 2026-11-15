-- An entry belongs to the membership that authored it. Leaving keeps it
-- hidden even if the same account later joins under a new membership.
create function diary_private.can_read_diary_entry(
  target_group uuid, author_membership uuid, diary_shared_at timestamptz
)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.group_members reader
    join public.group_members author
      on author.group_id = reader.group_id and author.id = author_membership
      and author.left_at is null
    where reader.group_id = target_group and reader.user_id = (select auth.uid())
      and reader.left_at is null
      and (diary_shared_at >= reader.joined_at or (
        diary_shared_at is null and reader.id = author.id
      ))
  );
$$;

revoke all on function diary_private.can_read_diary_entry(uuid, uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function diary_private.can_read_diary_entry(uuid, uuid, timestamptz)
  to authenticated;

alter policy diary_entries_read_as_member on public.diary_entries
  using (diary_private.can_read_diary_entry(group_id, author_member_id, shared_at));

-- Keep the next assigned membership in current_member_id during a pause.
-- The read and write paths both enforce the minimum of three active members.
create function diary_private.has_diary_quorum(target_group uuid)
returns boolean
language sql stable security invoker set search_path = ''
as $$
  select count(*) >= 3
  from public.group_members m where m.group_id = target_group and m.left_at is null;
$$;
revoke all on function diary_private.has_diary_quorum(uuid) from public, anon, authenticated;

create function diary_private.lock_diary_writer(target_group uuid, reader_id uuid)
returns table (id uuid, turn_position smallint)
language plpgsql security invoker set search_path = ''
as $$
begin
  -- Membership changes, invitation acceptance and diary writes all lock this row first.
  perform 1 from public.diary_groups g where g.id = target_group for update;
  if not diary_private.has_diary_quorum(target_group) then
    return;
  end if;

  return query
  select m.id, m.turn_position
  from public.diary_groups g
  join public.group_members m on m.group_id = g.id and m.id = g.current_member_id
  where g.id = target_group and m.user_id = reader_id and m.left_at is null;
end;
$$;
revoke all on function diary_private.lock_diary_writer(uuid, uuid)
  from public, anon, authenticated;

create or replace function diary_private.read_diary_turn(target_group uuid)
returns table (writer_name text, is_my_turn boolean)
language sql stable security definer set search_path = ''
as $$
  select p.display_name, coalesce(writer.user_id = (select auth.uid()), false)
  from public.diary_groups g
  left join public.group_members writer
    on writer.group_id = g.id and writer.id = g.current_member_id and writer.left_at is null
    and diary_private.has_diary_quorum(g.id)
  left join public.profiles p on p.id = writer.user_id
  where g.id = target_group
    and exists (
      select 1 from public.group_members reader
      where reader.group_id = g.id and reader.user_id = (select auth.uid())
        and reader.left_at is null
    );
$$;

create or replace function diary_private.save_diary_draft(target_group uuid, draft_body text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  reader_id uuid := auth.uid();
  writer_member_id uuid;
  saved_id uuid;
begin
  if reader_id is null then
    raise exception using errcode = '42501', message = 'Sign in to save a draft.';
  end if;

  select writer.id into writer_member_id
  from diary_private.lock_diary_writer(target_group, reader_id) writer;

  if writer_member_id is null then
    raise exception using errcode = '42501', message = 'Only the current writer can save a draft.';
  end if;

  if draft_body is null or draft_body !~ '[^[:space:]　]' then
    raise exception using errcode = '22023', message = 'A draft needs text.';
  end if;

  insert into public.diary_entries (group_id, author_member_id, body)
  values (target_group, writer_member_id, draft_body)
  on conflict (author_member_id) where shared_at is null
  do update set body = excluded.body
  returning id into saved_id;

  return saved_id;
end;
$$;

create or replace function diary_private.publish_diary_draft(
  target_group uuid, target_draft uuid, expected_body text
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  reader_id uuid := auth.uid();
  writer_member_id uuid;
  writer_position smallint;
  next_member_id uuid;
  saved_body text;
begin
  if reader_id is null then
    raise exception using errcode = '42501', message = 'Sign in to share a diary.';
  end if;

  select writer.id, writer.turn_position into writer_member_id, writer_position
  from diary_private.lock_diary_writer(target_group, reader_id) writer;

  if writer_member_id is null then
    raise exception using errcode = '42501', message = 'Only the current writer can share a draft.';
  end if;

  select e.body into saved_body
  from public.diary_entries e
  where e.id = target_draft and e.author_member_id = writer_member_id
    and e.group_id = target_group and e.shared_at is null
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'The draft is unavailable.';
  end if;
  if saved_body is distinct from expected_body then
    raise exception using errcode = '40001', message = 'The saved draft has changed.';
  end if;

  select m.id into next_member_id
  from public.group_members m
  where m.group_id = target_group and m.left_at is null and m.id <> writer_member_id
  -- Wrap to the first active member once there is no higher position.
  order by (m.turn_position <= writer_position), m.turn_position
  limit 1
  for update;

  if next_member_id is null then
    raise exception using errcode = '22023', message = 'There is no active next writer.';
  end if;

  -- A failed update rolls back both changes in this RPC transaction.
  update public.diary_entries set shared_at = clock_timestamp()
  where id = target_draft;
  update public.diary_groups set current_member_id = next_member_id
  where id = target_group;

  return target_draft;
end;
$$;

create function diary_private.leave_diary_group(target_group uuid, expected_membership uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  reader_id uuid := auth.uid();
  leaving public.group_members%rowtype;
  invite_manager uuid;
  current_writer uuid;
  first_user uuid;
  remaining record;
  position smallint := 0;
begin
  -- Include historical memberships so a retry cannot end a later membership.
  select g.created_by, g.current_member_id into invite_manager, current_writer
  from public.diary_groups g
  join public.group_members m on m.group_id = g.id and m.id = expected_membership
  where g.id = target_group and m.user_id = reader_id
  for update of g;

  if not found then
    raise exception using errcode = '42501', message = 'You cannot leave this membership.';
  end if;

  select m.* into strict leaving from public.group_members m
  where m.group_id = target_group and m.id = expected_membership;
  if leaving.left_at is not null then
    return;
  end if;

  update public.group_members set left_at = greatest(clock_timestamp(), leaving.joined_at)
  where id = leaving.id and group_id = target_group;

  if current_writer = leaving.id then
    select m.id into current_writer
    from public.group_members m
    where m.group_id = target_group and m.left_at is null
    order by (m.turn_position <= leaving.turn_position), m.turn_position
    limit 1;
  end if;

  -- Pack the active slots in ascending order. Each target slot is either the
  -- same slot or already vacant, so the active-position unique index is preserved.
  for remaining in
    select m.id, m.user_id, m.turn_position from public.group_members m
    where m.group_id = target_group and m.left_at is null
    order by m.turn_position
  loop
    position := position + 1;
    if position = 1 then
      first_user := remaining.user_id;
    end if;
    if position <> remaining.turn_position then
      update public.group_members set turn_position = position
      where id = remaining.id and group_id = target_group;
    end if;
  end loop;

  if invite_manager is null or invite_manager = reader_id then
    invite_manager := first_user;
    delete from diary_private.diary_invites i
    where i.group_id = target_group and i.accepted_by is null;
  end if;

  update public.diary_groups set created_by = invite_manager, current_member_id = current_writer
  where id = target_group;
end;
$$;

create function public.leave_diary_group(target_group uuid, expected_membership uuid)
returns void
language sql security invoker set search_path = ''
as $$
  select diary_private.leave_diary_group(target_group, expected_membership);
$$;

revoke all on function diary_private.leave_diary_group(uuid, uuid),
  public.leave_diary_group(uuid, uuid) from public, anon, authenticated;
grant execute on function diary_private.leave_diary_group(uuid, uuid),
  public.leave_diary_group(uuid, uuid) to authenticated;
