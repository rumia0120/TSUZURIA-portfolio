import type { SupabaseClient } from "@supabase/supabase-js";
import { useEffect, useRef, useState } from "react";

const options = [
  { kind: "heart", label: "いいね", stamp: "♥" },
  { kind: "smile", label: "にっこり", stamp: "☺" },
  { kind: "support", label: "応援", stamp: "✦" },
] as const;

type ReactionKind = (typeof options)[number]["kind"];
type Reactions = {
  selected: ReactionKind | null;
  received: (typeof options)[number][];
};

type DiaryReactionsProps = { client: SupabaseClient; entryId: string; userId: string };

export function DiaryReactions({ client, entryId, userId }: DiaryReactionsProps) {
  const [reactions, setReactions] = useState<Reactions | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [saveFailed, setSaveFailed] = useState(false);
  const [pending, setPending] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const requestPending = useRef(false);

  useEffect(() => {
    const controller = new AbortController();
    const { signal } = controller;

    async function load() {
      try {
        const { data, error } = await client.from("diary_reactions")
          .select("user_id, kind").eq("entry_id", entryId).abortSignal(signal);
        if (signal.aborted) return;
        if (error) throw error;

        const own = data.find((reaction) => reaction.user_id === userId);
        setReactions({
          selected: options.find(({ kind }) => kind === own?.kind)?.kind ?? null,
          received: options.filter(({ kind }) => data.some((reaction) => (
            reaction.user_id !== userId && reaction.kind === kind
          ))),
        });
      } catch {
        if (!signal.aborted) setLoadFailed(true);
      }
    }

    void load();
    return () => controller.abort();
  }, [client, entryId, userId, attempt]);

  async function choose(kind: ReactionKind) {
    if (!reactions || requestPending.current) return;
    requestPending.current = true;
    setPending(true);
    setSaveFailed(false);

    const next = reactions.selected === kind ? null : kind;
    try {
      const { data, error } = await client.rpc("set_diary_reaction", {
        target_entry: entryId,
        reaction_kind: next,
      });
      if (error || data !== next) {
        setSaveFailed(true);
        return;
      }
      setReactions({ ...reactions, selected: next });
    } catch {
      setSaveFailed(true);
    } finally {
      requestPending.current = false;
      setPending(false);
    }
  }

  return (
    <footer className="diary-reactions">
      <h2 id="diary-reactions-title">リアクション</h2>
      <div className="reaction-options" role="group" aria-labelledby="diary-reactions-title">
        {options.map(({ kind, label, stamp }) => (
          <button
            key={kind}
            className="reaction-button"
            data-kind={kind}
            type="button"
            aria-pressed={reactions ? reactions.selected === kind : undefined}
            disabled={!reactions}
            aria-disabled={pending || undefined}
            onClick={() => choose(kind)}
          >
            <span className="reaction-symbol" aria-hidden="true">{stamp}</span>
            {label}
            {reactions?.selected === kind && <span className="reaction-check" aria-hidden="true">✓</span>}
          </button>
        ))}
      </div>
      <p className="sr-only" role="status">
        {pending ? "リアクションを保存中…" : !reactions && !loadFailed ? "リアクションを読み込み中…" : ""}
      </p>
      {reactions?.selected && <p className="muted reaction-note">同じボタンで取り消せます。</p>}
      {reactions && reactions.received.length > 0 && (
        <div className="reaction-receipts">
          <span>ほかのメンバーの反応</span>
          <ul aria-label="届いたリアクション">
            {reactions.received.map(({ kind, label, stamp }) => (
              <li key={kind} className="reaction-stamp">
                <span className="reaction-symbol" aria-hidden="true">{stamp}</span>
                <span className="sr-only">{label}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
      {loadFailed && (
        <>
          <p className="draft-error" role="alert">リアクションを読み込めませんでした。</p>
          <button className="back-link" type="button" onClick={() => {
            setLoadFailed(false);
            setAttempt((value) => value + 1);
          }}>リアクションを再読み込み</button>
        </>
      )}
      {saveFailed && <p className="draft-error" role="alert">リアクションを更新できませんでした。もう一度お試しください。</p>}
    </footer>
  );
}
