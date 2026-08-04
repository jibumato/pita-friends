/**
 * アプリ内で表示する規約・ポリシー類。
 * 利用規約/プライバシー/特商法/資金決済法表示は docs/legal/ のドラフトを
 * 唯一の出典として ?raw で読み込む(二重管理を避ける)。
 * 表示側で「施行前ドラフト」バナーを出す。
 *
 * ⚠️ **人に渡す書類になりうるものは、必ず Markdown 側に置くこと。**
 * 資金決済法表示は当初ここに文字列で書いていたが、他の3点が
 * `tools/md-to-docx.cjs` で Word にできるのに**これだけ作れない**、という
 * 差ができていた。弁護士へ別紙として送る段になって気づいた。
 * みまもり説明は画面専用の案内文なので、ここに残す。
 */
import termsRaw from '../../docs/legal/terms-of-service-draft.md?raw'
import privacyRaw from '../../docs/legal/privacy-policy-draft.md?raw'
import tokushohoRaw from '../../docs/legal/tokushoho-draft.md?raw'
import shikinRaw from '../../docs/legal/shikin-kessai-draft.md?raw'
// 役務提供に関するガイドラインは**規約の一部**(第1条2項)。
// 「本サービス上で別途定める」ものなので、**アプリから到達できないと成立しない。**
import guidelineRaw from '../../docs/legal/service-standard-guideline.md?raw'
// 事例集は規約の**外**。⚠️ 名称に「ガイドライン」を使わないこと(第1条2項が
// その名称の文書を自動的に規約へ取り込むため、1件直すたびに規約変更になる)
import examplesRaw from '../../docs/help/service-standard-examples.md?raw'
import { BUSINESS, ADDRESS_DISCLOSURE, TERMS_PARTY_NAME } from './businessInfo'

export type LegalDocKey =
  | 'terms'
  | 'privacy'
  | 'tokushoho'
  | 'shikin'
  | 'guideline'
  | 'examples'
  | 'mimamori'

/**
 * ドラフトの前付け(H1タイトル・社内レビュー用の引用注記・作成日)を落として
 * 最初の水平線以降の本文だけを返す。画面側でタイトルとドラフトバナーを出すため。
 */
function body(md: string): string {
  const idx = md.indexOf('\n---\n')
  return idx >= 0 ? md.slice(idx + 5).trim() : md.trim()
}

const ON_REQUEST = 'ご請求があれば遅滞なく開示します（下記のメールアドレスへご連絡ください）'

/**
 * 条文中の事業者情報の差込み。**値は `businessInfo.ts` の1か所にしかない。**
 * ドラフト側に住所や氏名を直接書くと、書類ごとにずれていく。
 */
function fillBusiness(md: string): string {
  const open = ADDRESS_DISCLOSURE === 'public'
  const pairs: [string, string][] = [
    // 規約 第1条だけは屋号を前に出す（当事者を名乗る箇所なので、個人名も残す）
    ['【事業者名（屋号）：公開前に記入】', TERMS_PARTY_NAME],
    ['【氏名（個人事業主本人）：公開前に記入】', BUSINESS.name],
    ['【氏名（個人事業主）：公開前に記入】', BUSINESS.name],
    ['【サービス専用の問い合わせ用メールアドレス：公開前に記入】', BUSINESS.email],
    ['【所在地：公開前に記入】', open ? `〒${BUSINESS.postalCode} ${BUSINESS.address}` : ON_REQUEST],
    ['【電話番号：公開前に記入】', open ? BUSINESS.phone : ON_REQUEST],
  ]
  return pairs.reduce((acc, [from, to]) => acc.split(from).join(to), md)
}

