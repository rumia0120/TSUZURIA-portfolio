create function diary_private.publish_diary_draft(
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

  -- Use the same turn lock as draft saving so both operations use one order.
  select m.id, m.turn_position into writer_member_id, writer_position
  from public.diary_groups g
  join public.group_members m on m.group_id = g.id and m.id = g.current_member_id
  where g.id = target_group and m.user_id = reader_id and m.left_at is null
  for update of g, m;

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

revoke all on function diary_private.publish_diary_draft(uuid, uuid, text) from public, anon, authenticated;
grant execute on function diary_private.publish_diary_draft(uuid, uuid, text) to authenticated;

create function public.publish_diary_draft(target_group uuid, target_draft uuid, expected_body text)
returns uuid
language sql security invoker set search_path = ''
as $$
  select diary_private.publish_diary_draft(target_group, target_draft, expected_body);
$$;

revoke all on function public.publish_diary_draft(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.publish_diary_draft(uuid, uuid, text) to authenticated;
