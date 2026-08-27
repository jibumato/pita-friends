import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import { isBackendConfigured } from '../lib/supabase'
import {
  fetchMyChargebackOffsets,
  objectToChargebackOffset,
  type MyChargebackOffset,
} from '../lib/queries'

/**
 * 報酬コインの控除の予告と、それに対する異議（規約 第8条の6第4項3号）。
 *
 * ■ なぜ画面が要るのか
 *   DB側（0088）は最初から揃っていた。予告を本人が読める RLS も、異議を
 *   受け取る関数もある。**無かったのは画面だけ。**
 *
 *   その状態で何が起きるか。予告の通知は「お心当たりのない点があれば
 *   お問い合わせ窓口までご連絡ください」と案内する。ところが窓口へ来た
 *   メールは `objected_at` に入らない。運営側は `objected_at` を見て
 *   「異議が出ているなら理由必須」と判定するので、**異議を述べたのに
 *   出ていない扱いのまま実行される。**
 *   条文が定めた機会が、実装では働いていなかった。
 *
 * ■ 出し方
 *   予告が1件も無ければ**何も描かない。** 大半の人には一生関係の無い話で、
 *   常設すると「自分もいつか減らされる」という誤解だけが残る。
 *   逆に予告が来ているときは、ウォレットのいちばん上に出す——
 *   **見えないまま減らされるのが最悪**だから。
 */
