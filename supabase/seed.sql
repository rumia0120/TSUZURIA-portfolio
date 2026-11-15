-- Fictional data for local Supabase only. These records have no login credentials.
insert into auth.users (id, email)
select ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       'demo-' || n || '@example.invalid'
from generate_series(1, 8) as n;

insert into public.profiles (id, display_name)
select ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, label
from unnest(array['あおい', 'はる', 'なぎ', 'りく', 'そら', 'ゆい', 'みなと', 'ひなた'])
  with ordinality as names(label, n);

insert into public.diary_groups (id, name) values
  ('10000000-0000-4000-8000-000000000001', '週末の交換日記'),
  ('10000000-0000-4000-8000-000000000002', '放課後の交換日記');

insert into public.group_members (id, group_id, user_id, turn_position, joined_at, left_at)
select ('20000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       ('10000000-0000-4000-8000-00000000000' || group_no)::uuid,
       ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       position, joined_at::timestamptz, left_at::timestamptz
from (values
  (1, 1, 1, '2026-11-01T00:00Z', null),
  (2, 1, 2, '2026-11-01T00:00Z', null),
  (3, 1, 3, '2026-11-01T00:00Z', null),
  (4, 1, 4, '2026-11-06T00:00Z', null),
  (5, 1, 4, '2026-11-01T00:00Z', '2026-11-05T00:00Z'),
  (6, 2, 1, '2026-11-01T00:00Z', null),
  (7, 2, 2, '2026-11-01T00:00Z', null),
  (8, 2, 3, '2026-11-01T00:00Z', null)
) as members(n, group_no, position, joined_at, left_at);

update public.diary_groups set current_member_id = '20000000-0000-4000-8000-000000000002'
where id = '10000000-0000-4000-8000-000000000001';
update public.diary_groups set current_member_id = '20000000-0000-4000-8000-000000000007'
where id = '10000000-0000-4000-8000-000000000002';

insert into public.diary_entries (id, group_id, author_member_id, body, created_at, shared_at) values
  ('30000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   '20000000-0000-4000-8000-000000000005', '帰り道で夕焼けを見た。',
   '2026-11-03T10:00Z', '2026-11-03T10:05Z'),
  ('30000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
   '20000000-0000-4000-8000-000000000001', '久しぶりに本を一冊読み終えた。',
   '2026-11-09T10:00Z', '2026-11-09T10:05Z'),
  ('30000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001',
   '20000000-0000-4000-8000-000000000002', '次の日記の下書き。',
   '2026-11-10T10:00Z', null),
  ('30000000-0000-4000-8000-000000000004', '10000000-0000-4000-8000-000000000002',
   '20000000-0000-4000-8000-000000000006', '新しいお茶を試した。',
   '2026-11-09T10:00Z', '2026-11-09T10:05Z');

insert into public.diary_reactions (entry_id, user_id, kind, member_id) values
  ('30000000-0000-4000-8000-000000000002', '00000000-0000-4000-8000-000000000003', 'heart',
   '20000000-0000-4000-8000-000000000003');
