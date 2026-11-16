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
- 共有済みの日記は、現在のメンバーが書いたもののうち、自分の参加時点以降に共有されたものを読めます。下書きは所属中の作成者だけが読めます。退出した本人はグループの日記を読めなくなり、残ったメンバーは退出者が書いた日記を読めなくなります。
- ログイン、グループ作成、招待からの参加、日記の下書き保存と受け渡し、退出は Supabase に接続します。

### グループ作成と招待をローカルで試す

ローカルの Supabase に最新のマイグレーションを適用し、アプリをその環境につなぎます。架空のアカウントを3つ用意してください。

1. 作成者としてログインし、グループ一覧の「グループを作る」から名前を入力します。
2. グループ内で1人分ずつ招待リンクを発行します。リンクは7日間有効で、参加に成功すると使い切ります。
3. 別々のブラウザープロファイルなどで友達役のアカウントに切り替え、それぞれの招待リンクから参加します。
4. 3人目の参加後、作成者の画面で「参加状況を更新」を押します。作成者が最初の担当になり、そこから参加順に日記が回ります。1グループの上限は5人です。

ローカルの Supabase では `supabase test db` で、招待、参加、日記の受け渡し、退出を検証できます。

退出を確認するときは、グループの日記一覧から「グループから退出」を選びます。別のアカウントで退出者の日記の本文URLを開き直して、アクセスが止まることを確認できます。3人から2人になった場合は、新しく3人目が入るまで受け渡しを待ちます。

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

## 番が回ったときのメール通知

「マイグループ」で通知をオンにすると、日記を渡されたときに、確認済みのメールアドレスへ通知を送ります。初期設定はオフです。メールには「あなたの番です」とアプリのURLを載せます。

日記の共有と担当交代の処理は、DBに送信予定を記録した時点で完了します。宛先は送信直前に取得し、通知をオフにした人や、すでに番が過ぎた人には送信しません。一時的な送信失敗は、6時間以内に最大5回まで試行します。

### 配信を有効にする

対象プロジェクトにDBマイグレーションを適用し、Supabase Edge Function の `turn-emails` をデプロイします。送信元を Resend に登録し、以下の値を対象プロジェクトの Edge Function Secrets に設定します。

| キー | 内容 |
| --- | --- |
| `RESEND_API_KEY` | メール送信用の Resend API キー |
| `TURN_EMAIL_FROM` | Resend で送信可能な From アドレス |
| `TURN_EMAIL_APP_URL` | メールから開くアプリの HTTPS URL |
| `TURN_EMAIL_CRON_SECRET` | スケジューラーだけが知るランダムなシークレット（32文字以上） |

Supabase Cron と Vault を使う場合は、Vault に `tsuzuria_project_url` と `tsuzuria_turn_email_cron_secret` を保存します。後者には Edge Function Secrets の `TURN_EMAIL_CRON_SECRET` と同じ値を設定します。5分間隔のジョブを登録する例です。

```sql
select cron.schedule('tsuzuria-turn-emails', '*/5 * * * *', $job$
  select net.http_post(
    url := rtrim((select decrypted_secret from vault.decrypted_secrets
      where name = 'tsuzuria_project_url'), '/') || '/functions/v1/turn-emails',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets
        where name = 'tsuzuria_turn_email_cron_secret')
    )
  );
$job$);
```

接続後は、確認用のメンバーで通知をオンにし、別のメンバーが日記を渡したときに宛先へ1通届くことを確認します。

ローカルのDBは `supabase test db` で、送信処理は `node --test supabase/tests/turn_emails_worker.test.mjs` で検証できます。送信テストは Resend の応答を模擬します。

[Supabase の定期実行](https://supabase.com/docs/guides/functions/schedule-functions) · [Resend の再送時の重複防止](https://resend.com/docs/dashboard/emails/idempotency-keys)
