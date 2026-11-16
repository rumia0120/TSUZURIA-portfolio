import type { SupabaseClient } from "@supabase/supabase-js";
import { useEffect, useRef, useState } from "react";

type Props = { client: SupabaseClient; hasVerifiedEmail: boolean };

export function TurnEmailPreference({ client, hasVerifiedEmail }: Props) {
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const [saveStatus, setSaveStatus] = useState<"idle" | "saving" | "saved" | "failed">("idle");
  const requestPending = useRef(false);
  const canToggle = enabled !== null && (enabled || hasVerifiedEmail);

  useEffect(() => {
    const controller = new AbortController();
    const { signal } = controller;

    async function loadPreference() {
      try {
        const { data, error } = await client.rpc("read_turn_email_preference").abortSignal(signal);
        if (signal.aborted) return;
        if (error || typeof data !== "boolean") {
          setLoadFailed(true);
          return;
        }
        setEnabled(data);
      } catch {
        if (!signal.aborted) setLoadFailed(true);
      }
    }

    void loadPreference();
    return () => controller.abort();
  }, [client, attempt]);

  async function toggle() {
    if (!canToggle || requestPending.current) return;
    requestPending.current = true;
    setSaveStatus("saving");

    const next = !enabled;
    try {
      const { data, error } = await client.rpc("set_turn_email_preference", { enabled: next });
      if (error || data !== next) {
        setSaveStatus("failed");
        return;
      }
      setEnabled(data);
      setSaveStatus("saved");
    } catch {
      setSaveStatus("failed");
    } finally {
      requestPending.current = false;
    }
  }

  return (
    <section className="turn-email-preference" aria-labelledby="turn-email-title">
      <div className="turn-email-setting">
        <div>
          <h2 id="turn-email-title">メール通知</h2>
          <p className="muted" id="turn-email-description">
            自分の番が来たとき、確認済みのメールアドレスにお知らせします。
          </p>
        </div>
        {enabled !== null && (
          <button
            className="turn-email-toggle"
            type="button"
            role="switch"
            aria-checked={enabled}
            aria-labelledby="turn-email-title"
            aria-describedby={hasVerifiedEmail ? "turn-email-description" : "turn-email-description turn-email-verification"}
            aria-disabled={!canToggle || saveStatus === "saving" || undefined}
            onClick={toggle}
          >
            <span className="turn-email-track" aria-hidden="true" />
            <span aria-hidden="true">{enabled ? "オン" : "オフ"}</span>
          </button>
        )}
      </div>
      {!hasVerifiedEmail && (
        <p className="muted turn-email-note" id="turn-email-verification">
          メールアドレスを確認すると通知を受け取れます。
        </p>
      )}
      <p className="muted" role="status">
        {enabled === null && !loadFailed && "設定を読み込み中…"}
        {saveStatus === "saving" && "設定を保存中…"}
        {saveStatus === "saved" && `メール通知を${enabled ? "オン" : "オフ"}にしました。`}
      </p>
      {loadFailed && (
        <>
          <p className="draft-error" role="alert">メール通知の設定を読み込めませんでした。</p>
          <button className="back-link" type="button" onClick={() => {
            setLoadFailed(false);
            setAttempt((value) => value + 1);
          }}>設定を再読み込み</button>
        </>
      )}
      {saveStatus === "failed" && <p className="draft-error" role="alert">メール通知の設定を保存できませんでした。もう一度お試しください。</p>}
    </section>
  );
}
