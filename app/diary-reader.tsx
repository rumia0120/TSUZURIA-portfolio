"use client";

import Link from "next/link";
import type { FormEvent } from "react";
import { useEffect, useState } from "react";
import type { SupabaseClient, User } from "@supabase/supabase-js";
import { supabase } from "./diary-client";

type Selection = { groupId?: string; entryId?: string; writing?: boolean };
type Turn = { writer_name: string | null; is_my_turn: boolean };
type Group = { id: string; name: string };
type Entry = { id: string; body: string; shared_at: string };
type View =
  | { kind: "groups"; groups: Group[] }
  | { kind: "entries"; group: Group; entries: Entry[]; turn: Turn }
  | { kind: "write"; group: Group; draftBody: string }
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

  const group = await client.from("diary_groups").select("id, name").eq("id", groupId).maybeSingle();
  if (group.error) throw group.error;
  if (!group.data) return { kind: "missing" };

  const turn = entryId ? null : await client.rpc("read_diary_turn", { target_group: groupId }).maybeSingle<Turn>();
  if (turn?.error) throw turn.error;
  if (!entryId && !turn?.data) return { kind: "missing" };
  if (writing) {
    if (!turn?.data?.is_my_turn) return { kind: "missing" };
    // RLS limits draft reads to the signed-in author.
    const { data, error } = await client.from("diary_entries").select("body")
      .eq("group_id", groupId).is("shared_at", null).maybeSingle();
    if (error) throw error;
    return { kind: "write", group: group.data, draftBody: data?.body ?? "" };
  }

  // RLS checks the signed-in reader's membership and when the entry was shared.
  const shared = client.from("diary_entries").select("id, body, shared_at")
    .eq("group_id", groupId).not("shared_at", "is", null);
  if (entryId) {
    const { data, error } = await shared.eq("id", entryId).maybeSingle();
    if (error) throw error;
    return data ? { kind: "entry", group: group.data, entry: data } : { kind: "missing" };
  }
  const { data, error } = await shared.order("shared_at", { ascending: false });
  if (error) throw error;
  if (!turn?.data) return { kind: "missing" };
  return { kind: "entries", group: group.data, entries: data, turn: turn.data };
}

function Login({ client }: { client: SupabaseClient }) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");

  async function signIn(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setPending(true);
    setError("");
    try {
      const result = await client.auth.signInWithPassword({
        email: String(form.get("email")).trim(),
        password: String(form.get("password")),
      });
      if (result.error) setError("ログインできませんでした。入力内容を確認してください。");
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
        <h1 id="login-title">ログイン</h1>
        <form className="reader-login" onSubmit={signIn}>
          <label>メールアドレス<input name="email" type="email" autoComplete="username" required /></label>
          <label>パスワード<input name="password" type="password" autoComplete="current-password" required /></label>
          {error && <p role="alert">{error}</p>}
          <button type="submit" disabled={pending}>{pending ? "ログイン中…" : "ログイン"}</button>
        </form>
      </section>
    </main>
  );
}

function DiaryDraft({ client, group, initialBody }: { client: SupabaseClient; group: Group; initialBody: string }) {
  const [body, setBody] = useState(initialBody);
  const [status, setStatus] = useState<"idle" | "saving" | "saved">("idle");
  const [errorMessage, setErrorMessage] = useState("");
  const saveFailure = "下書きを保存できませんでした。もう一度お試しください。";

  async function saveDraft(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (status === "saving" || !body.trim()) return;

    setStatus("saving");
    setErrorMessage("");
    try {
      const { error } = await client.rpc("save_diary_draft", {
        target_group: group.id,
        draft_body: body,
      });
      if (error) {
        setErrorMessage(error.code === "42501"
          ? "下書きを保存できませんでした。日記一覧で今の番を確認してください。"
          : saveFailure);
        setStatus("idle");
      } else {
        setStatus("saved");
      }
    } catch {
      setErrorMessage(saveFailure);
      setStatus("idle");
    }
  }

  return (
    <>
      <Link className="back-link" href={`/?group=${group.id}`}>← 日記一覧</Link>
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
            readOnly={status === "saving"}
            onChange={(event) => {
              setBody(event.target.value);
              setErrorMessage("");
              setStatus("idle");
            }}
          />
          <p id="write-note" className="muted">下書きは自分だけが読めます。</p>
          <div className="draft-actions">
            <button className="write-link" type="submit" disabled={status === "saving" || !body.trim()}>
              {status === "saving" ? "保存中…" : "下書きを保存"}
            </button>
            <p className="muted" role="status">{status === "saved" ? "下書きを保存しました。" : ""}</p>
          </div>
          {errorMessage && <p className="draft-error" role="alert">{errorMessage}</p>}
        </form>
      </article>
    </>
  );
}

function DiaryContent({ client, groupId, entryId, writing }: Selection & { client: SupabaseClient }) {
  const [view, setView] = useState<View | null>(null);
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    let active = true;
    loadView(client, { groupId, entryId, writing }).then(
      (next) => { if (active) setView(next); },
      () => { if (active) setFailed(true); },
    );
    return () => { active = false; };
  }, [client, groupId, entryId, writing, attempt]);

  if (failed) return <><p role="alert">日記を読み込めませんでした。</p>
    <button className="back-link" onClick={() => { setFailed(false); setAttempt((n) => n + 1); }}>再試行</button></>;
  if (!view) return <p role="status">読み込み中…</p>;
  if (view.kind === "missing") return <><h1>日記を開けません</h1><Link className="back-link" href="/">マイグループへ</Link></>;
  if (view.kind === "groups") return (
    <>
      <h1>マイグループ</h1>
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
    </>
  );

  const groupLink = `/?group=${view.group.id}`;
  if (view.kind === "write") {
    return <DiaryDraft client={client} group={view.group} initialBody={view.draftBody} />;
  }
  if (view.kind === "entries") return (
    <>
      <Link className="back-link" href="/">← マイグループ</Link>
      <h1>{view.group.name}</h1>
      <section className="turn-summary" aria-label="日記の順番">
        <p>{view.turn.is_my_turn ? "あなたの番です" : view.turn.writer_name ? `今は${view.turn.writer_name}さんの番です` : "まだ番は決まっていません"}</p>
        {view.turn.is_my_turn && <Link className="write-link" href={`${groupLink}&write=1`}>日記を書く</Link>}
      </section>
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
    </>
  );

  return (
    <>
      <Link className="back-link" href={groupLink}>← 日記一覧</Link>
      <article className="paper">
        <p className="paper-label">{view.group.name}</p>
        <h1><time dateTime={view.entry.shared_at}>{date.format(new Date(view.entry.shared_at))}</time>の日記</h1>
        <div className="paper-body reader-body">{view.entry.body}</div>
      </article>
    </>
  );
}

export default function DiaryReader({ groupId, entryId, writing }: Selection) {
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
  if (!user) return <Login client={client} />;

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
        <DiaryContent key={JSON.stringify([user.id, groupId, entryId, writing])} client={client} groupId={groupId} entryId={entryId} writing={writing} />
      </main>
    </div>
  );
}
