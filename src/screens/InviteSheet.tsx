import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { Shield } from '../components/Icon'
import { GAMES, WHENS } from '../flow'
import { usePress } from '../hooks/usePress'
import { isBackendConfigured } from '../lib/supabase'

function PickRow({
  options,
  value,
  onPick,
}: {
  options: readonly string[]
  value: string
  onPick: (v: string) => void
}) {
  return (
    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
      {options.map((o) => {
        const sel = value === o
        return (
          <span
            key={o}
            onClick={() => onPick(o)}
            style={{
              cursor: 'pointer',
              fontSize: 12,
              color: sel ? C.lime : C.ink,
              background: sel ? C.fill : C.white,
              border: `1.5px solid ${C.border}`,
              padding: '7px 13px',
              borderRadius: 4,
            }}
          >
            {o}
          </span>
        )
      })}
    </div>
  )
}

export default function InviteSheet({ flow }: { flow: Flow }) {
  const send = usePress(`3px 3px 0 ${C.lavender}`)
  const target = flow.inviteTarget
  const useReal = isBackendConfigured && !!target

  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)
  const [sent, setSent] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const name = useReal ? target!.name : 'みなと'
  const initial = useReal ? name.charAt(0) : 'み'

  const dismiss = () => {
    if (useReal && target) flow.openProfile(target.userId)
    else flow.go('profile')
  }

  async function handleSend() {
    if (busy) return
    setBusy(true)
    setError(null)
    try {
      await flow.submitInvite(flow.game, flow.when, message.trim())
      setSent(true)
    } catch (e) {
      setError(e instanceof Error ? e.message : '送信に失敗しました')
      setBusy(false)
    }
  }

  return (
    <div
      style={{
        position: 'absolute',
        inset: 0,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'flex-end',
      }}
    >
      <div
        onClick={dismiss}
        style={{ position: 'absolute', inset: 0, background: 'rgba(22,18,31,.55)', animation: 'scrIn .2s ease both' }}
      />
      <div
        style={{
          position: 'relative',
          background: C.surface,
          borderTop: `1.5px solid ${C.border}`,
          borderRadius: '20px 20px 0 0',
          padding: '14px 20px 30px',
          display: 'flex',
          flexDirection: 'column',
          gap: 14,
          animation: 'sheetUp .3s cubic-bezier(.2,.9,.3,1) both',
        }}
      >
        <div style={{ width: 44, height: 5, borderRadius: 99, background: C.placeholder, margin: '0 auto' }} />

        {sent ? (
          <>
            <span style={{ fontSize: 16, color: C.ink }}>誘いを送りました</span>
            <span style={{ fontSize: 12, color: C.body, lineHeight: 1.7 }}>
              {name} さんが承認すると、いっしょに遊べます。承認されるまで、相手にあなたのトーク・連絡先は開きません。
            </span>
            <div
              onClick={() => flow.go('home')}
              style={{
                background: C.ctaBg,
                color: C.ctaFg,
                borderRadius: 8,
                padding: '14px 0',
                textAlign: 'center',
                fontSize: 14,
                cursor: 'pointer',
              }}
            >
              ホームへ戻る
            </div>
          </>
        ) : (
          <>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <div
                style={{
                  width: 44,
                  height: 44,
                  borderRadius: 8,
                  background: C.avatarAqua,
                  border: `1.5px solid ${C.border}`,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontSize: 19,
                  color: C.ink,
                }}
              >
                {initial}
              </div>
              <span style={{ fontSize: 16, color: C.ink }}>{name}さんを誘う</span>
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <span style={{ fontSize: 12, color: C.muted }}>ゲーム</span>
              <PickRow options={GAMES} value={flow.game} onPick={flow.setGame} />
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <span style={{ fontSize: 12, color: C.muted }}>日時</span>
              <PickRow options={WHENS} value={flow.when} onPick={flow.setWhen} />
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <span style={{ fontSize: 12, color: C.muted }}>メッセージ(任意)</span>
              {useReal ? (
                <textarea
                  value={message}
                  onChange={(e) => setMessage(e.target.value)}
                  maxLength={200}
                  placeholder="はじめまして！ゴールド帯でランク回しませんか?"
                  style={{
                    background: C.white,
                    border: `1.5px solid ${C.border}`,
                    borderRadius: 8,
                    padding: '12px 14px',
                    minHeight: 60,
                    fontSize: 12.5,
                    color: C.ink,
                    resize: 'none',
                    fontFamily: 'inherit',
                    outline: 'none',
                  }}
                />
              ) : (
                <div style={{ background: C.white, border: `1.5px solid ${C.border}`, borderRadius: 8, padding: '12px 14px', minHeight: 44 }}>
                  <span style={{ fontSize: 12.5, color: C.placeholder }}>
                    はじめまして！ゴールド帯でランク回しませんか?
                  </span>
                </div>
              )}
            </div>

            <div
              style={{
                background: C.surfaceLavender,
                border: `1.5px solid ${C.lavender}`,
                borderRadius: 8,
                padding: '10px 12px',
                display: 'flex',
                gap: 8,
                alignItems: 'flex-start',
              }}
            >
              <Shield style={{ flex: 'none', marginTop: 1 }} />
              <span style={{ fontSize: 10.5, lineHeight: 1.6, color: C.body }}>
                やり取りと通話はアプリ内で完結します。外部アプリへの誘導や、アプリ外での直接の金銭要求は通報の対象です。
              </span>
            </div>

            {error && <span style={{ fontSize: 11, color: C.avatarPink, lineHeight: 1.6 }}>{error}</span>}

            <div
              className="pita-press"
              onClick={useReal ? handleSend : flow.sendInvite}
              {...(busy ? {} : send.handlers)}
              style={{
                cursor: busy ? 'not-allowed' : 'pointer',
                opacity: busy ? 0.6 : 1,
                background: C.ctaBg,
                color: C.ctaFg,
                borderRadius: 8,
                padding: '14px 0',
                textAlign: 'center',
                fontSize: 14,
                ...(busy ? {} : send.style),
              }}
            >
              {busy ? '送信中…' : '誘いを送る ▶'}
            </div>

            {!useReal && (
              <span
                onClick={flow.openSendFail}
                style={{ cursor: 'pointer', textAlign: 'center', fontSize: 10.5, color: C.placeholder }}
              >
                相手がオフラインのとき(デモ) →
              </span>
            )}
          </>
        )}
      </div>
    </div>
  )
}
