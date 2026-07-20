import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import { ChevronLeft, DotsHorizontal, Heart } from '../components/Icon'
import { usePress } from '../hooks/usePress'
import { isBackendConfigured } from '../lib/supabase'
import { fetchPublicProfile, type PublicProfile } from '../lib/queries'

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
      <span style={{ fontSize: 16, color: fg }}>{value}</span>
      <span style={{ fontSize: 9.5, color: sub }}>{label}</span>
    </div>
  )
}

export default function Profile({ flow }: { flow: Flow }) {
  const cta = usePress(`3px 3px 0 ${C.lavender}`)
  const targetId = flow.profileUserId
  const useReal = isBackendConfigured && !!targetId

  const [data, setData] = useState<PublicProfile | null>(null)
  const [loading, setLoading] = useState(useReal)
  const [error, setError] = useState<string | null>(null)

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

  const back = () => flow.go(useReal ? flow.profileReturn : 'home')

  // 表示値(実データ or モック)
  const name = useReal ? data?.nickname ?? '' : 'みなと'
  const initial = useReal ? data?.avatarInitial ?? '?' : 'み'
  const avatarColor = useReal ? data?.avatarColor ?? C.avatarAqua : C.avatarAqua
  const verified = useReal ? !!data?.isVerified : true
  const subtitle = useReal
    ? data?.isHost
      ? `ホスト · 1時間 ${data.hourlyRate} コイン`
      : 'ゲーマー'
    : '社会人ゲーマー · 平日夜メイン · 都内'
  const bio = useReal ? data?.bio ?? '' : '仕事終わりの21時から遊べます。ランクはガチすぎず、笑いながら上を目指したい派。建築ゲーも好きなのでまったり勢も歓迎です。'

  const realStats = data
    ? [
        { value: `★${data.mannerScore.toFixed(1)}`, label: 'マナースコア', bg: C.white, fg: C.lavender, sub: C.muted },
        { value: `${data.dotakyanRate}%`, label: 'ドタキャン率', bg: C.lime, fg: C.ink, sub: C.ink },
        { value: `${data.confirmedCount}`, label: '一緒に遊んだ', bg: C.white, fg: C.ink, sub: C.muted },
      ]
    : []
  const stats = useReal ? realStats : MOCK_STATS

  const onCta = () => {
    if (useReal && data?.isHost) {
      flow.startBooking({
        name: data.nickname,
        initial: data.avatarInitial,
        color: data.avatarColor,
        hourlyRate: data.hourlyRate,
        userId: data.userId,
      })
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
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', color: '#fff', fontSize: 13 }}>
          <span>21:47</span>
          <div style={{ display: 'flex', gap: 5, alignItems: 'center' }}>
            <div style={{ width: 16, height: 9, borderRadius: 2, background: '#fff' }} />
            <div style={{ width: 20, height: 9, borderRadius: 3, border: '1.5px solid #fff' }} />
          </div>
        </div>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 0 40px' }}>
          <div onClick={back} style={{ cursor: 'pointer' }}>
            <ChevronLeft color="#fff" />
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
              }}
            >
              {initial}
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4, paddingBottom: 4 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 7, flexWrap: 'wrap' }}>
                <span style={{ fontSize: 20, color: C.ink }}>{name}</span>
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
              <span style={{ fontSize: 11, color: C.muted }}>{subtitle}</span>
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

          {/* あそぶゲーム */}
          {(useReal ? (data?.games.length ?? 0) > 0 : true) && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <span style={{ fontSize: 13, color: C.ink }}>▶ あそぶゲーム</span>
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

          {/* あそべる時間(データ未保持のためデモのみ) */}
          {!useReal && (
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
