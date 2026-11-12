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

## 確認コマンド

```sh
npm run lint
npm run typecheck
npm run build
```
