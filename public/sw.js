/**
 * ピタフレ サービスワーカー(依存なし・ランタイムキャッシュ)。
 * - ナビゲーション: ネットワーク優先 → 失敗時はキャッシュした index.html(オフライン起動)
 * - 同一オリジンのGETアセット: キャッシュ優先 → なければ取得してキャッシュ
 * - クロスオリジン(Supabase等)は素通し。**フォントは自己ホストなので同一オリジン**
 *   (弁護士回答Q20・外部送信規律。public/fonts/dotgothic16/)
 * Viteはアセット名をハッシュ化するため、事前プリキャッシュではなく取得時キャッシュにしている。
 */
// ロゴ等の静的アセットを差し替えたらここを上げる(キャッシュ優先のため古い版が残り続ける)
const CACHE = 'pita-friends-v7'
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

// ------------------------------------------------------------
// プッシュ通知(0064)
// ------------------------------------------------------------
// 本文は push-send が RFC 8291 で暗号化して送ってくるので、配信元
// (FCM/Apple)には中身が読めない。ただし**ロック画面には出る**ので、
// 何を入れるかはサーバ側で絞ってある(_push_lockscreen_body)。
self.addEventListener('push', (event) => {
  let data = {}
  try {
    data = event.data ? event.data.json() : {}
  } catch {
    /* 本文が読めなくても、通知そのものは出す(黙って落とすと理由が分からない) */
  }
  const type = data.type || 'pita'
  event.waitUntil(
    self.registration.showNotification(data.title || 'ピタフレ', {
      body: data.body || '',
      icon: '/icon-192.png',
      badge: '/icon-192.png',
      lang: 'ja',
      // 同じ相手・同じ予約についての連投は1つにまとめる。
      // type だけで束ねると別の人からのメッセージが隠れてしまうので、
      // 関連ID(相手のトーク・予約)まで含めて分ける。
      tag: type + ':' + (data.relatedId || ''),
      data: { type, relatedId: data.relatedId || null },
    }),
  )
})

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const info = event.notification.data || {}
  event.waitUntil(
    (async () => {
      const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
      // すでに開いていればそれを前に出して、画面遷移だけ頼む
      for (const c of clients) {
        if (new URL(c.url).origin === self.location.origin) {
          if ('focus' in c) await c.focus()
          c.postMessage({ source: 'pita-push', type: info.type, relatedId: info.relatedId })
          return
        }
      }
      // 開いていなければ起動する。行き先はクエリで渡す
      await self.clients.openWindow('/?push=' + encodeURIComponent(info.type || ''))
    })(),
  )
})
