/**
 * 「みまもり」の一次検知(送信前の警告)。docs/trust-safety-spec.md §4 準拠。
 * 外部アプリへの誘導・アプリ外での金銭要求のパターンにヒットしたら、
 * 送信をブロックせず警告を表示する(本人の選択に委ねる)。
 * 「フレンドID/フレンドコード」等のゲーム用語は誤検知しないよう除外する。
 */
const PATTERNS: RegExp[] = [
  /line\s*id|ライン\s*id|ラインで|LINEで|LINEID|らいん/i,
  /インスタ|instagram|ig\s*id/i,
  /電話番号|でんわばんごう|tel[:：]/i,
  /直接\s*(会|払|渡)|現金|振込|銀行口座|個人的に(連絡|払)/,
  /rmt|アカウント売買|通貨(の)?販売/i,
]

export function containsWarningPattern(text: string): boolean {
  return PATTERNS.some((re) => re.test(text))
}