export default function ChargebackOffsetNotice() {
  const [items, setItems] = useState<MyChargebackOffset[] | null>(null)
  const [openId, setOpenId] = useState<string | null>(null)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const load = () => {
    if (!isBackendConfigured) return
    fetchMyChargebackOffsets()
      .then(setItems)
      // 取れなければ出さない。ここで「読み込めません」と出しても、
      // 利用者にできることが無い
      .catch(() => {})
  }

  useEffect(load, [])

  if (!items) return null
  // 予告中のものと、直近で実行/取消になったものだけ見せる。
  // 済んだ話を延々と残さない
  const notified = items.filter((x) => x.status === 'notified')
  const settled = items.filter((x) => x.status !== 'notified').slice(0, 3)
  if (notified.length === 0 && settled.length === 0) return null

  const submit = async (id: string) => {
    if (busy) return
    setBusy(true)
    setError(null)
    try {
      await objectToChargebackOffset(id, note)
      setNote('')
      setOpenId(null)
      load()
    } catch (e) {
      setError(e instanceof Error ? e.message : '送信できませんでした')
    } finally {
      setBusy(false)
    }
  }

  const day = (iso: string) =>
    new Date(iso).toLocaleDateString('ja-JP', { year: 'numeric', month: 'long', day: 'numeric' })

  const target = (o: MyChargebackOffset) =>
    o.giftId ? 'ありがとうギフト' : 'ご一緒したプレイ'

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      <span style={{ fontSize: 13, color: C.ink }}>▶ 報酬コインの控除について</span>

      {notified.length > 0 && (
        <div
          style={{
            background: C.avatarPink,
            border: `1.5px solid ${C.border}`,
            borderRadius: 10,
            padding: '12px 14px',
            display: 'flex',
            flexDirection: 'column',
            gap: 10,
          }}
        >
          <span style={{ fontSize: 11, lineHeight: 1.8, color: C.ink }}>
            ゲストの決済が取り消されたため、その決済で支払われた分について、
            <b>未払いの報酬コインからの控除</b>を予定しています（利用規約 第8条の6）。
            <br />
            <b>既にお振込みが完了した分を、あとから請求することはありません。</b>
          </span>

          {notified.map((o) => (
            <div
              key={o.id}
              style={{
                background: C.white,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '10px 12px',
                display: 'flex',
                flexDirection: 'column',
                gap: 7,
              }}
            >
              <span style={{ fontSize: 12.5, color: C.ink }}>
                {target(o)}の <b>{o.coins.toLocaleString()}コイン</b>
              </span>
              <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
                {day(o.notifiedAt)}にお知らせしました。
                <br />
                {o.objectedAt ? (
                  <>
                    <b style={{ color: C.ink }}>異議を受け付けています</b>（
                    {day(o.objectedAt)}）。運営が内容を確認して判断します。
                  </>
                ) : (
                  <>
                    <b style={{ color: C.ink }}>{day(o.objectionDeadline)}まで</b>
                    、この控除に異議を述べられます。
                  </>
                )}
              </span>

              {o.objectionNote && (
                <span
                  style={{
                    fontSize: 10.5,
                    color: C.body,
                    lineHeight: 1.7,
                    background: C.surface,
                    borderRadius: 6,
                    padding: '7px 9px',
                    whiteSpace: 'pre-wrap',
                  }}
                >
                  お送りいただいた内容: {o.objectionNote}
                </span>
              )}

              {!o.objectedAt &&
                (openId === o.id ? (
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
                    <textarea
                      value={note}
                      onChange={(e) => setNote(e.target.value)}
                      maxLength={1000}
                      rows={4}
                      placeholder="心当たりのない点や、事情をお書きください"
                      style={{
                        background: C.white,
                        border: `1.5px solid ${C.border}`,
                        borderRadius: 8,
                        padding: '9px 11px',
                        fontSize: 12,
                        color: C.ink,
                        outline: 'none',
                        fontFamily: 'inherit',
                        resize: 'vertical',
                        width: '100%',
                        boxSizing: 'border-box',
                      }}
                    />
                    {error && (
                      <span style={{ fontSize: 10.5, color: C.ink }}>{error}</span>
                    )}
                    <div style={{ display: 'grid', gridAutoFlow: 'column', gap: 6 }}>
                      <span
                        onClick={() => void submit(o.id)}
                        role="button"
                        tabIndex={0}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') void submit(o.id)
                        }}
                        style={{
                          cursor: busy ? 'default' : 'pointer',
                          fontSize: 12,
                          color: C.ctaFg,
                          background: C.ctaBg,
                          textAlign: 'center',
                          padding: '9px 0',
                          borderRadius: 6,
                        }}
                      >
                        {busy ? '送信中…' : '異議を送る'}
                      </span>
                      <span
                        onClick={() => {
                          setOpenId(null)
                          setNote('')
                          setError(null)
                        }}
                        role="button"
                        tabIndex={0}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') setOpenId(null)
                        }}
                        style={{
                          cursor: 'pointer',
                          fontSize: 12,
                          color: C.ink,
                          background: C.white,
                          border: `1.5px solid ${C.border}`,
                          textAlign: 'center',
                          padding: '8px 0',
                          borderRadius: 6,
                        }}
                      >
                        やめる
                      </span>
                    </div>
                  </div>
                ) : (
                  <span
                    onClick={() => {
                      setOpenId(o.id)
                      setNote('')
                      setError(null)
                    }}
                    role="button"
                    tabIndex={0}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') setOpenId(o.id)
                    }}
                    style={{
                      cursor: 'pointer',
                      alignSelf: 'flex-start',
                      fontSize: 11.5,
                      color: C.ink,
                      background: C.white,
                      border: `1.5px solid ${C.border}`,
                      padding: '7px 13px',
                      borderRadius: 6,
                    }}
                  >
                    この控除に異議を述べる
                  </span>
                ))}
            </div>
          ))}
        </div>
      )}

      {settled.map((o) => (
        <div
          key={o.id}
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '10px 12px',
            fontSize: 11,
            lineHeight: 1.7,
            color: C.body,
          }}
        >
          {o.status === 'cancelled' ? (
            <>
              {target(o)}の {o.coins.toLocaleString()}コインの控除は
              <b style={{ color: C.ink }}>取りやめになりました</b>。
            </>
          ) : (
            <>
              {target(o)}について、
              <b style={{ color: C.ink }}>
                {(o.executedCoins ?? o.coins).toLocaleString()}コイン
              </b>
              を控除しました（{o.executedAt ? day(o.executedAt) : ''}）。
            </>
          )}
        </div>
      ))}
    </div>
  )
}
