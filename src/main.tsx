import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import ErrorBoundary from './components/ErrorBoundary.tsx'
import { initInstall } from './lib/install.ts'

// beforeinstallprompt は React が乗る前に飛ぶことがあり、取り逃すと
// ネイティブの追加ダイアログを二度と出せない。描画より先に構える。
initInstall()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </StrictMode>,
)

// サービスワーカー登録(本番のみ。開発中はキャッシュを避ける)
if ('serviceWorker' in navigator && import.meta.env.PROD) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => {
      /* 登録失敗はオフライン非対応になるだけなので握りつぶす */
    })
  })
}
