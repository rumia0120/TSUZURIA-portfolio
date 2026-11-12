create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 80)
);

create table public.diary_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 100),
  current_member_id uuid
);

create table public.group_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.diary_groups (id),
  user_id uuid not null references public.profiles (id),
  turn_position smallint not null check (turn_position between 1 and 5),
  joined_at timestamptz not null default now(),
  left_at timestamptz check (left_at >= joined_at),
  unique (group_id, id)
);

create unique index group_members_active_user
  on public.group_members (group_id, user_id) where left_at is null;
create unique index group_members_active_position
  on public.group_members (group_id, turn_position) where left_at is null;
create index group_members_active_by_user
  on public.group_members (user_id, group_id) where left_at is null;

alter table public.diary_groups
  add foreign key (id, current_member_id)
  references public.group_members (group_id, id);

create table public.diary_entries (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  author_member_id uuid not null,
  body text not null check (btrim(body) <> ''),
  created_at timestamptz not null default now(),
  shared_at timestamptz check (shared_at >= created_at),
  foreign key (group_id, author_member_id)
    references public.group_members (group_id, id)
);

create index diary_entries_group_shared
  on public.diary_entries (group_id, shared_at desc) where shared_at is not null;
create index diary_entries_author on public.diary_entries (author_member_id);

create table public.diary_reactions (
  entry_id uuid not null references public.diary_entries (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('heart', 'smile', 'support')),
  primary key (entry_id, user_id)
);

alter table public.profiles enable row level security;
alter table public.diary_groups enable row level security;
alter table public.group_members enable row level security;
alter table public.diary_entries enable row level security;
alter table public.diary_reactions enable row level security;

revoke all on public.profiles, public.diary_groups, public.group_members,
  public.diary_entries, public.diary_reactions from public, anon, authenticated;
grant select on public.profiles, public.diary_groups, public.group_members,
  public.diary_entries, public.diary_reactions to authenticated;
grant insert (entry_id, kind), update (kind), delete
  on public.diary_reactions to authenticated;

create policy profiles_read_own on public.profiles
  for select to authenticated using (id = (select auth.uid()));

create policy group_members_read_own_active on public.group_members
  for select to authenticated
  using (user_id = (select auth.uid()) and left_at is null);

create policy diary_groups_read_as_member on public.diary_groups
  for select to authenticated using (
    exists (select 1 from public.group_members m where m.group_id = diary_groups.id)
  );

-- The membership policy limits this lookup to the reader's active membership.
create policy diary_entries_read_as_member on public.diary_entries
  for select to authenticated using (
    exists (
      select 1 from public.group_members m
      where m.group_id = diary_entries.group_id
        and (
          diary_entries.shared_at >= m.joined_at
          or (diary_entries.shared_at is null and diary_entries.author_member_id = m.id)
        )
    )
  );

create policy diary_reactions_read_on_shared_entry on public.diary_reactions
  for select to authenticated using (
    exists (
      select 1 from public.diary_entries e
      where e.id = diary_reactions.entry_id and e.shared_at is not null
    )
  );

create policy diary_reactions_manage_own on public.diary_reactions
  for all to authenticated
  using (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.diary_entries e
      where e.id = diary_reactions.entry_id and e.shared_at is not null
    )
  )
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.diary_entries e
      where e.id = diary_reactions.entry_id and e.shared_at is not null
    )
  );
