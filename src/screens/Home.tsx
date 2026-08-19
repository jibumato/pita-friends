import { useEffect, useRef, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import BottomTabs from '../components/BottomTabs'
import { Bell, Sun, MoonSmall, Moon, ChevronDown } from '../components/Icon'
import { usePress } from '../hooks/usePress'
import { clickable } from '../hooks/clickable'
import OnlineBadge from '../components/OnlineBadge'
import GameThumb from '../components/GameThumb'
import { mannerScoreLabel, NEW_MEMBER_LABEL } from '../lib/trustDisplay'
import { useIsMobile } from '../hooks/useMediaQuery'
import { isBackendConfigured } from '../lib/supabase'
import { consumeHostIntent } from '../lib/hostIntent'
import SignedOutPrompt from '../components/SignedOutPrompt'
import ActivityStats from '../components/ActivityStats'
import { subscribeOnlineUsers, type OnlineUser } from '../lib/presence'
import type { PresenceStatus } from '../lib/database.types'
import { coinsPer30, GAMES } from '../flow'
import FavoriteStar from '../components/FavoriteStar'
import HostStatus from '../components/HostStatus'
import VoiceChip from '../components/VoiceChip'
import RepeatBadge from '../components/RepeatBadge'
import LegalLinks from '../components/LegalLinks'
import {
  fetchDiscoverableHosts,
  fetchPublicHostCards,
  fetchMyFavorites,
  type FavoriteHost,
  fetchPendingInviteCount,
  fetchUnreadNotificationCount,
  fetchHostRanking,
  type DiscoverableHost,
  type RankingEntry,
} from '../lib/queries'

const MEDAL = ['🥇', '🥈', '🥉']

/** デモ時の週間ランキング(実データ接続時は fetchHostRanking から取得)。 */
const DEMO_RANKING: RankingEntry[] = [
  { rank: 1, hostId: 'd1', nickname: 'ののか', avatarInitial: 'の', avatarColor: '#FFC7D9', avatarUrl: null, completedCount: 58, mannerScore: 4.9, score: 98, isVerified: true },
  { rank: 2, hostId: 'd2', nickname: 'みなと', avatarInitial: 'み', avatarColor: '#B3E5F2', avatarUrl: null, completedCount: 51, mannerScore: 4.8, score: 94, isVerified: true },
  { rank: 3, hostId: 'd3', nickname: 'あおい', avatarInitial: 'あ', avatarColor: '#E3DCFF', avatarUrl: null, completedCount: 47, mannerScore: 4.8, score: 91, isVerified: true },
  { rank: 4, hostId: 'd4', nickname: 'りく', avatarInitial: 'り', avatarColor: '#C9F2C7', avatarUrl: null, completedCount: 40, mannerScore: 4.7, score: 87, isVerified: false },
  { rank: 5, hostId: 'd5', nickname: 'そら', avatarInitial: 'そ', avatarColor: '#FBD79E', avatarUrl: null, completedCount: 36, mannerScore: 4.7, score: 84, isVerified: true },
]

/** デモ時の新人ランキング(実データ接続時は完了数の少ない=新人ピタメイトから導出)。 */
const DEMO_ROOKIE: RankingEntry[] = [
  { rank: 1, hostId: 'r1', nickname: 'そうた', avatarInitial: 'そ', avatarColor: '#C9F2C7', avatarUrl: null, completedCount: 8, mannerScore: 4.9, score: 70, isVerified: true },
  { rank: 2, hostId: 'r2', nickname: 'みるく', avatarInitial: 'み', avatarColor: '#F5B8CE', avatarUrl: null, completedCount: 6, mannerScore: 5.0, score: 66, isVerified: true },
  { rank: 3, hostId: 'r3', nickname: 'かえで', avatarInitial: 'か', avatarColor: '#B3E5F2', avatarUrl: null, completedCount: 5, mannerScore: 4.8, score: 61, isVerified: false },
  { rank: 4, hostId: 'r4', nickname: 'ひかる', avatarInitial: 'ひ', avatarColor: '#FBD79E', avatarUrl: null, completedCount: 4, mannerScore: 4.9, score: 58, isVerified: true },
  { rank: 5, hostId: 'r5', nickname: 'ゆの', avatarInitial: 'ゆ', avatarColor: '#E3DCFF', avatarUrl: null, completedCount: 3, mannerScore: 5.0, score: 55, isVerified: true },
]

/** ヒーロー直下のアイコン一覧(いろんな人を紹介する用)のデモデータ。 */
const ONLINE_STRIP = [
  { initial: 'る', name: 'るか', color: C.avatarOrange },
  { initial: 'そ', name: 'そら', color: C.avatarAqua },
  { initial: 'ひ', name: 'ひなた', color: C.avatarPink },
  { initial: 'カ', name: 'カイト', color: C.lime },
  { initial: 'み', name: 'みなと', color: C.avatarAqua },
  { initial: 'あ', name: 'あおい', color: C.lavender },
  { initial: 'り', name: 'りく', color: '#C9F2C7' },
  { initial: 'の', name: 'ののか', color: '#FFC7D9' },
  { initial: 'ゆ', name: 'ゆうき', color: C.avatarOrange },
  { initial: 'は', name: 'はると', color: C.avatarAqua },
  { initial: 'な', name: 'なな', color: C.avatarPink },
  { initial: 'れ', name: 'れん', color: '#C9F2C7' },
]

/** ヒーロー直下に置く、今あそべる人のアイコンのみ横並び(コンパクト)。 */
function OnlineStrip({ flow, online, onOpen }: { flow: Flow; online: OnlineUser[]; onOpen: (id: string | null) => void }) {
  const items = isBackendConfigured
    ? online.map((u) => ({ key: u.userId, initial: u.avatarInitial, name: u.nickname, color: u.avatarColor, userId: u.userId, status: 'online' as PresenceStatus }))
    : ONLINE_STRIP.map((u, i) => ({ key: `${u.initial}-${i}`, initial: u.initial, name: u.name, color: u.color, userId: null as string | null, status: 'online' as PresenceStatus }))

  if (isBackendConfigured && items.length === 0) return null

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ fontSize: 12.5, color: C.ink }}>🟢 今あそべる</span>
        <span style={{ fontSize: 10.5, color: C.muted }}>{items.length}人</span>
        <div style={{ flex: 1 }} />
        <span
          onClick={() => flow.go('search')}
          {...clickable(() => flow.go('search'), 'ピタメイトをさがす')}
          style={{ cursor: 'pointer', fontSize: 10.5, color: C.lavender, fontWeight: 700 }}
        >
          もっと見る ›
        </span>
      </div>
      <div className="pita-scroll" style={{ display: 'flex', gap: 8, overflowX: 'auto', paddingBottom: 2 }}>
        {items.map((u) => (
          <div
            key={u.key}
            onClick={() => onOpen(u.userId)}
            {...clickable(() => onOpen(u.userId), `${u.name} のプロフィールを見る`)}
            style={{
              flex: 'none',
              width: 52,
              cursor: 'pointer',
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 4,
            }}
          >
            <div style={{ position: 'relative' }}>
              <div
                style={{
                  width: 44,
                  height: 44,
                  borderRadius: '50%',
                  background: u.color,
                  border: `1.5px solid ${C.border}`,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  fontSize: 17,
                  color: C.ink,
                }}
              >
                {u.initial}
              </div>
              <span style={{ position: 'absolute', bottom: 1, right: 1, display: 'inline-flex' }}>
                <OnlineBadge variant="dot" live status={u.status} size={11} ringColor={C.surface} />
              </span>
            </div>
            {/* 名前は1行に収める(長いニックネームは…で省略) */}
            <span
              style={{
                maxWidth: '100%',
                fontSize: 9.5,
                color: C.muted,
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
              }}
            >
              {u.name}
            </span>
          </div>
        ))}
      </div>
    </div>
  )
}

