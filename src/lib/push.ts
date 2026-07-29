/**
 * プッシュ通知(0064)の許可取得と購読。
 *
 * ■ いつ聞くかが、この機能のほぼ全部
 *   ブラウザの許可ダイアログは**一度しか出せない。** 断られたら二度と
 *   出せず、以後は利用者が自分でブラウザの設定を開くしかない。つまり
 *   「とりあえず起動時に聞く」は、この通知経路を永久に捨てるのと同じ。
 *
 *   だから:
 *     ・起動時には絶対に聞かない
 *     ・**先にアプリ内で理由を説明するシートを出す**(PushPrompt)。
 *       本物のダイアログは、そこで「受け取る」を押した人にだけ見せる。
 *       これなら本物のダイアログは形式的な確認になり、断られにくい
 *     ・聞くきっかけは「通知が欲しくなる操作の直後」だけ:
 *         推しに追加した   → 枠が空いたら知らせる(0054)
 *         予約が確定した   → 相手からの連絡を取り逃さない
 *     ・断られたら記録して二度と出さない。設定画面には
 *       「ブラウザ側で許可し直す方法」を出す
 *
 * ■ iOSはホーム画面に追加しないと通知が使えない
 *   Safariのタブで開いているあいだは PushManager そのものが無い。
 *   なので**追加の案内(install.ts)と一本の導線**になっている:
 *   通知が今すぐ取れるなら通知を、取れないならホーム画面への追加を勧める。
 */
import { requireSupabase, isBackendConfigured } from './supabase'
import { armInstallGuide, isIOS, isStandalone } from './install'

/** VAPIDの公開鍵。公開されて問題ない値(秘密鍵はSupabaseのSecretsに置く)。 */
const VAPID_PUBLIC_KEY = (import.meta.env.VITE_VAPID_PUBLIC_KEY as string | undefined) ?? ''

export type PushState =
  /** 許可済み。購読もできている */
  | 'granted'
  /** まだ聞いていない。聞けば出せる */
  | 'default'
  /** 断られた。もう聞けない。ブラウザの設定から戻すしかない */
  | 'denied'
  /** iOSでホーム画面に追加していない。追加すれば使える */
  | 'needs-install'
  /** このブラウザでは使えない / VAPIDが未設定 */
  | 'unsupported'

/** 聞くきっかけ。文面を変えるために使う。 */
export type PushReason = 'favorite' | 'booking'

export function pushConfigured(): boolean {
  return VAPID_PUBLIC_KEY.length > 0
}

export function pushState(): PushState {
  if (typeof window === 'undefined') return 'unsupported'
  if (!pushConfigured() || !isBackendConfigured) return 'unsupported'
  // iOSはホーム画面に追加したときだけ通知が使える。**機能検出に頼らない。**
  // タブで開いているときに Notification / PushManager / pushManager のどれが
  // 欠けるかはiOSの版によって違い、どれかが「あるように見える」ことがある。
  // これはプラットフォームの決まりなので、UAと表示形態で判定するほうが確実。
  // 「使えない」ではなく「追加すれば使える」なので unsupported とは区別する。
  if (isIOS() && !isStandalone()) return 'needs-install'
  if (!('serviceWorker' in navigator) || !('Notification' in window) || !('PushManager' in window)) {
    return 'unsupported'
  }
  const p = Notification.permission
  return p === 'granted' ? 'granted' : p === 'denied' ? 'denied' : 'default'
}

// ------------------------------------------------------------
// 出す/出さないの記憶(install.ts と同じ考え方で別のキー)
// ------------------------------------------------------------

const KEY = 'pita:push:v1'
/** 「あとで」の回数ごとに、次に誘うまでの日数。尽きたら自分からは誘わない。 */
const SNOOZE_DAYS = [14, 60] as const
const DAY_MS = 86_400_000

type Stored = { dismissed: number; snoozeUntil: number }
const EMPTY: Stored = { dismissed: 0, snoozeUntil: 0 }

function read(): Stored {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return EMPTY
    const d = JSON.parse(raw) as Partial<Stored>
    return {
      dismissed: typeof d.dismissed === 'number' && d.dismissed >= 0 ? d.dismissed : 0,
      snoozeUntil: typeof d.snoozeUntil === 'number' ? d.snoozeUntil : 0,
    }
  } catch {
    return EMPTY
  }
}

function write(s: Stored): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(s))
  } catch {
    /* 保存できなくても、誘いが毎回出るだけ */
  }
}

export function snoozePushPrompt(): void {
  const s = read()
  const days: number | undefined = SNOOZE_DAYS[s.dismissed]
  write({
    dismissed: s.dismissed + 1,
    snoozeUntil: days === undefined ? Number.MAX_SAFE_INTEGER : Date.now() + days * DAY_MS,
  })
}

/** こちらから誘ってよい状態か。 */
export function canAskPush(): boolean {
  if (pushState() !== 'default') return false
  return Date.now() >= read().snoozeUntil
}

// ------------------------------------------------------------
// 誘うきっかけ(画面をまたぐので小さなイベントで持つ)
// ------------------------------------------------------------

type Listener = (reason: PushReason) => void
const listeners = new Set<Listener>()

