# デプロイの仕組みと、詰まったときの手順

`main` に push すると、GitHub Actions がビルドして Cloudflare へ配信します。
定義は [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml)。

```
main に push
  → npm ci → npm run build      (GitHub Actions)
  → npx wrangler deploy          (Cloudflare Workers・静的アセット配信)
  → 本番が新しいアセットを返すまで確認     ← ここが要
```

**最後の確認が本体です。** デプロイが「成功」と報告されても、実際に配信されている
とは限りません。ビルドしたアセット名（`assets/index-XXXX.js`）が
`https://pitafure.com/` から返ってくるまで確かめ、返らなければジョブを失敗させます。

---

## 1回だけの準備（GitHubのシークレット登録）

### (a) Cloudflare の API トークンを作る

1. Cloudflare ダッシュボード → 右上のアカウントメニュー → **My Profile**
2. **API Tokens** → **Create Token**
3. テンプレート **「Edit Cloudflare Workers」** を使う
4. Account Resources / Zone Resources を自分のアカウント・`pitafure.com` に絞る
5. 作成後に表示される文字列を控える。**この画面を閉じると二度と見られません**

### (b) アカウントIDを控える

Cloudflare ダッシュボードの Workers & Pages の画面、または URL の
`dash.cloudflare.com/<ここがアカウントID>/workers/...` の部分。

### (c) GitHub に登録する

`https://github.com/jibumato/pita-friends` →
**Settings** → **Secrets and variables** → **Actions** → **New repository secret**

| Name | Secret |
|---|---|
| `CLOUDFLARE_API_TOKEN` | (a) のトークン |
| `CLOUDFLARE_ACCOUNT_ID` | (b) のアカウントID |

> ⚠️ **名前は一字一句このとおりに。** 違うと、ジョブは動くのに認証だけ落ちます。
> 値はリポジトリには入りません。GitHubのシークレットにだけ置きます。

### (d) Cloudflare 側の自動ビルドを止める

Actions が通ることを確認してから、Cloudflare の
`pita-friends` → 設定 → ビルド → **接続を解除** を実行してください。

**両方が動いていると、同じコミットを2回デプロイして版が二重に積まれます。**
どちらが配信したのか分からなくなるので、配信経路は1本にします。

---

## 動いているかの確認

- GitHub の **Actions** タブに「デプロイ」が並びます。緑なら配信済み
- サイトのフッターに `build 2026-08-03 15:21` のようにビルド時刻が出ます。
  **ここが古ければ、原因はコードではなく配信側です**

## 詰まったときの見どころ

| 症状 | 見るところ |
|---|---|
| Actions に何も出ない | ワークフローが `main` にあるか。Actions が無効化されていないか |
| `npm ci` で落ちる | `package-lock.json` が `package.json` とずれている。手元で `npm ci` を試す |
| デプロイの手順で落ちる | シークレット2つの名前と値。トークンの権限（Workers Scripts: Edit） |
| 「反映の確認」だけ落ちる | デプロイ自体は成功している。Cloudflare のルーティング・独自ドメインの設定・キャッシュ |

## 手で配信する（最後の手段）

```bash
git clone https://github.com/jibumato/pita-friends.git
cd pita-friends
npm ci
npm run build
npx wrangler deploy     # 初回は npx wrangler login
```

Supabase の接続情報は `.env.production` がリポジトリに入っているので、
環境変数を用意しなくても実データに繋がります。

---

## キャッシュについて（2026-08-03）

`public/_headers` で、**HTMLは毎回検証させています**（`/`・`/index.html`・
`/legal/*`・`/reset-password`）。ハッシュ付きアセットは1年の不変キャッシュですが、
**そのハッシュを指しているのは index.html** で、ここが古いまま残ると
新しいバンドルに切り替わりません。この指定を消さないでください。

静的アセット（ロゴ等）を差し替えたときは、`public/sw.js` の `CACHE` の版も
上げてください。サービスワーカーはアセットをキャッシュ優先で返すため、
上げないと古い版が残り続けます。