/**
 * 社内向けの注記 `〔※ … 〕` を落とす。
 *
 * **利用者に見せるものではない。** 注記には、弁護士回答の引用、同種サービスの
 * 名前、「なぜこの条文にしたか」の判断の経緯が入っている。ドラフトの間は
 * 画面にもそのまま出ていたが、公開する書面としては不適切なので落とす。
 *
 * `tools/md-to-docx.cjs` の `stripNotes` と同じ扱いにしてある
 * （Word版と画面で中身が食い違うと、どちらが本物か分からなくなる）。
 * `〔監視〕` のような**通常の亀甲括弧には触れない。**
 */
function stripNotes(md: string): string {
  return md
    .replace(/〔※[^〕]*〕/g, '')
    // 注記だけの行が空になるので、空行の連続を1つに畳む
    .split('\n')
    .filter((l, i, a) => !(l.trim() === '' && (a[i - 1] ?? '').trim() === ''))
    .join('\n')
    .replace(/[ 　]+$/gm, '')
    // 末尾の「AIが作ったたたき台」の断り書き。Word版でも落としている
    .replace(/\n\*本ドラフトはAI[\s\S]*?\*/, '')
    .trim()
}

const doc = (md: string) => stripNotes(fillBusiness(body(md)))

const mimamoriMd = `# みまもり（監視）について

作成日: 2026-07-15

---

ピタフレは、みんなが安心して遊べる場を守るために、アプリ内のやり取りを「みまもり」しています。

## 何を確認するの？

安全のため、アプリ内で送受信されるメッセージ・募集文・プロフィール文などを確認することがあります。目的は、次のような違反の検知・防止に限られます。

- アプリを介さない金銭のやり取りを目的とした外部サービスへの誘導
- アプリ外での直接の金銭・RMTの要求
- 出会い・恋愛目的の勧誘
- 暴言・ハラスメント、なりすまし・年齢詐称 など

> **Discord等のボイスチャットの併用は問題ありません。** ピタフレには通話機能がないため、一緒に遊ぶときは外部のボイスチャットをお使いください。禁止しているのは、**お金のやり取りをアプリの外へ持ち出すこと**です。

## どうやって確認するの？

- **原則は自動的な検知（プログラム）**です。
- 担当者が個別の内容を読むのは、**通報があったとき、または違反の兆候を検知したときだけ**です。確認する範囲も、その事案に必要な範囲に限ります。
- 対象は**アプリ内のやり取りだけ**です。アプリ外のやり取りは対象にしません。

## 同意の撤回について

みまもりへの同意は、**設定 ＞ プライバシー・安全 ＞ みまもりへの同意**から、いつでも撤回できます。

ただし、みまもりはピタフレの安全を守るための土台です。撤回されると、次の機能はご利用いただけなくなります。

- メッセージの送受信
- 誘いの送受信
- 募集の投稿・参加
- 新しい予約

一方で、**すでに成立している予約の進行（チェックイン・完了・キャンセル）と、換金の手続は、そのまま続けられます。**

設定画面から改めて同意していただければ、いつでも再開できます。

> メッセージは相手との**両方のやり取り**です。そのため、どちらか一方が撤回されている間は、その相手とのやり取りはお互いに止まります。

## あなたを守る仕組み

- ワンタップの通報・ブロック（相手には通知されません）
- 違反者は身分証ベースで再登録できないよう措置します

安心して、ゲームを一緒に楽しむことに集中してください。`

export const LEGAL_DOCS: Record<LegalDocKey, { title: string; markdown: string }> = {
  terms: { title: '利用規約', markdown: doc(termsRaw) },
  privacy: { title: 'プライバシーポリシー', markdown: doc(privacyRaw) },
  tokushoho: { title: '特定商取引法に基づく表記', markdown: doc(tokushohoRaw) },
  shikin: { title: '資金決済法に基づく表示', markdown: doc(shikinRaw) },
  guideline: { title: '役務提供に関するガイドライン', markdown: doc(guidelineRaw) },
  examples: { title: 'プレイの内容が約束と違ったとき', markdown: doc(examplesRaw) },
  mimamori: { title: 'みまもり（監視）について', markdown: doc(mimamoriMd) },
}
