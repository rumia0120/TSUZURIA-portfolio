begin;

create extension if not exists pgtap with schema extensions;
set local search_path to public, extensions;
select plan(42);

insert into auth.users (id, email)
select ('10000000-0000-0000-0000-00000000000' || member)::uuid,
  'diary-invite-test-' || member || '@example.invalid'
from generate_series(1, 6) as fixtures(member);

insert into public.profiles (id, display_name)
values ('10000000-0000-0000-0000-000000000003', 'Existing writer');

select ok(
  not has_function_privilege('anon', 'public.create_diary_group(text, text, uuid)', 'execute')
  and not has_function_privilege('anon', 'public.create_diary_invite(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.accept_diary_invite(text, text)', 'execute'),
  'Anonymous callers cannot execute any group or invitation mutation'
);

set local role authenticated;
set local "request.jwt.claims" = '{}';
set local "request.jwt.claim.sub" = '';
select throws_ok(
  $$select public.create_diary_group('Test notebook', 'Owner')$$,
  '42501', null, 'Creating a group requires a user identity'
);

set local "request.jwt.claim.sub" = '10000000-0000-0000-0000-000000000001';
select throws_ok(
  $$select public.create_diary_group(' ', 'Owner')$$,
  '22023', null, 'A blank group name is rejected'
);
select throws_ok(
  $$select public.create_diary_group('Test notebook', null)$$,
  '22023', null, 'A creator without a profile must provide a display name'
);

set local "test.diary_group" = '20000000-0000-0000-0000-000000000001';
select ok(
  public.create_diary_group(' Test notebook ', ' Owner ', current_setting('test.diary_group')::uuid)
    = current_setting('test.diary_group')::uuid,
  'Creating a group accepts a client-generated ID'
);
select ok(
  public.create_diary_group('Another name', null, current_setting('test.diary_group')::uuid)
    = current_setting('test.diary_group')::uuid,
  'Retrying with the same ID returns the original group'
);
select ok((
  select created_by = auth.uid() and name = 'Test notebook'
  from public.diary_groups where id = current_setting('test.diary_group')::uuid
), 'The creator sees their new group with the trimmed name');
select ok((
  select display_name = 'Owner' from public.profiles where id = auth.uid()
), 'Creating a group adds the missing profile with the trimmed display name');
select ok((
  select count(*) = 1 and min(turn_position) = 1
  from public.group_members where group_id = current_setting('test.diary_group')::uuid
), 'The creator has a single membership in the first position after a retry');
select ok((
  select current_member_id is null
  from public.diary_groups where id = current_setting('test.diary_group')::uuid
), 'A group with only its owner has no writing turn');

do $$
begin
  for invite_number in 2..7 loop
    perform set_config('test.diary_invite_' || invite_number,
      public.create_diary_invite(current_setting('test.diary_group')::uuid), true);
  end loop;
end;
$$;

select throws_ok(
  $$select token_hash from diary_private.diary_invites$$,
  '42501', null, 'An authenticated owner cannot read the private invitation table'
);

reset role;
select ok((
  select count(*) = 6 and bool_and(invite.token_hash = sha256(convert_to(issued.token, 'UTF8')))
  from generate_series(2, 7) as issue(number)
  cross join lateral (select current_setting('test.diary_invite_' || issue.number) as token) as issued
  join diary_private.diary_invites as invite
    on invite.token_hash = sha256(convert_to(issued.token, 'UTF8'))
  where issued.token ~ '^[0-9a-f]{64}$'
    and invite.group_id = current_setting('test.diary_group')::uuid
    and invite.accepted_by is null
    and invite.expires_at > clock_timestamp() + interval '6 days 23 hours'
    and invite.expires_at <= clock_timestamp() + interval '7 days'
), 'Issued links have separate opaque tokens, hashed storage, and a seven-day expiry');

update diary_private.diary_invites
set expires_at = now() - interval '1 minute'
where token_hash = sha256(convert_to(current_setting('test.diary_invite_7'), 'UTF8'));

