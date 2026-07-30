/**
 * ホーム画面への追加(A2HS)の判定と、案内をいつ出すかの管理。
 *
 * ■ なぜ要るのか
 *   ピタフレはPWAで、App Storeには出していない。予約手数料は第1段階でも20%
 *   しかなく、Appleの15%(Small Business Program)はその総額にかかるので、
 *   運営の取り分2,000円のうち1,500円が消える。第3段階(14%)以降は赤字になる。
 *   ギフト35%なら成立するが、予約を主にしたこの手数料モデルとは両立しない。
 *   だから**ホーム画面への追加が、アイコン起動と(将来の)通知の唯一の入口**になる。
 *
 *   そしてiOSでは、Safariの共有シートから追加する以外に経路がない。
 *   ボタンがどこにもないので、**案内しないと誰も気づかない。**
 *
 * ■ 流入がSNSなので、いちばん多いのは「そもそも追加できないブラウザ」
 *   X・Instagram・LINE のアプリ内ブラウザには「ホーム画面に追加」がない。
 *   ここで共有ボタンの手順を出すと、押しても項目がなくて詰む。
 *   この場合は手順ではなく、**外のブラウザで開き直してもらう案内**に切り替える。
 *
 * ■ しつこくしない
 *   閉じた回数で次に出すまでを延ばし(14日 → 60日 → もう出さない)、
 *   「追加した」と言われたら以後出さない。設定からはいつでも開ける。
 */

/** 案内の出し方。何を表示するかがこれで決まる。 */
export type InstallMode =
  /** すでにホーム画面から開いている。何も出さない */
  | 'installed'
  /** ブラウザの追加ダイアログを呼べる(Android Chrome など) */
  | 'prompt'
  /** iOS Safari。共有 → ホーム画面に追加 を手で案内する */
  | 'ios-safari'
  /** iOS の Safari 以外。手順が違うので Safari で開いてもらう */
  | 'ios-other'
  /** SNSのアプリ内ブラウザ。ここからは追加できない */
  | 'inapp'
  /** その他(Android Firefox など)。メニューから入れてもらう */
  | 'manual'
  /** PCなど。案内しない */
  | 'none'

type BeforeInstallPromptEvent = Event & {
  prompt: () => Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>
}

let deferredPrompt: BeforeInstallPromptEvent | null = null

// ------------------------------------------------------------
// 環境の判定
// ------------------------------------------------------------

function ua(): string {
  return typeof navigator === 'undefined' ? '' : navigator.userAgent
}

/**
 * SNSのアプリ内ブラウザ。ここからはホーム画面に追加できない。
 * 判定を外しても「追加できるのに外で開けと言う」だけで済むよう、
 * 確信のあるトークンに限っている。
 */
