create table diary_private.turn_email_preferences (
  user_id uuid primary key references auth.users (id) on delete cascade,
  enabled_at timestamptz
);

create table diary_private.turn_email_jobs (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null unique references public.diary_entries (id) on delete cascade,
  recipient_member_id uuid not null references public.group_members (id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  available_at timestamptz not null default clock_timestamp(),
  attempts smallint not null default 0,
  lease_token uuid,
  lease_expires_at timestamptz,
  finished_at timestamptz,
  sent_at timestamptz
);
create index turn_email_jobs_ready on diary_private.turn_email_jobs (available_at, id)
  where finished_at is null;
create index turn_email_jobs_recipient on diary_private.turn_email_jobs (recipient_member_id);

alter table diary_private.turn_email_preferences enable row level security;
alter table diary_private.turn_email_jobs enable row level security;
revoke all on diary_private.turn_email_preferences, diary_private.turn_email_jobs
  from public, anon, authenticated, service_role;

create function diary_private.read_turn_email_preference()
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare
  reader_id uuid := auth.uid();
begin
  if reader_id is null then
    raise exception using errcode = '42501', message = 'Sign in to read the notification preference.';
  end if;
  return exists (
    select 1 from diary_private.turn_email_preferences p
    where p.user_id = reader_id and p.enabled_at is not null
  );
end;
$$;

create function diary_private.set_turn_email_preference(enabled boolean)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  reader_id uuid := auth.uid();
begin
  if reader_id is null then
    raise exception using errcode = '42501', message = 'Sign in to set the notification preference.';
  end if;
  if enabled is null then
    raise exception using errcode = '22023', message = 'Choose whether to receive notifications.';
  end if;
  if enabled and not exists (
    select 1 from auth.users u where u.id = reader_id
      and u.email_confirmed_at is not null and nullif(btrim(u.email), '') is not null
  ) then
    raise exception using errcode = '22023', message = 'Verify an email address first.';
  end if;

  -- A later opt-in does not revive notifications queued before the opt-out.
  insert into diary_private.turn_email_preferences as p (user_id, enabled_at)
  values (reader_id, case when enabled then clock_timestamp() end)
  on conflict (user_id) do update set enabled_at =
    case when enabled then coalesce(p.enabled_at, excluded.enabled_at) end;
  return enabled;
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

  insert into diary_private.turn_email_jobs (entry_id, recipient_member_id)
  select target_draft, m.id
  from public.group_members m
  join diary_private.turn_email_preferences p on p.user_id = m.user_id
  join auth.users u on u.id = m.user_id
  where m.id = next_member_id and m.group_id = target_group and m.left_at is null
    and p.enabled_at is not null
    and u.email_confirmed_at is not null and nullif(btrim(u.email), '') is not null
  on conflict (entry_id) do nothing;

  return target_draft;
end;
$$;

create function diary_private.claim_turn_email_jobs(batch_size integer)
returns table (job_id uuid, lease_token uuid, email text)
language plpgsql security definer set search_path = ''
as $$
declare
  job diary_private.turn_email_jobs%rowtype;
  current_time_at_claim timestamptz := clock_timestamp();
  recipient_email text;
  new_lease uuid;
begin
  if batch_size is null or batch_size not between 1 and 10 then
    raise exception using errcode = '22023', message = 'Choose a batch size between 1 and 10.';
  end if;

  for job in
    select q.* from diary_private.turn_email_jobs q
    where q.finished_at is null and q.available_at <= current_time_at_claim
      and (q.lease_expires_at is null or q.lease_expires_at <= current_time_at_claim)
    order by q.available_at, q.id
    limit batch_size
    for update of q skip locked
  loop
    recipient_email := null;
    if job.attempts < 5 and job.created_at > current_time_at_claim - interval '6 hours' then
      select u.email into recipient_email
      from public.diary_entries e
      join public.group_members author
        on author.id = e.author_member_id and author.group_id = e.group_id and author.left_at is null
      join public.diary_groups g on g.id = e.group_id and g.current_member_id = job.recipient_member_id
      join public.group_members m on m.group_id = g.id and m.id = job.recipient_member_id
      join auth.users u on u.id = m.user_id
      join diary_private.turn_email_preferences p on p.user_id = m.user_id
      where e.id = job.entry_id and e.shared_at is not null and e.shared_at >= m.joined_at
        and m.left_at is null and p.enabled_at <= job.created_at
        and u.email_confirmed_at is not null and nullif(btrim(u.email), '') is not null
        and diary_private.has_diary_quorum(g.id)
        and not exists (
          select 1 from public.diary_entries newer where newer.group_id = g.id
            and (newer.shared_at, newer.id) > (e.shared_at, e.id)
        );
    end if;

    if recipient_email is null then
      update diary_private.turn_email_jobs q
      set finished_at = current_time_at_claim, lease_token = null, lease_expires_at = null
      where q.id = job.id;
      continue;
    end if;

    new_lease := gen_random_uuid();
    update diary_private.turn_email_jobs q
    set attempts = q.attempts + 1, lease_token = new_lease,
      lease_expires_at = current_time_at_claim + interval '2 minutes'
    where q.id = job.id;

    return query select job.id, new_lease, recipient_email;
  end loop;
end;
$$;

create function diary_private.finish_turn_email_job(
  job_id uuid, lease_token uuid, delivered boolean, retryable boolean
)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  finished_time timestamptz := clock_timestamp();
begin
  if delivered is null or retryable is null then
    raise exception using errcode = '22023', message = 'A delivery result is required.';
  end if;

  update diary_private.turn_email_jobs q
  set finished_at = case
        when delivered or not retryable or q.attempts >= 5
          or q.created_at <= finished_time - interval '6 hours' then finished_time
      end,
      sent_at = case when delivered then finished_time end,
      available_at = finished_time + make_interval(mins => q.attempts * 5),
      lease_token = null,
      lease_expires_at = null
  where q.id = job_id and q.lease_token = finish_turn_email_job.lease_token
    and q.finished_at is null;
  return found;
end;
$$;

create function public.read_turn_email_preference()
returns boolean
language sql stable security invoker set search_path = ''
as $$
  select diary_private.read_turn_email_preference();
$$;

create function public.set_turn_email_preference(enabled boolean)
returns boolean
language sql security invoker set search_path = ''
as $$
  select diary_private.set_turn_email_preference(enabled);
$$;

create function public.claim_turn_email_jobs(batch_size integer)
returns table (job_id uuid, lease_token uuid, email text)
language sql security invoker set search_path = ''
as $$
  select * from diary_private.claim_turn_email_jobs(batch_size);
$$;

create function public.finish_turn_email_job(
  job_id uuid, lease_token uuid, delivered boolean, retryable boolean
)
returns boolean
language sql security invoker set search_path = ''
as $$
  select diary_private.finish_turn_email_job(job_id, lease_token, delivered, retryable);
$$;

revoke all on function diary_private.read_turn_email_preference(),
  diary_private.set_turn_email_preference(boolean), public.read_turn_email_preference(),
  public.set_turn_email_preference(boolean) from public, anon, authenticated, service_role;
grant execute on function diary_private.read_turn_email_preference(),
  diary_private.set_turn_email_preference(boolean), public.read_turn_email_preference(),
  public.set_turn_email_preference(boolean) to authenticated;

revoke all on function diary_private.claim_turn_email_jobs(integer),
  diary_private.finish_turn_email_job(uuid, uuid, boolean, boolean),
  public.claim_turn_email_jobs(integer), public.finish_turn_email_job(uuid, uuid, boolean, boolean)
  from public, anon, authenticated, service_role;
grant usage on schema diary_private to service_role;
grant execute on function diary_private.claim_turn_email_jobs(integer),
  diary_private.finish_turn_email_job(uuid, uuid, boolean, boolean),
  public.claim_turn_email_jobs(integer), public.finish_turn_email_job(uuid, uuid, boolean, boolean)
  to service_role;
