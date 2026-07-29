// ============================================================
// webpush.ts
// ------------------------------------------------------------
// Web Push の1通ぶんのリクエスト(URL・ヘッダ・本文)を組み立てる。
//
// **なぜ npm の web-push を使わないのか**
//   あれは Node の crypto(createECDH 等)に依存していて、Deno の互換層で
//   動くかは実際に動かすまで分からない。ここは Web Crypto だけで書いてある
//   ので、Deno でも Node でもブラウザでも同じように動く。おかげで
//   ローカルで「暗号化 → 復号」の往復を確かめられる(復号側は仕様どおりの
//   受信者を模したテストコード)。
//
// 仕様:
//   RFC 8291 (Message Encryption for Web Push)
//   RFC 8188 (Encrypted Content-Encoding: aes128gcm)
//   RFC 8292 (VAPID)
// ============================================================

/** 1レコードに収める最大。ペイロードは小さいので固定でよい。 */
const RECORD_SIZE = 4096
/** aes128gcm のヘッダに入る公開鍵の長さ(非圧縮のP-256点)。 */
const KEY_LENGTH = 65

export type VapidKeys = {
  /** base64url。0x04||X||Y の非圧縮P-256公開鍵 */
  publicKey: string
  /** base64url。P-256の秘密スカラー d (32バイト) */
  privateKey: string
  /** mailto: か https: のURL。配信元が運営に連絡するための宛先 */
  subject: string
}

export type PushTarget = {
  endpoint: string
  /** ブラウザが発行した公開鍵(base64url) */
  p256dh: string
  /** ブラウザが発行した認証シークレット(base64url) */
  auth: string
}

export type PushRequest = {
  url: string
  headers: Record<string, string>
  body: Uint8Array
}

// ------------------------------------------------------------
// base64url
// ------------------------------------------------------------

export function b64urlToBytes(s: string): Uint8Array {
  const pad = s.replace(/-/g, '+').replace(/_/g, '/')
  const padded = pad + '='.repeat((4 - (pad.length % 4)) % 4)
  const bin = atob(padded)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

export function bytesToB64url(b: Uint8Array): string {
  let bin = ''
  for (let i = 0; i < b.length; i++) bin += String.fromCharCode(b[i])
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0)
  const out = new Uint8Array(total)
  let at = 0
  for (const p of parts) {
    out.set(p, at)
    at += p.length
  }
  return out
}

const utf8 = (s: string) => new TextEncoder().encode(s)

// ------------------------------------------------------------
// HKDF(抽出+展開を Web Crypto に任せる)
// ------------------------------------------------------------

async function hkdf(
  salt: Uint8Array,
  ikm: Uint8Array,
  info: Uint8Array,
  bytes: number,
): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', ikm as BufferSource, 'HKDF', false, ['deriveBits'])
  const bits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: salt as BufferSource, info: info as BufferSource },
    key,
    bytes * 8,
  )
  return new Uint8Array(bits)
}

// ------------------------------------------------------------
// 本文の暗号化(RFC 8291 / 8188)
// ------------------------------------------------------------

/**
 * 受信者だけが読める形に包む。
 * 配信元(FCM/Apple)は中身を読めない — **ここが端から端まで暗号化される所**。
 * ロック画面には出るので、何を入れるかは別途 SQL 側で絞っている
 * (0064 の _push_lockscreen_body)。
 */
