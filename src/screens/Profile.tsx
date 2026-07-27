import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import { ChevronLeft, DotsHorizontal, Heart } from '../components/Icon'
import { usePress } from '../hooks/usePress'
import { isBackendConfigured } from '../lib/supabase'
import { fetchPublicProfile, fetchHostSchedule, type PublicProfile } from '../lib/queries'
import ScheduleGrid, { buildScheduleView, type SlotState } from '../components/ScheduleGrid'
import { coinsPer30, screenNames } from '../flow'
import { mannerScoreLabel, dotakyanLabel, NEW_MEMBER_LABEL } from '../lib/trustDisplay'
import OnlineBadge from '../components/OnlineBadge'
import { subscribeOnlineUsers } from '../lib/presence'
import FavoriteStar from '../components/FavoriteStar'
import { fetchMyFavorites } from '../lib/queries'

/* ---- デモ(モック)用の固定データ ---- */
const MOCK_STATS = [
  { value: '★4.9', label: 'マナースコア', bg: C.white, fg: C.lavender, sub: C.muted },
  { value: '0%', label: 'ドタキャン率', bg: C.lime, fg: C.ink, sub: C.ink },
  { value: '132', label: '一緒に遊んだ', bg: C.white, fg: C.ink, sub: C.muted },
]
const WEEK = [
  { d: '月', on: true }, { d: '火', on: true }, { d: '水', on: false }, { d: '木', on: true },
  { d: '金', on: true }, { d: '土', on: false }, { d: '日', on: false },
]
const MOCK_GAME_TAGS = [
  { name: 'Apex', rank: 'ゴールドⅡ' }, { name: 'VALORANT', rank: 'シルバーⅠ' },
  { name: 'マイクラ', rank: '' }, { name: 'あつ森', rank: '' },
]

function StatTile({ value, label, bg, fg, sub }: { value: string; label: string; bg: string; fg: string; sub: string }) {
  return (
    <div
      style={{
        flex: 1,
        background: bg,
        border: `1.5px solid ${C.border}`,
        borderRadius: 8,
        boxShadow: `2px 2px 0 ${C.shadowCol}`,
        padding: '10px 6px',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        gap: 2,
      }}
    >
      {/* 「実績これから」のような文言も入るため、長さに応じて縮める */}
      <span style={{ fontSize: value.length > 5 ? 11 : 16, color: fg, textAlign: 'center' }}>{value}</span>
      <span style={{ fontSize: 9.5, color: sub }}>{label}</span>
    </div>
  )
}