/** 「今夜のおすすめマッチ」カード1枚分の表示データ。 */
type RecommendCardData = {
  key: string
  userId: string | null
  initial: string
  color: string
  name: string
  verified: boolean
  chips: string[]
  price30: number
  compat: number | null
  meta: string
  /** ボイスプロフィール(人気ユーザーのカードで直接再生する)。URLが無くても秒数があればデモ再生。 */
  voiceUrl?: string | null
  voiceSeconds?: number | null
  /** アイコン画像URL。あれば頭文字＋カラーの代わりに表示する。 */
  avatarUrl?: string | null
  /** オンライン表示用。live=いま接続中、lastSeenAt=最終在席。 */
  live?: boolean
  lastSeenAt?: string | null
  presenceStatus?: PresenceStatus
}

/** デモの在席状態(実データ接続時は profiles.last_seen_at と Realtime から出す)。 */
const demoAgo = (min: number) => new Date(Date.now() - min * 60_000).toISOString()


/** デモ時の人気ユーザー(実データ接続時は掲載ピタメイトをマナー順に表示)。相性%は出さずプレイ実績で見せる。 */
const DEMO_POPULAR: RecommendCardData[] = [
  { key: 'p-の', userId: null, initial: 'の', color: C.avatarPink, name: 'ののか', verified: true, chips: ['VALORANT', 'Apex'], price30: 250, compat: null, meta: '★4.9 · 320回プレイ', voiceSeconds: 9 , live: true, presenceStatus: 'ready' },
  { key: 'p-み', userId: null, initial: 'み', color: C.avatarAqua, name: 'みなと', verified: true, chips: ['Apex'], price30: 300, compat: null, meta: '★4.8 · 280回プレイ', voiceSeconds: 12 , live: true },
  { key: 'p-あ', userId: null, initial: 'あ', color: C.lavender, name: 'あおい', verified: true, chips: ['Fortnite'], price30: 280, compat: null, meta: '★4.8 · 260回プレイ', voiceSeconds: 7 , lastSeenAt: demoAgo(12) },
  { key: 'p-れ', userId: null, initial: 'れ', color: C.avatarAqua, name: 'れん', verified: true, chips: ['Overwatch 2'], price30: 350, compat: null, meta: '★4.8 · 240回プレイ', voiceSeconds: 10 , live: true, presenceStatus: 'busy' },
  { key: 'p-な', userId: null, initial: 'な', color: C.avatarPink, name: 'なな', verified: true, chips: ['スプラ', 'あつ森'], price30: 260, compat: null, meta: '★4.9 · 190回プレイ', voiceSeconds: 8 , lastSeenAt: demoAgo(48) },
  { key: 'p-り', userId: null, initial: 'り', color: '#C9F2C7', name: 'りく', verified: false, chips: ['LoL'], price30: 220, compat: null, meta: '★4.7 · 210回プレイ', voiceSeconds: 6 , lastSeenAt: demoAgo(3) },
  { key: 'p-か', userId: null, initial: 'か', color: C.lime, name: 'かい', verified: false, chips: ['Overwatch 2', 'VALORANT'], price30: 400, compat: null, meta: '★4.7 · 180回プレイ', voiceSeconds: 11 , lastSeenAt: demoAgo(180) },
  { key: 'p-そ', userId: null, initial: 'そ', color: C.avatarOrange, name: 'そら', verified: true, chips: ['Apex'], price30: 200, compat: null, meta: '★4.7 · 170回プレイ', voiceSeconds: 8 , live: true },
]

