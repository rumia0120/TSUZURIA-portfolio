export const demoAccounts = [
  { id: "aoi", name: "あおい", groupId: "weekend", joinedOn: "2026-11-01", hint: "週末の交換日記" },
  { id: "riku", name: "りく", groupId: "weekend", joinedOn: "2026-11-06", hint: "週末の交換日記 · 途中参加" },
  { id: "yui", name: "ゆい", groupId: "after-school", joinedOn: "2026-11-01", hint: "放課後の交換日記" },
] as const;

export const demoGroups = [
  { id: "weekend", name: "週末の交換日記", members: ["あおい", "はる", "なぎ", "りく"], currentWriter: "はる" },
  { id: "after-school", name: "放課後の交換日記", members: ["ゆい", "みなと", "ひなた"], currentWriter: "みなと" },
] as const;

// Fictional excerpts for the UI preview, modeled on the local database seed.
export const demoEntries = [
  {
    id: "book", groupId: "weekend", author: "あおい", sharedOn: "2026-11-09",
    title: "本を一冊読み終えた日",
    paragraphs: [
      "久しぶりに、本を一冊読み終えた。ずっと机の端に置いていた本で、今日はあたたかいお茶をいれて、最後の数ページをゆっくり読んだ。",
      "読み終わってから、しばらく表紙を眺めていた。次の本も急いで決めずに、今週はこの話のことを思い出しながら過ごそうと思う。",
      "みんなは最近、何か読んだ？ 次の日記で聞けたらうれしい。",
    ],
  },
  {
    id: "sunset", groupId: "weekend", author: "そら", sharedOn: "2026-11-03",
    title: "帰り道の夕焼け",
    paragraphs: [
      "帰り道、いつもより空が明るい気がして見上げたら、雲の端がオレンジ色だった。",
      "少し遠回りして帰った。忙しい日だったけど、最後にいいものを見られた気がする。",
    ],
  },
  {
    id: "tea", groupId: "after-school", author: "ゆい", sharedOn: "2026-11-09",
    title: "新しいお茶をいれてみた",
    paragraphs: [
      "帰りに見つけたお茶をいれてみた。思っていたより香ばしくて、飲み終わってからもしばらくいい香りが残っていた。",
      "次にみんなで集まるときにも持っていこうかな。",
    ],
  },
] as const;
