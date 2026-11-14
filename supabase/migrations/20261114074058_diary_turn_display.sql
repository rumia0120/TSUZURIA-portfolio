create schema if not exists diary_private;
revoke all on schema diary_private from public;
grant usage on schema diary_private to authenticated;

create function diary_private.read_diary_turn(target_group uuid)
returns table (writer_name text, is_my_turn boolean)
language sql stable security definer set search_path = ''
as $$
  select p.display_name, coalesce(writer.user_id = (select auth.uid()), false)
  from public.diary_groups g
  left join public.group_members writer
    on writer.group_id = g.id and writer.id = g.current_member_id and writer.left_at is null
  left join public.profiles p on p.id = writer.user_id
  where g.id = target_group
    and exists (
      select 1 from public.group_members reader
      where reader.group_id = g.id and reader.user_id = (select auth.uid())
        and reader.left_at is null
    );
$$;
revoke all on function diary_private.read_diary_turn(uuid) from public, anon, authenticated;
grant execute on function diary_private.read_diary_turn(uuid) to authenticated;

create function public.read_diary_turn(target_group uuid)
returns table (writer_name text, is_my_turn boolean)
language sql stable security invoker set search_path = ''
as $$
  select * from diary_private.read_diary_turn(target_group);
$$;
revoke all on function public.read_diary_turn(uuid) from public, anon, authenticated;
grant execute on function public.read_diary_turn(uuid) to authenticated;
