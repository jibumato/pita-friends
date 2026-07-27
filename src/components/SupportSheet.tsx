/**
 * 遊び終わったあとに、ピタメイトを応援する(ありがとうチップを贈る)シート。
 *
 * **裏側は既存のギフト(send_gift)をそのまま使う。** 別系統の送金にしていない。
 * 0020で弁護士の指摘に沿って「一緒に遊んだ相手への“ありがとうチップ”」へ
 * 作り替え、送信条件と上限(1回5万・24時間5万・30日20万・相互送金禁止・
 * チャージ後24時間は不可)をそこへ集約した。もう1本作ると上限が二重になり、
 * 役務に付随する謝礼という整理も崩れる。ここは**出す場面が増えただけ**。
 */
import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import { GIFT_AMOUNTS, sendGift, fetchPaidBalance } from '../lib/queries'

/** 定型の応援メッセージ。金額とは独立に選ぶ。 */
export const SUPPORT_MESSAGES = [
  '🎉 ナイスプレイ！',
  '☕ おつかれ！',
  '🌸 応援してる！',
  '👏 また遊ぼう！',
] as const

type Props = {
  promiseId: string
  partnerName: string
  onClose: () => void
  onSent: (coins: number) => void
}

export default function SupportSheet({ promiseId, partnerName, onClose, onSent }: Props) {
  const [message, setMessage] = useState<string>(SUPPORT_MESSAGES[0])
  const [custom, setCustom] = useState('')
  const [amount, setAmount] = useState<number>(GIFT_AMOUNTS[0])
  const [balance, setBalance] = useState<number | null>(null)
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    fetchPaidBalance()
      .then((b) => active && setBalance(b))
      .catch(() => active && setBalance(null))
    return () => {
      active = false
    }
  }, [])

  const short = balance !== null && balance < amount
  const body = custom.trim() ? `${message} ${custom.trim()}` : message

  async function handleSend() {
    if (sending || short) return
    setSending(true)
    setError(null)
    try {
      await sendGift(promiseId, amount, body)
      onSent(amount)
    } catch (e) {
      setError(e instanceof Error ? e.message : '送信に失敗しました')
    } finally {
      setSending(false)
    }
  }

  const chip = (selected: boolean) => ({
    cursor: 'pointer',
    fontSize: 13,
    color: selected ? C.ink : C.body,
    background: selected ? C.lime : C.white,
    border: `1.5px solid ${C.border}`,
    padding: '10px 14px',
    borderRadius: 8,
  })

  return (
    <div
      onClick={onClose}
      style={{
        position: 'absolute',
        inset: 0,
        background: 'rgba(0,0,0,.45)',
        display: 'flex',
        alignItems: 'flex-end',
        zIndex: 60,
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        className="pita-scroll"
        style={{
          width: '100%',
          maxHeight: '88%',
          overflowY: 'auto',
          background: C.surface,
          borderTop: `1.5px solid ${C.border}`,
          borderRadius: '16px 16px 0 0',
          padding: '16px 20px 26px',
          display: 'flex',
          flexDirection: 'column',
          gap: 12,
          boxSizing: 'border-box',
          animation: 'scrIn .25s ease both',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10 }}>
          <span style={{ fontSize: 15, color: C.ink }}>{partnerName}さんを応援する</span>
          <span onClick={onClose} style={{ cursor: 'pointer', flex: 'none', fontSize: 13, color: C.muted }}>
            閉じる
          </span>
        </div>

        <span style={{ fontSize: 11, color: C.muted, lineHeight: 1.7 }}>
          気持ちをコインで贈れます。<b style={{ color: C.ink }}>任意</b>です。贈らなくても評価やプレイに影響はありません。
        </span>

        <span style={{ fontSize: 11.5, color: C.ink, marginTop: 2 }}>ひとこと</span>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {SUPPORT_MESSAGES.map((m) => (
            <span key={m} onClick={() => setMessage(m)} style={chip(message === m)}>
              {m}
            </span>
          ))}
        </div>
        <input
          value={custom}
          onChange={(e) => setCustom(e.target.value)}
          placeholder="ひとこと添える(任意)"
          maxLength={100}
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '11px 14px',
            fontSize: 12.5,
            color: C.ink,
            outline: 'none',
            fontFamily: 'inherit',
            width: '100%',
            boxSizing: 'border-box',
          }}
        />

        <span style={{ fontSize: 11.5, color: C.ink, marginTop: 2 }}>金額（コイン）</span>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {GIFT_AMOUNTS.map((a) => (
            <span key={a} onClick={() => setAmount(a)} style={chip(amount === a)}>
              {a.toLocaleString()}
            </span>
          ))}
        </div>

        {balance !== null && (
          <span style={{ fontSize: 11, color: short ? C.avatarOrange : C.muted }}>
            購入コインの残高 {balance.toLocaleString()}
            {short && ' — 足りません'}
          </span>
        )}

        {error && (
          <div
            style={{
              background: C.avatarPink,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '10px 12px',
              fontSize: 11.5,
              color: C.ink,
            }}
          >
            {error}
          </div>
        )}

        <button
          onClick={() => void handleSend()}
          disabled={sending || short}
          style={{
            cursor: sending || short ? 'not-allowed' : 'pointer',
            background: sending || short ? C.fill : C.ctaBg,
            color: sending || short ? C.placeholder : C.ctaFg,
            opacity: sending || short ? 0.55 : 1,
            border: 'none',
            borderRadius: 10,
            padding: '14px 0',
            fontSize: 15,
            fontFamily: 'inherit',
            marginTop: 2,
          }}
        >
          {sending ? '送信中…' : `${amount.toLocaleString()}コインを贈る ▶`}
        </button>

        {/* 資金決済法・規約まわりの必須表示。ギフトシート(Talk)と同じ内容を保つこと。 */}
        <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
          原資は購入コインのみです（おまけコインは使えません）。贈ったコインは
          <b style={{ color: C.ink }}>返金・取り消しができません</b>。
          相手には報酬コイン（受領から7日後に換金可能）として届きます。
        </span>
      </div>
    </div>
  )
}