set local role authenticated;
set local "request.jwt.claim.sub" = '10000000-0000-0000-0000-000000000002';
select throws_ok(
  $$select public.create_diary_group('Different group', 'Other owner', current_setting('test.diary_group')::uuid)$$,
  '23505', null, 'Another account cannot claim a group ID already in use'
);
select ok(not exists (
  select 1 from public.profiles where id = auth.uid()
), 'The rejected account gains no profile from a conflicting group creation');
select ok(not exists (
  select 1 from public.diary_groups where id = current_setting('test.diary_group')::uuid
), 'A signed-in user cannot see a group before joining');
select throws_ok(
  $$select public.create_diary_invite(current_setting('test.diary_group')::uuid)$$,
  '42501', null, 'An outsider cannot issue a link for the group'
);
select throws_ok(
  $$select public.accept_diary_invite('malformed', 'Second writer')$$,
  'P0002', null, 'A malformed token is unavailable'
);
select throws_ok(
  $$select public.accept_diary_invite(current_setting('test.diary_invite_7'), 'Second writer')$$,
  'P0002', null, 'An expired token is unavailable'
);
select throws_ok(
  $$select public.accept_diary_invite(current_setting('test.diary_invite_2'), null)$$,
  '22023', null, 'A new member without a profile must provide a display name'
);
select ok(
  public.accept_diary_invite(current_setting('test.diary_invite_2'), 'Second writer')
    = current_setting('test.diary_group')::uuid,
  'An invite is still usable after a failed attempt to add a member'
);
select throws_ok(
  $$select public.create_diary_invite(current_setting('test.diary_group')::uuid)$$,
  '42501', null, 'An ordinary group member cannot issue a link'
);
select ok((
  select current_member_id is null
  from public.diary_groups where id = current_setting('test.diary_group')::uuid
), 'A group with two members still has no writing turn');
select throws_ok(
  $$select public.accept_diary_invite(current_setting('test.diary_invite_3'), 'Second writer')$$,
  '23505', null, 'A member cannot join again through a different link'
);

reset role;
update diary_private.diary_invites
set expires_at = now() - interval '1 minute'
where token_hash = sha256(convert_to(current_setting('test.diary_invite_2'), 'UTF8'));

set local role authenticated;
select ok(
  public.accept_diary_invite(current_setting('test.diary_invite_2'), null)
    = current_setting('test.diary_group')::uuid,
  'An original accepter can repeat the same successful request even after expiry'
);

set local "request.jwt.claim.sub" = '10000000-0000-0000-0000-000000000003';
select throws_ok(
  $$select public.accept_diary_invite(current_setting('test.diary_invite_2'), null)$$,
  'P0002', null, 'A spent invitation cannot be reused by a different account'
);
select ok(
  public.accept_diary_invite(current_setting('test.diary_invite_3'), 'Replacement writer')
    = current_setting('test.diary_group')::uuid,
  'A duplicate-membership failure does not consume the link for the next new member'
);
select ok((
  select display_name = 'Existing writer' from public.profiles where id = auth.uid()
), 'An invite acceptance preserves an existing profile');
select ok((
  select writer_name = 'Owner' and not is_my_turn
  from public.read_diary_turn(current_setting('test.diary_group')::uuid)
), 'The third member starts the rotation with the creator writing first');

set local "request.jwt.claim.sub" = '10000000-0000-0000-0000-000000000001';
with draft as (
  select public.save_diary_draft(current_setting('test.diary_group')::uuid, 'Owner diary') as id
)
select ok(
  public.publish_diary_draft(current_setting('test.diary_group')::uuid, draft.id, 'Owner diary') = draft.id,
  'The creator can save and share the first entry'
) from draft;