const IN_APP_BROWSERS: ReadonlyArray<readonly [RegExp, string]> = [
  [/\bLine\//i, 'LINE'],
  [/Instagram/i, 'Instagram'],
  [/FBAN|FBAV|FB_IAB/i, 'Facebook'],
  [/Twitter for|TwitterAndroid/i, 'X'],
  [/musical_ly|BytedanceWebview/i, 'TikTok'],
  [/DiscordAndroid/i, 'Discord'],
]

/** アプリ内ブラウザならそのアプリ名。違えば null。 */
export function inAppBrowserName(): string | null {
  const s = ua()
  for (const [re, name] of IN_APP_BROWSERS) {
    if (re.test(s)) return name
  }
  return null
}

export function isIOS(): boolean {
  const s = ua()
  if (/iPhone|iPad|iPod/.test(s)) return true
  // iPadOS 13以降は Mac を装う。タッチ点数でしか見分けられない
  return /Macintosh/.test(s) && typeof navigator !== 'undefined' && navigator.maxTouchPoints > 1
}

/** ホーム画面(または全画面)から開かれているか。 */
export function isStandalone(): boolean {
  if (typeof window === 'undefined') return false
  // iOS Safari は display-mode の実装が遅かったので、独自の navigator.standalone も見る
  const nav = navigator as Navigator & { standalone?: boolean }
  if (nav.standalone === true) return true
  if (typeof window.matchMedia !== 'function') return false
  return ['standalone', 'fullscreen', 'minimal-ui'].some(
    (m) => window.matchMedia(`(display-mode: ${m})`).matches,
  )
}

/**
 * いま出すべき案内の種類。
 *
 * 注意: Androidで既に追加済みの人がブラウザのタブで開くと 'manual' になる
 * (beforeinstallprompt が飛ばないため)。getInstalledRelatedApps() で判る
 * こともあるが対応が限られるので、そこまでは見ていない。案内が一度余計に
 * 出るだけで、閉じれば止まる。
 */
export function installMode(): InstallMode {
  if (typeof window === 'undefined') return 'none'
  if (isStandalone()) return 'installed'
  if (inAppBrowserName()) return 'inapp'
  if (isIOS()) {
    // iOSは中身が全部WebKitだが、共有シートの項目はブラウザごとに違う。
    // 確実な手順を書けるのはSafariだけなので、他はSafariへ寄せる。
    return /CriOS|FxiOS|EdgiOS|OPiOS|GSA\//.test(ua()) ? 'ios-other' : 'ios-safari'
  }
  if (deferredPrompt) return 'prompt'
  if (/Android/i.test(ua())) return 'manual'
  return 'none'
}

// ------------------------------------------------------------
// 出す/出さないの記憶
// ------------------------------------------------------------

// 好み(pita:prefs:v1)とは別のキーにしている。こちらは「しつこさの抑制」で
// あって利用者の設定ではなく、App の state に載せる意味もないため。
const KEY = 'pita:a2hs:v1'

/** 閉じた回数ごとに、次に出すまでの日数。尽きたら以後は自動で出さない。 */
const SNOOZE_DAYS = [14, 60] as const
const DAY_MS = 86_400_000

type StoredState = {
  /** 閉じた回数 */
  dismissed: number
  /** これより前は自動で出さない(epoch ms) */
  snoozeUntil: number
  /** 追加済み。以後は自動で出さない */
  done: boolean
}

const EMPTY: StoredState = { dismissed: 0, snoozeUntil: 0, done: false }

function read(): StoredState {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return EMPTY
    const d = JSON.parse(raw) as Partial<StoredState>
    return {
      dismissed: typeof d.dismissed === 'number' && d.dismissed >= 0 ? d.dismissed : 0,
      snoozeUntil: typeof d.snoozeUntil === 'number' ? d.snoozeUntil : 0,
      done: d.done === true,
    }
  } catch {
    return EMPTY
  }
}

function write(s: StoredState): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(s))
  } catch {
    /* プライベートモード等で保存できなくても、案内が毎回出るだけ */
  }
}

/** 「追加した」と言われた / 実際に追加された。以後は自動で出さない。 */
export function markInstallDone(): void {
  write({ ...read(), done: true })
  notifyMode()
}

/** 「あとで」。閉じた回数に応じて次に出すまでを延ばす。 */
export function snoozeInstallGuide(): void {
  const s = read()
  const days: number | undefined = SNOOZE_DAYS[s.dismissed]
  write({
    dismissed: s.dismissed + 1,
    // 回数を使い切ったら二度と自動で出さない(設定からは開ける)
    snoozeUntil: days === undefined ? Number.MAX_SAFE_INTEGER : Date.now() + days * DAY_MS,
    done: s.done,
  })
  // マイページのカードも一緒に引っ込める。シートで「あとで」と言った人に
  // 同じ案内を残しておくのは、しつこくしない方針に反する
  notifyMode()
}

/** 自動で出してよい状態か(抑制期間・追加済み・そもそも出す意味がない環境を除く)。 */
export function canAutoShowInstallGuide(): boolean {
  const s = read()
  if (s.done) return false
  if (Date.now() < s.snoozeUntil) return false
  const m = installMode()
  return m !== 'installed' && m !== 'none'
}

/** 設定に導線を出すかどうか(すでに追加済み・PCでは出さない)。 */
export function installGuideAvailable(): boolean {
  const m = installMode()
  return m !== 'installed' && m !== 'none'
}

// ------------------------------------------------------------
// 開くきっかけ(画面をまたぐので小さなイベントで持つ)
// ------------------------------------------------------------

/** auto=true は自動で開いた場合。呼ばれた側は少し待ってから出す。 */
type Listener = (auto: boolean) => void

const openListeners = new Set<Listener>()
const modeListeners = new Set<Listener>()

