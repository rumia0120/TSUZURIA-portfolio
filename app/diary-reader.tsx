"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import type { FormEvent } from "react";
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import type { SupabaseClient, User } from "@supabase/supabase-js";
import { supabase } from "./diary-client";
import { clearInviteLink, GroupMembershipForm, InviteLink, isInviteToken, LeaveGroup, readInviteToken, subscribeToInviteLink } from "./diary-groups";
import { DiaryReactions } from "./diary-reactions";
import { TurnEmailPreference } from "./turn-email-preference";

type Selection = { groupId?: string; entryId?: string; writing?: boolean };
type Turn = { writer_name: string | null; is_my_turn: boolean };
type Group = { id: string; name: string; created_by: string | null };
type Entry = { id: string; body: string; shared_at: string };
type Draft = Pick<Entry, "id" | "body">;
type View =
  | { kind: "groups"; groups: Pick<Group, "id" | "name">[] }
  | { kind: "entries"; group: Group; entries: Entry[]; turn: Turn; membershipId: string }
  | { kind: "write"; group: Group; draft: Draft | null }
  | { kind: "entry"; group: Group; entry: Entry }
  | { kind: "missing" };

const date = new Intl.DateTimeFormat("ja-JP", {
  dateStyle: "long",
  timeZone: "Asia/Tokyo",
});
const uuid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;

async function loadView(client: SupabaseClient, { groupId, entryId, writing }: Selection): Promise<View> {
  if (!groupId) {
    const { data, error } = await client.from("diary_groups").select("id, name").order("name");
    if (error) throw error;
    return { kind: "groups", groups: data };
  }
  if (!uuid.test(groupId) || (entryId && !uuid.test(entryId))) return { kind: "missing" };

  const group = await client.from("diary_groups").select("id, name, created_by").eq("id", groupId).maybeSingle();
  if (group.error) throw group.error;
  if (!group.data) return { kind: "missing" };

  const turn = entryId ? null : await client.rpc("read_diary_turn", { target_group: groupId }).maybeSingle<Turn>();
  if (turn?.error) throw turn.error;
  if (!entryId && !turn?.data) return { kind: "missing" };
  if (writing) {
    if (!turn?.data?.is_my_turn) return { kind: "missing" };
    // RLS limits draft reads to the signed-in author.
    const { data, error } = await client.from("diary_entries").select("id, body")
      .eq("group_id", groupId).is("shared_at", null).maybeSingle();
    if (error) throw error;
    return { kind: "write", group: group.data, draft: data };
  }

  // RLS checks the signed-in reader's membership and when the entry was shared.
  const shared = client.from("diary_entries").select("id, body, shared_at")
    .eq("group_id", groupId).not("shared_at", "is", null);
  if (entryId) {
    const { data, error } = await shared.eq("id", entryId).maybeSingle();
    if (error) throw error;
    return data ? { kind: "entry", group: group.data, entry: data } : { kind: "missing" };
  }
  const [entries, membership] = await Promise.all([
    shared.order("shared_at", { ascending: false }),
    client.from("group_members").select("id").eq("group_id", groupId).is("left_at", null).maybeSingle(),
  ]);
  if (entries.error) throw entries.error;
  if (membership.error) throw membership.error;
  if (!turn?.data || !membership.data) return { kind: "missing" };
  return { kind: "entries", group: group.data, entries: entries.data, turn: turn.data, membershipId: membership.data.id };
}

