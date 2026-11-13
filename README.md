# TSUZURIA

友達と一冊の日記を順番に回す交換日記アプリ。プロダクトの方針は [docs/concept.md](docs/concept.md) を参照してください。

## ローカル開発

Node.js 22 以上と npm を使います。依存関係をインストールして開発サーバーを起動します。

```sh
npm ci
npm run dev
```

ブラウザで http://localhost:3000 を開きます。

## Supabase

接続するときは `.env.example` を `.env.local` にコピーし、Supabase のプロジェクト URL と publishable key を設定します。現在のトップページは環境変数なしで起動できます。

### ローカルのデータベース試作

Supabase CLI と Docker が使える環境で、実装フォルダから `supabase start` を実行します。作成済みのローカルDBを初期化してマイグレーションとサンプルを読み直すときは `supabase db reset --local` を使います。リセットするとローカルDBの既存データが消えます。

- `supabase/migrations/` にプロフィール、グループ、所属と順番、日記、リアクションの定義があります。
- [supabase/seed.sql](supabase/seed.sql) に架空の2グループ、利用者8人、共有済みの日記と下書きが入っています。確認用の利用者にはログイン資格情報がありません。
- 閲覧は現在のメンバーに限定し、共有済みの日記は参加時点以降のものを表示します。下書きは作成者だけが閲覧できます。退出後は閲覧できなくなり、共有済みの投稿は試作用データに残ります。これらは [決定・検討記録](docs/decisions.md) にある検討案を試すための設定です。
- ログイン画面、招待・退出の操作、日記の作成と受け渡し、メール通知は今後接続します。現在のDBではプロフィール・所属・日記を読み取り専用とし、閲覧できる共有済み日記への本人のリアクションだけを更新できます。

## 確認コマンド

```sh
npm run lint
npm run typecheck
npm run build
```

### Supabase につないで閲覧を確認する

専用の開発用プロジェクトに試作用マイグレーションを適用します。Dashboard の Authentication で `reader-a@example.test` と `reader-b@example.test` を確認済みユーザーとして作り、本人だけが知る別々のパスワードを設定します。続いて SQL Editor で [閲覧確認用データ](supabase/dev/reader-fixtures.sql) を一度だけ実行します。通常の `seed.sql` はローカル試作用です。

`.env.local` に Project URL と publishable key を設定して開発サーバーを再起動します。両方が空の場合は架空アカウントの画面プレビューを表示します。

1. A でログインし、「週末の交換日記」から「久しぶりに本を一冊読み終えた。」を開く。参加前の投稿と下書きは一覧に表示されない。
2. ログアウトして B でログインし、「放課後の交換日記」だけが表示されることを確認する。
3. B の状態で A の本文URLを開き、「日記を開けません」と表示されることを確認する。ログアウト後は同じURLでログイン画面が出る。
