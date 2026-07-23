/**
 * 廃止済み: 端末ステータスバー(時刻 + 電池)の疑似演出。
 * スマホ実機っぽさを出す目的だったが、常時何も描画しないようにした
 * (呼び出し側の30箇所近くは残っているが、すべて無害なno-opになる)。
 */
export default function StatusBar(_props: { time: string; dark?: boolean }) {
  return null
}
