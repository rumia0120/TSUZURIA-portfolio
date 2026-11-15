"use client";

import { useRouter } from "next/navigation";
import type { FormEvent } from "react";
import { useEffect, useRef, useState } from "react";
import type { SupabaseClient, User } from "@supabase/supabase-js";

const tokenPattern = /^[0-9a-f]{64}$/;
const groupIdPattern = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;

export function isInviteToken(token: string | null): boolean {
  return token !== null && tokenPattern.test(token);
}

export function readInviteToken() {
  return new URLSearchParams(window.location.hash.slice(1)).get("invite");
}

export function subscribeToInviteLink(callback: () => void) {
  window.addEventListener("hashchange", callback);
  return () => window.removeEventListener("hashchange", callback);
}

export function clearInviteLink() {
  if (readInviteToken() === null) return;
  window.history.replaceState(window.history.state, "", window.location.pathname + window.location.search);
  window.dispatchEvent(new Event("hashchange"));
}

function membershipError(code: string | undefined, joining: boolean) {
  if (!joining) {
    return code === "22023"
      ? "グループ名と表示名を確認してください。"
      : "グループを作成できませんでした。もう一度お試しください。";
  }

  switch (code) {
    case "P0002": return "この招待リンクは使えません。招待した人に新しいリンクをお願いしてください。";
    case "23514": return "グループが定員に達しています。";
    case "23505": return "このグループにはすでに参加しています。";
    case "22023": return "表示名を確認してください。";
    default: return "グループに参加できませんでした。もう一度お試しください。";
  }
}

type MembershipFormProps = {
  client: SupabaseClient;
  user: User;
  onCancel: () => void;
  inviteToken?: string;
};

export function GroupMembershipForm({ client, user, inviteToken, onCancel }: MembershipFormProps) {
  const router = useRouter();
  const [profile, setProfile] = useState<{ display_name: string } | null>();
  const [profileError, setProfileError] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const requestPending = useRef(false);
  const creationId = useRef<string | null>(null);
  const active = useRef(false);
  const joining = inviteToken !== undefined;

  useEffect(() => {
    let ignore = false;
    active.current = true;

    async function loadProfile() {
      try {
        const { data, error } = await client.from("profiles")
          .select("display_name").eq("id", user.id).maybeSingle();
        if (error) throw error;
        if (!ignore) setProfile(data);
      } catch {
        if (!ignore) setProfileError(true);
      }
    }
    if (!joining || tokenPattern.test(inviteToken)) void loadProfile();

    return () => {
      ignore = true;
      active.current = false;
    };
  }, [client, user.id, inviteToken, joining, attempt]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (requestPending.current || profile === undefined) return;

    const fields = new FormData(event.currentTarget);
    const displayName = profile?.display_name ?? String(fields.get("displayName") ?? "").trim();
    const groupName = String(fields.get("groupName") ?? "").trim();
    if (!displayName || (!joining && !groupName)) {
      setError(membershipError("22023", joining));
      return;
    }

    requestPending.current = true;
    setPending(true);
    setError("");
    let navigating = false;
    try {
      const { data, error } = joining
        ? await client.rpc("accept_diary_invite", { invite_token: inviteToken, display_name: displayName })
        : await client.rpc("create_diary_group", {
          group_name: groupName,
          display_name: displayName,
          creation_id: creationId.current ??= crypto.randomUUID(),
        });
      if (!active.current) return;
      if (error || typeof data !== "string" || !groupIdPattern.test(data)) {
        setError(membershipError(error?.code, joining));
        return;
      }

      if (joining) clearInviteLink();
      router.replace(`/?group=${data}`);
      navigating = true;
    } catch {
      if (active.current) setError(membershipError(undefined, joining));
    } finally {
      if (active.current && !navigating) {
        requestPending.current = false;
        setPending(false);
      }
    }
  }

  return (
    <section aria-labelledby="membership-title">
      <h1 id="membership-title">{joining ? "グループへの招待" : "グループを作る"}</h1>
      {joining && <p className="muted">{user.email ? `${user.email} で参加します。` : "ログイン中のアカウントで参加します。"}</p>}
      {joining && !tokenPattern.test(inviteToken) ? (
        <p role="alert" className="draft-error">{membershipError("P0002", true)}</p>
      ) : profileError ? (
        <>
          <p role="alert" className="draft-error">表示名を読み込めませんでした。</p>
          <button className="back-link" type="button" onClick={() => {
            setProfileError(false);
            setAttempt((value) => value + 1);
          }}>再試行</button>
        </>
      ) : profile === undefined ? (
        <p className="muted" role="status">読み込み中…</p>
      ) : (
        <form className="reader-login group-form" onSubmit={submit}>
          {!joining && <label>グループ名<input name="groupName" maxLength={100} required /></label>}
          {!profile && <label>表示名<input name="displayName" autoComplete="nickname" maxLength={80} required /></label>}
          {error && <p className="draft-error" role="alert">{error}</p>}
          <button type="submit" disabled={pending}>
            {pending ? (joining ? "参加中…" : "作成中…") : (joining ? "参加する" : "作成する")}
          </button>
        </form>
      )}
      <button className="back-link" type="button" onClick={onCancel} disabled={pending}>
        {joining ? "招待を閉じる" : "← マイグループ"}
      </button>
    </section>
  );
}

