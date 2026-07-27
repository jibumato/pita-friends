/**
 * 外部アプリ誘導・金銭要求の一次検知(ルールベース)。
 * 設計: docs/trust-safety-spec.md §4。
 *
 * 方針:
 *  - 送信をブロックしない。初回ヒットは確認ダイアログを出し、送るかは本人に委ねる
 *    (過検知で正常な会話を止めないため)
 *  - ゲーム用語の許可リスト(フレンドコード等)を先に除外してから判定する
 *  - 「金銭要求」は1回でも人の確認対象にする(エスカレーション判断は呼び出し側)
 *
 * 対象は メッセージ・募集文・プロフィール文 のみ。定型情報は対象外。
 */

/** 検知カテゴリ。重大度の判断に使う。 */
export type GuardCategory = 'contact' | 'money' | 'dating'

export type GuardHit = {
  category: GuardCategory
  /** 実際に一致した箇所(ログ・運営確認用。画面には出さない)。 */
  matched: string
}

export type GuardResult = {
  hits: GuardHit[]
  /** 人による確認に回すべきか(金銭要求は1回でも対象)。 */
  needsReview: boolean
}

export const guardCategoryLabel: Record<GuardCategory, string> = {
  contact: '外部連絡先の交換',
  money: 'アプリ外の金銭のやり取り',
  dating: '出会い・恋愛目的',
}

/**
 * ゲーム内で正当に使う語。これらに一致した部分は判定前に伏せ字へ置き換え、
 * 「フレンドコード」を LINE 誘導と誤検知しないようにする。
 */
