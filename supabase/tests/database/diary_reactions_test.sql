begin;

create extension if not exists pgtap with schema extensions;
set local search_path to public, extensions;
select plan(31);

insert into auth.users (id, email)
select ('61000000-0000-0000-0000-00000000000' || member)::uuid,
  'diary-reaction-test-' || member || '@example.invalid'
from generate_series(1, 5) as fixtures(member);

-- Use identical display names to exercise ownership by user ID.
insert into public.profiles (id, display_name)
select ('61000000-0000-0000-0000-00000000000' || member)::uuid, 'Diary member'
from generate_series(1, 5) as fixtures(member);

set local "test.reaction_group" = '60000000-0000-0000-0000-000000000001';
set local "test.reaction_entry" = '63000000-0000-0000-0000-000000000001';
set local "test.reaction_draft" = '63000000-0000-0000-0000-000000000002';

insert into public.diary_groups (id, name, created_by) values
  (current_setting('test.reaction_group')::uuid, 'Reaction test notebook', '61000000-0000-0000-0000-000000000001'),
  ('60000000-0000-0000-0000-000000000002', 'Other notebook', '61000000-0000-0000-0000-000000000005');

insert into public.group_members (id, group_id, user_id, turn_position, joined_at)
select ('62000000-0000-0000-0000-00000000000' || member)::uuid,
  current_setting('test.reaction_group')::uuid,
  ('61000000-0000-0000-0000-00000000000' || member)::uuid,
  member, now() - case when member = 4 then interval '10 minutes' else interval '2 days' end
from generate_series(1, 4) as fixtures(member);

insert into public.group_members (id, group_id, user_id, turn_position)
values ('62000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000002',
  '61000000-0000-0000-0000-000000000005', 1);

update public.diary_groups set current_member_id = '62000000-0000-0000-0000-000000000001'
where id = current_setting('test.reaction_group')::uuid;

insert into public.diary_entries (id, group_id, author_member_id, body, created_at, shared_at) values
  (current_setting('test.reaction_entry')::uuid, current_setting('test.reaction_group')::uuid,
    '62000000-0000-0000-0000-000000000001', 'Earlier shared diary', now() - interval '1 day', now() - interval '1 hour'),
  (current_setting('test.reaction_draft')::uuid, current_setting('test.reaction_group')::uuid,
    '62000000-0000-0000-0000-000000000001', 'Diary to share later', now(), null);

select ok(
  not has_function_privilege('anon', 'public.set_diary_reaction(uuid, text)', 'execute'),
  'Anonymous callers cannot execute the reaction function'
);
select ok(
  not has_any_column_privilege('authenticated', 'public.diary_reactions', 'insert')
  and not has_any_column_privilege('authenticated', 'public.diary_reactions', 'update')
  and not has_table_privilege('authenticated', 'public.diary_reactions', 'delete'),
  'Authenticated callers cannot mutate reactions directly'
);

set local role authenticated;
set local "request.jwt.claims" = '{}';
set local "request.jwt.claim.sub" = '';
select throws_ok($$
  select public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, 'heart')
$$, '42501', null, 'Setting a reaction requires an authenticated user');

set local "request.jwt.claim.sub" = '61000000-0000-0000-0000-000000000001';
select throws_ok($$
  select public.set_diary_reaction('63000000-0000-0000-0000-000000000003', 'heart')
$$, '42501', null, 'An unknown entry cannot receive reactions');
select throws_ok($$
  select public.set_diary_reaction(current_setting('test.reaction_draft')::uuid, 'heart')
$$, '42501', null, 'A draft cannot receive a reaction even from its author');
select throws_ok($$
  select public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, 'invalid-kind')
$$, '22023', null, 'Only the supported reaction kinds can be saved');
select ok(
  public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, 'heart') = 'heart',
  'An author can react to their own shared diary'
);

set local "request.jwt.claim.sub" = '61000000-0000-0000-0000-000000000002';
select ok(
  public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, 'smile') = 'smile',
  'A participant can react before their writing turn'
);
select ok(
  public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, 'smile') = 'smile',
  'Retrying the same selection returns the selected kind'
);
select ok(
  public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, 'support') = 'support',
  'Selecting another kind changes the saved reaction'
);
select ok((
  select count(*) = 2 and count(*) filter (where user_id = auth.uid() and kind = 'support') = 1
    and count(*) filter (where user_id <> auth.uid() and kind = 'heart') = 1
  from public.diary_reactions where entry_id = current_setting('test.reaction_entry')::uuid
), 'Each user has exactly one reaction and changing one does not affect another');
select ok(
  public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, null) is null,
  'A null kind clears the caller’s reaction'
);
select ok(
  public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, null) is null,
  'Clearing the reaction twice succeeds'
);
select ok((
  select count(*) = 1 and bool_and(user_id <> auth.uid() and kind = 'heart')
  from public.diary_reactions where entry_id = current_setting('test.reaction_entry')::uuid
), 'Clearing a selection leaves other users’ reactions untouched');
select ok(
  public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, 'support') = 'support',
  'A participant can react again after clearing their selection'
);

