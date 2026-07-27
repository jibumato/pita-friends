/**
 * ピタフレ サービスワーカー(依存なし・ランタイムキャッシュ)。
 * - ナビゲーション: ネットワーク優先 → 失敗時はキャッシュした index.html(オフライン起動)
 * - 同一オリジンのGETアセット: キャッシュ優先 → なければ取得してキャッシュ
 * - クロスオリジン(Google Fonts等)は素通し
 * Viteはアセット名をハッシュ化するため、事前プリキャッシュではなく取得時キャッシュにしている。
 */
// ロゴ等の静的アセットを差し替えたらここを上げる(キャッシュ優先のため古い版が残り続ける)
const CACHE = 'pita-friends-v6'
const APP_SHELL = ['/', '/index.html', '/manifest.webmanifest', '/favicon.ico', '/icon-192.png', '/icon-512.png']

/**
 * Safariは「redirectedフラグが立ったレスポンス」をナビゲーションのSW応答として拒否する
 * ("Response served by service worker has redirections")。ルートへのアクセスは
 * Cloudflare側の内部リダイレクトを経由することがあり、その結果を素通し・キャッシュすると
 * オフライン起動時にこのエラーになる。redirectedなら中身だけ取り出して包み直す。
 */
function dropRedirected(res) {
  if (!res || !res.redirected) return res
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers: res.headers })
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((cache) => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting()),
  )
})

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  )
})

self.addEventListener('fetch', (event) => {
  const req = event.request
  if (req.method !== 'GET') return

  const url = new URL(req.url)
  if (url.origin !== self.location.origin) return // フォント等クロスオリジンは素通し

  // ページ遷移: ネットワーク優先、オフライン時はキャッシュ済みシェル
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req)
        .then((res) => {
          const clean = dropRedirected(res)
          caches.open(CACHE).then((c) => c.put('/index.html', clean.clone()))
          return clean
        })
        .catch(() =>
          caches
            .match('/index.html')
            .then((r) => r || caches.match('/'))
            .then((r) => dropRedirected(r)),
        ),
    )
    return
  }

  // アセット: キャッシュ優先
  event.respondWith(
    caches.match(req).then(
      (cached) =>
        cached ||
        fetch(req)
          .then((res) => {
            if (res.ok && res.type === 'basic') {
              const clone = res.clone()
              caches.open(CACHE).then((c) => c.put(req, clone))
            }
            return res
          })
          .catch(() => cached),
    ),
  )
})
