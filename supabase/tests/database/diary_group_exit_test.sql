begin;

create extension if not exists pgtap with schema extensions;
set local search_path to public, extensions;
select plan(43);

insert into auth.users (id, email)
select ('31000000-0000-0000-0000-00000000000' || member)::uuid,
  'diary-exit-test-' || member || '@example.invalid'
from generate_series(1, 6) as fixtures(member);

insert into public.profiles (id, display_name)
select ('31000000-0000-0000-0000-00000000000' || member)::uuid,
  'Writer ' || member
from generate_series(1, 5) as fixtures(member);

set local "test.exit_group" = '30000000-0000-0000-0000-000000000001';
insert into public.diary_groups (id, name, created_by)
values (current_setting('test.exit_group')::uuid, 'Exit test notebook', '31000000-0000-0000-0000-000000000001');

insert into public.group_members (id, group_id, user_id, turn_position, joined_at)
select ('40000000-0000-0000-0000-00000000000' || member)::uuid,
  current_setting('test.exit_group')::uuid,
  ('31000000-0000-0000-0000-00000000000' || member)::uuid,
  member, now() - interval '2 days'
from generate_series(1, 5) as fixtures(member);

update public.diary_groups set current_member_id = '40000000-0000-0000-0000-000000000003'
where id = current_setting('test.exit_group')::uuid;

insert into public.diary_entries (id, group_id, author_member_id, body, created_at, shared_at)
select ('50000000-0000-0000-0000-00000000000' || member)::uuid,
  current_setting('test.exit_group')::uuid,
  ('40000000-0000-0000-0000-00000000000' || member)::uuid,
  'Shared diary ' || member, now() - interval '1 day', now() - interval '1 hour'
from generate_series(1, 5) as fixtures(member);

insert into public.diary_entries (id, group_id, author_member_id, body)
values ('50000000-0000-0000-0000-000000000006', current_setting('test.exit_group')::uuid,
  '40000000-0000-0000-0000-000000000003', 'Old draft from writer 3');

insert into public.diary_reactions (entry_id, user_id, kind, member_id)
values ('50000000-0000-0000-0000-000000000003', '31000000-0000-0000-0000-000000000001', 'heart',
  '40000000-0000-0000-0000-000000000001');

