import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import BottomTabs from '../components/BottomTabs'
import { Plus, PlusCircle } from '../components/Icon'
import { EmptyState } from '../components/States'
import { boardPosts } from '../data/mock'
import { isBackendConfigured } from '../lib/supabase'
import { fetchBoardPosts, joinBoardPost, type BoardPostItem } from '../lib/queries'
import { useIsMobile } from '../hooks/useMediaQuery'

const DEMO_FILTERS = ['すべて', '今夜', 'Apex', 'まったり']
const REAL_FILTERS = ['すべて', '今夜', 'Apex', 'エンジョイ']

function RealPostCard({ p, onJoined }: { p: BoardPostItem; onJoined: (id: string, full: boolean) => void }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [joined, setJoined] = useState(p.hasJoined)

  async function handleJoin() {
    if (busy || joined || p.isMine) return
    setBusy(true)
    setError(null)
    try {
      await joinBoardPost(p.id)
      setJoined(true)
      onJoined(p.id, p.joinedCount + 1 >= p.capacity)
    } catch (e) {
      setError(e instanceof Error ? e.message : '参加に失敗しました')
    } finally {
      setBusy(false)
    }
  }

  const remaining = Math.max(0, p.capacity - p.joinedCount)

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
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <span style={{ fontSize: 14, color: C.ink }}>
          {p.game} {p.mood}
        </span>
        <span
          style={{
            fontSize: 11,
            color: C.ink,
            background: C.lime,
            border: `1.5px solid ${C.border}`,
            padding: '3px 9px',
            borderRadius: 4,
          }}
        >
          あと{remaining}人
        </span>
      </div>
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
        {[p.whenText, `VC${p.vc}`, p.audience === '同性のみ' ? '同性のみ' : null, p.verifiedOnly ? '本人確認済みのみ' : null]
          .filter((t): t is string => !!t)
          .map((t) => (
            <span
              key={t}
              style={{
                fontSize: 11,
                color: C.ink,
                background: C.surfaceLavender,
                padding: '4px 10px',
                borderRadius: 4,
                border: `1.5px solid ${C.border}`,
              }}
            >
              {t}
            </span>
          ))}
      </div>
      {p.note && <span style={{ fontSize: 11.5, color: C.body, lineHeight: 1.6 }}>{p.note}</span>}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <div
          style={{
            width: 30,
            height: 30,
            borderRadius: 6,
            background: p.creatorColor,
            border: `1.5px solid ${C.border}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 13,
            color: C.ink,
          }}
        >
          {p.creatorInitial}
        </div>
        <span style={{ fontSize: 11.5, color: C.ink }}>{p.creatorName}</span>
        <span style={{ fontSize: 10.5, color: C.muted }}>★{p.creatorManner.toFixed(1)}</span>
        <div style={{ flex: 1 }} />
        {p.isMine ? (
          <span style={{ fontSize: 11, color: C.muted }}>自分の募集</span>
        ) : (
          <span
            onClick={handleJoin}
            style={{
              cursor: joined || busy ? 'default' : 'pointer',
              opacity: busy ? 0.6 : 1,
              fontSize: 12,
              color: joined ? C.ink : C.ctaFg,
              background: joined ? C.disabledBg : C.ctaBg,
              border: joined ? `1.5px solid ${C.disabledBorder}` : 'none',
              padding: '7px 16px',
              borderRadius: 4,
              boxShadow: joined ? 'none' : `2px 2px 0 ${C.lavender}`,
            }}
          >
            {joined ? '✓ 参加済み' : busy ? '処理中…' : '参加する'}
          </span>
        )}
      </div>
      {error && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{error}</span>}
    </div>
  )
}

export default function Board({ flow }: { flow: Flow }) {
  const mobile = useIsMobile()
  const [filter, setFilter] = useState('すべて')
  const [realPosts, setRealPosts] = useState<BoardPostItem[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchBoardPosts()
      .then((data) => active && setRealPosts(data))
      .catch((e) => active && setError(e instanceof Error ? e.message : '取得に失敗しました'))
    return () => {
      active = false
    }
  }, [])

  const handleJoined = (postId: string, full: boolean) => {
    if (!full) return
    // 定員に達した募集はサーバー側でclosedになる(0011: join_board_post)ので一覧から外す
    setRealPosts((xs) => (xs ? xs.filter((x) => x.id !== postId) : xs))
  }

  const filteredReal = (realPosts ?? []).filter((p) => {
    if (filter === '今夜') return p.whenText.includes('今夜')
    if (filter === 'Apex') return p.game === 'Apex'
    if (filter === 'エンジョイ') return p.mood === 'エンジョイ'
    return true
  })

  // デモ:「まったり」だけは掲示板が空(状態網羅 B2)になる従来の演出を維持
  const demoEmpty = filter === 'まったり'

  const empty = isBackendConfigured ? realPosts !== null && filteredReal.length === 0 : demoEmpty

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <div style={{ padding: '12px 20px 0', display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <span style={{ fontSize: 21, color: C.ink }}>▶ 募集板</span>
          {!mobile && (
            <div
              onClick={() => flow.go('boardCreate')}
              style={{
                cursor: 'pointer',
                display: 'flex',
                alignItems: 'center',
                gap: 6,
                background: C.lime,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '9px 15px',
                boxShadow: `2px 2px 0 ${C.shadowCol}`,
              }}
            >
              <Plus size={15} />
              <span style={{ fontSize: 12.5, color: C.ink }}>募集する</span>
            </div>
          )}
        </div>
        <div style={{ display: 'flex', gap: 7, flexWrap: 'wrap' }}>
          {(isBackendConfigured ? REAL_FILTERS : DEMO_FILTERS).map((f) => {
            const sel = filter === f
            return (
              <span
                key={f}
                onClick={() => setFilter(f)}
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
                {f}
              </span>
            )
          })}
        </div>
      </div>

      {error && (
        <div style={{ margin: '12px 20px 0', background: C.avatarPink, border: `1.5px solid ${C.border}`, borderRadius: 8, padding: '10px 12px', fontSize: 11.5, color: C.ink }}>
          {error}
        </div>
      )}

      {isBackendConfigured && realPosts === null && !error ? (
        <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <span style={{ fontSize: 12, color: C.muted }}>読み込み中…</span>
        </div>
      ) : empty ? (
        <EmptyState
          tileColor={C.avatarAqua}
          icon={<PlusCircle size={44} color={C.ink} strokeWidth={2.4} />}
          title={
            <>
              今この条件の募集は
              <br />
              まだありません
            </>
          }
          desc={
            <>
              最初の募集を出すと、
              <br />
              いちばん上に表示されます
            </>
          }
          cta="＋ 募集をつくる"
          onCta={() => flow.go('boardCreate')}
        />
      ) : (
        <div
          className="pita-scroll"
          style={{
            flex: 1,
            overflowY: 'auto',
            padding: '16px 20px 0',
            display: 'flex',
            flexDirection: 'column',
            gap: 12,
          }}
        >
          <div className="search-grid">
          {isBackendConfigured
            ? filteredReal.map((p) => <RealPostCard key={p.id} p={p} onJoined={handleJoined} />)
            : boardPosts.map((p) => (
                <div
                  key={p.title}
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
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <span style={{ fontSize: 14, color: C.ink }}>{p.title}</span>
                    <span
                      style={{
                        fontSize: 11,
                        color: C.ink,
                        background: C.lime,
                        border: `1.5px solid ${C.border}`,
                        padding: '3px 9px',
                        borderRadius: 4,
                      }}
                    >
                      {p.slots}
                    </span>
                  </div>
                  <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                    {p.tags.map((t) => (
                      <span
                        key={t}
                        style={{
                          fontSize: 11,
                          color: C.ink,
                          background: C.surfaceLavender,
                          padding: '4px 10px',
                          borderRadius: 4,
                          border: `1.5px solid ${C.border}`,
                        }}
                      >
                        {t}
                      </span>
                    ))}
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <div
                      style={{
                        width: 30,
                        height: 30,
                        borderRadius: 6,
                        background: p.host.color,
                        border: `1.5px solid ${C.border}`,
                        display: 'flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        fontSize: 13,
                        color: C.ink,
                      }}
                    >
                      {p.host.initial}
                    </div>
                    <span style={{ fontSize: 11.5, color: C.ink }}>{p.host.name}</span>
                    <span
                      style={{
                        fontSize: 9.5,
                        color: C.ink,
                        background: C.lime,
                        border: `1.5px solid ${C.border}`,
                        padding: '1px 6px',
                        borderRadius: 4,
                      }}
                    >
                      ✓
                    </span>
                    <span style={{ fontSize: 10.5, color: C.muted }}>{p.host.score}</span>
                    <div style={{ flex: 1 }} />
                    <span
                      onClick={() => flow.go('talk')}
                      style={{
                        cursor: 'pointer',
                        fontSize: 12,
                        color: C.ctaFg,
                        background: C.ctaBg,
                        padding: '7px 16px',
                        borderRadius: 4,
                        boxShadow: `2px 2px 0 ${C.lavender}`,
                      }}
                    >
                      参加する
                    </span>
                  </div>
                </div>
              ))}
          </div>
        </div>
      )}

      {mobile && !empty && (
        <div
          onClick={() => flow.go('boardCreate')}
          style={{
            position: 'absolute',
            right: 18,
            bottom: 104,
            display: 'flex',
            alignItems: 'center',
            gap: 7,
            background: C.lime,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '12px 16px',
            boxShadow: `3px 3px 0 ${C.shadowCol}`,
            cursor: 'pointer',
          }}
        >
          <Plus />
          <span style={{ fontSize: 13, color: C.ink }}>募集する</span>
        </div>
      )}

      <BottomTabs current={flow.screen} onNavigate={flow.go} />
    </Screen>
  )
}