/** 人気ユーザーのカード。アイコンを大きく(カードの約6割)し、その場でボイスプロフィールを再生できる。 */
function PopularUserCard({ data, onOpen }: { data: RecommendCardData; onOpen: () => void }) {
  const press = usePress(`3px 3px 0 ${C.shadowCol}`)
  const [playing, setPlaying] = useState(false)
  const audioRef = useRef<HTMLAudioElement | null>(null)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const hasVoice = !!data.voiceUrl || data.voiceSeconds != null

  useEffect(() => () => { if (timerRef.current) clearTimeout(timerRef.current) }, [])

  const toggleVoice = (e: React.MouseEvent | React.KeyboardEvent) => {
    e.stopPropagation()
    if (data.voiceUrl) {
      const a = audioRef.current
      if (!a) return
      if (playing) {
        a.pause()
        a.currentTime = 0
        setPlaying(false)
      } else {
        a.currentTime = 0
        a.play().then(() => setPlaying(true)).catch(() => {})
      }
    } else {
      // デモ: 音源が無いので秒数ぶんだけ再生状態を演出する。
      if (playing) {
        if (timerRef.current) clearTimeout(timerRef.current)
        setPlaying(false)
      } else {
        setPlaying(true)
        timerRef.current = setTimeout(() => setPlaying(false), (data.voiceSeconds ?? 8) * 1000)
      }
    }
  }

  return (
    <div
      className="pita-press"
      onClick={onOpen}
      {...clickable(onOpen, `${data.name} のプロフィールを見る`)}
      style={{
        cursor: 'pointer',
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 12,
        overflow: 'hidden',
        display: 'flex',
        flexDirection: 'column',
        ...press.style,
      }}
    >
      {/* アイコン(カードの約6割)。オンライン中や本人確認バッジ・ボイス再生を重ねる。 */}
      <div
        style={{
          position: 'relative',
          width: '100%',
          aspectRatio: '1 / 1',
          background: data.color,
          borderBottom: `1.5px solid ${C.border}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          fontSize: 56,
          color: C.ink,
        }}
      >
        {data.avatarUrl ? (
          <img
            src={data.avatarUrl}
            alt=""
            style={{ position: 'absolute', inset: 0, width: '100%', height: '100%', objectFit: 'cover' }}
          />
        ) : (
          data.initial
        )}
        {data.verified && (
          <span
            style={{
              position: 'absolute',
              top: 8,
              left: 8,
              fontSize: 9,
              color: C.ink,
              background: C.lime,
              border: `1.5px solid ${C.border}`,
              padding: '2px 6px',
              borderRadius: 4,
            }}
          >
            ✓ 確認済み
          </span>
        )}
        {/* オンライン状態(右上)。非公開・未記録なら何も出ない。 */}
        <span style={{ position: 'absolute', top: 8, right: 8 }}>
          <OnlineBadge
            live={data.live}
            lastSeenAt={data.lastSeenAt}
            status={data.presenceStatus}
            fontSize={9.5}
          />
        </span>
        {hasVoice && (
          <span
            onClick={toggleVoice}
            role="button"
            tabIndex={0}
            aria-label={playing ? 'ボイスプロフィールを停止' : 'ボイスプロフィールを再生'}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') toggleVoice(e)
            }}
            style={{
              position: 'absolute',
              left: 8,
              bottom: 8,
              display: 'inline-flex',
              alignItems: 'center',
              gap: 6,
              cursor: 'pointer',
              background: C.lime,
              color: C.ink,
              border: `1.5px solid ${C.border}`,
              borderRadius: 20,
              boxShadow: `2px 2px 0 ${C.border}`,
              padding: '5px 11px',
              fontSize: 11,
              fontWeight: 700,
            }}
          >
            {playing ? (
              <>
                <span style={{ display: 'inline-flex', alignItems: 'flex-end', gap: 2, height: 12 }} aria-hidden>
                  {[0, 1, 2].map((i) => (
                    <span
                      key={i}
                      style={{
                        width: 2.5,
                        height: 12,
                        background: C.ink,
                        borderRadius: 2,
                        transformOrigin: 'bottom',
                        animation: `vpBar .8s ease-in-out ${i * 0.16}s infinite`,
                      }}
                    />
                  ))}
                </span>
                再生中
              </>
            ) : (
              <>▶ ボイス{data.voiceSeconds ? ` ${data.voiceSeconds}秒` : ''}</>
            )}
          </span>
        )}
        {data.voiceUrl && (
          <audio ref={audioRef} src={data.voiceUrl} preload="none" onEnded={() => setPlaying(false)} />
        )}
      </div>
      {/* 情報(残り約4割) */}
      <div style={{ padding: '10px 12px 12px', display: 'flex', flexDirection: 'column', gap: 8 }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
          <span style={{ fontSize: 14, color: C.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {data.name}
          </span>
          <span style={{ fontSize: 10, color: C.muted }}>{data.meta}</span>
        </div>
        <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
          {data.chips.map((t) => (
            <span
              key={t}
              style={{
                fontSize: 10,
                color: C.body,
                background: C.surfaceLavender,
                border: `1.5px solid ${C.border}`,
                padding: '2px 8px',
                borderRadius: 5,
              }}
            >
              {t}
            </span>
          ))}
        </div>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 1 }}>
          <span style={{ fontSize: 11.5, color: C.ink }}>
            30分 <b>{data.price30}</b> コイン
          </span>
          <span
            style={{
              fontSize: 10.5,
              color: C.ink,
              background: C.lime,
              border: `1.5px solid ${C.border}`,
              padding: '4px 11px',
              borderRadius: 6,
            }}
          >
            予約 ▶
          </span>
        </div>
      </div>
    </div>
  )
}

/** ランキングの1行(順位で強調度を変える: 1位が最も大きく、2〜3位も強調、以降はコンパクト)。 */
function RankRow({ flow, r, rookie }: { flow: Flow; r: RankingEntry; rookie?: boolean }) {
  const first = r.rank === 1
  const podium = r.rank <= 3
  const avatar = first ? 60 : podium ? 46 : 36
  const nameSize = first ? 20 : podium ? 15.5 : 13
  const pad = first ? '18px 18px' : podium ? '13px 15px' : '10px 14px'
  const bg = first ? C.surfaceLavender : C.white
  const border = first ? `2.5px solid ${C.border}` : `1.5px solid ${C.border}`
  const shadow = first ? `6px 6px 0 ${C.lavender}` : podium ? `3px 3px 0 ${C.shadowCol}` : `2px 2px 0 ${C.shadowCol}`
  const lead = podium ? MEDAL[r.rank - 1] : r.rank
  const leadSize = first ? 34 : podium ? 24 : 15
  const leadW = first ? 46 : podium ? 32 : 24
  return (
    <div
      onClick={() => flow.go('ranking')}
      {...clickable(() => flow.go('ranking'), `${r.nickname} · ${r.rank}位`)}
      style={{
        cursor: 'pointer',
        background: bg,
        border,
        borderRadius: 14,
        boxShadow: shadow,
        padding: pad,
        display: 'flex',
        alignItems: 'center',
        gap: first ? 14 : 11,
      }}
    >
      <span
        style={{
          width: leadW,
          fontSize: leadSize,
          textAlign: 'center',
          flex: 'none',
          fontWeight: podium ? 400 : 800,
          color: podium ? C.ink : C.muted,
        }}
      >
        {lead}
      </span>
      <div
        style={{
          position: 'relative',
          width: avatar,
          height: avatar,
          borderRadius: first ? 12 : 9,
          background: r.avatarColor,
          border: `1.5px solid ${C.border}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          fontSize: first ? 26 : podium ? 20 : 16,
          color: C.ink,
          flex: 'none',
          overflow: 'hidden',
        }}
      >
        {r.avatarUrl ? (
          <img
            src={r.avatarUrl}
            alt=""
            style={{ position: 'absolute', inset: 0, width: '100%', height: '100%', objectFit: 'cover' }}
          />
        ) : (
          r.avatarInitial
        )}
      </div>
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: first ? 4 : 2 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, minWidth: 0 }}>
          <span
            style={{
              fontSize: nameSize,
              fontWeight: first ? 800 : 400,
              color: C.ink,
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              whiteSpace: 'nowrap',
            }}
          >
            {r.nickname}
          </span>
          {r.isVerified && (
            <span
              aria-label="本人確認済み"
              style={{
                fontSize: 8.5,
                color: C.ink,
                background: C.lime,
                border: `1.5px solid ${C.border}`,
                padding: '1px 4px',
                borderRadius: 4,
                flex: 'none',
              }}
            >
              ✓
            </span>
          )}
          {rookie && (
            <span
              style={{
                fontSize: 8.5,
                fontWeight: 800,
                color: C.ink,
                background: C.surfaceLavender,
                border: `1.5px solid ${C.border}`,
                borderRadius: 4,
                padding: '1px 5px',
                flex: 'none',
              }}
            >
              NEW
            </span>
          )}
        </div>
        <span style={{ fontSize: first ? 12 : 10.5, color: C.muted }}>
          ★{r.mannerScore.toFixed(1)} · {r.completedCount}回プレイ
        </span>
      </div>
      <div style={{ flex: 'none', textAlign: 'right', display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 1 }}>
        <span style={{ fontSize: first ? 9 : 8, color: C.muted, letterSpacing: '.08em' }}>スコア</span>
        <span
          style={{
            fontSize: first ? 24 : podium ? 16 : 14,
            fontWeight: 800,
            color: first ? C.lavender : C.ink,
            fontVariantNumeric: 'tabular-nums',
          }}
        >
          {r.score}
        </span>
      </div>
    </div>
  )
}

