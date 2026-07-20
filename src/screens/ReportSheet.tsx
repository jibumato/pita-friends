import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { REPORT_CATEGORIES } from '../flow'
import type { ReportCategory } from '../lib/database.types'

export default function ReportSheet({ flow }: { flow: Flow }) {
  const target = flow.reportTarget
  const [selected, setSelected] = useState<ReportCategory | null>(null)
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const nickname = target?.nickname ?? 'この相手'

  async function submit(alsoBlock: boolean) {
    if (!selected || busy) return
    setBusy(true)
    setError(null)
    try {
      await flow.submitReport(selected, alsoBlock)
      setDone(true)
    } catch (e) {
      setError(e instanceof Error ? e.message : '送信に失敗しました。時間をおいて再度お試しください')
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
        onClick={flow.closeReport}
        style={{
          position: 'absolute',
          inset: 0,
          background: 'rgba(22,18,31,.55)',
          animation: 'scrIn .2s ease both',
        }}
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
        <div
          style={{ width: 44, height: 5, borderRadius: 99, background: C.placeholder, margin: '0 auto' }}
        />

        {done ? (
          <>
            <span style={{ fontSize: 16, color: C.ink }}>受け付けました</span>
            <span style={{ fontSize: 12, color: C.body, lineHeight: 1.7, whiteSpace: 'pre-line' }}>
              {'通報ありがとうございます。運営が内容を確認します。\n悪質と判断した場合は、身分証ベースで再登録できないよう措置します。通報したことは相手に通知されません。'}
            </span>
            <div
              onClick={flow.closeReport}
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
              閉じる
            </div>
          </>
        ) : (
          <>
            <span style={{ fontSize: 16, color: C.ink }}>{nickname} さんを通報 / ブロック</span>
            <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.6 }}>
              当てはまる理由を選んでください。運営が確認し、悪質なユーザーには利用制限を行います。通報は相手に通知されません。
            </span>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {REPORT_CATEGORIES.map((r) => {
                const on = selected === r.value
                return (
                  <div
                    key={r.value}
                    role="radio"
                    aria-checked={on}
                    tabIndex={0}
                    onClick={() => setSelected(r.value)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault()
                        setSelected(r.value)
                      }
                    }}
                    style={{
                      background: on ? C.lime : C.white,
                      border: `1.5px solid ${on ? C.ink : C.border}`,
                      borderRadius: 8,
                      padding: '12px 14px',
                      fontSize: 12.5,
                      color: C.ink,
                      cursor: 'pointer',
                      display: 'flex',
                      alignItems: 'center',
                      gap: 8,
                    }}
                  >
                    <div
                      style={{
                        width: 16,
                        height: 16,
                        flex: 'none',
                        borderRadius: '50%',
                        border: `1.5px solid ${C.border}`,
                        background: on ? C.ink : C.white,
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        fontSize: 9,
                        color: C.lime,
                      }}
                    >
                      {on ? '✓' : ''}
                    </div>
                    {r.label}
                  </div>
                )
              })}
            </div>

            {error && <span style={{ fontSize: 11, color: C.avatarPink, lineHeight: 1.6 }}>{error}</span>}

            <div
              onClick={() => submit(true)}
              style={{
                background: C.fill,
                color: C.avatarPink,
                borderRadius: 8,
                padding: '14px 0',
                textAlign: 'center',
                fontSize: 14,
                boxShadow: selected && !busy ? `3px 3px 0 ${C.avatarPink}` : 'none',
                opacity: selected && !busy ? 1 : 0.5,
                cursor: selected && !busy ? 'pointer' : 'not-allowed',
              }}
            >
              {busy ? '送信中…' : 'ブロックして通報する'}
            </div>

            <div
              onClick={() => submit(false)}
              style={{
                textAlign: 'center',
                fontSize: 12.5,
                color: selected && !busy ? C.ink : C.muted,
                cursor: selected && !busy ? 'pointer' : 'not-allowed',
              }}
            >
              ブロックせず通報だけする
            </div>

            <span
              onClick={flow.closeReport}
              style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.muted }}
            >
              閉じる
            </span>
          </>
        )}
      </div>
    </div>
  )
}
