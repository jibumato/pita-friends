/**
 * 設定画面の「通知」欄に足すプッシュの行(0064)。
 *
 * 状態が5通りあり、**それぞれで押せることが違う**のでここに集めてある。
 *   unsupported   … 出さない(設定するものがない)
 *   needs-install … iOSで未追加。ホーム画面への追加へ送る
 *   default       … まだ聞いていない。説明シートを開く
 *   denied        … 断られた。アプリからは出し直せないので戻し方を出す
 *   granted       … 受け取る/受け取らない と、静かにする時間
 */
import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import { ListRow, Toggle } from './Ui'
import { openInstallGuide } from '../lib/install'
import {
  fetchPushSettings,
  openPushPrompt,
  pushState,
  savePushSettings,
  type PushSettings,
  type PushState,
} from '../lib/push'

export default function PushSettingsRows() {
  const [state, setState] = useState<PushState>(() => pushState())
  const [settings, setSettings] = useState<PushSettings | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    // シートを閉じて戻ってきたときに追随させたいので、表示のたびに読み直す
    setState(pushState())
    if (pushState() !== 'granted') return
    let active = true
    fetchPushSettings()
      .then((s) => active && setSettings(s))
      .catch(() => active && setError('通知の設定を読み込めませんでした'))
    return () => {
      active = false
    }
  }, [])

  if (state === 'unsupported') return null

  if (state === 'needs-install') {
    return (
      <ListRow
        label="ロック画面に通知"
        sub="ホーム画面に追加すると使えます"
        onClick={openInstallGuide}
      />
    )
  }

  if (state === 'default') {
    return (
      <ListRow
        label="ロック画面に通知"
        sub="お気に入りのピタメイトの枠・予約の連絡を、開いていなくても受け取る"
        onClick={() => openPushPrompt('favorite')}
        right={<Toggle on={false} onToggle={() => openPushPrompt('favorite')} label="ロック画面に通知" />}
      />
    )
  }

  if (state === 'denied') {
    return (
      <ListRow
        label="ロック画面に通知"
        sub="ブロック中 — ブラウザの設定から許可し直せます"
        onClick={() => openPushPrompt('favorite')}
      />
    )
  }

  // granted
  const s = settings
  async function save(next: PushSettings) {
    setSettings(next)
    setError(null)
    try {
      await savePushSettings({ enabled: next.enabled, quietFrom: next.quietFrom, quietTo: next.quietTo })
    } catch {
      setError('設定を保存できませんでした')
    }
  }

  const quietOn = s !== null && s.quietFrom !== null && s.quietTo !== null

  return (
    <>
      <ListRow
        label="ロック画面に通知"
        sub={s ? `この端末を含め${s.devices}台で受け取り中` : '読み込み中…'}
        right={
          <Toggle
            on={s?.enabled ?? true}
            onToggle={s ? () => void save({ ...s, enabled: !s.enabled }) : undefined}
            label="ロック画面に通知"
          />
        }
      />
      <ListRow
        label="静かにする時間"
        sub={
          quietOn
            ? `${s!.quietFrom}時〜${s!.quietTo}時は、急がない通知を止めます`
            : '設定なし（深夜も届きます）'
        }
        right={
          <Toggle
            on={quietOn}
            // 既定は 0時〜7時。ゲームは夜に遊ぶので**運営からは既定で入れない**
            onToggle={
              s
                ? () =>
                    void save(
                      quietOn ? { ...s, quietFrom: null, quietTo: null } : { ...s, quietFrom: 0, quietTo: 7 },
                    )
                : undefined
            }
            label="静かにする時間"
          />
        }
      />
      {quietOn && s && (
        <div
          style={{
            padding: '4px 14px 13px',
            display: 'flex',
            alignItems: 'center',
            gap: 8,
            borderBottom: `1.5px solid ${C.divider}`,
          }}
        >
          <HourSelect
            value={s.quietFrom!}
            label="開始"
            onChange={(h) => void save({ ...s, quietFrom: h })}
          />
          <span style={{ fontSize: 12, color: C.muted }}>〜</span>
          <HourSelect value={s.quietTo!} label="終了" onChange={(h) => void save({ ...s, quietTo: h })} />
          <span style={{ fontSize: 10, color: C.muted, lineHeight: 1.5 }}>
            予約・メッセージ・誘いは、この時間でも届きます
          </span>
        </div>
      )}
      {error && <span style={{ fontSize: 10.5, color: C.avatarPink, padding: '0 14px 10px' }}>{error}</span>}
    </>
  )
}

function HourSelect({
  value,
  label,
  onChange,
}: {
  value: number
  label: string
  onChange: (h: number) => void
}) {
  return (
    <select
      value={value}
      aria-label={label}
      onChange={(e) => onChange(Number(e.target.value))}
      style={{
        background: C.white,
        color: C.ink,
        border: `1.5px solid ${C.border}`,
        borderRadius: 8,
        padding: '7px 8px',
        fontSize: 12,
        fontFamily: 'inherit',
      }}
    >
      {Array.from({ length: 24 }, (_, h) => (
        <option key={h} value={h}>
          {h}時
        </option>
      ))}
    </select>
  )
}
