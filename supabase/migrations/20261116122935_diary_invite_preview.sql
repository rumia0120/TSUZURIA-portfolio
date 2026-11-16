create function diary_private.preview_diary_invite(invite_token text)
returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  reader_id uuid := auth.uid();
  target_group uuid;
  target_name text;
  used_by uuid;
  expires_at timestamptz;
  already_member boolean;
begin
  if reader_id is null then
    raise exception using errcode = '42501', message = 'Sign in first.';
  end if;
  if invite_token is null or length(invite_token) <> 64 or invite_token !~ '^[0-9a-f]+$' then
    raise exception using errcode = 'P0002', message = 'The invitation is unavailable.';
  end if;

  select g.id, g.name, i.accepted_by, i.expires_at
    into target_group, target_name, used_by, expires_at
  from diary_private.diary_invites i
  join public.diary_groups g on g.id = i.group_id
  where i.token_hash = sha256(convert_to(invite_token, 'UTF8'));

  if not found then
    raise exception using errcode = 'P0002', message = 'The invitation is unavailable.';
  end if;

  select exists (
    select 1 from public.group_members m
    where m.group_id = target_group and m.user_id = reader_id and m.left_at is null
  ) into already_member;

  -- Match acceptance's idempotent retry for the original accepter.
  if used_by = reader_id and already_member then
    return target_name;
  end if;
  if used_by is not null or expires_at <= statement_timestamp() then
    raise exception using errcode = 'P0002', message = 'The invitation is unavailable.';
  end if;
  if already_member then
    raise exception using errcode = '23505', message = 'You are already a member.';
  end if;
  if (select count(*) from public.group_members m
      where m.group_id = target_group and m.left_at is null) >= 5 then
    raise exception using errcode = '23514', message = 'The group is full.';
  end if;

  return target_name;
end;
$$;

-- Preview returns only the name. The accepting RPC rechecks the invitation
-- under a lock when assigning a seat and consuming the link.
create function public.preview_diary_invite(invite_token text)
returns text
language sql stable security invoker set search_path = ''
as $$
  select diary_private.preview_diary_invite(invite_token);
$$;

revoke all on function diary_private.preview_diary_invite(text),
  public.preview_diary_invite(text) from public, anon, authenticated;
grant execute on function diary_private.preview_diary_invite(text),
  public.preview_diary_invite(text) to authenticated;
