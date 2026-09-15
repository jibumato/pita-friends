/**
 * 「今週はじめた人」(0123)。
 *
 * ■ なぜ別枠が要るか
 *   さがすの並びは「また呼ばれているか」順(0060)で、これは正しい。
 *   ただし始めたばかりの人は実績がゼロなので必ず下に来る。
 *   予約が入らない → 評価がつかない → 表示されない、で輪が閉じる。
 *   **順位と関係なく見てもらえる場所**を1つ作って、そこを切る。
 *
 * ■ 出さない場合
 *   - 0人のとき(区画ごと消す。「新しい人はいません」と書いてある場所は
 *     無いほうがましな場所になる)
 *   - 絞り込み中のとき(呼び出し側で判断する。「Apex」で絞っているのに
 *     関係ない新人が並ぶと、結果の一部だと誤解される)
 *
 * 枠を1つも登録していない人はサーバ側で除いてある——押しても予約できない
 * 相手を推す場所に並べると、ゲストのタップを捨てることになる。
 */
import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import { clickable } from '../hooks/clickable'
import { coinsPer30 } from '../flow'
import { fetchNewHostCards, type NewHost } from '../lib/queries'

/** 「3日前から」。何日前かが分かると、新しさが具体的になる。 */
function sinceLabel(iso: string): string {
  const days = Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000)
  if (days <= 0) return '今日から'
  if (days === 1) return '昨日から'
  return `${days}日前から`
}

export default function NewHostsRail({ onOpen }: { onOpen: (hostId: string) => void }) {
  const [hosts, setHosts] = useState<NewHost[] | null>(null)

  useEffect(() => {
    let active = true
    fetchNewHostCards(12, 14)
      .then((rows) => active && setHosts(rows))
      // 取れなくても、さがす画面の本体は出す。**この区画は黙って消える**
      .catch(() => active && setHosts([]))
    return () => {
      active = false
    }
  }, [])

  if (!hosts || hosts.length === 0) return null

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
        <span style={{ fontSize: 13, color: C.ink }}>⭐ 最近はじめた人</span>
        <span style={{ fontSize: 10.5, color: C.muted }}>まだ評価がつく前のピタメイトです</span>
      </div>
      <div
        className="pita-scroll"
        style={{ display: 'flex', gap: 10, overflowX: 'auto', paddingBottom: 4 }}
      >
        {hosts.map((h) => (
          <div
            key={h.userId}
            onClick={() => onOpen(h.userId)}
            {...clickable(() => onOpen(h.userId), `${h.nickname}さんのプロフィールを開く`)}
            style={{
              cursor: 'pointer',
              flex: 'none',
              width: 128,
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 12,
              boxShadow: `2px 2px 0 ${C.shadowCol}`,
              padding: 11,
              display: 'flex',
              flexDirection: 'column',
              gap: 7,
            }}
          >
            <div
              style={{
                width: 44,
                height: 44,
                borderRadius: 8,
                background: h.avatarColor,
                border: `1.5px solid ${C.border}`,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                fontSize: 18,
                color: C.onPale,
                overflow: 'hidden',
              }}
            >
              {h.avatarUrl ? (
                <img
                  src={h.avatarUrl}
                  alt=""
                  style={{ width: '100%', height: '100%', objectFit: 'cover' }}
                />
              ) : (
                h.avatarInitial
              )}
            </div>
            <span
              style={{
                fontSize: 12.5,
                color: C.ink,
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
              }}
            >
              {h.nickname}
            </span>
            <span style={{ fontSize: 9.5, color: C.muted }}>{sinceLabel(h.hostSince)}</span>
            {h.games.length > 0 && (
              <span
                style={{
                  fontSize: 10,
                  color: C.body,
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                }}
              >
                {h.games.join('・')}
              </span>
            )}
            <span style={{ fontSize: 10.5, color: C.ink }}>
              {coinsPer30(h.hourlyRate)}コイン/30分
            </span>
          </div>
        ))}
      </div>
    </div>
  )
}
