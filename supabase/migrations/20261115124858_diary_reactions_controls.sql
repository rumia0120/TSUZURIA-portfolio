alter table public.diary_reactions
  add column member_id uuid references public.group_members (id);
create index diary_reactions_member_id on public.diary_reactions (member_id);

-- Older rows have no creation timestamp. Restore only unambiguous membership links.
with legacy_memberships as (
  select r.entry_id, r.user_id, (array_agg(m.id))[1] as member_id
  from public.diary_reactions r
  join public.diary_entries e on e.id = r.entry_id
  join public.group_members m on m.group_id = e.group_id and m.user_id = r.user_id
  group by r.entry_id, r.user_id
  having count(*) = 1
)
update public.diary_reactions r set member_id = legacy.member_id
from legacy_memberships legacy where r.entry_id = legacy.entry_id and r.user_id = legacy.user_id;

create function diary_private.can_read_diary_reaction(
  target_entry uuid, reaction_user uuid, reacting_member uuid
)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.diary_entries e
    join public.group_members m on m.group_id = e.group_id and m.id = reacting_member
    where e.id = target_entry and e.shared_at is not null
      and m.user_id = reaction_user and m.left_at is null
      and diary_private.can_read_diary_entry(e.group_id, e.author_member_id, e.shared_at)
  );
$$;
revoke all on function diary_private.can_read_diary_reaction(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function diary_private.can_read_diary_reaction(uuid, uuid, uuid)
  to authenticated;

drop policy diary_reactions_manage_own on public.diary_reactions;
alter policy diary_reactions_read_on_shared_entry on public.diary_reactions
  using (diary_private.can_read_diary_reaction(entry_id, user_id, member_id));
revoke insert (entry_id, kind), update (kind), delete
  on public.diary_reactions from authenticated;

create function diary_private.set_diary_reaction(target_entry uuid, reaction_kind text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  reader_id uuid := auth.uid();
  target_group uuid;
  diary_author uuid;
  diary_shared_at timestamptz;
  reacting_member uuid;
begin
  if reader_id is null then
    raise exception using errcode = '42501', message = 'Sign in to react.';
  end if;
  if reaction_kind is not null and reaction_kind not in ('heart', 'smile', 'support') then
    raise exception using errcode = '22023', message = 'Unknown reaction.';
  end if;

  -- Use the same group lock as publishing, joining and leaving.
  select g.id into target_group
  from public.diary_entries e
  join public.diary_groups g on g.id = e.group_id
  where e.id = target_entry
    and diary_private.can_read_diary_entry(e.group_id, e.author_member_id, e.shared_at)
  for update of g;

  select e.author_member_id, e.shared_at into diary_author, diary_shared_at
  from public.diary_entries e where e.id = target_entry and e.group_id = target_group;
  if diary_shared_at is null
    or not diary_private.can_read_diary_entry(target_group, diary_author, diary_shared_at) then
    raise exception using errcode = '42501', message = 'This diary cannot receive a reaction.';
  end if;

  select m.id into strict reacting_member from public.group_members m
  where m.group_id = target_group and m.user_id = reader_id and m.left_at is null;

  if reaction_kind is null then
    delete from public.diary_reactions r where r.entry_id = target_entry and r.user_id = reader_id;
  else
    insert into public.diary_reactions (entry_id, user_id, kind, member_id)
    values (target_entry, reader_id, reaction_kind, reacting_member)
    on conflict (entry_id, user_id) do update
    set kind = excluded.kind, member_id = excluded.member_id;
  end if;
  return reaction_kind;
end;
$$;

create function public.set_diary_reaction(target_entry uuid, reaction_kind text)
returns text
language sql security invoker set search_path = ''
as $$
  select diary_private.set_diary_reaction(target_entry, reaction_kind);
$$;
revoke all on function diary_private.set_diary_reaction(uuid, text),
  public.set_diary_reaction(uuid, text) from public, anon, authenticated;
grant execute on function diary_private.set_diary_reaction(uuid, text),
  public.set_diary_reaction(uuid, text) to authenticated;
