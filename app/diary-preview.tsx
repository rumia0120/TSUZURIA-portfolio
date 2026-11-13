"use client";

import { useEffect, useRef, useState } from "react";
import { demoAccounts, demoEntries, demoGroups } from "./diary-preview-data";

type Account = (typeof demoAccounts)[number];
type Entry = (typeof demoEntries)[number];
type Screen =
  | { kind: "login" }
  | { kind: "groups"; account: Account }
  | { kind: "entries"; account: Account }
  | { kind: "entry"; account: Account; entry: Entry };

const dateLabel = new Intl.DateTimeFormat("ja-JP", {
  month: "long",
  day: "numeric",
  weekday: "short",
  timeZone: "Asia/Tokyo",
});

function EntryDate({ date }: { date: string }) {
  return <time dateTime={date}>{dateLabel.format(new Date(date))}</time>;
}

export default function DiaryPreview() {
  const [screen, setScreen] = useState<Screen>({ kind: "login" });
  const heading = useRef<HTMLHeadingElement>(null);
  const didNavigate = useRef(false);

  useEffect(() => {
    if (didNavigate.current) {
      heading.current?.focus({ preventScroll: true });
      window.scrollTo(0, 0);
    }
  }, [screen]);

  function navigate(next: Screen) {
    didNavigate.current = true;
    setScreen(next);
  }

  if (screen.kind === "login") {
    return (
      <main className="preview-shell welcome">
        <section className="login-panel" aria-labelledby="login-title">
          <div className="brand">Tsuzuria</div>
          <h1 id="login-title" ref={heading} tabIndex={-1}>ログイン</h1>
          <p className="muted">試作用のアカウントを選んで、日記を開いてみてください。</p>
          <div className="account-list">
            {demoAccounts.map((account) => (
              <button className="account-row" key={account.id} onClick={() => navigate({ kind: "groups", account })}>
                <span className={`avatar avatar-${account.id}`} aria-hidden="true">{account.name[0]}</span>
                <span className="row-copy"><strong>{account.name}</strong><small>{account.hint}</small></span>
                <span className="chevron" aria-hidden="true">›</span>
              </button>
            ))}
          </div>
        </section>
      </main>
    );
  }

  const { account } = screen;
  const groups = demoGroups.filter((group) => group.id === account.groupId);
  const group = groups[0];
  const entries = demoEntries.filter((entry) => entry.groupId === group.id && entry.sharedOn >= account.joinedOn);

  return (
    <div className="preview-shell">
      <header className="app-header">
        <div className="brand">Tsuzuria</div>
        <button className="switch-account" onClick={() => navigate({ kind: "login" })}>
          <span className={`avatar avatar-${account.id}`} aria-hidden="true">{account.name[0]}</span>
          <span>{account.name}<small>アカウント切替</small></span>
        </button>
      </header>
      <main className="app-content">
        {screen.kind === "groups" && (
          <>
            <h1 ref={heading} tabIndex={-1}>マイグループ</h1>
            <div className="group-list">
              {groups.map((item) => (
                <button className="group-card" key={item.id} onClick={() => navigate({ kind: "entries", account })}>
                  <span className="notebook-icon" aria-hidden="true" />
                  <span className="row-copy">
                    <strong>{item.name}</strong>
                    <small>{item.members.length}人 · 今は{item.currentWriter}さんの番</small>
                  </span>
                  <span className="chevron" aria-hidden="true">›</span>
                </button>
              ))}
            </div>
          </>
        )}
        {screen.kind === "entries" && (
          <>
            <button className="back-link" onClick={() => navigate({ kind: "groups", account })}>← マイグループ</button>
            <div className="notebook-header">
              <h1 ref={heading} tabIndex={-1}>{group.name}</h1>
              <p className="muted">今は{group.currentWriter}さんの番</p>
            </div>
            <h2 className="list-heading">日記一覧 <span>{entries.length}件</span></h2>
            <ul className="entry-list">
              {entries.map((entry) => (
                <li key={entry.id}>
                  <button className="entry-row" onClick={() => navigate({ kind: "entry", account, entry })}>
                    <span className="entry-meta"><EntryDate date={entry.sharedOn} /> · {entry.author}</span>
                    <strong>{entry.title}</strong>
                    <span className="entry-excerpt">{entry.paragraphs[0]}</span>
                    <span className="chevron" aria-hidden="true">›</span>
                  </button>
                </li>
              ))}
            </ul>
          </>
        )}
        {screen.kind === "entry" && (
          <>
            <button className="back-link" onClick={() => navigate({ kind: "entries", account })}>← 日記一覧</button>
            <article className="paper">
              <p className="paper-label">{group.name}</p>
              <h1 ref={heading} tabIndex={-1}>{screen.entry.title}</h1>
              <p className="entry-meta"><EntryDate date={screen.entry.sharedOn} /> · {screen.entry.author}</p>
              <div className="paper-body">
                {screen.entry.paragraphs.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
              </div>
            </article>
          </>
        )}
      </main>
    </div>
  );
}
