import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { Shield } from '../components/Icon'
import {
  approveVerification,
  fetchPendingVerifications,
  getSignedVerificationImageUrl,
  rejectVerification,
  type PendingVerification,
} from '../lib/queries'
import { usePress } from '../hooks/usePress'

function ImageThumb({ label, path }: { label: string; path: string | null }) {
  const [url, setUrl] = useState<string | null>(null)
  const [error, setError] = useState(false)

  useEffect(() => {
    if (!path) return
    let active = true
    getSignedVerificationImageUrl(path)
      .then((u) => {
        if (active) setUrl(u)
      })
      .catch(() => {
        if (active) setError(true)
      })
    return () => {
      active = false
    }
  }, [path])

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 4, flex: 1 }}>
      <span style={{ fontSize: 10, color: C.muted }}>{label}</span>
      {!path || error ? (
        <div
          style={{
            aspectRatio: '4/3',
            background: C.disabledBg,
            border: `1.5px solid ${C.disabledBorder}`,
            borderRadius: 8,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 10,
            color: C.disabledFg,
          }}
        >
          画像なし
        </div>
      ) : url ? (
        <a href={url} target="_blank" rel="noreferrer">
          <img
            src={url}
            alt={label}
            style={{
              width: '100%',
              aspectRatio: '4/3',
              objectFit: 'cover',
              borderRadius: 8,
              border: `1.5px solid ${C.border}`,
            }}
          />
        </a>
      ) : (
        <div
          style={{
            aspectRatio: '4/3',
            background: C.disabledBg,
            borderRadius: 8,
            border: `1.5px solid ${C.disabledBorder}`,
          }}
        />
      )}
    </div>
  )
}

function VerificationCard({
  v,
  onDecide,
}: {
  v: PendingVerification
  onDecide: (id: string) => void
}) {
  const [isAdultChecked, setIsAdultChecked] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const approve = usePress(`2px 2px 0 ${C.shadowCol}`)
  const reject = usePress(`2px 2px 0 ${C.shadowCol}`)

  async function handleApprove() {
    if (!isAdultChecked || busy) return
    setBusy(true)
    setError(null)
    try {
      await approveVerification(v.id, true)
      onDecide(v.id)
    } catch (e) {
      setError(e instanceof Error ? e.message : '承認に失敗しました')
      setBusy(false)
    }
  }

  async function handleReject() {
    if (busy) return
    const reason = window.prompt('却下理由(ユーザーには表示されません。運営メモとして保存)', '書類が不鮮明') ?? ''
    setBusy(true)
    setError(null)
    try {
      await rejectVerification(v.id, reason)
      onDecide(v.id)
    } catch (e) {
      setError(e instanceof Error ? e.message : '却下に失敗しました')
      setBusy(false)
    }
  }

  return (
    <div
      style={{
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 12,
        boxShadow: `3px 3px 0 ${C.shadowCol}`,
        padding: 14,
        display: 'flex',
        flexDirection: 'column',
        gap: 10,
      }}
    >
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
        <span style={{ fontSize: 14, color: C.ink }}>{v.nickname}</span>
        <span style={{ fontSize: 10, color: C.muted }}>{new Date(v.createdAt).toLocaleString('ja-JP')}</span>
      </div>

      <div style={{ display: 'flex', gap: 10 }}>
        <ImageThumb label="本人確認書類" path={v.documentPath} />
        <ImageThumb label="顔写真" path={v.selfiePath} />
      </div>

      <div
        onClick={() => setIsAdultChecked((x) => !x)}
        role="checkbox"
        aria-checked={isAdultChecked}
        tabIndex={0}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            setIsAdultChecked((x) => !x)
          }
        }}
        style={{
          cursor: 'pointer',
          display: 'flex',
          alignItems: 'center',
          gap: 8,
          background: isAdultChecked ? C.lime : C.surface,
          border: `1.5px solid ${C.border}`,
          borderRadius: 8,
          padding: '9px 11px',
        }}
      >
        <div
          style={{
            width: 18,
            height: 18,
            flex: 'none',
            borderRadius: 5,
            border: `1.5px solid ${C.border}`,
            background: isAdultChecked ? C.ink : C.white,
            color: C.lime,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 11,
          }}
        >
          {isAdultChecked ? '✓' : ''}
        </div>
        <span style={{ fontSize: 11, color: C.ink }}>書類の生年月日から18歳以上であることを確認した</span>
      </div>

      {error && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{error}</span>}

      <div style={{ display: 'flex', gap: 8 }}>
        <div
          className="pita-press"
          onClick={handleReject}
          {...reject.handlers}
          style={{
            flex: 1,
            cursor: busy ? 'not-allowed' : 'pointer',
            opacity: busy ? 0.6 : 1,
            textAlign: 'center',
            fontSize: 12.5,
            color: C.ink,
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '10px 0',
            ...reject.style,
          }}
        >
          却下
        </div>
        <div
          className="pita-press"
          onClick={handleApprove}
          {...(isAdultChecked && !busy ? approve.handlers : {})}
          style={{
            flex: 1.6,
            cursor: isAdultChecked && !busy ? 'pointer' : 'not-allowed',
            opacity: isAdultChecked && !busy ? 1 : 0.55,
            textAlign: 'center',
            fontSize: 12.5,
            color: C.ink,
            background: C.lime,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '10px 0',
            ...(isAdultChecked && !busy ? approve.style : {}),
          }}
        >
          {busy ? '処理中…' : '✓ 承認する'}
        </div>
      </div>
    </div>
  )
}

export default function AdminVerifications({ flow }: { flow: Flow }) {
  const [items, setItems] = useState<PendingVerification[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!flow.isAdmin) {
      flow.go('mypage')
      return
    }
    let active = true
    fetchPendingVerifications()
      .then((data) => {
        if (active) setItems(data)
      })
      .catch((e) => {
        if (active) setError(e instanceof Error ? e.message : '取得に失敗しました')
      })
    return () => {
      active = false
    }
    // 初回マウント時のみ
  }, [flow.isAdmin])

  if (!flow.isAdmin) return null

  const removeItem = (id: string) => setItems((xs) => (xs ? xs.filter((x) => x.id !== id) : xs))

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="本人確認の審査" onBack={() => flow.go('mypage')} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '4px 20px 24px',
          display: 'flex',
          flexDirection: 'column',
          gap: 14,
        }}
      >
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
          <Shield size={14} style={{ flex: 'none', marginTop: 1 }} />
          <span style={{ fontSize: 10.5, lineHeight: 1.6, color: C.body }}>
            承認・却下すると、書類・顔写真の画像はサーバー側で自動的に削除されます。
          </span>
        </div>

        {error && (
          <div
            style={{
              background: C.avatarPink,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '11px 13px',
              fontSize: 12,
              color: C.ink,
            }}
          >
            {error}
          </div>
        )}

        {items === null && !error && (
          <span style={{ fontSize: 12, color: C.muted, textAlign: 'center', padding: '20px 0' }}>
            読み込み中…
          </span>
        )}

        {items !== null && items.length === 0 && (
          <span style={{ fontSize: 12, color: C.muted, textAlign: 'center', padding: '20px 0' }}>
            審査待ちの申請はありません
          </span>
        )}

        {items?.map((v) => (
          <VerificationCard key={v.id} v={v} onDecide={removeItem} />
        ))}
      </div>
    </Screen>
  )
}
