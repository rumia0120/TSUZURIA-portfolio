-- Run only in a dedicated development project after creating these two confirmed
-- Auth users in the dashboard. Supply their passwords privately at login.
begin;

do $$
declare
  a uuid;
  b uuid;
  ga uuid := '10000000-0000-4000-8000-000000000011';
  gb uuid := '10000000-0000-4000-8000-000000000012';
  ma uuid := '20000000-0000-4000-8000-000000000011';
  mb uuid := '20000000-0000-4000-8000-000000000012';
begin
  select id into strict a from auth.users where email = 'reader-a@example.test' and email_confirmed_at is not null;
  select id into strict b from auth.users where email = 'reader-b@example.test' and email_confirmed_at is not null;

  insert into public.profiles (id, display_name) values (a, 'あおい'), (b, 'ゆい');
  insert into public.diary_groups (id, name) values (ga, '週末の交換日記'), (gb, '放課後の交換日記');
  insert into public.group_members (id, group_id, user_id, turn_position, joined_at)
    values (ma, ga, a, 1, now() - interval '2 days'), (mb, gb, b, 1, now() - interval '2 days');
  update public.diary_groups set current_member_id = ma where id = ga;
  update public.diary_groups set current_member_id = mb where id = gb;

  insert into public.diary_entries (id, group_id, author_member_id, body, created_at, shared_at) values
    ('30000000-0000-4000-8000-000000000011', ga, ma, '久しぶりに本を一冊読み終えた。', now(), now()),
    ('30000000-0000-4000-8000-000000000012', gb, mb, '新しいお茶を試した。', now(), now()),
    ('30000000-0000-4000-8000-000000000013', ga, ma, '参加前のテスト投稿。', now() - interval '3 days', now() - interval '3 days'),
    ('30000000-0000-4000-8000-000000000014', ga, ma, 'まだ共有していない下書き。', now(), null);
end
$$;

commit;
