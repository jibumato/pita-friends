/**
 * マイページに出す「ホーム画面に追加」の小さなカード。
 *
 * ⭐からの自動案内(armInstallGuide)は抑制がかかると出なくなるので、
 * **見つけられる場所に静かに残しておく**のがこのカードの役目。
 * すでに追加済み・PCでは出さない。閉じたら以後は出さない(設定からは開ける)。
 */
import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import {
  canAutoShowInstallGuide,
  installMode,
  openInstallGuide,
  snoozeInstallGuide,
  subscribeInstallMode,
} from '../lib/install'

export default function InstallCard() {
  // 抑制中は出さない。シートで「あとで」と言われたあとにカードだけ
  // 残しておくのはしつこい。ずっと開けておく口は設定の行のほうにある。
  const [show, setShow] = useState(() => canAutoShowInstallGuide())

  // beforeinstallprompt が遅れて届いたとき、閉じられたときに追随する
  useEffect(() => subscribeInstallMode(() => setShow(canAutoShowInstallGuide())), [])

  if (!show) return null

  const inApp = installMode() === 'inapp'

  return (
    <div
      style={{
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 12,
        boxShadow: `3px 3px 0 ${C.shadowCol}`,
        padding: '12px 14px',
        display: 'flex',
        alignItems: 'center',
        gap: 11,
      }}
    >
      <span aria-hidden style={{ flex: 'none', fontSize: 20, lineHeight: 1 }}>
        📲
      </span>
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
        <span style={{ fontSize: 12.5, color: C.ink }}>
          {inApp ? 'ブラウザで開くと、もっと使いやすく' : 'ホーム画面に追加する'}
        </span>
        <span style={{ fontSize: 10, color: C.muted, lineHeight: 1.6 }}>
          {inApp
            ? 'いまはアプリ内ブラウザです。開き直す手順を見る'
            : 'アイコンから一発で開けます（App Storeは不要）'}
        </span>
      </div>
      <button
        onClick={openInstallGuide}
        style={{
          cursor: 'pointer',
          flex: 'none',
          background: C.lime,
          color: C.ink,
          border: `1.5px solid ${C.border}`,
          borderRadius: 8,
          padding: '8px 12px',
          fontSize: 11.5,
          fontFamily: 'inherit',
        }}
      >
        手順を見る
      </button>
      <span
        onClick={snoozeInstallGuide}
        role="button"
        tabIndex={0}
        aria-label="この案内を閉じる"
        title="閉じる"
        style={{ cursor: 'pointer', flex: 'none', fontSize: 13, color: C.placeholder, padding: '0 2px' }}
      >
        ✕
      </span>
    </div>
  )
}
