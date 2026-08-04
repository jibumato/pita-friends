/**
 * ギフト(応援チップ)のトーク本文を、スタンプ表示に読み替える。
 *
 * send_gift が、トークへ次の本文を投稿している:
 *   0097以降: 🎁 ありがとうギフト {コイン}コイン「{ひとこと}」
 *   0097より前: 🎁 {コイン}コインのありがとうギフトを贈りました「{ひとこと}」
 *
 * **旧い本文も読める。** 既に流れたメッセージは書き換えていない
 * (過去の事実の改変になる)ので、新旧どちらも受ける。
 *
 * **本文の形は変えていない。** 表示だけをこちらで読み替える。
 * そうすることで、
 *   ・マイグレーションが要らない(既に流れた分もスタンプになる)
 *   ・スタンプ画像が無い環境や、読み替えに失敗したときも、
 *     元の文章がそのまま出るだけで情報は落ちない
 * という二点を満たせる。**サーバ側の文言を変えるときはここも直すこと。**
 */

/** ひとことの定型文と、対応するスタンプ画像。 */
const STICKERS: { label: string; src: string }[] = [
  { label: '🎉 ナイスプレイ！', src: '/stickers/nice_play.webp' },
  { label: '☕ おつかれ！', src: '/stickers/otsukare.webp' },
  { label: '🌸 応援してる！', src: '/stickers/ouen.webp' },
  { label: '👏 また遊ぼう！', src: '/stickers/mata_asobo.webp' },
]

export type GiftMessage = {
  coins: number
  /** 添えられたひとこと(定型＋自由入力)。無ければ null。 */
  text: string | null
  /** 定型文に対応するスタンプ。定型を選ばなかった場合は null。 */
  stickerSrc: string | null
  /** スタンプの代替テキスト(読み上げ・画像が出ないとき用)。 */
  stickerAlt: string | null
}

// 0097: 「贈りました」= A→B の移転を表す言い方をやめた(規約 第7条の2)。
// 旧い本文が残っているので、両方を受ける。
const PATTERN_NEW = /^🎁\s*ありがとうギフト\s*([\d,]+)コイン(?:「(.*)」)?$/s
const PATTERN_OLD = /^🎁\s*([\d,]+)コインのありがとうギフトを贈りました(?:「(.*)」)?$/s

/** ギフトの本文なら中身を返す。違えば null(通常のメッセージとして描く)。 */
export function parseGiftMessage(body: string): GiftMessage | null {
  const t = body.trim()
  const m = PATTERN_NEW.exec(t) ?? PATTERN_OLD.exec(t)
  if (!m) return null
  const coins = Number(m[1].replace(/,/g, ''))
  if (!Number.isFinite(coins)) return null
  const text = m[2]?.trim() || null
  const hit = text ? STICKERS.find((s) => text.startsWith(s.label)) : undefined
  return {
    coins,
    text,
    stickerSrc: hit?.src ?? null,
    stickerAlt: hit?.label ?? null,
  }
}
