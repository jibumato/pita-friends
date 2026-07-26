/**
 * ゲームタイトルの表示メタデータ(サムネ用)。
 *
 * ⚠️ 画像について
 * ゲームのキーアート・ロゴ・スクリーンショットは各社の著作物・商標です。
 * 日本には包括的なフェアユース規定が無く、二次利用ガイドラインも
 * 「非商用に限る」としているものが多いため、**コインを販売する本サービスで
 * 公式画像を無断掲載するのは権利侵害のリスクがあります**。
 * そのため既定では、ブランドに合わせた**自作のタイルを生成**して表示します。
 *
 * 許諾を得た画像がある場合は、`public/games/` に置いて `image` にパスを
 * 入れれば、そのタイトルだけ画像表示に切り替わります(混在可)。
 */

export type GameMeta = {
  /** タイルに出す短い表記(全角2文字/半角3文字までを目安に) */
  short: string
  /** タイルの配色(2色のグラデーション) */
  from: string
  to: string
  /** 許諾済みの画像があるときだけ設定する。例: '/games/apex.webp' */
  image?: string
}

/**
 * 色はジャンルのイメージでゆるく分けている(FPS=寒色、ホラー=暗色、
 * カジュアル=暖色/明色)。判別のためであって、各タイトルの公式カラーを
 * 再現する意図はない(公式配色の模倣は出所混同のもとになるため避ける)。
 */
export const GAME_META: Record<string, GameMeta> = {
  Apex: { short: 'AP', from: '#e2673c', to: '#b23a2e' },
  VALORANT: { short: 'VAL', from: '#e0524f', to: '#a32f3c' },
  スプラ: { short: 'スプ', from: '#3fbf7f', to: '#1c8f5a' },
  'Overwatch 2': { short: 'OW', from: '#f0a33c', to: '#c26a1e' },
  Fortnite: { short: 'FN', from: '#7a6ce0', to: '#4a3aa7' },
  CoD: { short: 'CoD', from: '#6d7684', to: '#3f4650' },
  R6S: { short: 'R6', from: '#4a90c4', to: '#2b5d85' },
  タルコフ: { short: 'タル', from: '#6b7358', to: '#3f4634' },
  荒野行動: { short: '荒野', from: '#c9a24a', to: '#8a6a24' },
  BF6: { short: 'BF', from: '#5a8fa8', to: '#33596d' },
  DbD: { short: 'DbD', from: '#5c4a6e', to: '#2e2440' },
  第五人格: { short: '第五', from: '#7d5f8f', to: '#43304f' },
  モンハン: { short: 'モン', from: '#c07a3a', to: '#84491c' },
  ARK: { short: 'ARK', from: '#4f9e86', to: '#26604f' },
  LoL: { short: 'LoL', from: '#3f7fb8', to: '#1f4d75' },
  スマブラ: { short: 'スマ', from: '#e05a72', to: '#a32b47' },
  マリカ: { short: 'マリ', from: '#e8564a', to: '#b02f2a' },
  ポケモン: { short: 'ポケ', from: '#f0c33c', to: '#c28a1e' },
  マイクラ: { short: 'マイ', from: '#63a83f', to: '#356b21' },
  あつ森: { short: 'あつ', from: '#67c9b0', to: '#2f8f79' },
  'Among Us': { short: 'AU', from: '#e05a5a', to: '#8f2f3f' },
  原神: { short: '原神', from: '#6fb3d9', to: '#3a6f9e' },
  VRChat: { short: 'VRC', from: '#8f6ce0', to: '#573aa7' },
  オンライン飲み: { short: '飲み', from: '#e8a25a', to: '#b06a24' },
  雑談: { short: '雑談', from: '#a78bdf', to: '#6a58c4' },
  相談: { short: '相談', from: '#8fa8d9', to: '#4f6f9e' },
  その他: { short: '他', from: '#9d98ad', to: '#655f78' },
}

/** 未登録のタイトルでも必ずタイルを出せるようにする。 */
export function gameMetaOf(name: string): GameMeta {
  const hit = GAME_META[name]
  if (hit) return hit
  return { short: name.slice(0, 2), from: '#a78bdf', to: '#6a58c4' }
}
