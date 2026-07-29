/**
 * 「ホーム画面に追加」の案内シート。
 *
 * 環境ごとに**言うことを変える**のが要点。iOSの共有シートの手順を
 * アプリ内ブラウザの人に出すと、押しても項目がなくて詰む(そしてもう戻って
 * こない)。判定は lib/install.ts に置いてある。
 *
 * 通知の話はまだ書いていない。Web Push を実装していないので、
 * 「追加すると通知が届く」は今はまだ嘘になる。実装したらここに一行足す
 * (iOSはホーム画面から開いたときしか届かないので、いちばん強い理由になる)。
 */
import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import {
  androidChromeUrl,
  appUrl,
  copyAppUrl,
  inAppBrowserName,
  installMode,
  markInstallDone,
  promptInstall,
  snoozeInstallGuide,
  subscribeInstallMode,
  type InstallMode,
} from '../lib/install'

type Props = {
  onClose: () => void
}

export default function InstallSheet({ onClose }: Props) {
  const [mode, setMode] = useState<InstallMode>(() => installMode())
  const [copied, setCopied] = useState(false)
  const [promptFailed, setPromptFailed] = useState(false)

  // beforeinstallprompt が開いたあとに届くことがある
  useEffect(() => subscribeInstallMode(() => setMode(installMode())), [])

  function later() {
    snoozeInstallGuide()
    onClose()
  }

  function done() {
    markInstallDone()
    onClose()
  }

  async function copy() {
    setCopied(await copyAppUrl())
  }

  async function install() {
    const ok = await promptInstall()
    if (ok) {
      onClose()
      return
    }
    // ダイアログを出せなかった(もう使ったイベント等)。手順に切り替える
    setPromptFailed(true)
  }

  const appName = inAppBrowserName()
  const chromeUrl = androidChromeUrl()
  const effective: InstallMode = promptFailed && mode === 'prompt' ? 'manual' : mode

  // 追加し終わった / そもそも追加できない環境では出さない。
  // 呼び側(設定の行・カード)でも弾いているが、ここでも閉じておく。
  // 開いている間に追加が完了した場合も、これで自然に消える。
  if (effective === 'installed' || effective === 'none') return null

  return (
    <div
      onClick={later}
      style={{
        position: 'absolute',
        inset: 0,
        background: 'rgba(0,0,0,.45)',
        display: 'flex',
        alignItems: 'flex-end',
        zIndex: 60,
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        className="pita-scroll"
        role="dialog"
        aria-label="ホーム画面に追加する"
        style={{
          width: '100%',
          maxHeight: '88%',
          overflowY: 'auto',
          background: C.surface,
          borderTop: `1.5px solid ${C.border}`,
          borderRadius: '16px 16px 0 0',
          padding: '16px 20px 26px',
          display: 'flex',
          flexDirection: 'column',
          gap: 12,
          boxSizing: 'border-box',
          animation: 'scrIn .25s ease both',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10 }}>
          <span style={{ fontSize: 15, color: C.ink }}>
            {effective === 'inapp' ? 'ブラウザで開き直してください' : 'ホーム画面に追加する'}
          </span>
          <span onClick={later} role="button" tabIndex={0} style={{ cursor: 'pointer', flex: 'none', fontSize: 13, color: C.muted }}>
            閉じる
          </span>
        </div>

        {effective === 'inapp' ? (
          <>
            <span style={{ fontSize: 11.5, color: C.body, lineHeight: 1.8 }}>
              {appName ?? 'このアプリ'}の中のブラウザからは、ホーム画面に追加できません。
              このまま使えますが、<b style={{ color: C.ink }}>SafariやChromeで開き直す</b>と
              アイコンから一発で開けるようになります。
            </span>
            <Steps
              items={[
                '下の「リンクをコピー」を押す',
                'Safari（AndroidはChrome）を開く',
                'アドレス欄に貼り付けて開く',
              ]}
            />
            {chromeUrl && (
              <a
                href={chromeUrl}
                style={{
                  textDecoration: 'none',
                  textAlign: 'center',
                  background: C.white,
                  color: C.ink,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 10,
                  padding: '13px 0',
                  fontSize: 14,
                }}
              >
                Chromeで開く ▶
              </a>
            )}
            <Primary onClick={() => void copy()}>{copied ? 'コピーしました ✓' : 'リンクをコピー'}</Primary>
            {copied && (
              <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
                {appUrl()}
              </span>
            )}
          </>
        ) : effective === 'ios-safari' ? (
          <>
            <Why />
            <Steps
              items={[
                '画面下の共有ボタン（□に↑）を押す（iPadは右上）',
                'メニューを下にたどって「ホーム画面に追加」を選ぶ',
                '右上の「追加」を押す',
              ]}
            />
            <Secondary onClick={done}>追加しました</Secondary>
            <Later onClick={later} />
          </>
        ) : effective === 'ios-other' ? (
          <>
            <Why />
            <span style={{ fontSize: 11.5, color: C.body, lineHeight: 1.8 }}>
              いま使っているブラウザは手順が違います。
              <b style={{ color: C.ink }}>Safariで開く</b>のがいちばん確実です。
            </span>
            <Steps
              items={[
                '「リンクをコピー」を押す',
                'Safariを開いてアドレス欄に貼り付ける',
                '共有ボタン（□に↑）→「ホーム画面に追加」',
              ]}
            />
            <Primary onClick={() => void copy()}>{copied ? 'コピーしました ✓' : 'リンクをコピー'}</Primary>
            <Later onClick={later} />
          </>
        ) : effective === 'prompt' ? (
          <>
            <Why />
            <Primary onClick={() => void install()}>ホーム画面に追加する ▶</Primary>
            <Later onClick={later} />
          </>
        ) : (
          <>
            <Why />
            <Steps
              items={[
                'ブラウザのメニュー（⋮）を開く',
                '「アプリをインストール」または「ホーム画面に追加」を選ぶ',
              ]}
            />
            <Secondary onClick={done}>追加しました</Secondary>
            <Later onClick={later} />
          </>
        )}
      </div>
    </div>
  )
}

/** 追加すると何が変わるのか。App Storeに無いことも先に言っておく。 */
function Why() {
  return (
    <span style={{ fontSize: 11.5, color: C.body, lineHeight: 1.8 }}>
      ピタフレは<b style={{ color: C.ink }}>App Storeにアプリを出していません</b>。
      ホーム画面に追加すると、アイコンから一発で開けて、アドレスバーのない全画面で動きます。
      追加してもアプリのダウンロードは発生しません。
    </span>
  )
}

function Steps({ items }: { items: string[] }) {
  return (
    <ol
      style={{
        margin: 0,
        // listStyle: none + 明示の padding で、ol の既定のぶら下げインデントを消す
        listStyle: 'none',
        display: 'flex',
        flexDirection: 'column',
        gap: 8,
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 10,
        padding: '13px 14px',
      }}
    >
      {items.map((t, i) => (
        <li key={t} style={{ display: 'flex', gap: 9, alignItems: 'flex-start' }}>
          <span
            aria-hidden
            style={{
              flex: 'none',
              width: 18,
              height: 18,
              borderRadius: '50%',
              background: C.lime,
              border: `1.5px solid ${C.border}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 10,
              color: C.ink,
              lineHeight: 1,
            }}
          >
            {i + 1}
          </span>
          <span style={{ fontSize: 12, color: C.ink, lineHeight: 1.6 }}>{t}</span>
        </li>
      ))}
    </ol>
  )
}

function Primary({ onClick, children }: { onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      style={{
        cursor: 'pointer',
        background: C.ctaBg,
        color: C.ctaFg,
        border: 'none',
        borderRadius: 10,
        padding: '14px 0',
        fontSize: 15,
        fontFamily: 'inherit',
      }}
    >
      {children}
    </button>
  )
}

/**
 * 「追加しました」用。**目立たせない。**
 * この変種にはアプリ側でできる操作がなく、手順そのものが本文になる。
 * ここを塗りのCTAにすると、追加する前に反射で押されて案内が二度と出なくなる。
 */
function Secondary({ onClick, children }: { onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      style={{
        cursor: 'pointer',
        background: C.white,
        color: C.ink,
        border: `1.5px solid ${C.border}`,
        borderRadius: 10,
        padding: '13px 0',
        fontSize: 14,
        fontFamily: 'inherit',
      }}
    >
      {children}
    </button>
  )
}

function Later({ onClick }: { onClick: () => void }) {
  return (
    <span
      onClick={onClick}
      role="button"
      tabIndex={0}
      style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.muted, padding: '2px 0' }}
    >
      あとで
    </span>
  )
}