select ok(
  not has_function_privilege('anon', 'public.leave_diary_group(uuid, uuid)', 'execute'),
  'Anonymous callers cannot execute the exit operation'
);
select ok(
  not has_function_privilege('anon', 'public.read_my_diary_groups()', 'execute')
  and not has_function_privilege('anon', 'public.read_shared_diary_entries(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'diary_private.read_shared_diary_entries(uuid, uuid)', 'execute'),
  'Anonymous callers cannot request group cards or shared entries with author labels'
);

set local role authenticated;
set local "request.jwt.claims" = '{}';
set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000006';
select throws_ok($$
  select public.leave_diary_group(current_setting('test.exit_group')::uuid, '40000000-0000-0000-0000-000000000003')
$$, '42501', null, 'An outsider cannot end an existing membership');
select ok(
  not exists (select 1 from public.read_my_diary_groups())
  and not exists (select 1 from public.read_shared_diary_entries(current_setting('test.exit_group')::uuid))
  and not exists (
    select 1 from public.read_shared_diary_entries(current_setting('test.exit_group')::uuid, '50000000-0000-0000-0000-000000000001')
  ),
  'An outsider cannot see a group card, list shared entries, or fetch shared entry detail'
);

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000001';
select throws_ok($$
  select public.leave_diary_group(current_setting('test.exit_group')::uuid, '40000000-0000-0000-0000-000000000003')
$$, '42501', null, 'Even the owner cannot end someone else’s membership');
select ok(
  exists (select 1 from public.diary_entries where id = '50000000-0000-0000-0000-000000000005')
  and not exists (select 1 from public.diary_entries where id = '50000000-0000-0000-0000-000000000006'),
  'Before leaving, a member’s shared entry is visible and someone else’s draft is private'
);
select ok((
  select name = 'Exit test notebook' and writer_name = 'Writer 3' and not is_my_turn
  from public.read_my_diary_groups() where id = current_setting('test.exit_group')::uuid
), 'Group cards include the current writer when it is another member’s turn');
select ok(
  (select count(*) = 5 and count(distinct author_name) = 5
    from public.read_shared_diary_entries(current_setting('test.exit_group')::uuid))
  and (select author_name = 'Writer 3' and body = 'Shared diary 3' and shared_at is not null
    from public.read_shared_diary_entries(current_setting('test.exit_group')::uuid, '50000000-0000-0000-0000-000000000003'))
  and not exists (select 1 from public.profiles where display_name = 'Writer 3'),
  'The list and detail name shared entry authors without opening up their profile rows'
);

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000005';
select public.leave_diary_group(current_setting('test.exit_group')::uuid, '40000000-0000-0000-0000-000000000005');
select ok(
  not exists (select 1 from public.diary_groups where id = current_setting('test.exit_group')::uuid)
  and not exists (select 1 from public.group_members where group_id = current_setting('test.exit_group')::uuid)
  and not exists (select 1 from public.diary_entries where group_id = current_setting('test.exit_group')::uuid)
  and not exists (select 1 from public.read_diary_turn(current_setting('test.exit_group')::uuid)),
  'A departing reader immediately loses group, membership, diary, and turn access'
);

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000001';
select ok(
  not exists (select 1 from public.diary_entries where id = '50000000-0000-0000-0000-000000000005')
  and exists (select 1 from public.diary_entries where id = '50000000-0000-0000-0000-000000000001'),
  'Remaining members lose the departing author’s entry and retain active authors’ entries'
);
select ok(
  not exists (
    select 1 from public.read_shared_diary_entries(current_setting('test.exit_group')::uuid)
    where author_name = 'Writer 5'
  )
  and not exists (
    select 1 from public.read_shared_diary_entries(current_setting('test.exit_group')::uuid, '50000000-0000-0000-0000-000000000005')
  ),
  'Shared entry lists and detail hide departed authors and their entries'
);
select ok((
  select writer_name = 'Writer 3' and not is_my_turn
  from public.read_diary_turn(current_setting('test.exit_group')::uuid)
), 'A non-current member’s departure preserves the current turn');

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000003';
select ok((
  select writer_name = 'Writer 3' and is_my_turn
  from public.read_my_diary_groups() where id = current_setting('test.exit_group')::uuid
) and not exists (
  select 1 from public.read_shared_diary_entries(current_setting('test.exit_group')::uuid, '50000000-0000-0000-0000-000000000006')
), 'The card identifies the reader’s own turn and shared detail still excludes the reader’s own draft');
select public.leave_diary_group(current_setting('test.exit_group')::uuid, '40000000-0000-0000-0000-000000000003');
select throws_ok($$
  select public.save_diary_draft(current_setting('test.exit_group')::uuid, 'Write after leaving')
$$, '42501', null, 'A departed current writer cannot save a draft');
select throws_ok($$
  select public.publish_diary_draft(current_setting('test.exit_group')::uuid,
    '50000000-0000-0000-0000-000000000006', 'Old draft from writer 3')
$$, '42501', null, 'A departed current writer cannot publish their old draft');

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000004';
select ok((
  select writer_name = 'Writer 4' and is_my_turn
  from public.read_diary_turn(current_setting('test.exit_group')::uuid)
), 'With three members remaining, a current writer’s exit hands the turn to the next active member');
select ok(
  not exists (select 1 from public.diary_entries where id = '50000000-0000-0000-0000-000000000003')
  and not exists (select 1 from public.diary_reactions where entry_id = '50000000-0000-0000-0000-000000000003'),
  'The departing writer’s shared entry and attached reactions become invisible to the remaining reader'
);
do $$
begin
  perform set_config('test.exit_next_draft',
    public.save_diary_draft(current_setting('test.exit_group')::uuid, 'New diary from writer 4')::text, true);
end;
$$;

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000002';
select public.leave_diary_group(current_setting('test.exit_group')::uuid, '40000000-0000-0000-0000-000000000002');

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000004';
select ok((
  select writer_name is null and not is_my_turn
  from public.read_diary_turn(current_setting('test.exit_group')::uuid)
), 'With two members remaining, the app reports that the rotation is paused');
select ok((
  select writer_name is null and not is_my_turn
  from public.read_my_diary_groups() where id = current_setting('test.exit_group')::uuid
), 'Group cards show a paused rotation instead of showing a designated writer');
select ok((
  select body = 'New diary from writer 4'
  from public.diary_entries where id = current_setting('test.exit_next_draft')::uuid
), 'A paused writer can still read their own unchanged draft');
select throws_ok($$
  select public.save_diary_draft(current_setting('test.exit_group')::uuid, 'Edit while paused')
$$, '42501', null, 'The designated writer cannot update the draft while the group is paused');
select throws_ok($$
  select public.publish_diary_draft(current_setting('test.exit_group')::uuid,
    current_setting('test.exit_next_draft')::uuid, 'New diary from writer 4')
$$, '42501', null, 'The designated writer cannot share the draft while the group is paused');

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000001';
do $$
begin
  perform set_config('test.exit_invite_rejoin',
    public.create_diary_invite(current_setting('test.exit_group')::uuid), true);
  perform set_config('test.exit_invite_old_owner',
    public.create_diary_invite(current_setting('test.exit_group')::uuid), true);
end;
$$;

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000003';
select ok(
  public.accept_diary_invite(current_setting('test.exit_invite_rejoin'), null) = current_setting('test.exit_group')::uuid,
  'A former member can rejoin with a fresh invitation'
);
select public.leave_diary_group(current_setting('test.exit_group')::uuid, '40000000-0000-0000-0000-000000000003');
select ok((
  select count(*) = 1 and min(turn_position) = 3
  from public.group_members where group_id = current_setting('test.exit_group')::uuid
    and id <> '40000000-0000-0000-0000-000000000003'
), 'Rejoining appends one new membership and replaying the old leave request keeps it active');
select ok(not exists (
  select 1 from public.diary_entries where group_id = current_setting('test.exit_group')::uuid
), 'A rejoining account cannot read its old draft or any entries shared before rejoining');
select ok(not exists (
  select 1 from public.read_shared_diary_entries(current_setting('test.exit_group')::uuid)
), 'Author-labelled shared entries also start at the reader’s rejoin time');

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000004';
select ok((
  select writer_name = 'Writer 4' and is_my_turn
  from public.read_diary_turn(current_setting('test.exit_group')::uuid)
), 'A third active member resumes the previously designated turn');
select ok(
  public.publish_diary_draft(current_setting('test.exit_group')::uuid,
    current_setting('test.exit_next_draft')::uuid, 'New diary from writer 4') = current_setting('test.exit_next_draft')::uuid,
  'The resumed writer can share the draft saved before the pause'
);

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000003';
select ok((
  select writer_name = 'Writer 3' and is_my_turn
  from public.read_diary_turn(current_setting('test.exit_group')::uuid)
) and exists (
  select 1 from public.diary_entries where id = current_setting('test.exit_next_draft')::uuid and shared_at is not null
), 'The rejoining member reads entries shared after rejoining and receives their new turn');
select ok(
  public.save_diary_draft(current_setting('test.exit_group')::uuid, 'Fresh draft from writer 3')
    <> '50000000-0000-0000-0000-000000000006'::uuid,
  'A new turn creates a fresh draft and leaves the former membership draft untouched'
);

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000001';
select ok(not exists (
  select 1 from public.diary_entries where id = '50000000-0000-0000-0000-000000000003'
), 'Other members still cannot read an earlier entry from the former membership after the author rejoins');
select public.leave_diary_group(current_setting('test.exit_group')::uuid, '40000000-0000-0000-0000-000000000001');
select throws_ok($$
  select public.create_diary_invite(current_setting('test.exit_group')::uuid)
$$, '42501', null, 'The departed owner can no longer invite');

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000006';
select throws_ok($$
  select public.accept_diary_invite(current_setting('test.exit_invite_old_owner'), 'Writer 6')
$$, 'P0002', null, 'An unused link from the departed owner is invalidated');

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000004';
select ok((
  select created_by = auth.uid() from public.diary_groups where id = current_setting('test.exit_group')::uuid
), 'The earliest remaining active member inherits invitation ownership');
do $$
begin
  perform set_config('test.exit_invite_new_owner',
    public.create_diary_invite(current_setting('test.exit_group')::uuid), true);
end;
$$;

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000006';
select ok(
  public.accept_diary_invite(current_setting('test.exit_invite_new_owner'), 'Writer 6')
    = current_setting('test.exit_group')::uuid,
  'The successor can issue a usable invite for a new sixth account'
);
select ok((
  select writer_name = 'Writer 3' and not is_my_turn
  from public.read_diary_turn(current_setting('test.exit_group')::uuid)
), 'After the owner exits, the next join resumes the same designated turn');

reset role;
select ok((
  select count(*) = 6 and count(*) filter (where shared_at is null) = 1
  from public.diary_entries where id::text like '50000000-0000-0000-0000-00000000000%'
), 'All original diary records and the original draft remain stored after members exit');
select ok((
  select array_agg(user_id::text order by turn_position) = array[
    '31000000-0000-0000-0000-000000000004',
    '31000000-0000-0000-0000-000000000003',
    '31000000-0000-0000-0000-000000000006'
  ] and array_agg(turn_position::integer order by turn_position) = array[1, 2, 3]
  from public.group_members where group_id = current_setting('test.exit_group')::uuid and left_at is null
), 'Departures compact the remaining order and new memberships take the last position');
select ok((
  select count(*) = 4 and bool_and(left_at >= joined_at)
  from public.group_members where group_id = current_setting('test.exit_group')::uuid and left_at is not null
), 'Exactly four prior memberships are ended and their timing is retained');

set local "test.exit_legacy_group" = '30000000-0000-0000-0000-000000000002';
insert into public.diary_groups (id, name)
values (current_setting('test.exit_legacy_group')::uuid, 'Legacy two-member notebook');
insert into public.group_members (id, group_id, user_id, turn_position, joined_at) values
  ('40000000-0000-0000-0000-000000000101', current_setting('test.exit_legacy_group')::uuid,
    '31000000-0000-0000-0000-000000000002', 1, now() - interval '2 days'),
  ('40000000-0000-0000-0000-000000000102', current_setting('test.exit_legacy_group')::uuid,
    '31000000-0000-0000-0000-000000000004', 2, now() - interval '2 days');
update public.diary_groups set current_member_id = '40000000-0000-0000-0000-000000000101'
where id = current_setting('test.exit_legacy_group')::uuid;

set local role authenticated;
set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000002';
select ok((
  select writer_name is null and not is_my_turn
  from public.read_diary_turn(current_setting('test.exit_legacy_group')::uuid)
), 'A legacy group with two members is paused even when it has a designated writer');
select throws_ok($$
  select public.save_diary_draft(current_setting('test.exit_legacy_group')::uuid, 'Legacy draft while paused')
$$, '42501', null, 'A legacy group’s paused designated writer also cannot write');
select public.leave_diary_group(current_setting('test.exit_legacy_group')::uuid,
  '40000000-0000-0000-0000-000000000101');

set local "request.jwt.claim.sub" = '31000000-0000-0000-0000-000000000004';
select ok((
  select created_by = auth.uid() from public.diary_groups where id = current_setting('test.exit_legacy_group')::uuid
), 'An ownerless legacy group gives its earliest remaining member invitation ownership after an exit');
select ok((
  select count(*) = 2
    and count(*) filter (where id = current_setting('test.exit_group')::uuid and writer_name = 'Writer 3' and not is_my_turn) = 1
    and count(*) filter (where id = current_setting('test.exit_legacy_group')::uuid and writer_name is null and not is_my_turn) = 1
  from public.read_my_diary_groups()
), 'One request returns the independent turn status for all of a reader’s groups');

reset role;
select * from finish();
rollback;