/** 案内を開く要求を受け取る。戻り値を呼ぶと購読を外す。 */
export function subscribeInstallGuide(fn: Listener): () => void {
  openListeners.add(fn)
  return () => openListeners.delete(fn)
}

/** installMode() の答えが変わったことを受け取る(beforeinstallprompt の到着など)。 */
export function subscribeInstallMode(fn: Listener): () => void {
  modeListeners.add(fn)
  return () => modeListeners.delete(fn)
}

function notifyMode(): void {
  modeListeners.forEach((f) => f(false))
}

/** 設定などから本人が明示的に開いたとき。抑制を無視して開く。 */
export function openInstallGuide(): void {
  openListeners.forEach((f) => f(false))
}

/**
 * 「通知が効くようになる」操作(お気に入り登録・予約)の直後に呼ぶ。
 * 抑制中や出す意味がない環境では何も起きない。
 */
export function armInstallGuide(): void {
  if (!canAutoShowInstallGuide()) return
  openListeners.forEach((f) => f(true))
}

// ------------------------------------------------------------
// ブラウザ側の口
// ------------------------------------------------------------

/**
 * beforeinstallprompt を捕まえる。**main.tsx の先頭で一度だけ呼ぶ。**
 * このイベントは React が乗る前に飛ぶことがあり、取り逃すと
 * ネイティブの追加ダイアログを二度と出せない。
 */
export function initInstall(): void {
  if (typeof window === 'undefined') return
  window.addEventListener('beforeinstallprompt', (e) => {
    // 既定のミニ情報バーを止めて、こちらのタイミングで出す
    e.preventDefault()
    deferredPrompt = e as BeforeInstallPromptEvent
    notifyMode()
  })
  window.addEventListener('appinstalled', () => {
    deferredPrompt = null
    markInstallDone()
    notifyMode()
  })
}

/**
 * ブラウザの追加ダイアログを出す。追加されたら true。
 * 呼べる状態でなければ false を返すので、呼び側は手順の表示に切り替える。
 */
export async function promptInstall(): Promise<boolean> {
  const e = deferredPrompt
  if (!e) return false
  // このイベントは一度しか使えない。先に手放して二重呼び出しを防ぐ
  deferredPrompt = null
  try {
    await e.prompt()
    const { outcome } = await e.userChoice
    if (outcome === 'accepted') markInstallDone()
    return outcome === 'accepted'
  } catch {
    return false
  } finally {
    notifyMode()
  }
}

/**
 * Androidのアプリ内ブラウザからChromeで開き直すURL。
 * Chromeが入っていなければ何も起きないだけなので、押せて損はない。
 * iOSには同等の手段がないので null を返す(コピーして貼ってもらう)。
 */
export function androidChromeUrl(): string | null {
  if (typeof window === 'undefined' || !/Android/i.test(ua())) return null
  // **パスもクエリも混ぜない。** intent:// はフラグメント以降を
  // 「起動するアプリの指定」として解釈するので、URLに攻撃者の文字列が
  // 混じると別のアプリを起動させられる余地が残る(%23 が # として
  // 解釈されるかはAndroid側の実装に依存する)。ここで開きたいのは
  // トップページだけなので、ホスト名しか入れない。
  return `intent://${window.location.host}/#Intent;scheme=https;package=com.android.chrome;end`
}

/** トップページのURL。 */
export function appUrl(): string {
  return typeof window === 'undefined' ? 'https://pitafure.com/' : `${window.location.origin}/`
}

/**
 * URLをクリップボードへ。
 * **アプリ内ブラウザでは Clipboard API が塞がれていることがある**ので、
 * 失敗したら旧 execCommand で入れ直す。ここがいちばん効いてほしい場面。
 */
export async function copyAppUrl(): Promise<boolean> {
  const url = appUrl()
  try {
    await navigator.clipboard.writeText(url)
    return true
  } catch {
    /* 次の手を試す */
  }
  try {
    const el = document.createElement('textarea')
    el.value = url
    el.setAttribute('readonly', '')
    el.style.position = 'fixed'
    el.style.opacity = '0'
    document.body.appendChild(el)
    el.select()
    el.setSelectionRange(0, url.length)
    const ok = document.execCommand('copy')
    document.body.removeChild(el)
    return ok
  } catch {
    return false
  }
}
