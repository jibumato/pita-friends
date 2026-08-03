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
とは限りません。`https://pitafure.com/version.json` が**そのコミットのSHA**を返すまで
確かめ、返らなければジョブを失敗させます。

> アセット名（`assets/index-XXXX.js`）では判定できません。**同じコミットでも
> ビルドのたびに名前が変わる**ので、別の経路がビルドした場合に食い違います。
> 2026-08-03、これで判定を誤りました。

---

## 1回だけの準備（GitHubのシークレット登録）

### (a) Cloudflare の API トークンを作る

1. Cloudflare ダッシュボード → 右上のアカウントメニュー → **My Profile**
2. **API Tokens** → **Create Token**
3. テンプレート **「Edit Cloudflare Workers」** を使う
4. Account Resources / Zone Resources を自分のアカウント・`pitafure.com` に絞る
5. 作成後に表示される文字列を控える。**この画面を閉じると二度と見られません**

### (b) GitHub に登録する

`https://github.com/jibumato/pita-friends` →
**Settings** → **Secrets and variables** → **Actions** → **New repository secret**

| Name | Secret |
|---|---|
| `CLOUDFLARE_API_TOKEN` | (a) のトークン |

**アカウントIDは登録しません。** トークンが1つのアカウントに限定されていれば、
wrangler が自分で判別します。32桁の英数字を手で書き写すのは、
**1文字ずれても「object identifier is invalid」としか出ない**ので、
やらないほうが安全です。

> ⚠️ **名前は一字一句このとおりに。** 違うと、ジョブは動くのに認証だけ落ちます。
> 値はリポジトリには入りません。GitHubのシークレットにだけ置きます。

### (c) Cloudflare 側の自動ビルドを止める ← **後回しにしないこと**

Cloudflare の `pita-friends` → 設定 → ビルド → **接続を解除**。

当初は「Actions が緑になってから」と書いていましたが、**順序が逆でした。**
両方が生きていると、同じコミットを2つの経路がそれぞれビルドして
**あとから終わったほうが上書きします。**どちらが配信されているのか分からず、
反映の確認も通りません。2026-08-03 に実際に起きています。

**先に解除して、配信経路を1本にしてください。**

---

## 動いているかの確認

- GitHub の **Actions** タブに「デプロイ」が並びます。緑なら配信済み
- サイトのフッターに `build 202608031521` のように出ます。**頭から `YYYYMMDDHHMM`(UTC)** で、
  この例なら 2026-08-03 15:21。区切りを入れないのは、訪問者に更新日時として読ませないためです。
  **ここが古ければ、原因はコードではなく配信側です**
- どのコミットが出ているかは `https://pitafure.com/version.json` を開くと完全なSHAで分かります

## 詰まったときの見どころ

| 症状 | 見るところ |
|---|---|
| Actions に何も出ない | ワークフローが `main` にあるか。Actions が無効化されていないか |
| `npm ci` で落ちる | `package-lock.json` が `package.json` とずれている。手元で `npm ci` を試す |
| デプロイの手順で落ちる | シークレットの名前と値。トークンの権限（Workers Scripts: Edit） |
| `object identifier is invalid [7003]` | アカウントIDが違う。**渡さないのが正解**（上記(b)の注記） |
| デプロイは成功するが確認だけ落ちる | **まず伝播待ちを疑う。**Cloudflare の反映は1〜3分かかることがある。3分待っても駄目なら、Cloudflare 側の Git 連携が上書きしていないか（上記(c)） |
| `Missing entry-point` | wrangler が古く `wrangler.jsonc` を読めていない。**wrangler は `devDependencies` に固定してある**ので、`npm ci` が効いているか確認する |
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

## なぜ Cloudflare の自動ビルドが止まったのか（2026-08-03）

設定は何も変えていません。**push の仕方が変わっただけ**です。

この日、1時間のうちに6コミットを1本ずつ `main` に積みました。
Cloudflare Workers Builds は、短時間に複数の push が来ると
**古いほうを「スキップ」して最新だけをビルド**します。そして最後の1件が
「キャンセル」になりました。結果、6コミット分がまとめて配信されないまま残りました。

厄介なのは、**Cloudflare のバージョン履歴には成功したものしか出ない**ことです。
スキップもキャンセルも別の画面（ビルドの一覧）にしか出ないので、
「止まっている」ことに気づく手掛かりがトップの画面に何もありません。

GitHub Actions では `concurrency` を設定してあるので、連続して push しても
飛ばされず、順番にすべて配信されます。失敗すれば赤くなって通知が来ます。

## キャッシュについて（2026-08-03）

`public/_headers` で、**HTMLは毎回検証させています**（`/`・`/index.html`・
`/legal/*`・`/reset-password`）。ハッシュ付きアセットは1年の不変キャッシュですが、
**そのハッシュを指しているのは index.html** で、ここが古いまま残ると
新しいバンドルに切り替わりません。この指定を消さないでください。

静的アセット（ロゴ等）を差し替えたときは、`public/sw.js` の `CACHE` の版も
上げてください。サービスワーカーはアセットをキャッシュ優先で返すため、
上げないと古い版が残り続けます。