export function InviteLink({ client, groupId }: { client: SupabaseClient; groupId: string }) {
  const [link, setLink] = useState("");
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const requestPending = useRef(false);

  async function issueInvite() {
    if (requestPending.current) return;
    requestPending.current = true;
    setPending(true);
    setError("");
    setMessage("");
    try {
      const { data, error } = await client.rpc("create_diary_invite", { target_group: groupId });
      if (error || typeof data !== "string" || !tokenPattern.test(data)) {
        setError(error?.code === "23514"
          ? "グループが定員に達しています。"
          : "招待リンクを発行できませんでした。");
        return;
      }

      const invite = new URL("/", window.location.origin);
      invite.hash = new URLSearchParams({ invite: data }).toString();
      setLink(invite.href);
    } catch {
      setError("招待リンクを発行できませんでした。");
    } finally {
      requestPending.current = false;
      setPending(false);
    }
  }

  async function copyInvite() {
    try {
      await navigator.clipboard.writeText(link);
      setMessage("招待リンクをコピーしました。");
    } catch {
      setMessage("招待リンクを選択して手動でコピーしてください。");
    }
  }

  return (
    <section className="invite-panel" aria-labelledby="invite-title">
      <h2 id="invite-title">友だちを招待</h2>
      <p className="muted">発行から7日間、1人だけが使えます。参加してほしい友だち本人に送ってください。</p>
      {link && (
        <label className="invite-link">招待リンク
          <input value={link} readOnly onFocus={(event) => event.currentTarget.select()} />
        </label>
      )}
      <div className="draft-actions">
        <button className="write-link draft-save" type="button" onClick={issueInvite} disabled={pending}>
          {pending ? "発行中…" : link ? "別のリンクを発行" : "招待リンクを発行"}
        </button>
        {link && <button className="write-link" type="button" onClick={copyInvite} disabled={pending}>リンクをコピー</button>}
      </div>
      {message && <p className="muted" role="status">{message}</p>}
      {error && <p className="draft-error" role="alert">{error}</p>}
    </section>
  );
}

type LeaveGroupProps = {
  client: SupabaseClient;
  groupId: string;
  groupName: string;
  membershipId: string;
  onLeft: () => void;
};

export function LeaveGroup({ client, groupId, groupName, membershipId, onLeft }: LeaveGroupProps) {
  const dialog = useRef<HTMLDialogElement>(null);
  const requestPending = useRef(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");

  async function leave() {
    if (requestPending.current) return;
    requestPending.current = true;
    setPending(true);
    setError("");

    try {
      const { error } = await client.rpc("leave_diary_group", {
        target_group: groupId,
        expected_membership: membershipId,
      });
      if (error) throw error;
      if (dialog.current?.open) onLeft();
    } catch {
      requestPending.current = false;
      setPending(false);
      setError("退出できませんでした。もう一度お試しください。");
    }
  }

  return (
    <div className="leave-group">
      <button className="back-link" type="button" onClick={() => {
        setError("");
        dialog.current?.showModal();
      }}>グループから退出</button>
      <dialog
        ref={dialog}
        className="leave-dialog"
        aria-labelledby="leave-title"
        aria-describedby="leave-consequences"
        onCancel={(event) => { if (requestPending.current) event.preventDefault(); }}
      >
        <h2 id="leave-title">グループから退出しますか？</h2>
        <p id="leave-consequences">
          退出すると「{groupName}」の日記を読めなくなります。あなたが共有した日記はグループに表示されなくなり、再参加しても表示されません。
        </p>
        {error && <p className="draft-error" role="alert">{error}</p>}
        <div className="draft-actions">
          <button className="write-link draft-save" type="button" disabled={pending} onClick={() => dialog.current?.close()}>
            キャンセル
          </button>
          <button className="write-link" type="button" disabled={pending} onClick={leave}>
            {pending ? "退出中…" : "退出する"}
          </button>
        </div>
      </dialog>
    </div>
  );
}
