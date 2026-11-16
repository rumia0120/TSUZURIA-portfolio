begin;

create extension if not exists pgtap with schema extensions;
set local search_path to public, extensions;
select plan(46);

create function pg_temp.mail_group(notebook integer) returns uuid
language sql immutable as $$
  select ('70000000-0000-0000-0000-0000000000' || lpad(notebook::text, 2, '0'))::uuid;
$$;
create function pg_temp.mail_member(notebook integer, member integer) returns uuid
language sql immutable as $$
  select ('72000000-0000-0000-0000-00000000' || lpad(notebook::text, 2, '0') || lpad(member::text, 2, '0'))::uuid;
$$;
create function pg_temp.share_for_mail(notebook integer, diary_body text) returns uuid
language plpgsql as $$
declare
  target_group uuid := pg_temp.mail_group(notebook);
  draft uuid;
begin
  draft := public.save_diary_draft(target_group, diary_body);
  return public.publish_diary_draft(target_group, draft, diary_body);
end;
$$;

insert into auth.users (id, email, email_confirmed_at)
select ('71000000-0000-0000-0000-00000000000' || member)::uuid,
  'turn-email-test-' || member || '@example.invalid',
  case when member <> 3 then now() - interval '1 day' end
from generate_series(1, 4) as fixtures(member);
insert into public.profiles (id, display_name)
select ('71000000-0000-0000-0000-00000000000' || member)::uuid, 'Email writer ' || member
from generate_series(1, 4) as fixtures(member);
insert into public.diary_groups (id, name, created_by)
select pg_temp.mail_group(notebook), 'Mail test notebook ' || notebook, '71000000-0000-0000-0000-000000000001'
from generate_series(1, 10) as fixtures(notebook);
insert into public.group_members (id, group_id, user_id, turn_position, joined_at)
select pg_temp.mail_member(notebook, member), pg_temp.mail_group(notebook),
  ('71000000-0000-0000-0000-00000000000' || member)::uuid, member, now() - interval '1 day'
from generate_series(1, 10) as groups(notebook)
cross join generate_series(1, 4) as members(member);
update public.diary_groups g set current_member_id = pg_temp.mail_member(notebook, 1)
from generate_series(1, 10) as fixtures(notebook) where g.id = pg_temp.mail_group(notebook);

create temporary table claimed_turn_mail (job_id uuid, lease_token uuid, email text) on commit drop;
grant select, insert, delete on claimed_turn_mail to service_role;

select ok(
  not has_function_privilege('anon', 'public.read_turn_email_preference()', 'execute')
  and not has_function_privilege('anon', 'public.set_turn_email_preference(boolean)', 'execute')
  and not has_function_privilege('anon', 'public.claim_turn_email_jobs(integer)', 'execute')
  and not has_function_privilege('anon', 'public.finish_turn_email_job(uuid, uuid, boolean, boolean)', 'execute'),
  'Anonymous callers cannot change preferences or execute worker operations'
);

set local role authenticated;
set local "request.jwt.claims" = '{}';
set local "request.jwt.claim.sub" = '';
select throws_ok($$select public.read_turn_email_preference()$$,
  '42501', null, 'Reading preferences requires an authenticated user');
select throws_ok($$select public.set_turn_email_preference(true)$$,
  '42501', null, 'Writing preferences requires an authenticated user');

set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000002';
select ok(public.read_turn_email_preference() is false, 'Email notifications are off by default');
select throws_ok($$select public.set_turn_email_preference(null)$$,
  '22023', null, 'The preference requires an explicit on or off value');
select ok(public.set_turn_email_preference(true) is true, 'A user with confirmed email can enable notifications');
select ok(public.read_turn_email_preference() is true, 'The opted-in user reads their own setting');
select throws_ok($$select * from diary_private.turn_email_preferences$$,
  '42501', null, 'Users cannot read the private preference table');
select throws_ok($$select * from diary_private.turn_email_jobs$$,
  '42501', null, 'Users cannot read private jobs');
select throws_ok($$select * from public.claim_turn_email_jobs(1)$$,
  '42501', null, 'An authenticated user cannot claim jobs or addresses');
select throws_ok($$
  select public.finish_turn_email_job(pg_temp.mail_group(1), pg_temp.mail_group(1), true, false)
$$, '42501', null, 'An authenticated user cannot finish jobs');

set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000003';
select throws_ok($$select public.set_turn_email_preference(true)$$,
  '22023', null, 'An account without a confirmed email cannot enable notifications');

set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000001';
select ok(public.read_turn_email_preference() is false, 'Another user’s opt-in does not change the caller’s setting');
do $$
begin
  perform set_config('test.email_draft', public.save_diary_draft(pg_temp.mail_group(1), 'Private fixture body')::text, true);
end;
$$;
select throws_ok($$
  select public.publish_diary_draft(pg_temp.mail_group(1), current_setting('test.email_draft')::uuid, 'Different text')
$$, '40001', null, 'A stale draft fails to publish');

