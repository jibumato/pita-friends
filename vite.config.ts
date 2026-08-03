import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

/**
 * ビルドの目印。フッターに小さく出す。
 *
 * **「直したのにサイトが変わらない」を目視で切り分けるためのもの。**
 * 2026-08-03、デプロイ済みのつもりで古い画面を見ていた事故があった。
 * ここが更新されていなければ、原因はコードではなく配信側(デプロイ未実行、
 * またはHTMLのキャッシュ)だと1秒で分かる。
 */
const BUILD_ID = new Date().toISOString().slice(0, 16).replace('T', ' ')

// https://vite.dev/config/
export default defineConfig({
  define: { __BUILD_ID__: JSON.stringify(BUILD_ID) },
  plugins: [react()],
  server: {
    host: true,
    port: 5173,
  },
})