set local "request.jwt.claim.sub" = '61000000-0000-0000-0000-000000000005';
select throws_ok($$
  select public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, 'smile')
$$, '42501', null, 'Someone from another group cannot react using the entry ID');
select ok(not exists (
  select 1 from public.diary_reactions where entry_id = current_setting('test.reaction_entry')::uuid
), 'Someone from another group cannot read reactions using the entry ID');

set local "request.jwt.claim.sub" = '61000000-0000-0000-0000-000000000004';
select throws_ok($$
  select public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, 'smile')
$$, '42501', null, 'A late joiner cannot react to an entry shared before they joined');
select throws_ok($$
  select public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, null)
$$, '42501', null, 'Clearing a reaction also requires a readable shared entry');
select ok(not exists (
  select 1 from public.diary_reactions where entry_id = current_setting('test.reaction_entry')::uuid
), 'A late joiner cannot read reactions on an entry shared before they joined');

set local "request.jwt.claim.sub" = '61000000-0000-0000-0000-000000000002';
select public.leave_diary_group(current_setting('test.reaction_group')::uuid, '62000000-0000-0000-0000-000000000002');
select throws_ok($$
  select public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, 'heart')
$$, '42501', null, 'A former member can no longer react');

set local "request.jwt.claim.sub" = '61000000-0000-0000-0000-000000000001';
select ok((
  select count(*) = 1 and bool_and(kind = 'heart' and user_id = auth.uid())
  from public.diary_reactions where entry_id = current_setting('test.reaction_entry')::uuid
), 'Upon exit only the former member’s reaction becomes invisible');
do $$
begin
  perform set_config('test.reaction_invite', public.create_diary_invite(current_setting('test.reaction_group')::uuid), true);
end;
$$;

set local "request.jwt.claim.sub" = '61000000-0000-0000-0000-000000000002';
select ok(
  public.accept_diary_invite(current_setting('test.reaction_invite'), null) = current_setting('test.reaction_group')::uuid,
  'A former member can rejoin with a fresh invitation'
);
select throws_ok($$
  select public.set_diary_reaction(current_setting('test.reaction_entry')::uuid, 'heart')
$$, '42501', null, 'Rejoining does not recover the right to react to earlier entries');

set local "request.jwt.claim.sub" = '61000000-0000-0000-0000-000000000001';
select ok((
  select count(*) = 1 and bool_and(kind = 'heart' and user_id = auth.uid())
  from public.diary_reactions where entry_id = current_setting('test.reaction_entry')::uuid
), 'Rejoining does not restore visibility of the former membership’s reaction');
select ok(
  public.publish_diary_draft(current_setting('test.reaction_group')::uuid,
    current_setting('test.reaction_draft')::uuid, 'Diary to share later') = current_setting('test.reaction_draft')::uuid,
  'The current writer can share a diary after the former member rejoins'
);

set local "request.jwt.claim.sub" = '61000000-0000-0000-0000-000000000002';
select ok(
  public.set_diary_reaction(current_setting('test.reaction_draft')::uuid, 'smile') = 'smile',
  'The new membership can react to an entry shared after rejoining'
);

set local "request.jwt.claim.sub" = '61000000-0000-0000-0000-000000000003';
select ok((
  select count(*) = 1 and bool_and(kind = 'smile' and user_id = '61000000-0000-0000-0000-000000000002')
  from public.diary_reactions where entry_id = current_setting('test.reaction_draft')::uuid
), 'The rejoined member’s new reaction is visible to another reader');

set local "request.jwt.claim.sub" = '61000000-0000-0000-0000-000000000001';
select public.leave_diary_group(current_setting('test.reaction_group')::uuid, '62000000-0000-0000-0000-000000000001');

set local "request.jwt.claim.sub" = '61000000-0000-0000-0000-000000000003';
select ok(not exists (
  select 1 from public.diary_reactions where entry_id = current_setting('test.reaction_draft')::uuid
), 'When the diary author leaves, all reactions to the hidden diary become invisible');
select throws_ok($$
  select public.set_diary_reaction(current_setting('test.reaction_draft')::uuid, 'smile')
$$, '42501', null, 'A remaining member cannot react once the author has left');

reset role;
select ok((
  select count(*) = 2 and count(*) filter (where reactor.left_at is null) = 1
    and count(*) filter (where reaction.member_id = '62000000-0000-0000-0000-000000000002') = 1
  from public.diary_reactions reaction
  join public.group_members reactor on reactor.id = reaction.member_id and reactor.user_id = reaction.user_id
  where reaction.user_id = '61000000-0000-0000-0000-000000000002'
), 'Reactions from the same account retain distinct old and current membership IDs');

select * from finish();
rollback;