function Login({ client, inviteToken }: { client: SupabaseClient; inviteToken: string | null }) {
  const invited = isInviteToken(inviteToken);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [showRegistrationGuide, setShowRegistrationGuide] = useState(false);
  const [registering, setRegistering] = useState(false);

  async function submitCredentials(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setPending(true);
    setError("");
    setShowRegistrationGuide(false);
    try {
      const credentials = {
        email: String(form.get("email")).trim(),
        password: String(form.get("password")),
      };
      if (registering) {
        const { data, error } = await client.auth.signUp({
          ...credentials,
          options: { emailRedirectTo: `${window.location.origin}/` },
        });
        const alreadyRegistered = error?.code === "user_already_exists" || error?.code === "email_exists";
        if (error && !alreadyRegistered) {
          setError("アカウントを作成できませんでした。入力内容を確認してください。");
        } else if (!data?.session) {
          setShowRegistrationGuide(true);
        }
      } else {
        const { error } = await client.auth.signInWithPassword(credentials);
        if (error) setError("ログインできませんでした。入力内容を確認してください。");
      }
    } catch {
      setError("接続できませんでした。少し待ってからお試しください。");
    } finally {
      setPending(false);
    }
  }

  return (
    <main className="preview-shell welcome">
      <section className="login-panel" aria-labelledby="login-title">
        <div className="brand">Tsuzuria</div>
        <h1 id="login-title">{registering ? "新規登録" : "ログイン"}</h1>
        {invited && !registering && <p className="muted">グループに参加するためにログインしてください。</p>}
        <form className="reader-login" onSubmit={submitCredentials}>
          <label>メールアドレス<input name="email" type="email" autoComplete="username" required /></label>
          <label>パスワード<input key={registering ? "new-password" : "current-password"} name="password" type="password" autoComplete={registering ? "new-password" : "current-password"} required /></label>
          {error && <p role="alert">{error}</p>}
          {showRegistrationGuide && (
            <div role="status">
              <p>確認メールが届いたら、リンクを開いて登録を完了してください。</p>
              <p>すでにアカウントをお持ちの場合は、そのままログインできます。</p>
              {invited && <p>メール確認後は、元の招待リンクからグループに参加できます。</p>}
            </div>
          )}
          <button type="submit" disabled={pending}>
            {registering ? (pending ? "作成中…" : "アカウントを作る") : (pending ? "ログイン中…" : "ログイン")}
          </button>
        </form>
        <div className="draft-actions">
          <button className="back-link" type="button" disabled={pending} onClick={() => {
            setRegistering((previous) => !previous);
            setError("");
            setShowRegistrationGuide(false);
          }}>{registering ? (showRegistrationGuide ? "ログインへ" : "ログインに戻る") : "新規登録"}</button>
          {invited && (
            <button className="back-link" type="button" disabled={pending} onClick={clearInviteLink}>招待を閉じる</button>
          )}
        </div>
        {inviteToken !== null && !invited && (
          <div className="invite-panel">
            <p role="alert">この招待リンクは使えません。招待した人に新しいリンクをお願いしてください。</p>
            <button className="back-link" type="button" onClick={clearInviteLink}>招待を閉じる</button>
          </div>
        )}
      </section>
    </main>
  );
}