const ALLOWLIST: RegExp[] = [
  // ボイスチャットのハンドルは「@名前」で書くのが普通で、SNSのDM誘導と形が同じ。
  // ピタフレに通話機能が無い以上、Discordへ移ってもらうのが正しい使い方なので、
  // ここは通す必要がある。ただし**サービス名と隣り合う @ハンドルだけ**を外し、
  // 単独の @ハンドル はSNS誘導として扱ったままにする。
  //
  // 順番に意味がある。**下のサービス名の規則より先に置くこと。**
  // 後ろに置くと、先にサービス名が伏せ字になって @ハンドル だけが残り、
  // 結局そこが誤検知する(「ディスコのユーザー名 @taro」がこれで漏れていた)。
  //
  // @ を必須にしているのは、任意にすると「ディスコで LINE交換しよ」の
  // 「LINE」まで伏せ字になり、**隠したい勧誘まで見逃す**ため。
  /(discord|ディスコ|ディスコード|steam|スチーム)\s*(は|の|:|：|で|→|->)?\s*(フレンド|ID|名|ネーム|ユーザー名|アカウント|タグ)?\s*(は|が|:|：)?\s*@[A-Za-z0-9_.]{2,32}/gi,
  /@[A-Za-z0-9_.]{2,32}\s*[（(]?\s*(discord|ディスコ|ディスコード|steam|スチーム)/gi,
  /フレンド\s*(コード|ID|ｺｰﾄﾞ)/gi,
  /フレコ/gi,
  /ゲーム\s*(内|の)?\s*ID/gi,
  /(スイッチ|switch|ps[45n]|steam|discord|ディスコ|ディスコード)\s*(の)?\s*(フレンド|ID|名|ネーム|ユーザー名|アカウント|タグ)/gi,
  // ランク帯やゲーム内通貨の話は金銭要求ではない
  /(ゴールド|シルバー|ブロンズ|プラチナ|ダイヤ)\s*(帯|ランク)?/gi,
]

/** 外部連絡先への誘導。 */
const CONTACT_PATTERNS: RegExp[] = [
  // 「ラインのID」のように助詞が挟まる書き方が最も多いのに、\s* だけでは
  // 助詞をまたげず素通りしていた。「の」を許して塞ぐ。
  // 直前の (?<!オン) は「オンラインしよう」を LINE 誘導と読まないため。
  /(?<!オン)(ライン|らいん)\s*(の)?\s*(交換|こうかん|して|しよ|やってる|ID|アカ)/gi,
  /(?<![A-Za-z])LINE\s*(の)?\s*(交換|こうかん|して|しよ|やってる|ID|アカ)/gi,
  /\bline\s*(id|add)\b/gi,
  /(カカオ|kakao|テレグラム|telegram|シグナル|signal)/gi,
  /(インスタ|instagram|ツイッター|twitter|(?<![a-z])X)\s*(の)?\s*(ID|アカ|垢|DM)/gi,
  /(電話|でんわ|携帯|ケータイ)\s*(番号|ばんごう)/gi,
  // 電話番号らしき数字列(ハイフン有無)
  /0\d{1,4}[-\s]?\d{1,4}[-\s]?\d{3,4}/g,
  // メールアドレス
  /[\w.+-]+@[\w-]+\.[\w.-]+/g,
  /(@[A-Za-z0-9_]{4,})/g,
]

/** アプリ外での金銭のやり取り。 */
const MONEY_PATTERNS: RegExp[] = [
  /(振込|振り込み|ふりこみ|送金|そうきん)/gi,
  /(現金|げんきん|手渡し|てわたし)/gi,
  /(直接|個人間|アプリ外|外で)\s*(払|支払|やり取り|取引)/gi,
  /(paypay|ペイペイ|アマギフ|アマゾンギフト|amazonギフト|ギフト券|プリペイド)/gi,
  /(口座|こうざ)\s*(番号)?/gi,
  // 金額表現(1,000円 / 3000えん / ¥500)
  /(¥\s?\d{3,}|[\d,]{3,}\s*(円|えん|エン))/g,
]

/** 出会い・恋愛目的の勧誘。 */
const DATING_PATTERNS: RegExp[] = [
  /(会いたい|あいたい|会おう|あおう|会える|オフ会|直接会)/gi,
  /(彼女|彼氏|カノジョ|カレシ)\s*(募集|ぼしゅう|ほしい|欲しい)/gi,
  /(付き合|つきあ)(って|おう|いたい)/gi,
  /(デート|でーと)/gi,
  /(タイプです|好みです|可愛い|かわいい|美人)/gi,
]

const RULES: { category: GuardCategory; patterns: RegExp[] }[] = [
  { category: 'money', patterns: MONEY_PATTERNS },
  { category: 'contact', patterns: CONTACT_PATTERNS },
  { category: 'dating', patterns: DATING_PATTERNS },
]

/** 許可リストに当たる部分を伏せ字にして、誤検知の元を先に取り除く。 */
function maskAllowed(text: string): string {
  let out = text
  for (const re of ALLOWLIST) {
    out = out.replace(re, (m) => '・'.repeat(m.length))
  }
  return out
}

/**
 * テキストを検査する。ヒットが無ければ hits は空配列。
 * 金銭要求は1件でも needsReview を立てる(§4.2-3)。
 */
export function inspectText(text: string): GuardResult {
  const target = maskAllowed(text ?? '')
  const hits: GuardHit[] = []

  for (const { category, patterns } of RULES) {
    for (const re of patterns) {
      // グローバル正規表現は lastIndex を持つため、実行ごとにリセットする
      re.lastIndex = 0
      const found = target.match(re)
      if (found && found.length > 0) {
        hits.push({ category, matched: found[0] })
        break // 同一カテゴリは1件で足りる(画面表示・記録の重複を避ける)
      }
    }
  }

  return { hits, needsReview: hits.some((h) => h.category === 'money') }
}

/**
 * 確認ダイアログ用の本文。カテゴリに応じて理由を出し分ける。
 *
 * **「連絡先の交換はアプリ内で」とは書かない。** ピタフレに通話機能が無い以上、
 * 一緒に遊ぶには Discord 等へ移ってもらう必要がある。そこまで止める文言を出すと、
 * 正しい使い方をしている人に嘘を伝えることになる。
 * 止めたいのは**お金のやり取りがアプリの外へ出ること**なので、そこだけを言う。
 */
export function guardWarningText(hits: GuardHit[]): string {
  const cats = [...new Set(hits.map((h) => h.category))]
  const reasons = cats.map((c) => guardCategoryLabel[c]).join('・')
  const tail = cats.includes('money')
    ? 'お金のやり取りは必ずアプリ内のコインで行ってください。'
    : 'ピタフレはゲームを一緒に楽しむ場です。'
  return `${reasons}に関わる内容が含まれているようです。${tail}（一緒に遊ぶためにDiscord等の通話を使うことは問題ありません）`
}
