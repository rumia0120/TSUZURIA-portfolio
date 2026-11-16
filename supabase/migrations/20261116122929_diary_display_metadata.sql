create function public.read_my_diary_groups()
returns table (id uuid, name text, writer_name text, is_my_turn boolean)
language sql stable security invoker set search_path = ''
as $$
  select g.id, g.name, turn.writer_name, turn.is_my_turn
  from public.diary_groups g
  cross join lateral diary_private.read_diary_turn(g.id) turn;
$$;

revoke all on function public.read_my_diary_groups() from public, anon, authenticated;
grant execute on function public.read_my_diary_groups() to authenticated;

-- Resolve an author's display name only for entries the caller can read.
-- The existing profile and membership table policies stay scoped to the caller.
create function diary_private.read_shared_diary_entries(target_group uuid, target_entry uuid)
returns table (id uuid, body text, shared_at timestamptz, author_name text)
language sql stable security definer set search_path = ''
as $$
  select e.id, e.body, e.shared_at, p.display_name
  from public.diary_entries e
  join public.group_members author on author.group_id = e.group_id and author.id = e.author_member_id
  join public.profiles p on p.id = author.user_id
  where e.group_id = target_group
    and (target_entry is null or e.id = target_entry)
    and e.shared_at is not null
    and diary_private.can_read_diary_entry(e.group_id, e.author_member_id, e.shared_at);
$$;

revoke all on function diary_private.read_shared_diary_entries(uuid, uuid)
  from public, anon, authenticated;
grant execute on function diary_private.read_shared_diary_entries(uuid, uuid)
  to authenticated;

create function public.read_shared_diary_entries(target_group uuid, target_entry uuid default null)
returns table (id uuid, body text, shared_at timestamptz, author_name text)
language sql stable security invoker set search_path = ''
as $$
  select * from diary_private.read_shared_diary_entries(target_group, target_entry);
$$;

revoke all on function public.read_shared_diary_entries(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.read_shared_diary_entries(uuid, uuid)
  to authenticated;