reset role;
select ok(not exists (select 1 from diary_private.turn_email_jobs),
  'Saving a draft and failing to publish it do not enqueue email');

set local role authenticated;
select ok(
  public.publish_diary_draft(pg_temp.mail_group(1), current_setting('test.email_draft')::uuid, 'Private fixture body')
    = current_setting('test.email_draft')::uuid,
  'Publishing succeeds for the current writer'
);
select throws_ok($$
  select public.publish_diary_draft(pg_temp.mail_group(1), current_setting('test.email_draft')::uuid, 'Private fixture body')
$$, '42501', null, 'Replaying a publication does not publish or enqueue it again');

reset role;
select ok((
  select count(*) = 1 and bool_and(
    j.entry_id = current_setting('test.email_draft')::uuid
    and j.recipient_member_id = pg_temp.mail_member(1, 2)
    and to_jsonb(j)::text not like '%@example.invalid%'
    and to_jsonb(j)::text not like '%Private fixture body%'
  ) from diary_private.turn_email_jobs j
), 'The job stores only the expected next membership and entry IDs, without an address or diary text');

set local role service_role;
select throws_ok($$select * from public.claim_turn_email_jobs(0)$$,
  '22023', null, 'The worker must request at least one job');
select throws_ok($$select * from public.claim_turn_email_jobs(11)$$,
  '22023', null, 'The worker cannot request a batch larger than ten jobs');
insert into claimed_turn_mail select * from public.claim_turn_email_jobs(10);
select ok((select count(*) = 1 and bool_and(email = 'turn-email-test-2@example.invalid' and lease_token is not null)
  from claimed_turn_mail), 'The worker receives one leased job addressed to the opted-in next member');
select ok(not exists (select 1 from public.claim_turn_email_jobs(10)),
  'An active lease prevents duplicate claims');
reset role;
select ok((
  select attempts = 1 and lease_expires_at > clock_timestamp() + interval '1 minute'
    and lease_expires_at <= clock_timestamp() + interval '2 minutes'
  from diary_private.turn_email_jobs where entry_id = current_setting('test.email_draft')::uuid
), 'A first claim establishes a two-minute lease');
set local role service_role;
select ok((
  select public.finish_turn_email_job(job_id, pg_temp.mail_group(1), true, false) is false from claimed_turn_mail
), 'An incorrect lease token cannot acknowledge delivery');
select ok((
  select public.finish_turn_email_job(job_id, lease_token, false, true) is true from claimed_turn_mail
), 'A retryable failure releases the lease and schedules a retry');
select ok(not exists (select 1 from public.claim_turn_email_jobs(10)),
  'A failed job is not immediately claimable during backoff');

reset role;
select ok((
  select attempts = 1 and lease_token is null and finished_at is null
    and available_at > clock_timestamp() + interval '4 minutes'
    and available_at <= clock_timestamp() + interval '5 minutes'
  from diary_private.turn_email_jobs where entry_id = current_setting('test.email_draft')::uuid
), 'The first failure records one claim and backs off for about five minutes');
update diary_private.turn_email_jobs set available_at = clock_timestamp() - interval '1 second'
where entry_id = current_setting('test.email_draft')::uuid;

set local role service_role;
with next_claim as (select * from public.claim_turn_email_jobs(10))
select ok((
  select count(*) = 1 and bool_and(next_claim.job_id = old.job_id and next_claim.lease_token <> old.lease_token)
  from next_claim cross join claimed_turn_mail old
), 'A retry claims the same job under a new lease token');
select ok((
  select public.finish_turn_email_job(job_id, lease_token, true, false) is false from claimed_turn_mail
), 'The previous lease cannot finish a re-claimed job');

reset role;
update claimed_turn_mail t set lease_token = j.lease_token from diary_private.turn_email_jobs j where j.id = t.job_id;
set local role service_role;
select ok((
  select public.finish_turn_email_job(job_id, lease_token, true, false) is true from claimed_turn_mail
), 'The worker can acknowledge successful delivery');
select ok((
  select public.finish_turn_email_job(job_id, lease_token, true, false) is false from claimed_turn_mail
), 'Acknowledging a delivered job twice makes no change');
select ok(not exists (select 1 from public.claim_turn_email_jobs(10)), 'Delivered jobs are never claimed again');

reset role;
select ok((
  select attempts = 2 and sent_at is not null and finished_at is not null
  from diary_private.turn_email_jobs where entry_id = current_setting('test.email_draft')::uuid
), 'A successful retry records delivery and closes the job');

set local role authenticated;
select pg_temp.share_for_mail(2, 'Permanent failure fixture');
set local role service_role;
delete from claimed_turn_mail;
insert into claimed_turn_mail select * from public.claim_turn_email_jobs(10);
select ok((
  select public.finish_turn_email_job(job_id, lease_token, false, false) is true from claimed_turn_mail
), 'A permanent failure can be recorded');
select ok(not exists (select 1 from public.claim_turn_email_jobs(10)), 'A permanently failed job is not re-claimed');