function DiaryDraft({ client, group, draft }: { client: SupabaseClient; group: Group; draft: Draft | null }) {
  const router = useRouter();
  const groupLink = `/?group=${group.id}`;
  const [body, setBody] = useState(draft?.body ?? "");
  const [savedDraft, setSavedDraft] = useState(draft);
  const [status, setStatus] = useState<"idle" | "saving" | "saved" | "publishing">("idle");
  const [errorMessage, setErrorMessage] = useState("");
  const requestPending = useRef(false);
  const editorActive = useRef(false);
  const busy = status === "saving" || status === "publishing";
  const canPublish = Boolean(savedDraft && savedDraft.body === body && body.trim());
  const saveFailure = "下書きを保存できませんでした。もう一度お試しください。";

  useEffect(() => {
    editorActive.current = true;
    return () => { editorActive.current = false; };
  }, []);

  async function saveDraft(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (requestPending.current || !body.trim()) return;

    requestPending.current = true;
    setStatus("saving");
    setErrorMessage("");
    try {
      const { data, error } = await client.rpc("save_diary_draft", {
        target_group: group.id,
        draft_body: body,
      });
      if (error || typeof data !== "string") {
        setErrorMessage(error?.code === "42501"
          ? "下書きを保存できませんでした。日記一覧で今の番を確認してください。"
          : saveFailure);
        setStatus("idle");
      } else {
        setSavedDraft({ id: data, body });
        setStatus("saved");
      }
    } catch {
      setErrorMessage(saveFailure);
      setStatus("idle");
    } finally {
      requestPending.current = false;
    }
  }

  async function publishDraft() {
    if (requestPending.current || !canPublish || !savedDraft) return;

    requestPending.current = true;
    setStatus("publishing");
    setErrorMessage("");
    const failure = "日記を渡せませんでした。日記一覧で今の番と共有状況を確認してください。";
    try {
      const { data, error } = await client.rpc("publish_diary_draft", {
        target_group: group.id,
        target_draft: savedDraft.id,
        expected_body: savedDraft.body,
      });
      if (!error && typeof data === "string") {
        // Changing the writing selection remounts DiaryContent and loads the latest entries and turn.
        if (editorActive.current) router.replace(groupLink);
        return;
      }
      switch (error?.code) {
        case "40001":
          setSavedDraft(null);
          setErrorMessage("保存済みの本文が変わりました。今の本文を保存し直してから渡してください。");
          break;
        case "P0002":
          setErrorMessage("この下書きを渡せませんでした。日記一覧で共有状況を確認してください。");
          break;
        case "42501":
          setErrorMessage("日記を渡せませんでした。日記一覧で今の番を確認してください。");
          break;
        case "22023":
          setErrorMessage("次に日記を書くメンバーがいないため、渡せませんでした。");
          break;
        default:
          setErrorMessage(failure);
      }
    } catch {
      setErrorMessage(failure);
    }
    requestPending.current = false;
    setStatus("idle");
  }

  return (
    <>
      <Link className="back-link" href={groupLink}>← 日記一覧</Link>
      <article className="paper">
        <p className="paper-label">{group.name}</p>
        <h1>日記を書く</h1>
        <form onSubmit={saveDraft}>
          <label className="write-label" htmlFor="diary-body">本文</label>
          <textarea
            id="diary-body"
            className="paper-body write-body"
            rows={6}
            aria-describedby="write-note"
            value={body}
            readOnly={busy}
            onChange={(event) => {
              setBody(event.target.value);
              setErrorMessage("");
              setStatus("idle");
            }}
          />
          <p id="write-note" className="muted">下書きは自分だけが読めます。</p>
          <div className="draft-actions">
            <button className="write-link draft-save" type="submit" disabled={busy || !body.trim()}>
              {status === "saving" ? "保存中…" : "下書きを保存"}
            </button>
            <button
              className="write-link"
              type="button"
              aria-describedby="publish-note"
              disabled={busy || !canPublish}
              onClick={publishDraft}
            >
              {status === "publishing" ? "渡しています…" : "次の人に渡す"}
            </button>
          </div>
          <p id="publish-note" className="muted publish-note">
            {canPublish ? "保存した本文をグループに共有し、次の人に番を渡します。" : "本文を保存すると、次の人に渡せます。"}
          </p>
          <p className="muted" role="status">{status === "saved" ? "下書きを保存しました。" : ""}</p>
          {errorMessage && <p className="draft-error" role="alert">{errorMessage}</p>}
        </form>
      </article>
    </>
  );
}

