import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

/**
 * ビルドの目印。フッターに小さく出す。
 *
 * **「直したのにサイトが変わらない」を目視で切り分けるためのもの。**
 * 2026-08-03、デプロイ済みのつもりで古い画面を見ていた事故があった。
 * ここが更新されていなければ、原因はコードではなく配信側(デプロイ未実行、
 * またはHTMLのキャッシュ)だと1秒で分かる。
 *
 * 形式は `YYYYMMDDHHMM` の**数字だけ**(UTC・分まで)。区切りを入れると
 * 訪問者にも更新日時として読めてしまうため、通し番号のように見せる。
 * こちらは頭から読めば日時なので、切り分けの用は変わらず足りる。
 *
 * **コミットの短縮ハッシュはここには併記しない。** 以前は同じコミットを
 * 別々の経路がビルドして混乱したので付けていたが、配信経路は
 * GitHub Actions の1本に絞った(`docs/deploy.md`)。どのコミットが出ているかは
 * `/version.json` に完全なSHAが入っており、デプロイ後の自動確認もそれを見ている。
 */
const BUILD_ID = new Date().toISOString().slice(0, 16).replace(/\D/g, '')

// https://vite.dev/config/
export default defineConfig({
  define: { __BUILD_ID__: JSON.stringify(BUILD_ID) },
  plugins: [react()],
  server: {
    host: true,
    port: 5173,
  },
})
