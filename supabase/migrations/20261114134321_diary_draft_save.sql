-- A membership can have many shared entries, but only one current draft.
create unique index diary_entries_one_draft_per_member
  on public.diary_entries (author_member_id) where shared_at is null;

create function diary_private.save_diary_draft(target_group uuid, draft_body text)
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

  -- Keep the turn and active membership consistent until the save commits.
  select m.id into writer_member_id
  from public.diary_groups g
  join public.group_members m on m.group_id = g.id and m.id = g.current_member_id
  where g.id = target_group and m.user_id = reader_id and m.left_at is null
  for update of g, m;

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

revoke all on function diary_private.save_diary_draft(uuid, text) from public, anon, authenticated;
grant execute on function diary_private.save_diary_draft(uuid, text) to authenticated;

create function public.save_diary_draft(target_group uuid, draft_body text)
returns uuid
language sql security invoker set search_path = ''
as $$
  select diary_private.save_diary_draft(target_group, draft_body);
$$;

revoke all on function public.save_diary_draft(uuid, text) from public, anon, authenticated;
grant execute on function public.save_diary_draft(uuid, text) to authenticated;