export default function Profile({ flow }: { flow: Flow }) {
  const cta = usePress(`3px 3px 0 ${C.lavender}`)
  const targetId = flow.profileUserId
  const useReal = isBackendConfigured && !!targetId
  // 推し登録の状態。自分自身のページには出さない。
  const [isFav, setIsFav] = useState<boolean | null>(null)

  const [live, setLive] = useState(false)
  const [data, setData] = useState<PublicProfile | null>(null)
  const [loading, setLoading] = useState(useReal)
  const [error, setError] = useState<string | null>(null)
  // 空き状況のタイル(0051)。ピタメイトでない相手には枠が無いので空配列になる。
  const [schedule, setSchedule] = useState<{ slotAt: Date; state: SlotState }[]>([])

  useEffect(() => {
    if (!useReal || !targetId || targetId === flow.userId) return
    let active = true
    fetchMyFavorites()
      .then((f) => active && setIsFav(f.some((x) => x.userId === targetId)))
      .catch(() => active && setIsFav(false))
    return () => {
      active = false
    }
  }, [useReal, targetId, flow.userId])

  useEffect(() => {
    if (!useReal || !targetId) return
    let active = true
    setLoading(true)
    fetchPublicProfile(targetId)
      .then((p) => {
        if (!active) return
        if (!p) setError('プロフィールが見つかりませんでした')
        else setData(p)
      })
      .catch((e) => active && setError(e instanceof Error ? e.message : '取得に失敗しました'))
      .finally(() => active && setLoading(false))
    return () => {
      active = false
    }
  }, [useReal, targetId])

  useEffect(() => {
    if (!useReal || !targetId) return
    let active = true
    fetchHostSchedule(targetId, 7)
      .then((rows) => {
        if (!active) return
        // 1枠も募集していない相手では、タイルを出しても意味がないので隠す
        setSchedule(rows.some((r) => r.state === 'open' || r.state === 'booked') ? rows : [])
      })
      .catch(() => active && setSchedule([]))
    return () => {
      active = false
    }
  }, [useReal, targetId])

  // Realtime Presence でいま接続中かを見る(last_seen_at より確実なので優先)。
  useEffect(() => {
    if (!useReal || !targetId) return
    return subscribeOnlineUsers(flow.userId, (users) => setLive(users.some((u) => u.userId === targetId)))
  }, [useReal, targetId, flow.userId])

  // 戻り先は開いた画面(さがす/ホーム/募集…)。デモ・実データを問わず元の一覧に戻す。
  const back = () => flow.go(flow.profileReturn)

  // 表示値(実データ or モック)
  const name = useReal ? data?.nickname ?? '' : 'みなと'
  const initial = useReal ? data?.avatarInitial ?? '?' : 'み'
  const avatarColor = useReal ? data?.avatarColor ?? C.avatarAqua : C.avatarAqua
  const avatarUrl = useReal ? data?.avatarUrl ?? null : null
  const verified = useReal ? !!data?.isVerified : true
  const subtitle = useReal
    ? data?.isHost
      ? `ピタメイト · 30分 ${coinsPer30(data.hourlyRate)} コイン`
      : 'ゲーマー'
    : '社会人ゲーマー · 平日夜メイン · 都内'
  const bio = useReal ? data?.bio ?? '' : '仕事終わりの21時から遊べます。ランクはガチすぎず、笑いながら上を目指したい派。建築ゲーも好きなのでまったり勢も歓迎です。'

  const realStats = data
    ? [
        // 実績が少ないうちは数値を出さない(docs/trust-safety-spec.md §1.2 / §2.2)
        {
          value: mannerScoreLabel(data.mannerScore, data.reviewCount) ?? NEW_MEMBER_LABEL,
          label: 'マナースコア',
          bg: C.white,
          fg: C.lavender,
          sub: C.muted,
        },
        {
          value: dotakyanLabel(data.dotakyanRate, data.confirmedCount),
          label: 'ドタキャン率',
          bg: C.lime,
          fg: C.ink,
          sub: C.ink,
        },
        { value: `${data.confirmedCount}`, label: '一緒に遊んだ', bg: C.white, fg: C.ink, sub: C.muted },
      ]
    : []
  const stats = useReal ? realStats : MOCK_STATS

  const onCta = () => {
    if (useReal && data) {
      if (data.isHost) {
        flow.startBooking({
          name: data.nickname,
          initial: data.avatarInitial,
          color: data.avatarColor,
          hourlyRate: data.hourlyRate,
          userId: data.userId,
        })
      } else {
        flow.openInvite(data.userId, data.nickname)
      }
    } else {
      flow.go('invite')
    }
  }
  const ctaLabel = useReal && data?.isHost ? '予約する ▶' : 'いっしょに遊ぶ ▶'

  return (
    <Screen background={C.surface}>
      {/* ラベンダーヘッダー */}
      <div
        style={{
          background: C.lavender,
          borderBottom: `1.5px solid ${C.border}`,
          padding: '14px 24px 0',
          display: 'flex',
          flexDirection: 'column',
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 0 40px' }}>
          {/* 戻る: 下部ナビが隠れる画面なので、アイコンだけでなくラベル付きの
              十分な当たり判定を持たせて「出口」が一目で分かるようにする。 */}
          <div
            onClick={back}
            role="button"
            tabIndex={0}
            aria-label={`${screenNames[flow.profileReturn]}に戻る`}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') back()
            }}
            style={{
              cursor: 'pointer',
              display: 'inline-flex',
              alignItems: 'center',
              gap: 3,
              margin: '-8px -6px',
              padding: '8px 10px 8px 6px',
              borderRadius: 8,
              color: '#fff',
              fontSize: 12.5,
            }}
          >
            <ChevronLeft color="#fff" />
            {screenNames[flow.profileReturn]}
          </div>
          {/* ⋯: 実データの相手なら通報/ブロックを開く */}
          <div
            onClick={targetId ? () => flow.openReport({ userId: targetId, nickname: name || 'この相手' }) : undefined}
            style={{ cursor: targetId ? 'pointer' : 'default' }}
            aria-label={targetId ? '通報・ブロック' : undefined}
          >
            <DotsHorizontal color="#fff" />
          </div>
        </div>
      </div>

      {loading ? (
        <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <span style={{ fontSize: 12, color: C.muted }}>読み込み中…</span>
        </div>
      ) : error ? (
        <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 24 }}>
          <span style={{ fontSize: 12.5, color: C.muted, textAlign: 'center' }}>{error}</span>
        </div>
      ) : (
        <div
          className="pita-scroll"
          style={{ flex: 1, overflowY: 'auto', display: 'flex', flexDirection: 'column', padding: '0 20px 16px', gap: 12 }}
        >
          <div style={{ display: 'flex', alignItems: 'flex-end', gap: 14, marginTop: -32 }}>
            <div
              style={{
                position: 'relative',
                width: 86,
                height: 86,
                borderRadius: 16,
                background: avatarColor,
                border: `1.5px solid ${C.border}`,
                boxShadow: `4px 4px 0 ${C.shadowCol}`,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: 34,
                color: C.ink,
                overflow: 'hidden',
              }}
            >
              {avatarUrl ? (
                <img
                  src={avatarUrl}
                  alt=""
                  style={{ position: 'absolute', inset: 0, width: '100%', height: '100%', objectFit: 'cover' }}
                />
              ) : (
                initial
              )}
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4, paddingBottom: 4 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 7, flexWrap: 'wrap' }}>
                <span style={{ fontSize: 20, color: C.ink }}>{name}</span>
                {/* 推し登録。相手には人数だけが伝わり、誰が押したかは伝わらない(0053) */}
                {targetId && targetId !== flow.userId && isFav !== null && (
                  <FavoriteStar hostId={targetId} initialOn={isFav} size={28} onChanged={setIsFav} />
                )}
                {verified && (
                  <span
                    style={{
                      fontSize: 9.5,
                      color: C.ink,
                      background: C.lime,
                      border: `1.5px solid ${C.border}`,
                      padding: '3px 8px',
                      borderRadius: 4,
                    }}
                  >
                    ✓ 本人確認済み
                  </span>
                )}
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                <span style={{ fontSize: 11, color: C.muted }}>{subtitle}</span>
                <OnlineBadge
                  live={live}
                  lastSeenAt={data?.lastSeenAt}
                  status={data?.presenceStatus}
                  fontSize={10.5}
                />
              </div>
            </div>
          </div>

          <div style={{ display: 'flex', gap: 8 }}>
            {stats.map((s) => (
              <StatTile key={s.label} {...s} />
            ))}
          </div>

          {bio && (
            <p style={{ margin: 0, fontSize: 12.5, lineHeight: 1.7, color: C.body }}>{bio}</p>
          )}

          {/* ボイスプロフィール */}
          {useReal && data?.voiceUrl && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                <span style={{ fontSize: 13, color: C.ink }}>🎤 ボイスプロフィール</span>
                {targetId && (
                  <span
                    onClick={() => flow.openReport({ userId: targetId, nickname: name || 'この相手' })}
                    style={{ cursor: 'pointer', fontSize: 10.5, color: C.muted, textDecoration: 'underline' }}
                  >
                    🚩 通報
                  </span>
                )}
              </div>
              <audio src={data.voiceUrl} controls style={{ width: '100%', height: 38 }} />
            </div>
          )}

          {/* あそぶゲーム */}
          {(useReal ? (data?.games.length ?? 0) > 0 : true) && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <span style={{ fontSize: 13, color: C.ink }}>▶ よく遊ぶゲーム</span>
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                {(useReal ? (data?.games ?? []).map((n) => ({ name: n, rank: '' })) : MOCK_GAME_TAGS).map((g) => (
                  <span
                    key={g.name}
                    style={{
                      fontSize: 11,
                      color: C.ink,
                      background: C.white,
                      border: `1.5px solid ${C.border}`,
                      padding: '6px 11px',
                      borderRadius: 4,
                    }}
                  >
                    {g.name} {g.rank && <b style={{ color: C.lavender }}>{g.rank}</b>}
                  </span>
                ))}
              </div>
            </div>
          )}

          {/* あそべる時間。1マス=1時間で、募集中・予約済み・募集なしが一目で分かる。
              曜日だけの表示だと「今週の何時が空いているか」が分からないので、
              日付 × 時間のタイルにしている(0051)。 */}
          {useReal ? (
            schedule.length > 0 && (
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                <span style={{ fontSize: 13, color: C.ink }}>▶ あそべる時間</span>
                <ScheduleGrid {...buildScheduleView(schedule)} />
              </div>
            )
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <span style={{ fontSize: 13, color: C.ink }}>▶ あそべる時間</span>
              <div style={{ display: 'flex', gap: 5 }}>
                {WEEK.map((w) => (
                  <div key={w.d} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4 }}>
                    <span style={{ fontSize: 10, color: C.muted }}>{w.d}</span>
                    <div style={{ width: '100%', height: 24, borderRadius: 4, background: w.on ? C.lavender : C.white, border: `1.5px solid ${C.border}` }} />
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* レビュー */}
          {useReal ? (
            data?.latestReview ? (
              <div
                style={{
                  background: C.white,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 8,
                  boxShadow: `2px 2px 0 ${C.shadowCol}`,
                  padding: '12px 14px',
                  display: 'flex',
                  flexDirection: 'column',
                  gap: 6,
                }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <span style={{ fontSize: 12, color: C.ink }}>{data.latestReview.reviewerName} さんからのレビュー</span>
                  <span style={{ fontSize: 11, color: C.avatarOrange }}>{'★'.repeat(data.latestReview.stars)}</span>
                </div>
                {data.latestReview.tags.length > 0 && (
                  <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                    {data.latestReview.tags.map((t) => (
                      <span key={t} style={{ fontSize: 10.5, color: C.body, background: C.surfaceLavender, border: `1.5px solid ${C.lavender}`, padding: '3px 8px', borderRadius: 4 }}>
                        {t}
                      </span>
                    ))}
                  </div>
                )}
              </div>
            ) : (
              <span style={{ fontSize: 11.5, color: C.muted, padding: '4px 0' }}>まだレビューはありません</span>
            )
          ) : (
            <div
              style={{
                background: C.white,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                boxShadow: `2px 2px 0 ${C.shadowCol}`,
                padding: '12px 14px',
                display: 'flex',
                flexDirection: 'column',
                gap: 5,
              }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <span style={{ fontSize: 12, color: C.ink }}>るか さんからのレビュー</span>
                <span style={{ fontSize: 11, color: C.avatarOrange }}>★★★★★</span>
              </div>
              <p style={{ margin: 0, fontSize: 11.5, lineHeight: 1.6, color: C.muted }}>
                時間ぴったりに来てくれて、負けても空気が重くならない神フレでした！
              </p>
            </div>
          )}
        </div>
      )}

      {/* フッターCTA */}
      {!loading && !error && (
        <div style={{ display: 'flex', gap: 10, padding: '12px 20px 26px', background: C.white, borderTop: `1.5px solid ${C.border}` }}>
          {!useReal && (
            <div
              style={{
                width: 50,
                height: 50,
                borderRadius: 8,
                background: C.white,
                border: `1.5px solid ${C.border}`,
                boxShadow: `2px 2px 0 ${C.shadowCol}`,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
              }}
            >
              <Heart />
            </div>
          )}
          <div
            className="pita-press"
            onClick={onCta}
            {...cta.handlers}
            style={{
              cursor: 'pointer',
              flex: 1,
              background: C.ctaBg,
              color: C.ctaFg,
              borderRadius: 8,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 15,
              padding: '15px 0',
              ...cta.style,
            }}
          >
            {ctaLabel}
          </div>
        </div>
      )}
    </Screen>
  )
}
