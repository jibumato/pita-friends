import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import { Shield } from '../components/Icon'
import { isBackendConfigured } from '../lib/supabase'
import {
  fetchBlockedUsers,
  unblockUser,
  fetchHiddenHosts,
  setHostHidden,
  type BlockedUser,
  type HiddenHost,
} from '../lib/queries'

export default function BlockList({ flow }: { flow: Flow }) {
  const [items, setItems] = useState<BlockedUser[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [unblocking, setUnblocking] = useState<string | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) {
      setItems([])
      return
    }
    let active = true
    fetchBlockedUsers()
      .then((data) => active && setItems(data))
      .catch((e) => active && setError(e instanceof Error ? e.message : '取得に失敗しました'))
    return () => {
      active = false
    }
  }, [])

  async function handleUnblock(userId: string) {
    if (unblocking) return
    setUnblocking(userId)
    setError(null)
    try {
      await unblockUser(userId)
      setItems((xs) => (xs ? xs.filter((x) => x.userId !== userId) : xs))
    } catch (e) {
      setError(e instanceof Error ? e.message : 'ブロック解除に失敗しました')
    } finally {
      setUnblocking(null)
    }
  }

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="ブロック・非表示" onBack={() => flow.go('settings')} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '4px 20px 24px',
          display: 'flex',
          flexDirection: 'column',
          gap: 12,
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
            ブロックした相手とは、お互いに検索・誘い・トークができなくなります。相手にブロックしたことは通知されません。
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
          <span style={{ fontSize: 12, color: C.muted, textAlign: 'center', padding: '28px 0' }}>
            ブロックしている相手はいません
          </span>
        )}

        {items?.map((u) => (
          <div
            key={u.userId}
            style={{
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 10,
              padding: '11px 13px',
              display: 'flex',
              alignItems: 'center',
              gap: 12,
            }}
          >
            <div
              style={{
                width: 40,
                height: 40,
                flex: 'none',
                borderRadius: 9,
                background: u.avatarColor,
                border: `1.5px solid ${C.border}`,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: 17,
                color: C.ink,
              }}
            >
              {u.avatarInitial}
            </div>
            <span style={{ flex: 1, fontSize: 14, color: C.ink }}>{u.nickname}</span>
            <div
              onClick={() => handleUnblock(u.userId)}
              style={{
                cursor: unblocking ? 'not-allowed' : 'pointer',
                opacity: unblocking === u.userId ? 0.6 : 1,
                fontSize: 12,
                color: C.ink,
                background: C.white,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '8px 14px',
              }}
            >
              {unblocking === u.userId ? '解除中…' : 'ブロック解除'}
            </div>
          </div>
        ))}

        {/* 0116: 非表示。ブロックと同じ画面に置くが、**別の節として分ける。**
            混ぜて並べると「弱いブロック」と読まれ、相手に何か起きると
            誤解される */}
        <HiddenSection />
      </div>
    </Screen>
  )
}

/**
 * 検索に出さないようにした相手(0116)。
 *
 * 軽い操作ほど誤タップされるので、**取り消せることのほうが大事**。
 * ここが無いと、間違えて押した相手が二度と一覧に出てこない。
 */
function HiddenSection() {
  const [items, setItems] = useState<HiddenHost[] | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) {
      setItems([])
      return
    }
    let active = true
    fetchHiddenHosts()
      .then((data) => active && setItems(data))
      .catch(() => active && setItems([]))
    return () => {
      active = false
    }
  }, [])

  // 1人もいないうちは節ごと出さない(使っていない機能の説明を読ませない)
  if (!items || items.length === 0) return null

  async function unhide(hostUserId: string) {
    if (busy) return
    setBusy(hostUserId)
    setError(null)
    try {
      await setHostHidden(hostUserId, false)
      setItems((xs) => (xs ? xs.filter((x) => x.hostUserId !== hostUserId) : xs))
    } catch (e) {
      setError(e instanceof Error ? e.message : '解除に失敗しました')
    } finally {
      setBusy(null)
    }
  }

  return (
    <>
      <span style={{ fontSize: 13, color: C.ink, marginTop: 10 }}>▶ さがす画面に出さない人</span>
      <span style={{ fontSize: 10.5, lineHeight: 1.6, color: C.muted }}>
        こちらは<b style={{ color: C.ink }}>相手に何の影響もありません</b>。
        通知は届かず、予約もトークもこれまでどおりできます。
      </span>
      {error && <span style={{ fontSize: 11, color: C.ink }}>{error}</span>}
      {items.map((u) => (
        <div
          key={u.hostUserId}
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 10,
            padding: '11px 13px',
            display: 'flex',
            alignItems: 'center',
            gap: 12,
          }}
        >
          <div
            style={{
              position: 'relative',
              width: 40,
              height: 40,
              flex: 'none',
              borderRadius: 9,
              background: u.avatarColor,
              border: `1.5px solid ${C.border}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 17,
              color: C.ink,
              overflow: 'hidden',
            }}
          >
            {u.avatarUrl ? (
              <img
                src={u.avatarUrl}
                alt=""
                style={{ position: 'absolute', inset: 0, width: '100%', height: '100%', objectFit: 'cover' }}
              />
            ) : (
              u.avatarInitial
            )}
          </div>
          <span style={{ flex: 1, fontSize: 14, color: C.ink }}>{u.nickname}</span>
          <div
            onClick={() => unhide(u.hostUserId)}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') unhide(u.hostUserId)
            }}
            style={{
              cursor: busy ? 'not-allowed' : 'pointer',
              opacity: busy === u.hostUserId ? 0.6 : 1,
              fontSize: 12,
              color: C.ink,
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '8px 14px',
            }}
          >
            {busy === u.hostUserId ? '解除中…' : 'また表示する'}
          </div>
        </div>
      ))}
    </>
  )
}
