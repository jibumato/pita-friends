/**
 * ピタフレ サービスワーカー(依存なし・ランタイムキャッシュ)。
 * - ナビゲーション: ネットワーク優先 → 失敗時はキャッシュした index.html(オフライン起動)
 * - 同一オリジンのGETアセット: キャッシュ優先 → なければ取得してキャッシュ
 * - クロスオリジン(Google Fonts等)は素通し
 * Viteはアセット名をハッシュ化するため、事前プリキャッシュではなく取得時キャッシュにしている。
 */
const CACHE = 'pita-friends-v1'
const APP_SHELL = ['/', '/index.html', '/manifest.webmanifest', '/pita.svg', '/icon-192.png', '/icon-512.png']

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
          const clone = res.clone()
          caches.open(CACHE).then((c) => c.put('/index.html', clone))
          return res
        })
        .catch(() => caches.match('/index.html').then((r) => r || caches.match('/'))),
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