set local "request.jwt.claim.sub" = '10000000-0000-0000-0000-000000000002';
select ok((
  select writer_name = 'Second writer' and is_my_turn
  from public.read_diary_turn(current_setting('test.diary_group')::uuid)
) and exists (
  select 1 from public.diary_entries where group_id = current_setting('test.diary_group')::uuid
    and shared_at is not null and body = 'Owner diary'
), 'The second member can read the first entry and has the next turn');
with draft as (
  select public.save_diary_draft(current_setting('test.diary_group')::uuid, 'Second diary') as id
)
select ok(
  public.publish_diary_draft(current_setting('test.diary_group')::uuid, draft.id, 'Second diary') = draft.id,
  'The second member can save and share an entry'
) from draft;

set local "request.jwt.claim.sub" = '10000000-0000-0000-0000-000000000003';
select ok((
  select writer_name = 'Existing writer' and is_my_turn
  from public.read_diary_turn(current_setting('test.diary_group')::uuid)
), 'Sharing hands the third member the next turn');
with draft as (
  select public.save_diary_draft(current_setting('test.diary_group')::uuid, 'Third diary') as id
)
select ok(
  public.publish_diary_draft(current_setting('test.diary_group')::uuid, draft.id, 'Third diary') = draft.id,
  'The third member can save and share an entry'
) from draft;

set local "request.jwt.claim.sub" = '10000000-0000-0000-0000-000000000001';
select ok((
  select writer_name = 'Owner' and is_my_turn
  from public.read_diary_turn(current_setting('test.diary_group')::uuid)
) and (
  select count(*) = 3 from public.diary_entries where group_id = current_setting('test.diary_group')::uuid
    and shared_at is not null
), 'A complete rotation returns the turn to the creator with three readable shared entries');

set local "request.jwt.claim.sub" = '10000000-0000-0000-0000-000000000004';
select ok(
  public.accept_diary_invite(current_setting('test.diary_invite_4'), 'Fourth writer')
    = current_setting('test.diary_group')::uuid,
  'The fourth member can join an ongoing rotation'
);
select ok(not exists (
  select 1 from public.diary_entries where group_id = current_setting('test.diary_group')::uuid
), 'A new member cannot see entries shared before they joined');

set local "request.jwt.claim.sub" = '10000000-0000-0000-0000-000000000005';
select ok(
  public.accept_diary_invite(current_setting('test.diary_invite_5'), 'Fifth writer')
    = current_setting('test.diary_group')::uuid,
  'The fifth member can join an ongoing rotation'
);

set local "request.jwt.claim.sub" = '10000000-0000-0000-0000-000000000006';
select throws_ok(
  $$select public.accept_diary_invite(current_setting('test.diary_invite_6'), 'Sixth writer')$$,
  '23514', null, 'A group refuses a sixth active member'
);
select ok(
  not exists (select 1 from public.profiles where id = auth.uid())
  and not exists (select 1 from public.diary_groups where id = current_setting('test.diary_group')::uuid),
  'The rejected account gains neither a profile nor access to the group'
);

reset role;
select ok((
  select array_agg(user_id::text order by turn_position) = array(
    select '10000000-0000-0000-0000-00000000000' || member from generate_series(1, 5) as fixtures(member)
  ) and array_agg(turn_position::integer order by turn_position) = array[1, 2, 3, 4, 5]
  from public.group_members where group_id = current_setting('test.diary_group')::uuid and left_at is null
), 'Membership order contains the creator and four joiners exactly once');
select ok((
  select accepted_by is null from diary_private.diary_invites
  where token_hash = sha256(convert_to(current_setting('test.diary_invite_6'), 'UTF8'))
), 'Rejecting a full-group join leaves its invitation unused');

set local role authenticated;
set local "request.jwt.claim.sub" = '10000000-0000-0000-0000-000000000001';
select throws_ok(
  $$select public.create_diary_invite(current_setting('test.diary_group')::uuid)$$,
  '23514', null, 'The creator cannot issue another link while the group is full'
);

reset role;
select * from finish();
rollback;
