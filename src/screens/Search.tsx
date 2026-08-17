import { useEffect, useState } from 'react'
import type { Flow, BookingHost } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import BottomTabs from '../components/BottomTabs'
import { Search as SearchIcon } from '../components/Icon'
import { EmptyState, ErrorState, SkeletonCard } from '../components/States'
import { searchUsers } from '../data/mock'
import { isBackendConfigured } from '../lib/supabase'
import SignedOutPrompt from '../components/SignedOutPrompt'
import {
  fetchDiscoverableHosts,
  fetchHostsOpenAt,
  fetchHiddenHosts,
  type OpenHost,
} from '../lib/queries'
import {
  TIME_WINDOWS,
  timeWindowRange,
  formatStart,
  type TimeWindowKey,
} from '../content/bookingPolicy'
import { subscribeOnlineUsers } from '../lib/presence'
import { useIsMobile } from '../hooks/useMediaQuery'
import { clickable } from '../hooks/clickable'
import { mannerScoreLabel, NEW_MEMBER_LABEL } from '../lib/trustDisplay'
import OnlineBadge from '../components/OnlineBadge'
import VoiceChip from '../components/VoiceChip'
import HostStatus from '../components/HostStatus'
import RepeatBadge from '../components/RepeatBadge'
import type { PresenceStatus } from '../lib/database.types'
import { GAMES, coinsPer30, SEARCH_VERIFIED_FILTER as VERIFIED_FILTER, SEARCH_DEMO_FILTERS as DEMO_FILTERS, SEARCH_REAL_FILTERS as REAL_FILTERS } from '../flow'

type Phase = 'loading' | 'results' | 'empty' | 'error'

/**
 * 並び替え(0116)。
 *
 * 既定の「おすすめ」はサーバが返した順=「また呼ばれているか」順で、
 * これは触らない(未ログインの掲載カードと同じ並びである必要があるため)。
 * 足したのは、その順のままだと**新人が永久に埋もれる**からで、
 * 新人ランキングはホームにあるのに、探す画面からは辿れなかった。
 */
type SortKey = 'recommended' | 'cheap' | 'new'
const SORTS: { key: SortKey; label: string }[] = [
  { key: 'recommended', label: 'おすすめ' },
  { key: 'cheap', label: '料金が安い順' },
  { key: 'new', label: '新人' },
]

/** デモのモックユーザーと実データのピタメイトを、カード表示用の共通形に正規化する。 */
type DisplayCard = {
  key: string
  initial: string
  color: string
  name: string
  verified: boolean
  meta: string
  scoreLabel: string
  tags: string[]
  hourlyRate?: number
  bookingHost?: BookingHost
  avatarUrl?: string | null
  lastSeenAt?: string | null
  presenceStatus?: PresenceStatus
  /** ボイスあいさつ(0024)。カードから直接聞ける。 */
  voiceUrl?: string | null
  voiceSeconds?: number | null
  /** ひとこと(0056)。 */
  statusText?: string | null
  statusUpdatedAt?: string | null
  /** 2回以上遊んだ人の数(0058)。 */
  repeatGuests?: number
  /** 「新人」の並び替えに使う(0116)。表示はしない——scoreLabel が担当。 */
  reviewCount?: number
}

function fromMock(u: (typeof searchUsers)[number]): DisplayCard {
  return {
    key: u.name,
    initial: u.initial,
    color: u.color,
    name: u.name,
    verified: true,
    meta: u.meta,
    scoreLabel: `相性${u.score}%`,
    tags: u.tags,
    hourlyRate: u.hourlyRate,
    bookingHost:
      u.hourlyRate != null
        ? { name: u.name, initial: u.initial, color: u.color, hourlyRate: u.hourlyRate }
        : undefined,
  }
}