/** ランキング(今週 / 新人 共通)。順位で強調度を変えた縦積み表示。 */
function RankingSection({
  flow,
  title,
  rows,
  rookie,
}: {
  flow: Flow
  title: string
  rows: RankingEntry[]
  rookie?: boolean
}) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
        <span style={{ fontSize: 15, color: C.ink }}>{title}</span>
        <span
          onClick={() => flow.go('ranking')}
          {...clickable(() => flow.go('ranking'), 'ランキングをすべて見る')}
          style={{ cursor: 'pointer', fontSize: 10, color: C.lavender, fontWeight: 700 }}
        >
          すべて見る ›
        </span>
      </div>
      {rows.length === 0 ? (
        <div
          style={{
            background: C.white,
            border: `1.5px dashed ${C.border}`,
            borderRadius: 12,
            padding: '20px 16px',
            textAlign: 'center',
            fontSize: 11.5,
            color: C.muted,
            lineHeight: 1.7,
          }}
        >
          まだランキングがありません。
          <br />
          プレイが記録されると、ここに上位ピタメイトが表示されます。
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
          {rows.map((r) => (
            <RankRow key={r.hostId} flow={flow} r={r} rookie={rookie} />
          ))}
        </div>
      )}
    </div>
  )
}

/**
 * 今日のピックアップ: 1人だけ大きく出す。
 *
 * 小さいカードを並べるのは「探す」ための形で、**お気に入りは1人を深く見て生まれる**。
 * 顔・声・自己紹介まで一度に見えるようにして、その場でお気に入り登録も予約もできる。
 *
 * 誰を出すかは日付で決めて1日固定する。表示のたびに変わると、
 * 「さっきの人をもう一度見たい」ができない。ランダムも同じ理由で使わない。
 */
function PickupCard({
  flow,
  host,
  isFav,
  onOpen,
  onFavChanged,
}: {
  flow: Flow
  host: DiscoverableHost
  isFav: boolean
  /** カードを開く。未ログインならプロフィールへ行かず登録へ誘導する(openHost)。 */
  onOpen: (id: string) => void
  onFavChanged: (on: boolean) => void
}) {
  const open = () => onOpen(host.userId)
  const score = mannerScoreLabel(host.mannerScore, host.reviewCount)
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <span style={{ fontSize: 14, color: C.ink }}>✨ 今日のピタメイト</span>
      <div
        onClick={open}
        {...clickable(open, `${host.nickname} のプロフィールを見る`)}
        style={{
          cursor: 'pointer',
          background: C.white,
          border: `1.5px solid ${C.border}`,
          borderRadius: 14,
          boxShadow: `4px 4px 0 ${C.lavender}`,
          padding: 16,
          display: 'flex',
          gap: 14,
          alignItems: 'flex-start',
        }}
      >
        {host.avatarUrl ? (
          <img
            src={host.avatarUrl}
            alt=""
            style={{ width: 88, height: 88, flex: 'none', borderRadius: 14, objectFit: 'cover', border: `1.5px solid ${C.border}` }}
          />
        ) : (
          <div
            style={{
              width: 88, height: 88, flex: 'none', borderRadius: 14,
              background: host.avatarColor, border: `1.5px solid ${C.border}`,
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 36, color: C.ink,
            }}
          >
            {host.avatarInitial}
          </div>
        )}
        <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 6 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
            <span style={{ fontSize: 17, color: C.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {host.nickname}
            </span>
            {host.isVerified && (
              <span style={{ flex: 'none', fontSize: 9, color: C.ink, background: C.lime, border: `1.5px solid ${C.border}`, padding: '2px 6px', borderRadius: 4 }}>
                ✓
              </span>
            )}
            <div style={{ flex: 1 }} />
            <FavoriteStar
              hostId={host.userId}
              initialOn={isFav}
              size={30}
              onChanged={onFavChanged}
              // 未ログインだと保存できず失敗するだけなので、登録へ誘導する
              onBlocked={() => flow.go('signUp')}
            />
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 7, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 11.5, color: C.muted }}>
              {score ? `${score}・マナー◎` : NEW_MEMBER_LABEL}
            </span>
            <VoiceChip url={host.voiceUrl} seconds={host.voiceSeconds} variant="quiet" />
            <RepeatBadge count={host.repeatGuests} />
          </div>
          <HostStatus text={host.statusText} at={host.statusUpdatedAt} />
          {host.bio && (
            <span style={{ fontSize: 12, color: C.body, lineHeight: 1.7, display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden' }}>
              {host.bio}
            </span>
          )}
          <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
            {host.games.slice(0, 3).map((g) => (
              <span key={g} style={{ fontSize: 10, color: C.body, background: C.surface, border: `1.5px solid ${C.border}`, padding: '3px 8px', borderRadius: 4 }}>
                {g}
              </span>
            ))}
          </div>
          <span style={{ fontSize: 12.5, color: C.ink }}>30分 {coinsPer30(host.hourlyRate)} コイン</span>
        </div>
      </div>
    </div>
  )
}

/**
 * 新しく入ったピタメイト。
 *
 * 実績順に並べると、始めたばかりの人は永遠に埋もれる。1件も予約が来ないまま
 * 辞めていくと供給が育たないので、レビューの少ない順に別枠で出す。
 * 「早く見つけた」という感覚は、お気に入りに入れる動機そのものでもある。
 */
function NewcomerRow({ flow, items, onOpen }: { flow: Flow; items: DiscoverableHost[]; onOpen: (id: string) => void }) {
  if (items.length === 0) return null
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ fontSize: 14, color: C.ink }}>🌱 新しく入ったピタメイト</span>
        <div style={{ flex: 1 }} />
        <span
          onClick={() => flow.go('search')}
          {...clickable(() => flow.go('search'), 'もっと見る')}
          style={{ cursor: 'pointer', fontSize: 10.5, color: C.lavender, fontWeight: 700 }}
        >
          もっと見る ›
        </span>
      </div>
      <div className="pita-scroll" style={{ display: 'flex', gap: 10, overflowX: 'auto', paddingBottom: 4 }}>
        {items.map((h) => (
          <div
            key={h.userId}
            onClick={() => onOpen(h.userId)}
            {...clickable(() => onOpen(h.userId), `${h.nickname} のプロフィールを見る`)}
            style={{
              cursor: 'pointer', flex: 'none', width: 128,
              background: C.white, border: `1.5px solid ${C.border}`,
              borderRadius: 12, boxShadow: `2px 2px 0 ${C.shadowCol}`,
              padding: 10, display: 'flex', flexDirection: 'column', gap: 6, alignItems: 'center',
            }}
          >
            {h.avatarUrl ? (
              <img src={h.avatarUrl} alt="" style={{ width: 52, height: 52, borderRadius: '50%', objectFit: 'cover', border: `1.5px solid ${C.border}` }} />
            ) : (
              <div style={{ width: 52, height: 52, borderRadius: '50%', background: h.avatarColor, border: `1.5px solid ${C.border}`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 21, color: C.ink }}>
                {h.avatarInitial}
              </div>
            )}
            <span style={{ maxWidth: '100%', fontSize: 12, color: C.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {h.nickname}
            </span>
            <span style={{ fontSize: 10, color: C.muted }}>30分 {coinsPer30(h.hourlyRate)}</span>
          </div>
        ))}
      </div>
    </div>
  )
}