export function subscribePushPrompt(fn: Listener): () => void {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

/** 設定などから本人が明示的に開いたとき。抑制を無視する。 */
export function openPushPrompt(reason: PushReason = 'favorite'): void {
  listeners.forEach((f) => f(reason))
}

/**
 * 「通知が欲しくなる操作」の直後に呼ぶ入口。**呼び側はこれだけ使う。**
 *
 * 通知が今すぐ取れるなら通知を誘い、取れない(iOSで未追加)なら
 * ホーム画面への追加を勧める。**両方を同時に出さない**のが肝で、
 * 一度に2枚重ねると、どちらも読まずに閉じられる。
 */
export function armNotifyPrompt(reason: PushReason): void {
  if (canAskPush()) {
    openPushPrompt(reason)
    return
  }
  // 通知が無理 / 済み / 抑制中。まだホーム画面に追加していなければそちらを勧める
  // (install.ts 側でも抑制と環境の判定をしている)
  armInstallGuide()
}

// ------------------------------------------------------------
// 購読
// ------------------------------------------------------------

function b64urlToBytes(s: string): Uint8Array {
  const pad = s.replace(/-/g, '+').replace(/_/g, '/')
  const bin = atob(pad + '='.repeat((4 - (pad.length % 4)) % 4))
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

function bytesToB64url(b: ArrayBuffer | null): string {
  if (!b) return ''
  const a = new Uint8Array(b)
  let bin = ''
  for (let i = 0; i < a.length; i++) bin += String.fromCharCode(a[i])
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

async function saveSubscription(sub: PushSubscription): Promise<void> {
  const p256dh = bytesToB64url(sub.getKey('p256dh'))
  const auth = bytesToB64url(sub.getKey('auth'))
  if (!p256dh || !auth) throw new Error('PUSH_KEYS_MISSING')
  const { error } = await requireSupabase().rpc('save_push_subscription', {
    p_endpoint: sub.endpoint,
    p_p256dh: p256dh,
    p_auth: auth,
    p_ua: navigator.userAgent.slice(0, 300),
  })
  if (error) throw error
}

export type EnableResult = 'granted' | 'denied' | 'error'

/**
 * 許可を求めて購読する。**必ず利用者の操作(クリック)の中から呼ぶこと。**
 * ブラウザは操作を伴わない requestPermission を無視する。
 */
export async function enablePush(): Promise<EnableResult> {
  if (pushState() !== 'default' && pushState() !== 'granted') return 'error'
  try {
    const permission = await Notification.requestPermission()
    if (permission !== 'granted') {
      // 断られた。以後こちらからは誘わない(ダイアログはもう出せない)
      write({ dismissed: SNOOZE_DAYS.length + 1, snoozeUntil: Number.MAX_SAFE_INTEGER })
      return 'denied'
    }
    const reg = await navigator.serviceWorker.ready
    const sub =
      (await reg.pushManager.getSubscription()) ??
      (await reg.pushManager.subscribe({
        // Web Push の仕様上、本文を暗号化するので常に true でなければならない
        userVisibleOnly: true,
        applicationServerKey: b64urlToBytes(VAPID_PUBLIC_KEY) as BufferSource,
      }))
    await saveSubscription(sub)
    return 'granted'
  } catch (e) {
    console.error('[push] enable', e)
    return 'error'
  }
}

/** この端末への通知をやめる。許可そのものは残る(また入れ直せる)。 */
export async function disablePush(): Promise<void> {
  try {
    const reg = await navigator.serviceWorker.ready
    const sub = await reg.pushManager.getSubscription()
    if (!sub) return
    await requireSupabase()
      .rpc('delete_push_subscription', { p_endpoint: sub.endpoint })
      .then(({ error }) => {
        if (error) throw error
      })
    await sub.unsubscribe()
  } catch (e) {
    console.error('[push] disable', e)
  }
}

/**
 * 起動時に呼ぶ。すでに許可済みなら購読を保存し直す。
 *
 * **黙って何も聞かない。** ここで requestPermission を呼ぶと、上に書いた
 * 「一度しか出せないダイアログを無駄撃ちする」ことになる。
 * やることは2つだけ:
 *   ・購読が失効していたら作り直す(ブラウザが鍵を回すことがある)
 *   ・last_seen_at を更新して、古い購読の片付け対象から外す
 */
export async function refreshPushSubscription(): Promise<void> {
  if (pushState() !== 'granted') return
  try {
    const reg = await navigator.serviceWorker.ready
    const sub =
      (await reg.pushManager.getSubscription()) ??
      (await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: b64urlToBytes(VAPID_PUBLIC_KEY) as BufferSource,
      }))
    await saveSubscription(sub)
  } catch (e) {
    console.error('[push] refresh', e)
  }
}

// ------------------------------------------------------------
// 設定(設定画面用)
// ------------------------------------------------------------

export type PushSettings = {
  enabled: boolean
  quietFrom: number | null
  quietTo: number | null
  devices: number
}

export async function fetchPushSettings(): Promise<PushSettings> {
  const { data, error } = await requireSupabase().rpc('my_push_settings')
  if (error) throw error
  const q = (data ?? {}) as Partial<PushSettings>
  return {
    enabled: q.enabled !== false,
    quietFrom: typeof q.quietFrom === 'number' ? q.quietFrom : null,
    quietTo: typeof q.quietTo === 'number' ? q.quietTo : null,
    devices: typeof q.devices === 'number' ? q.devices : 0,
  }
}

export async function savePushSettings(s: {
  enabled: boolean
  quietFrom: number | null
  quietTo: number | null
}): Promise<void> {
  const { error } = await requireSupabase().rpc('set_push_settings', {
    p_enabled: s.enabled,
    p_quiet_from: s.quietFrom,
    p_quiet_to: s.quietTo,
  })
  if (error) throw error
}

/** ロック画面に本文を出さない種類(0064 の _push_lockscreen_body と対応)。 */
export const PUSH_BODY_HIDDEN_TYPES = ['message_received', 'gift_received'] as const