export default function Search({ flow }: { flow: Flow }) {
  const mobile = useIsMobile()
  const signedIn = !isBackendConfigured || flow.userId !== null
  const [phase, setPhase] = useState<Phase>('loading')
  // 検索語・絞り込みチップはFlow(App)側の共通状態。デスクトップではトップバー/サイドバーからも操作する。
  const selected = flow.searchFilters
  const query = flow.searchQuery
  const [realCards, setRealCards] = useState<DisplayCard[] | null>(null)
  const [onlineIds, setOnlineIds] = useState<Set<string>>(new Set())
  // 0115: 「いつ遊ぶか」で絞る。null なら時間で絞らない(従来どおり)
  const [timeWindow, setTimeWindow] = useState<TimeWindowKey | null>(null)
  const [openHosts, setOpenHosts] = useState<Map<string, OpenHost> | null>(null)
  const [openLoading, setOpenLoading] = useState(false)
  // 0116: 自分が「検索に出さない」にした相手
  const [hidden, setHidden] = useState<Set<string>>(new Set())
  // 0116: 並び替え。既定はサーバの順(リピート実績)のまま
  const [sort, setSort] = useState<SortKey>('recommended')

  useEffect(() => {
    if (!isBackendConfigured || flow.userId === null) return
    let active = true
    fetchHiddenHosts()
      .then((rows) => active && setHidden(new Set(rows.map((r) => r.hostUserId))))
      // 取れなくても一覧は出す。**出す方向に倒す**(消える側に倒すと、
      // 通信の失敗が「その人が居なくなった」に見える)
      .catch(() => {})
    return () => {
      active = false
    }
  }, [flow.userId])

  /**
   * 選んだ範囲で予約を受けられる人を引く(0115)。
   *
   * サーバ側の判定は create_booking と同じなので、**ここに出た時刻は
   * そのまま申し込める**。人ごとに空きを問い合わせる作りにすると、
   * 一覧の人数だけ往復が増えるので、まとめて1回で取る。
   */
  useEffect(() => {
    if (!isBackendConfigured || flow.userId === null) return
    if (!timeWindow) {
      setOpenHosts(null)
      setOpenLoading(false)
      return
    }
    let active = true
    setOpenLoading(true)
    const { from, to } = timeWindowRange(timeWindow)
    fetchHostsOpenAt(from, to, flow.bookingDuration)
      .then((rows) => {
        if (!active) return
        setOpenHosts(new Map(rows.map((r) => [r.hostUserId, r])))
        setOpenLoading(false)
      })
      .catch((err) => {
        console.warn('[pita-friends] 空き時間の取得に失敗:', err)
        // 取れなかったときは**絞り込みを解除する**。空の一覧を出すと
        // 「誰も空いていない」と読めてしまい、事実と違う
        if (!active) return
        setOpenHosts(null)
        setOpenLoading(false)
        setTimeWindow(null)
      })
    return () => {
      active = false
    }
  }, [timeWindow, flow.userId, flow.bookingDuration])

  // オンライン状態(カードのオンラインドット表示用)。安心設定で公開している人のみ届く。
  useEffect(() => {
    if (!isBackendConfigured) return
    const unsubscribe = subscribeOnlineUsers(flow.userId, (users) => setOnlineIds(new Set(users.map((u) => u.userId))))
    return unsubscribe
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // 初回マウント: バックエンド接続時は実際のピタメイト一覧を取得、
  // 未接続(デモモード)時はこれまでどおり一定時間後にモック結果を表示する。
  useEffect(() => {
    // 未ログインでは取得しない。認証が要るクエリを投げても失敗し、
    // 「接続できませんでした(NET-503)」の画面になるだけ。
    if (isBackendConfigured && flow.userId === null) return
    if (!isBackendConfigured) {
      if (phase !== 'loading') return
      const t = setTimeout(() => setPhase('results'), 850)
      return () => clearTimeout(t)
    }
    let active = true
    setPhase('loading')
    fetchDiscoverableHosts(flow.userId)
      .then((hosts) => {
        if (!active) return
        const cards = hosts.map<DisplayCard>((h) => ({
          key: h.userId,
          initial: h.avatarInitial,
          color: h.avatarColor,
          name: h.nickname,
          verified: h.isVerified,
          meta: h.bio || 'よろしくお願いします！',
          // レビュー3件未満はスコアを出さない(docs/trust-safety-spec.md §1.2)
          scoreLabel: mannerScoreLabel(h.mannerScore, h.reviewCount)
            ? `${mannerScoreLabel(h.mannerScore, h.reviewCount)}・マナー◎`
            : NEW_MEMBER_LABEL,
          tags: h.games,
          hourlyRate: h.hourlyRate,
          bookingHost: {
            name: h.nickname,
            initial: h.avatarInitial,
            color: h.avatarColor,
            hourlyRate: h.hourlyRate,
            userId: h.userId,
          },
          avatarUrl: h.avatarUrl,
          lastSeenAt: h.lastSeenAt,
          presenceStatus: h.presenceStatus,
          voiceUrl: h.voiceUrl,
          voiceSeconds: h.voiceSeconds,
          statusText: h.statusText,
          statusUpdatedAt: h.statusUpdatedAt,
          repeatGuests: h.repeatGuests,
          reviewCount: h.reviewCount,
        }))
        setRealCards(cards)
        setPhase(cards.length > 0 ? 'results' : 'empty')
      })
      .catch((err) => {
        console.warn('[pita-friends] ピタメイト一覧の取得に失敗:', err)
        if (active) setPhase('error')
      })
    return () => {
      active = false
    }
    // 初回マウント時のみ実行(flow.userIdの変化では再実行しない)
  }, [])

  const allCards = isBackendConfigured ? (realCards ?? []) : searchUsers.map(fromMock)

  // 実データ時のみ、検索語・ゲーム・本人確認済みで実際に絞り込む
  const filtered = isBackendConfigured
    ? allCards.filter((c) => {
        // 0116: 自分が「検索に出さない」にした相手
        if (hidden.has(c.key)) return false
        // 時間で絞っているあいだは、その範囲で予約できる人だけ
        if (timeWindow && openHosts && !openHosts.has(c.key)) return false
        if (selected[VERIFIED_FILTER] && !c.verified) return false
        const activeGames = GAMES.filter((g) => selected[g])
        if (activeGames.length > 0 && !activeGames.some((g) => c.tags.includes(g))) return false
        const q = query.trim().toLowerCase()
        if (q) {
          const hay = `${c.name} ${c.meta} ${c.tags.join(' ')}`.toLowerCase()
          if (!hay.includes(q)) return false
        }
        return true
      })
    : allCards

  /**
   * 並び替え(0116)。
   *
   * **「おすすめ」では並べ替えない。** `fetchDiscoverableHosts` の並びは
   * 未ログインの掲載カードと揃える約束になっており(queries.ts の注記)、
   * ここで組み替えると「さっき見た人がいない」が起きる。
   * 明示的に選んだときだけ、その場で並べ替える。
   */
  const cards =
    sort === 'recommended'
      ? filtered
      : [...filtered].sort((a, b) => {
          if (sort === 'cheap') {
            // 料金未設定は末尾へ(押しても予約できないので前に出す意味がない)
            const ra = a.hourlyRate ?? Number.MAX_SAFE_INTEGER
            const rb = b.hourlyRate ?? Number.MAX_SAFE_INTEGER
            if (ra !== rb) return ra - rb
          } else {
            // レビューが少ない人ほど前へ。同数ならサーバの順を保つ
            const ca = a.reviewCount ?? 0
            const cb = b.reviewCount ?? 0
            if (ca !== cb) return ca - cb
          }
          return filtered.indexOf(a) - filtered.indexOf(b)
        })

  if (!signedIn) {
    // ピタメイトの検索はログインしてから。未ログインで叩くと認証エラーになり、
    // 「接続できませんでした」の画面が出てしまう(通信の問題だと誤解させる)。
    return (
      <Screen background={C.surface}>
        <StatusBar time="21:47" />
        <div style={{ padding: '12px 20px 0', display: 'flex', flexDirection: 'column', gap: 14 }}>
          <span style={{ fontSize: 21, color: C.ink }}>▶ さがす</span>
          <SignedOutPrompt
            flow={flow}
            title="ピタメイトをさがすには登録が必要です"
            body="ゲーム・時間帯・プレイスタイルで絞り込んで、ぴったりの相手を探せます。登録は無料で、すぐに使えます。"
          />
        </div>
        <BottomTabs current={flow.screen} onNavigate={flow.go} />
      </Screen>
    )
  }

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <div style={{ flex: 'none', padding: '12px 20px 0', display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
            <span style={{ fontSize: 21, color: C.ink }}>▶ さがす</span>
            {!mobile && phase === 'results' && (
              <span style={{ fontSize: 11.5, color: C.muted }}>
                {isBackendConfigured ? `${cards.length}人のピタメイトが見つかりました` : `${cards.length}人が条件にマッチ・相性順`}
              </span>
            )}
          </div>
          {/* デモ状態スイッチャ(ハーネス上での状態網羅プレビュー)。実データ接続時は非表示。 */}
          {!isBackendConfigured && (
            <div style={{ display: 'flex', gap: 4 }}>
              {(
                [
                  ['results', '結果'],
                  ['loading', '検索中'],
                  ['empty', '0件'],
                  ['error', 'エラー'],
                ] as [Phase, string][]
              ).map(([p, label]) => (
                <span
                  key={p}
                  onClick={() => setPhase(p)}
                  style={{
                    cursor: 'pointer',
                    fontSize: 9,
                    color: phase === p ? C.lime : C.muted,
                    background: phase === p ? C.fill : 'transparent',
                    border: `1.5px solid ${phase === p ? C.ink : C.placeholder}`,
                    padding: '2px 6px',
                    borderRadius: 4,
                  }}
                >
                  {label}
                </span>
              ))}
            </div>
          )}
        </div>
        {/* デスクトップでは検索ボックス/絞り込みチップをトップバー・サイドバーが担うため、ここは非表示。 */}
        {mobile && (
          <>
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 10,
                background: C.white,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '12px 14px',
                boxShadow: `2px 2px 0 ${C.shadowCol}`,
              }}
            >
              <SearchIcon size={16} color={C.ink} strokeWidth={2.4} />
              {isBackendConfigured ? (
                <input
                  value={query}
                  onChange={(e) => flow.setSearchQuery(e.target.value)}
                  placeholder="ゲーム名・プレイスタイルで検索"
                  style={{
                    flex: 1,
                    border: 'none',
                    outline: 'none',
                    background: 'transparent',
                    fontSize: 13,
                    color: C.ink,
                    fontFamily: 'inherit',
                  }}
                />
              ) : (
                <span style={{ fontSize: 13, color: C.placeholder }}>ゲーム名・プレイスタイルで検索</span>
              )}
            </div>
            {/* 0115: 「いつ遊ぶか」。ゲストが買っているのは「その時間に確実に
                遊べる状態」なので、ゲームより先に置く。実データのときだけ
                (デモには空き枠のデータが無く、押しても何も変わらない) */}
            {isBackendConfigured && (
              <div style={{ display: 'flex', gap: 7, alignItems: 'center', flexWrap: 'wrap' }}>
                {TIME_WINDOWS.map((w) => {
                  const sel = timeWindow === w.key
                  const toggle = () => setTimeWindow(sel ? null : w.key)
                  return (
                    <span
                      key={w.key}
                      onClick={toggle}
                      {...clickable(toggle, `${w.label}に遊べる人で絞り込む`)}
                      aria-pressed={sel}
                      style={{
                        cursor: 'pointer',
                        whiteSpace: 'nowrap',
                        fontSize: 12,
                        color: sel ? C.ink : C.body,
                        background: sel ? C.lime : C.white,
                        border: `1.5px solid ${C.border}`,
                        padding: '7px 13px',
                        borderRadius: 4,
                      }}
                    >
                      {w.label}
                    </span>
                  )
                })}
                {timeWindow && (
                  <span style={{ fontSize: 10.5, color: C.muted }}>
                    {openLoading
                      ? '空きを調べています…'
                      : `${flow.bookingDuration}分あそべる人だけ`}
                  </span>
                )}
              </div>
            )}
            {/* ゲームの絞り込みは実データだと27件あり、折り返すと画面の大半を
                占めて結果や空状態が押し出されてしまう。高さ1行の横スクロールに
                固定し、「本人確認済みのみ」は常に見える別行に置く。 */}
            <div
              className="pita-scroll"
              style={{ display: 'flex', gap: 7, overflowX: 'auto', paddingBottom: 2 }}
            >
              {(isBackendConfigured ? REAL_FILTERS : DEMO_FILTERS)
                .filter((f) => f !== VERIFIED_FILTER)
                .map((f) => {
                  const sel = !!selected[f]
                  return (
                    <span
                      key={f}
                      onClick={() => flow.toggleSearchFilter(f)}
                      {...clickable(() => flow.toggleSearchFilter(f), `${f}で絞り込む`)}
                      style={{
                        cursor: 'pointer',
                        whiteSpace: 'nowrap',
                        fontSize: 12,
                        color: sel ? C.lime : C.ink,
                        background: sel ? C.ink : C.white,
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
            {/* 0116: 並び替え。既定の「おすすめ」ではサーバの順のまま */}
            {isBackendConfigured && (
              <div style={{ display: 'flex', gap: 7, alignItems: 'center', flexWrap: 'wrap' }}>
                <span style={{ fontSize: 10.5, color: C.muted, flex: 'none' }}>並び</span>
                {SORTS.map((s) => {
                  const sel = sort === s.key
                  return (
                    <span
                      key={s.key}
                      onClick={() => setSort(s.key)}
                      {...clickable(() => setSort(s.key), `${s.label}に並べ替える`)}
                      aria-pressed={sel}
                      style={{
                        cursor: 'pointer',
                        whiteSpace: 'nowrap',
                        fontSize: 11.5,
                        color: sel ? C.lime : C.ink,
                        background: sel ? C.ink : C.white,
                        border: `1.5px solid ${C.border}`,
                        padding: '5px 11px',
                        borderRadius: 4,
                      }}
                    >
                      {s.label}
                    </span>
                  )
                })}
              </div>
            )}
            <span
              onClick={() => flow.toggleSearchFilter(VERIFIED_FILTER)}
              {...clickable(() => flow.toggleSearchFilter(VERIFIED_FILTER), '本人確認済みのみで絞り込む')}
              style={{
                cursor: 'pointer',
                alignSelf: 'flex-start',
                fontSize: 12,
                color: C.ink,
                background: selected[VERIFIED_FILTER] ? C.lime : C.white,
                border: `1.5px solid ${C.border}`,
                padding: '7px 13px',
                borderRadius: 4,
              }}
            >
              {VERIFIED_FILTER}
            </span>
          </>
        )}
      </div>

      {phase === 'results' && (
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
          {mobile && (
            <span style={{ fontSize: 11.5, color: C.muted }}>
              {isBackendConfigured ? `${cards.length}人のピタメイトが見つかりました` : `${cards.length}人が条件にマッチ · 相性順`}
            </span>
          )}
          <div
            style={{
              display: 'inline-flex',
              alignSelf: 'flex-start',
              background: C.surfaceLavender,
              border: `1.5px solid ${C.lavender}`,
              borderRadius: 8,
              padding: '8px 12px',
              gap: 7,
              alignItems: 'center',
            }}
          >
            <span style={{ fontSize: 13, flex: 'none' }}>🛡️</span>
            <span style={{ fontSize: 11, color: C.body }}>
              <b style={{ color: C.ink }}>受け身設定の人は非表示</b> ・ 誘いは承認制です
            </span>
          </div>
          {isBackendConfigured && allCards.length > 0 && cards.length === 0 && (
            <span style={{ fontSize: 12, color: C.muted, textAlign: 'center', padding: '20px 0', lineHeight: 1.8, whiteSpace: 'pre-line' }}>
              {openLoading
                ? '空きを調べています…'
                : timeWindow
                  ? `その時間に${flow.bookingDuration}分あそべるピタメイトが見つかりませんでした。\n時間を変えるか、あそぶ時間を短くしてみてください。`
                  : '条件に合うピタメイトが見つかりませんでした'}
            </span>
          )}
          <div className="search-grid">
          {cards.map((u, i) => {
            const online = isBackendConfigured ? onlineIds.has(u.key) : i % 3 !== 2
            const open = timeWindow ? openHosts?.get(u.key) : undefined
            return (
            <div
              key={u.key}
              onClick={() =>
                isBackendConfigured && u.bookingHost?.userId
                  ? flow.openProfile(u.bookingHost.userId)
                  : flow.go('profile')
              }
              style={{
                cursor: 'pointer',
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
              <div style={{ display: 'flex', gap: 11, alignItems: 'center' }}>
                <div
                  style={{
                    position: 'relative',
                    width: 50,
                    height: 50,
                    flex: 'none',
                    borderRadius: 8,
                    background: u.color,
                    border: `1.5px solid ${C.border}`,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    fontSize: 20,
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
                    u.initial
                  )}
                  {online && (
                    <span
                      aria-hidden
                      style={{
                        position: 'absolute',
                        bottom: -3,
                        right: -3,
                        width: 13,
                        height: 13,
                        borderRadius: '50%',
                        background: '#5FC26A',
                        border: `2px solid ${C.white}`,
                      }}
                    />
                  )}
                </div>
                <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 5, flexWrap: 'wrap' }}>
                    <span style={{ fontSize: 14.5, color: C.ink }}>{u.name}</span>
                    {u.verified && (
                      <span
                        aria-label="本人確認済み"
                        style={{
                          fontSize: 8.5,
                          color: C.ink,
                          background: C.lime,
                          border: `1.5px solid ${C.border}`,
                          padding: '1px 4px',
                          borderRadius: 4,
                        }}
                      >
                        ✓
                      </span>
                    )}
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 7, flexWrap: 'wrap' }}>
                    <span style={{ fontSize: 10.5, color: C.muted }}>{u.scoreLabel}</span>
                    <OnlineBadge
                      live={online}
                      lastSeenAt={u.lastSeenAt}
                      status={u.presenceStatus}
                      fontSize={10}
                    />
                    {/* 声はいちばん人となりが伝わる材料。名前のすぐ下に置く */}
                    <VoiceChip url={u.voiceUrl ?? null} seconds={u.voiceSeconds ?? null} variant="quiet" />
                    <RepeatBadge count={u.repeatGuests} size="sm" />
                  </div>
                </div>
              </div>
              <HostStatus text={u.statusText ?? null} at={u.statusUpdatedAt ?? null} />
              <span
                style={{
                  fontSize: 11,
                  color: C.body,
                  lineHeight: 1.6,
                  overflow: 'hidden',
                  display: '-webkit-box',
                  WebkitLineClamp: 2,
                  WebkitBoxOrient: 'vertical',
                }}
              >
                {u.meta}
              </span>
              <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
                {u.tags.map((t) => (
                  <span
                    key={t}
                    style={{
                      fontSize: 10,
                      color: C.body,
                      background: C.surface,
                      padding: '2px 7px',
                      borderRadius: 5,
                      border: `1.5px solid ${C.border}`,
                    }}
                  >
                    {t}
                  </span>
                ))}
              </div>
              {/* 0115: その範囲で最初に取れる時刻。押すとその時刻が入った状態で
                  予約画面に着く——「良さそうな人を開いて空きを見て閉じる」を
                  繰り返させないための近道 */}
              {open && u.bookingHost && (
                <span
                  onClick={(e) => {
                    e.stopPropagation()
                    flow.startBooking(u.bookingHost!, flow.bookingDuration)
                    flow.setBookingWhen('scheduled')
                    flow.setBookingStartAt(open.nextOpenAt)
                  }}
                  {...clickable(() => {
                    flow.startBooking(u.bookingHost!, flow.bookingDuration)
                    flow.setBookingWhen('scheduled')
                    flow.setBookingStartAt(open.nextOpenAt)
                  }, `${u.name}さんに ${formatStart(open.nextOpenAt)} から申し込む`)}
                  style={{
                    cursor: 'pointer',
                    alignSelf: 'flex-start',
                    fontSize: 11,
                    color: C.ink,
                    background: C.surfaceLavender,
                    border: `1.5px solid ${C.lavender}`,
                    padding: '5px 10px',
                    borderRadius: 6,
                  }}
                >
                  {formatStart(open.nextOpenAt)}〜 空き
                  {open.openStarts > 1 && `（ほか${open.openStarts - 1}枠）`}
                </span>
              )}
              {u.hourlyRate != null && u.bookingHost && (
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 2 }}>
                  <span style={{ fontSize: 12.5, color: C.ink }}>
                    30分 <b style={{ fontSize: 14 }}>{coinsPer30(u.hourlyRate)}</b> コイン
                  </span>
                  <span
                    onClick={(e) => {
                      e.stopPropagation()
                      flow.startBooking(u.bookingHost!)
                    }}
                    style={{
                      cursor: 'pointer',
                      fontSize: 11.5,
                      color: C.ink,
                      background: C.lime,
                      border: `1.5px solid ${C.border}`,
                      padding: '5px 12px',
                      borderRadius: 6,
                    }}
                  >
                    予約 ▶
                  </span>
                </div>
              )}
            </div>
            )
          })}
          </div>
        </div>
      )}

      {phase === 'loading' && (
        <div
          style={{
            flex: 1,
            padding: '16px 20px 0',
            display: 'flex',
            flexDirection: 'column',
            gap: 12,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <div
              style={{
                width: 16,
                height: 16,
                borderRadius: '50%',
                border: '2.5px solid #E3DEF0',
                borderTopColor: C.lavender,
                borderRightColor: C.lavender,
                animation: 'ringSpin .9s linear infinite',
              }}
            />
            <span style={{ fontSize: 11.5, color: C.muted }}>条件に合う仲間をさがしています…</span>
          </div>
          <SkeletonCard />
          <SkeletonCard dim />
        </div>
      )}

      {phase === 'empty' && (
        <EmptyState
          tileColor={C.white}
          icon={
            <svg width="42" height="42" viewBox="0 0 24 24" fill="none" stroke={C.placeholder} strokeWidth={2.2} strokeLinecap="round">
              <circle cx="11" cy="11" r="7" />
              <path d="M16.5 16.5 L21 21" />
              <path d="M8.5 11 h5" stroke={C.avatarPink} />
            </svg>
          }
          title={
            <>
              条件に合う仲間が
              <br />
              見つかりませんでした
            </>
          }
          desc={
            <>
              条件をすこしゆるめると、
              <br />
              候補がぐっと増えます
            </>
          }
          cta="募集を出して待つ ▶"
          onCta={() => flow.go('board')}
        />
      )}

      {phase === 'error' && <ErrorState code="NET-503" onRetry={() => setPhase('loading')} />}

      <BottomTabs current={flow.screen} onNavigate={flow.go} />
    </Screen>
  )
}