set local role authenticated;
set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000002';
select ok(public.set_turn_email_preference(false) is false, 'The recipient can opt out');
set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000001';
select pg_temp.share_for_mail(3, 'Opted out at send time');
set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000002';
select ok(public.set_turn_email_preference(true) is true, 'The recipient can opt in again');

reset role;
update auth.users set email_confirmed_at = null where id = '71000000-0000-0000-0000-000000000002';
set local role authenticated;
set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000001';
select pg_temp.share_for_mail(4, 'Email unconfirmed at send time');
reset role;
update auth.users set email_confirmed_at = now() where id = '71000000-0000-0000-0000-000000000002';
select ok(not exists (
  select 1 from diary_private.turn_email_jobs j join public.diary_entries e on e.id = j.entry_id
  where e.group_id in (pg_temp.mail_group(3), pg_temp.mail_group(4))
), 'An opted-out or unconfirmed recipient has no job even after becoming eligible again');

set local role authenticated;
select pg_temp.share_for_mail(5, 'Opt out before claim');
set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000002';
select public.set_turn_email_preference(false);
select public.set_turn_email_preference(true);
set local role service_role;
select ok(not exists (select 1 from public.claim_turn_email_jobs(10)),
  'A later opt-in does not revive a job from before the user opted out');

set local role authenticated;
set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000001';
select pg_temp.share_for_mail(6, 'Earliest turn change');
set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000002';
select pg_temp.share_for_mail(6, 'Later turn change');
set local role service_role;
select ok(not exists (select 1 from public.claim_turn_email_jobs(10)),
  'A queued job is skipped after the group’s current writer changes');

set local role authenticated;
set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000001';
select pg_temp.share_for_mail(7, 'Before leaving');
set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000002';
select public.leave_diary_group(pg_temp.mail_group(7), pg_temp.mail_member(7, 2));
set local role service_role;
select ok(not exists (select 1 from public.claim_turn_email_jobs(10)),
  'A queued job is skipped after the recipient leaves the group');

set local role authenticated;
set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000001';
select pg_temp.share_for_mail(8, 'Before confirmation removed');
reset role;
update auth.users set email_confirmed_at = null where id = '71000000-0000-0000-0000-000000000002';
set local role service_role;
select ok(not exists (select 1 from public.claim_turn_email_jobs(10)),
  'The worker does not receive an address that lost confirmation after queuing');

reset role;
update auth.users set email_confirmed_at = now() where id = '71000000-0000-0000-0000-000000000002';
set local role authenticated;
select pg_temp.share_for_mail(9, 'Expired lease fixture');
set local role service_role;
delete from claimed_turn_mail;
insert into claimed_turn_mail select * from public.claim_turn_email_jobs(10);

reset role;
update diary_private.turn_email_jobs j set lease_expires_at = clock_timestamp() - interval '1 second'
from claimed_turn_mail t where j.id = t.job_id;
set local role service_role;
with recovered as (select * from public.claim_turn_email_jobs(10))
select ok((
  select count(*) = 1 and bool_and(recovered.job_id = old.job_id and recovered.lease_token <> old.lease_token)
  from recovered cross join claimed_turn_mail old
), 'An expired worker lease can be recovered under a new token');

reset role;
update diary_private.turn_email_jobs j set attempts = 5, lease_expires_at = clock_timestamp() - interval '1 second'
from claimed_turn_mail t where j.id = t.job_id;
set local role service_role;
select ok(not exists (select 1 from public.claim_turn_email_jobs(10)), 'The attempt limit stops repeat leasing');

set local role authenticated;
select pg_temp.share_for_mail(10, 'Expired email fixture');
reset role;
update diary_private.turn_email_preferences set enabled_at = clock_timestamp() - interval '8 hours'
where user_id = '71000000-0000-0000-0000-000000000002';
update diary_private.turn_email_jobs j
set created_at = clock_timestamp() - interval '7 hours', available_at = clock_timestamp() - interval '7 hours'
from public.diary_entries e where j.entry_id = e.id and e.group_id = pg_temp.mail_group(10);
set local role service_role;
select ok(not exists (select 1 from public.claim_turn_email_jobs(10)), 'A job older than six hours expires unclaimed');

reset role;
select ok((
  select count(*) = 7 and bool_and(j.finished_at is not null and j.sent_at is null and j.lease_token is null)
  from diary_private.turn_email_jobs j join public.diary_entries e on e.id = j.entry_id
  where e.group_id in (pg_temp.mail_group(2), pg_temp.mail_group(5), pg_temp.mail_group(6),
    pg_temp.mail_group(7), pg_temp.mail_group(8), pg_temp.mail_group(9), pg_temp.mail_group(10))
), 'Permanent failures, exhausted jobs, and skipped jobs close without recording a send');
select * from finish();
rollback;