/**
 * お気に入りの近況: お気に入りに入れたピタメイトを最上部に出す。
 *
 * 既にお気に入りがいる人にとって、ホームに来る目的はほぼこれ一つ。
 * 掲載を休んでいる相手も**消さずに残す**(黙って消えると理由が分からない)。
 */
function FavoriteRow({
  flow,
  items,
  onChanged,
}: {
  flow: Flow
  items: FavoriteHost[]
  onChanged: () => void
}) {
  if (items.length === 0) return null
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ fontSize: 14, color: C.ink }}>⭐ お気に入りのピタメイト</span>
        <span style={{ fontSize: 10.5, color: C.muted }}>{items.length}人</span>
      </div>
      <div className="pita-scroll" style={{ display: 'flex', gap: 10, overflowX: 'auto', paddingBottom: 4 }}>
        {items.map((h) => (
          <div
            key={h.userId}
            onClick={() => flow.openProfile(h.userId)}
            {...clickable(() => flow.openProfile(h.userId), `${h.nickname} のプロフィールを見る`)}
            style={{
              cursor: 'pointer',
              flex: 'none',
              width: 148,
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 12,
              boxShadow: `2px 2px 0 ${C.shadowCol}`,
              padding: 10,
              display: 'flex',
              flexDirection: 'column',
              gap: 7,
              opacity: h.isActive ? 1 : 0.72,
            }}
          >
            <div style={{ display: 'flex', alignItems: 'flex-start', gap: 8 }}>
              {h.avatarUrl ? (
                <img
                  src={h.avatarUrl}
                  alt=""
                  style={{ width: 40, height: 40, borderRadius: '50%', objectFit: 'cover', border: `1.5px solid ${C.border}`, flex: 'none' }}
                />
              ) : (
                <div
                  style={{
                    width: 40, height: 40, flex: 'none', borderRadius: '50%',
                    background: h.avatarColor, border: `1.5px solid ${C.border}`,
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    fontSize: 16, color: C.ink,
                  }}
                >
                  {h.avatarInitial}
                </div>
              )}
              <div style={{ flex: 1 }} />
              <FavoriteStar hostId={h.userId} initialOn size={26} onChanged={onChanged} />
            </div>
            <span style={{ fontSize: 12.5, color: C.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {h.nickname}
            </span>
            <HostStatus text={h.statusText} at={h.statusUpdatedAt} compact />
            {h.isActive ? (
              <span style={{ fontSize: 10.5, color: C.muted }}>30分 {coinsPer30(h.hourlyRate)} コイン</span>
            ) : (
              <span style={{ fontSize: 10.5, color: C.avatarOrange, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                募集を休止中
              </span>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}

/**
 * ゲーム一覧: タップでそのゲームに絞ってさがす画面へ。
 *
 * 27件あり、開いたままだとホームの縦が伸びてピタメイトのカードまで
 * 遠くなる。既定は畳んでおき、見出しの押下で開く。
 * 件数を見出しに出しておかないと、畳まれていることに気づかれない。
 */
function GameGrid({ flow }: { flow: Flow }) {
  const [open, setOpen] = useState(false)
  const toggle = () => setOpen((v) => !v)
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      <div
        onClick={toggle}
        {...clickable(toggle, `ゲーム・ジャンルからさがす（${GAMES.length}件）を${open ? '閉じる' : '開く'}`)}
        aria-expanded={open}
        style={{
          cursor: 'pointer',
          display: 'flex',
          alignItems: 'center',
          gap: 8,
          background: C.white,
          border: `1.5px solid ${C.border}`,
          borderRadius: 10,
          boxShadow: `2px 2px 0 ${C.shadowCol}`,
          padding: '11px 14px',
        }}
      >
        <span style={{ fontSize: 14, color: C.ink }}>🎮 ゲーム・ジャンルからさがす</span>
        <span style={{ fontSize: 11, color: C.muted }}>{GAMES.length}件</span>
        <div style={{ flex: 1 }} />
        <ChevronDown
          size={14}
          color={C.muted}
          style={{ transform: open ? 'rotate(180deg)' : 'none', transition: 'transform .18s ease' }}
        />
      </div>
      {open && (
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(140px, 1fr))', gap: 10 }}>
        {GAMES.map((g) => (
          <div
            key={g}
            onClick={() => {
              if (!flow.searchFilters[g]) flow.toggleSearchFilter(g)
              flow.go('search')
            }}
            {...clickable(() => {
              if (!flow.searchFilters[g]) flow.toggleSearchFilter(g)
              flow.go('search')
            }, `${g} でさがす`)}
            style={{
              cursor: 'pointer',
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 10,
              boxShadow: `2px 2px 0 ${C.shadowCol}`,
              padding: '12px 10px',
              display: 'flex',
              alignItems: 'center',
              gap: 9,
            }}
          >
            <GameThumb name={g} size={26} />
            <span style={{ fontSize: 12.5, color: C.ink, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {g}
            </span>
          </div>
        ))}
      </div>
      )}
    </div>
  )
}

export default function HomeScreen({ flow }: { flow: Flow }) {
  const mobile = useIsMobile()
  // 深夜オフライン状態(状態網羅 C1)のデモ切替
  const [night, setNight] = useState(false)

  const [pendingCount, setPendingCount] = useState<number | null>(null)
  const [onlineUsers, setOnlineUsers] = useState<OnlineUser[]>([])
  // 未ログインの訪問者かどうか。デモモードは「ログイン済み扱い」にして、
  // ローカルでの画面確認をこれまでどおり通す。
  const signedIn = !isBackendConfigured || flow.userId !== null
  // ⭐の付け外しのあと、一覧を取り直すための参照(effect内で作った関数を持つ)
  const favRef = useRef<(() => void) | null>(null)
  /**
   * 人のカードを押したときの行き先。
   * 未ログインなら「見つける→興味が湧いたら登録」の導線に乗せる。
   * プロフィール画面はログイン前提のデータを読むので、開いても空になる。
   */
  const openHost = (userId: string | null) => {
    if (!signedIn) {
      flow.go('signUp')
      return
    }
    if (userId) flow.openProfile(userId)
    else flow.go('profile')
  }
  const [favorites, setFavorites] = useState<FavoriteHost[]>([])
  const [recommended, setRecommended] = useState<DiscoverableHost[]>([])
  const [ranking, setRanking] = useState<RankingEntry[]>([])
  const [unreadNotifs, setUnreadNotifs] = useState(0)
  /** いまRealtimeで在席が確認できているユーザー。カードのオンライン表示に使う。 */
  const liveIds = new Set(onlineUsers.map((u) => u.userId))
  const favIds = new Set(favorites.map((f) => f.userId))

  // 今日のピックアップ。日付で決めて1日固定する(表示のたびに変わると
  // 「さっきの人をもう一度」ができない)。日本時間の日付を基準にする。
  const pickup = (() => {
    if (recommended.length === 0) return null
    const jstDay = Math.floor((Date.now() + 9 * 3600_000) / 86_400_000)
    return recommended[jstDay % recommended.length]
  })()

  // 新人: レビューが少ない順。実績順の並びでは埋もれる人を拾う。
  const newcomers = [...recommended]
    .filter((h) => h.userId !== pickup?.userId)
    .sort((a, b) => a.reviewCount - b.reviewCount)
    .slice(0, 8)

  /**
   * ヒーローの「ピタメイトとして登録する」で入ってきた人を、
   * 登録が終わってここに着いた**1回だけ**ピタメイト設定へ送る。
   *
   * 登録は画面をいくつもまたぐので、意思は hostIntent.ts が localStorage に
   * 預かっている。取り出しは1回だけで24時間で失効する(hostIntent.ts)。
   * すでにピタメイトの人には用が無いので送らない。
   */
  useEffect(() => {
    if (!isBackendConfigured || flow.userId === null) return
    if (flow.hostSettings.isHost) return
    if (consumeHostIntent()) flow.go('hostSettings')
    // 着地の判定は初回のみ。以後のホーム表示で飛ばされては困る
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [flow.userId])

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true

    // 未ログインの訪問者。ピタメイトの一覧だけを公開の口(0052)から取る。
    // 誘い・通知・在席はログインしないと意味が無いので呼ばない。
    if (!signedIn) {
      fetchPublicHostCards(24)
        .then((hosts) => active && setRecommended(hosts.slice(0, 8)))
        .catch(() => {
          /* 取れなくてもホーム自体は表示する */
        })
      fetchHostRanking('weekly', 20)
        .then((rows) => active && setRanking(rows))
        .catch(() => {
          /* 同上 */
        })
      return () => {
        active = false
      }
    }

    // お気に入りの一覧。ホームに来る目的がこれ一つ、という人がいるので最初に取る。
    const loadFavorites = () =>
      fetchMyFavorites()
        .then((f) => active && setFavorites(f))
        .catch(() => {
          /* 取れなくてもホーム自体は表示する */
        })
    loadFavorites()
    favRef.current = loadFavorites

    fetchPendingInviteCount()
      .then((n) => active && setPendingCount(n))
      .catch(() => active && setPendingCount(0))
    const refreshNotifs = () =>
      fetchUnreadNotificationCount()
        .then((n) => active && setUnreadNotifs(n))
        .catch(() => {
          /* 取れなくてもベルは表示する */
        })
    refreshNotifs()
    // 新着通知に気づけるよう5秒ごとに未読数を取り直す
    const notifTimer = setInterval(refreshNotifs, 5000)
    fetchDiscoverableHosts(flow.userId)
      .then((hosts) => {
        if (!active || hosts.length === 0) return
        const top = [...hosts].sort((a, b) => b.mannerScore - a.mannerScore).slice(0, 8)
        setRecommended(top)
      })
      .catch(() => {
        /* おすすめが取れなくてもホーム自体は表示する */
      })
    // 今週ランキングと新人ランキングの両方を1回の取得から導出するため多めに取る。
    fetchHostRanking('weekly', 20)
      .then((rows) => active && setRanking(rows))
      .catch(() => {
        /* ランキングが取れなくてもホーム自体は表示する */
      })
    const unsubscribe = subscribeOnlineUsers(flow.userId, setOnlineUsers)
    return () => {
      active = false
      unsubscribe()
      clearInterval(notifTimer)
    }
    // 初回マウント時のみ実行
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <Screen background={C.surface}>
      {/* モバイルの疑似ステータスバーは廃止。代わりに画面最上部にヒーロー画像を設置。
          デスクトップはApp側のDesktopHeroが別途表示されるため、ここでは出さない。 */}
      {mobile && (
        <img
          src="/hero.webp"
          alt="オンラインで一緒に遊ぶ2人"
          style={{ width: '100%', height: 160, objectFit: 'cover', objectPosition: 'center 35%', display: 'block' }}
        />
      )}
      {/* デスクトップではロゴ/通知/テーマ切替をDesktopTopBarが担うため、ここは非表示。 */}
      {mobile && (
      <div
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          padding: '12px 20px 4px',
        }}
      >
        <img src="/logo-compact.webp" alt="ピタフレ" style={{ height: 34, display: 'block' }} />
        <div style={{ display: 'flex', gap: 8 }}>
          <div
            onClick={flow.toggleTheme}
            {...clickable(flow.toggleTheme, flow.theme === 'dark' ? 'ライトテーマに切替' : 'ダークテーマに切替')}
            style={{
              cursor: 'pointer',
              width: 38,
              height: 38,
              borderRadius: 8,
              background: C.white,
              border: `1.5px solid ${C.border}`,
              boxShadow: `2px 2px 0 ${C.shadowCol}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            {flow.theme === 'dark' ? <Sun /> : <MoonSmall />}
          </div>
          {signedIn ? (
          <div
            onClick={() => flow.go('notifications')}
            {...clickable(
              () => flow.go('notifications'),
              unreadNotifs > 0 ? `通知 未読${unreadNotifs}件` : '通知',
            )}
            style={{
              cursor: 'pointer',
              position: 'relative',
              width: 38,
              height: 38,
              borderRadius: 8,
              background: C.white,
              border: `1.5px solid ${C.border}`,
              boxShadow: `2px 2px 0 ${C.shadowCol}`,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            <Bell />
            {isBackendConfigured && unreadNotifs > 0 && (
              <span
                aria-hidden
                style={{
                  position: 'absolute',
                  top: -6,
                  right: -6,
                  minWidth: 18,
                  height: 18,
                  padding: '0 5px',
                  boxSizing: 'border-box',
                  borderRadius: 9,
                  background: C.badge,
                  color: '#fff',
                  fontSize: 10.5,
                  lineHeight: '18px',
                  textAlign: 'center',
                  fontWeight: 700,
                  border: `1.5px solid ${C.white}`,
                }}
              >
                {unreadNotifs > 99 ? '99+' : unreadNotifs}
              </span>
            )}
          </div>
          ) : (
            /* 未ログインの訪問者。ここが唯一の登録導線になるので消さないこと。 */
            <>
              <button
                onClick={flow.openLogin}
                style={{
                  cursor: 'pointer',
                  background: C.white,
                  color: C.ink,
                  border: `1.5px solid ${C.border}`,
                  boxShadow: `2px 2px 0 ${C.shadowCol}`,
                  borderRadius: 8,
                  padding: '0 12px',
                  height: 38,
                  fontSize: 12,
                  fontFamily: 'inherit',
                  whiteSpace: 'nowrap',
                }}
              >
                ログイン
              </button>
              <button
                onClick={() => flow.go('signUp')}
                style={{
                  cursor: 'pointer',
                  background: C.lime,
                  color: C.ink,
                  border: `1.5px solid ${C.border}`,
                  boxShadow: `2px 2px 0 ${C.border}`,
                  borderRadius: 8,
                  padding: '0 12px',
                  height: 38,
                  fontSize: 12,
                  fontFamily: 'inherit',
                  whiteSpace: 'nowrap',
                }}
              >
                新規登録
              </button>
            </>
          )}
        </div>
      </div>
      )}
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          display: 'flex',
          flexDirection: 'column',
          gap: 18,
          // 下を 0 にすると、モバイルでは下部タブに、
          // デスクトップではフッターの罫線に中身が接する
          padding: '14px 20px 24px',
        }}
      >
        {/* 0117: 未ログインの人にだけ、動いている形跡を数で見せる。
            ログイン後は自分のお気に入りや今あそべる人のほうが直接的なので出さない。
            個人が特定できる情報は含まない(在席は 0052 の判断どおり出さない)。 */}
        {!signedIn && <ActivityStats />}

        {/* 最上部: お気に入りのピタメイト。既にお気に入りがいる人は、ホームに来る目的が
            ほぼこれ一つなので、どの回遊導線よりも先に出す。 */}
        {signedIn && <FavoriteRow flow={flow} items={favorites} onChanged={() => favRef.current?.()} />}

        {/* 今日のピタメイト: 1人だけ深く見せる。小さいカードを並べるのは
            「探す」ための形で、お気に入りは1人を深く見て生まれる。 */}
        {isBackendConfigured && pickup && (
          <PickupCard
            flow={flow}
            host={pickup}
            isFav={favIds.has(pickup.userId)}
            onOpen={openHost}
            onFavChanged={() => favRef.current?.()}
          />
        )}

        {/* 新しく入ったピタメイト。実績順では埋もれる人を別枠で拾う。 */}
        {isBackendConfigured && <NewcomerRow flow={flow} items={newcomers} onOpen={openHost} />}

        {/* その次: 今あそべる人。「今すぐ誰かと遊びたい」が来訪の主目的。
            深夜オフライン時は隠す。 */}
        {!night && <OnlineStrip flow={flow} online={onlineUsers} onOpen={openHost} />}

        {/* ランキングへの導線(デスクトップはサイドバー/メニューに常設済みのため、モバイルのみ表示) */}
        {mobile && (
          <div
            onClick={() => flow.go('ranking')}
            style={{
              cursor: 'pointer',
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 12,
              boxShadow: `3px 3px 0 ${C.lavender}`,
              padding: '12px 14px',
              display: 'flex',
              alignItems: 'center',
              gap: 10,
            }}
          >
            <span style={{ fontSize: 18 }}>🏆</span>
            <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 1 }}>
              <span style={{ fontSize: 13, color: C.ink }}>ランキング</span>
              <span style={{ fontSize: 10, color: C.muted }}>プレイ実績・評価で決まる今週の上位ピタメイト</span>
            </div>
            <span style={{ fontSize: 11, color: C.lavender, fontWeight: 700 }}>見る ›</span>
          </div>
        )}

        {/* デモ: 通常 / 深夜オフライン 状態の切替。実データ接続時は非表示。 */}
        {!isBackendConfigured && (
          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 4, marginBottom: -8 }}>
            {(
              [
                [false, '通常'],
                [true, '深夜'],
              ] as [boolean, string][]
            ).map(([v, label]) => (
              <span
                key={label}
                onClick={() => setNight(v)}
                {...clickable(() => setNight(v), `${label}状態を表示`)}
                style={{
                  cursor: 'pointer',
                  fontSize: 9,
                  color: night === v ? C.lime : C.muted,
                  background: night === v ? C.fill : 'transparent',
                  border: `1.5px solid ${night === v ? C.border : C.placeholder}`,
                  padding: '2px 8px',
                  borderRadius: 4,
                }}
              >
                {label}
              </span>
            ))}
          </div>
        )}

        {/* 受け取った誘い(承認制)。対応が必要なときだけ出す。
            0件・取得中は出さない(常設すると本当に承認待ちのときの目立ちが弱まるため)。
            誘い自体の導線はマイページ「受け取った誘い」に常設されている。 */}
        {(isBackendConfigured ? (pendingCount ?? 0) > 0 : true) && (
          <div
            onClick={() => flow.go('requests')}
            {...clickable(() => flow.go('requests'), '承認待ちの誘いを確認する')}
            style={{
              cursor: 'pointer',
              background: C.lime,
              border: `1.5px solid ${C.border}`,
              borderRadius: 10,
              boxShadow: `2px 2px 0 ${C.shadowCol}`,
              padding: '10px 13px',
              display: 'flex',
              alignItems: 'center',
              gap: 10,
            }}
          >
            <span style={{ fontSize: 16 }}>🙌</span>
            <span style={{ flex: 1, fontSize: 12, color: C.ink }}>
              {isBackendConfigured ? `${pendingCount}件の誘いが承認待ちです` : '2件の誘いが承認待ちです'}
            </span>
            <span style={{ fontSize: 11, color: C.ink }}>確認する ›</span>
          </div>
        )}

        {night ? (
          <NightHome flow={flow} />
        ) : (
        <>
        {/* 人気のユーザー: 掲載ピタメイトをカードで並べて探せる(モバイル・デスクトップ共通)。 */}
        {(() => {
          const popular: RecommendCardData[] = isBackendConfigured
            ? [...recommended]
                .sort((a, b) => b.mannerScore - a.mannerScore)
                .slice(0, 12)
                .map((h) => ({
                  key: `pop-${h.userId}`,
                  userId: h.userId,
                  initial: h.avatarInitial,
                  color: h.avatarColor,
                  name: h.nickname,
                  verified: h.isVerified,
                  chips: h.games.slice(0, 2),
                  price30: coinsPer30(h.hourlyRate),
                  compat: null,
                  meta: mannerScoreLabel(h.mannerScore, h.reviewCount)
                    ? `${mannerScoreLabel(h.mannerScore, h.reviewCount)}・マナー◎`
                    : NEW_MEMBER_LABEL,
                  voiceUrl: h.voiceUrl,
                  voiceSeconds: h.voiceSeconds,
                  avatarUrl: h.avatarUrl,
                  live: liveIds.has(h.userId),
                  lastSeenAt: h.lastSeenAt,
                  presenceStatus: h.presenceStatus,
                }))
            : DEMO_POPULAR
          if (popular.length === 0) return null
          return (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
                <span style={{ fontSize: 15, color: C.ink }}>🔥 人気のユーザー</span>
                <span
                  onClick={() => flow.go('search')}
                  {...clickable(() => flow.go('search'), 'もっと見る')}
                  style={{ cursor: 'pointer', fontSize: 10, color: C.lavender, fontWeight: 700 }}
                >
                  もっと見る ›
                </span>
              </div>
              <div
                style={{
                  display: 'grid',
                  gridTemplateColumns: 'repeat(auto-fill, minmax(230px, 1fr))',
                  gap: 12,
                }}
              >
                {popular.map((c) => (
                  <PopularUserCard
                    key={c.key}
                    data={c}
                    onOpen={() => openHost(c.userId)}
                  />
                ))}
              </div>
            </div>
          )
        })()}

        {/* 未ログインの訪問者への登録導線。**人の顔を見せた直後**に1つだけ置く。
            ゲームジャンルの手前で出しても、まだ誰も見ていないので動機が無い。
            カードを押した人は openHost() が登録へ送るので、ここは
            「見たけれど押さなかった人」を拾う役目。 */}
        {!signedIn && (
          <SignedOutPrompt
            flow={flow}
            compact
            title="気になるピタメイトは見つかりましたか？"
            body="登録すると、遊びたい時間を指定して予約できます。本人確認とマナースコアがあるので、はじめてでも安心して申し込めます。"
          />
        )}

        {/* ゲーム一覧: タップでそのゲームに絞ってさがすへ。人より後に置く —
            お気に入りを探しに来た人には、条件で絞る前にまず人を見せる(モバイル・デスクトップ共通)。 */}
        <GameGrid flow={flow} />

        {/* ランキング(デスクトップのみ。モバイルは上部のランキング導線カードから)。
            今週=スコア上位、新人=完了数の少ない順(はじめたばかりの注目ピタメイト)。 */}
        {!mobile && (
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(auto-fit, minmax(360px, 1fr))',
              gap: 18,
              alignItems: 'start',
            }}
          >
            <RankingSection
              flow={flow}
              title="🏆 今週のランキング"
              rows={(isBackendConfigured ? ranking : DEMO_RANKING).slice(0, 5)}
            />
            <RankingSection
              flow={flow}
              title="🌱 新人ランキング"
              rookie
              rows={
                isBackendConfigured
                  ? [...ranking]
                      .sort((a, b) => a.completedCount - b.completedCount)
                      .slice(0, 5)
                      .map((r, i) => ({ ...r, rank: i + 1 }))
                  : DEMO_ROOKIE
              }
            />
          </div>
        )}
        </>
        )}

        {/* 未ログインの訪問者への法務リンク。**モバイルにはフッターが無い**ので、
            ここに置かないと、登録も購入もしていない人が特商法の表記に辿り着けない。
            デスクトップは DesktopFooter が同じものを出すため重ねない。 */}
        {!signedIn && mobile && (
          <div
            style={{
              borderTop: `1.5px solid ${C.border}`,
              paddingTop: 16,
              // 下余白はスクロール領域側(padding-bottom: 24)で確保している
              paddingBottom: 4,
              marginTop: 4,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 12,
            }}
          >
            <LegalLinks flow={flow} />
            <span style={{ fontSize: 10.5, color: C.muted }}>
              © 2026 ピタフレ　<span style={{ opacity: 0.7 }}>build {__BUILD_ID__}</span>
            </span>
          </div>
        )}
      </div>
      <BottomTabs current={flow.screen} onNavigate={flow.go} />
    </Screen>
  )
}

/** 深夜オフライン状態(状態網羅 C1): オンライン0人 + 予約導線。 */
function NightHome({ flow }: { flow: Flow }) {
  return (
    <>
      {/* いま遊べる(深夜) */}
      <div
        style={{
          background: C.deepCard,
          border: `1.5px solid ${C.border}`,
          borderRadius: 12,
          boxShadow: `4px 4px 0 ${C.shadowCol}`,
          padding: 16,
          display: 'flex',
          flexDirection: 'column',
          gap: 10,
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <span style={{ fontSize: 15, color: '#fff' }}>▶ いま遊べる</span>
          <span
            style={{
              fontSize: 10.5,
              color: C.ink,
              background: C.muted,
              border: `1.5px solid ${C.border}`,
              padding: '3px 9px',
              borderRadius: 4,
            }}
          >
            0人 ONLINE
          </span>
        </div>
        <div
          style={{
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            gap: 8,
            padding: '14px 0',
          }}
        >
          <Moon size={34} color="#948DA8" />
          <span style={{ fontSize: 11.5, color: C.muted, textAlign: 'center', lineHeight: 1.6 }}>
            いまはみんな寝ているみたい。
            <br />
            朝以降にまた覗いてみて
          </span>
        </div>
      </div>

      {/* 予約して寝る */}
      <div
        style={{
          background: C.white,
          border: `1.5px solid ${C.border}`,
          borderRadius: 12,
          boxShadow: `4px 4px 0 ${C.shadowCol}`,
          padding: 16,
          display: 'flex',
          flexDirection: 'column',
          gap: 10,
        }}
      >
        <span style={{ fontSize: 13, color: C.ink }}>▶ 予約して寝る</span>
        <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.6 }}>
          「明日21時〜Apex」で募集を予約しておくと、起きたら候補が集まっています。
        </span>
        <div
          onClick={() => flow.go('boardCreate')}
          {...clickable(() => flow.go('boardCreate'), '予約募集をつくる')}
          style={{
            cursor: 'pointer',
            background: C.lime,
            color: C.ink,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '11px 0',
            textAlign: 'center',
            fontSize: 13,
            boxShadow: `2px 2px 0 ${C.shadowCol}`,
          }}
        >
          予約募集をつくる
        </div>
      </div>
    </>
  )
}
