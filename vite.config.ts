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
 * **コミットの短縮ハッシュを併記する。** 時刻だけだと、同じコミットを
 * 別々の経路がビルドしたときに区別がつかない(実際に混乱した)。
 */
const BUILD_ID = [
  new Date().toISOString().slice(0, 16).replace('T', ' '),
  ((globalThis as { process?: { env?: Record<string, string | undefined> } }).process?.env?.GITHUB_SHA ?? '').slice(0, 7),
]
  .filter(Boolean)
  .join(' ')

// https://vite.dev/config/
export default defineConfig({
  define: { __BUILD_ID__: JSON.stringify(BUILD_ID) },
  plugins: [react()],
  server: {
    host: true,
    port: 5173,
  },
})