function DiaryContent({ client, user, groupId, entryId, writing }: Selection & { client: SupabaseClient; user: User }) {
  const router = useRouter();
  const [creatingGroup, setCreatingGroup] = useState(false);
  const [leftGroup, setLeftGroup] = useState(false);
  const [view, setView] = useState<View | null>(null);
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    if (leftGroup) return;
    let active = true;
    loadView(client, { groupId, entryId, writing }).then(
      (next) => { if (active) setView(next); },
      () => { if (active) setFailed(true); },
    );
    return () => { active = false; };
  }, [client, groupId, entryId, writing, attempt, leftGroup]);

  if (leftGroup) return <p role="status">グループを退出しました。</p>;
  if (failed) return <><p role="alert">日記を読み込めませんでした。</p>
    <button className="back-link" onClick={() => { setFailed(false); setAttempt((n) => n + 1); }}>再試行</button></>;
  if (!view) return <p role="status">読み込み中…</p>;
  if (view.kind === "missing") return <><h1>日記を開けません</h1><Link className="back-link" href="/">マイグループへ</Link></>;
  if (view.kind === "groups" && creatingGroup) {
    return <GroupMembershipForm client={client} user={user} onCancel={() => setCreatingGroup(false)} />;
  }
  if (view.kind === "groups") return (
    <>
      <div className="group-header">
        <h1>マイグループ</h1>
        <button className="write-link" type="button" onClick={() => setCreatingGroup(true)}>グループを作る</button>
      </div>
      {view.groups.length === 0 && <p className="muted">参加中のグループはありません。</p>}
      <div className="group-list">
        {view.groups.map((group) => (
          <Link className="group-card" key={group.id} href={`/?group=${group.id}`}>
            <span className="notebook-icon" aria-hidden="true" />
            <strong className="row-copy">{group.name}</strong>
            <span className="chevron" aria-hidden="true">›</span>
          </Link>
        ))}
      </div>
      <TurnEmailPreference client={client} hasVerifiedEmail={Boolean(user.email && user.email_confirmed_at)} />
    </>
  );

  const groupLink = `/?group=${view.group.id}`;
  if (view.kind === "write") {
    return <DiaryDraft client={client} group={view.group} draft={view.draft} />;
  }
  if (view.kind === "entries") return (
    <>
      <Link className="back-link" href="/">← マイグループ</Link>
      <h1>{view.group.name}</h1>
      <section className="turn-summary" aria-label="日記の順番">
        <p>{view.turn.is_my_turn ? "あなたの番です" : view.turn.writer_name ? `今は${view.turn.writer_name}さんの番です` : "メンバーの参加を待っています"}</p>
        {view.turn.is_my_turn && <Link className="write-link" href={`${groupLink}&write=1`}>日記を書く</Link>}
      </section>
      {!view.turn.is_my_turn && !view.turn.writer_name && (
        <div className="group-waiting">
          <p className="muted">3人そろうと日記を回せます。</p>
          <button className="back-link" type="button" onClick={() => setAttempt((n) => n + 1)}>
            参加状況を更新
          </button>
        </div>
      )}
      {view.group.created_by === user.id && <InviteLink client={client} groupId={view.group.id} />}
      <h2 className="list-heading">日記一覧 <span>{view.entries.length}件</span></h2>
      {view.entries.length === 0 && <p className="muted">共有された日記はまだありません。</p>}
      <ul className="entry-list">
        {view.entries.map((entry) => (
          <li key={entry.id}>
            <Link className="entry-row" href={`${groupLink}&entry=${entry.id}`}>
              <time className="entry-meta" dateTime={entry.shared_at}>{date.format(new Date(entry.shared_at))}</time>
              <span className="entry-excerpt">{entry.body}</span>
              <span className="chevron" aria-hidden="true">›</span>
            </Link>
          </li>
        ))}
      </ul>
      <LeaveGroup
        client={client}
        groupId={view.group.id}
        groupName={view.group.name}
        membershipId={view.membershipId}
        onLeft={() => {
          setLeftGroup(true);
          setView(null);
          router.replace("/");
        }}
      />
    </>
  );

  return (
    <>
      <Link className="back-link" href={groupLink}>← 日記一覧</Link>
      <article className="paper">
        <p className="paper-label">{view.group.name}</p>
        <h1><time dateTime={view.entry.shared_at}>{date.format(new Date(view.entry.shared_at))}</time>の日記</h1>
        <div className="paper-body reader-body">{view.entry.body}</div>
        <DiaryReactions client={client} entryId={view.entry.id} userId={user.id} />
      </article>
    </>
  );
}

export default function DiaryReader({ groupId, entryId, writing }: Selection) {
  const inviteToken = useSyncExternalStore(subscribeToInviteLink, readInviteToken, () => null);
  const [user, setUser] = useState<User | null | undefined>();
  const [signingOut, setSigningOut] = useState(false);
  const [logoutError, setLogoutError] = useState(false);
  const client = supabase;

  useEffect(() => {
    if (!client) return;
    const { data } = client.auth.onAuthStateChange((_event, session) => setUser(session?.user ?? null));
    return () => data.subscription.unsubscribe();
  }, [client]);

  if (!client) return <main className="preview-shell">Supabase の接続設定を確認してください。</main>;
  if (user === undefined) return <main className="preview-shell"><p role="status">ログイン状態を確認中…</p></main>;
  if (!user) return <Login key={inviteToken} client={client} inviteToken={inviteToken} />;

  async function signOut() {
    if (!client) return;
    setSigningOut(true);
    setLogoutError(false);
    try {
      const { error } = await client.auth.signOut({ scope: "local" });
      if (error) setLogoutError(true);
    } catch {
      setLogoutError(true);
    } finally {
      setSigningOut(false);
    }
  }

  return (
    <div className="preview-shell">
      <header className="app-header">
        <Link className="brand" href="/">Tsuzuria</Link>
        <button className="switch-account" onClick={signOut} disabled={signingOut}>ログアウト</button>
      </header>
      <main className="app-content">
        {logoutError && <p role="alert">ログアウトできませんでした。もう一度お試しください。</p>}
        {inviteToken !== null
          ? <GroupMembershipForm key={JSON.stringify([user.id, inviteToken])} client={client} user={user} inviteToken={inviteToken} onCancel={clearInviteLink} />
          : <DiaryContent key={JSON.stringify([user.id, groupId, entryId, writing])} client={client} user={user} groupId={groupId} entryId={entryId} writing={writing} />}
      </main>
    </div>
  );
}