export async function encryptPayload(
  target: Pick<PushTarget, 'p256dh' | 'auth'>,
  plaintext: Uint8Array,
  /** テスト用に salt と鍵を固定できるようにしてある。本番では省略する */
  fixed?: { salt?: Uint8Array; ephemeral?: CryptoKeyPair },
): Promise<Uint8Array> {
  const uaPublic = b64urlToBytes(target.p256dh)
  const authSecret = b64urlToBytes(target.auth)

  const ephemeral =
    fixed?.ephemeral ??
    ((await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, [
      'deriveBits',
    ])) as CryptoKeyPair)
  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', ephemeral.publicKey))

  // 共有秘密。相手の公開鍵と自分の一時秘密鍵から
  const uaKey = await crypto.subtle.importKey(
    'raw',
    uaPublic as BufferSource,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    [],
  )
  const shared = new Uint8Array(
    await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, ephemeral.privateKey, 256),
  )

  // IKM: 認証シークレットを salt にして、両者の公開鍵を info に混ぜる
  const keyInfo = concat(utf8('WebPush: info'), new Uint8Array([0]), uaPublic, asPublic)
  const ikm = await hkdf(authSecret, shared, keyInfo, 32)

  const salt = fixed?.salt ?? crypto.getRandomValues(new Uint8Array(16))
  const cek = await hkdf(salt, ikm, concat(utf8('Content-Encoding: aes128gcm'), new Uint8Array([0])), 16)
  const nonce = await hkdf(salt, ikm, concat(utf8('Content-Encoding: nonce'), new Uint8Array([0])), 12)

  // RFC 8188: レコードの末尾に区切りを足す。単一レコードなので 0x02
  const padded = concat(plaintext, new Uint8Array([2]))
  const aesKey = await crypto.subtle.importKey('raw', cek as BufferSource, { name: 'AES-GCM' }, false, [
    'encrypt',
  ])
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce as BufferSource }, aesKey, padded as BufferSource),
  )

  // ヘッダ: salt(16) || rs(4, ビッグエンディアン) || idlen(1) || 公開鍵(65)
  const rs = new Uint8Array(4)
  new DataView(rs.buffer).setUint32(0, RECORD_SIZE, false)
  return concat(salt, rs, new Uint8Array([KEY_LENGTH]), asPublic, ciphertext)
}

// ------------------------------------------------------------
// VAPID(RFC 8292)
// ------------------------------------------------------------

async function importVapidSigningKey(keys: VapidKeys): Promise<CryptoKey> {
  const pub = b64urlToBytes(keys.publicKey)
  if (pub.length !== KEY_LENGTH || pub[0] !== 0x04) {
    throw new Error('VAPID公開鍵の形が違います(0x04で始まる65バイトの非圧縮P-256点)')
  }
  // JWK で入れる。d だけでは足りず、x/y は公開鍵から切り出す
  return await crypto.subtle.importKey(
    'jwk',
    {
      kty: 'EC',
      crv: 'P-256',
      x: bytesToB64url(pub.subarray(1, 33)),
      y: bytesToB64url(pub.subarray(33, 65)),
      d: keys.privateKey,
      ext: true,
    },
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  )
}

/**
 * 配信元に「この送信は登録した運営からのものだ」と示す署名。
 * aud は**エンドポイントのオリジン**でなければならず、間違うと401になる。
 */
export async function vapidHeader(endpoint: string, keys: VapidKeys, nowSeconds: number): Promise<string> {
  const aud = new URL(endpoint).origin
  const header = bytesToB64url(utf8(JSON.stringify({ typ: 'JWT', alg: 'ES256' })))
  const payload = bytesToB64url(
    utf8(
      JSON.stringify({
        aud,
        // 12時間。仕様上の上限は24時間
        exp: nowSeconds + 12 * 60 * 60,
        sub: keys.subject,
      }),
    ),
  )
  const signingInput = `${header}.${payload}`
  const key = await importVapidSigningKey(keys)
  // Web Crypto の ECDSA は r||s の生の64バイトを返す。JWSが求める形と同じ
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, utf8(signingInput) as BufferSource),
  )
  return `vapid t=${signingInput}.${bytesToB64url(sig)}, k=${keys.publicKey}`
}

// ------------------------------------------------------------
// 組み立て
// ------------------------------------------------------------

export async function buildPushRequest(
  target: PushTarget,
  payload: unknown,
  keys: VapidKeys,
  nowSeconds: number,
  /** TTL(秒)。配信元が端末に届けられないときに保持する時間 */
  ttlSeconds = 6 * 60 * 60,
): Promise<PushRequest> {
  const body = await encryptPayload(target, utf8(JSON.stringify(payload)))
  return {
    url: target.endpoint,
    headers: {
      Authorization: await vapidHeader(target.endpoint, keys, nowSeconds),
      'Content-Encoding': 'aes128gcm',
      'Content-Type': 'application/octet-stream',
      TTL: String(ttlSeconds),
      // 端末が起きたら必ず出す(黙って捨てられないようにする)
      Urgency: 'normal',
    },
    body,
  }
}
