# 法務書類の Word 版（生成物）

このフォルダの `.docx` は **生成物** です。原本は `docs/legal/` の Markdown です。

| ファイル | 原本 | 渡す相手 |
|---|---|---|
| `ご照会_未査読の論点_2026-08-05.docx` | `../lawyer-questions-2026-08-04.md` | **弁護士に送る照会文。まだ誰の査読も受けていない論点（A〜F）だけを抜いたもの** |
| `ピタフレ利用規約_全文.docx` | `../terms-of-service-draft.md` | 弁護士・税理士・第三者。そのまま渡せます |
| `ピタフレ利用規約_全文_注記付き.docx` | 同上 | 弁護士のレビュー用。**なぜその条文があるか**が各条の直後に付きます |
| `ピタフレプライバシーポリシー.docx` | `../privacy-policy-draft.md` | 照会の別紙2 |
| `ピタフレ特定商取引法に基づく表記.docx` | `../tokushoho-draft.md` | 照会の別紙3 |
| `ピタフレ資金決済法に基づく表示.docx` | `../shikin-kessai-draft.md` | 照会の別紙4 |
| `ピタフレ役務提供に関するガイドライン.docx` | `../service-standard-guideline.md` | 規約第1条2項により**規約の一部**。アプリ内は 設定 ＞ 規約・ポリシー |
| `ピタフレ運用例_約束と違ったとき.docx` | `../../help/service-standard-examples.md` | **規約の外**（ヘルプ）。更新に規約変更の手続は要らない |

## ⚠️ 照会文のファイル名は、原本ではなく**内容の更新日**で付けています

原本の Markdown は `lawyer-questions-2026-08-04.md` のままですが（照会の「回」を
表すため。多数の文書からリンクされてもいます）、**Word のファイル名は
中身を最後に直した日**にしています。**先生がどの版をお持ちかを、
ファイル名だけで言えるようにするため**です。

内容を足したら、**古い日付の docx は消して**から新しい日付で作り直してください。
2つ並んでいると、どちらを送ったか分からなくなります。

| 版 | 追加された論点 |
|---|---|
| 2026-08-04 | 論点A〜E（作成時） |
| **2026-08-05** | **論点F**（サービス終了時の申出期間経過後の扱い／無償付与コインの返金） |

## ⚠️ `--fill-business` を付け忘れないこと

規約・プライバシー・特商法には `【…：公開前に記入】` が埋め込まれており、
アプリは表示時に `src/content/legalDocs.ts` が実値を差し込んでいます。
**素の Markdown から Word を作ると、そこだけ差し込まれません。**

2026-08-03 に出した利用規約の Word は、実際に
`【事業者名（屋号）：公開前に記入】` が4か所残ったまま、他の箇所には実値が
入っている、という状態で出来ていました。**弁護士に渡す前に気づけて幸いでした。**

いまは `--fill-business` を付けると差し込み、**差し込み漏れがあれば生成を止めます。**

「注記付き」には、どの指摘（弁護士回答の論点番号・税理士回答のQ番号）を受けて条文を書いたかが入っています。レビューを依頼するときはこちらのほうが往復が減ります。

## 再生成

```bash
npm i --no-save docx
# 照会文
node tools/md-to-docx.cjs docs/legal/lawyer-questions-2026-08-04.md docs/legal/word \
  --name 'ご照会_未査読の論点_2026-08-05' --variants keep \
  --title 'ご照会（未査読の論点）— ピタフレ' --require 論点A,論点B,論点C,論点D,論点E,論点F

# 別紙（--fill-business を必ず付ける）
node tools/md-to-docx.cjs docs/legal/terms-of-service-draft.md docs/legal/word \
  --name ピタフレ利用規約_全文 --variants both --title 'ピタフレ 利用規約' \
  --fill-business --require 第16条の6,第10条の2

node tools/md-to-docx.cjs docs/legal/privacy-policy-draft.md docs/legal/word \
  --name ピタフレプライバシーポリシー --variants keep \
  --title 'ピタフレ プライバシーポリシー' --fill-business

node tools/md-to-docx.cjs docs/legal/tokushoho-draft.md docs/legal/word \
  --name ピタフレ特定商取引法に基づく表記 --variants keep \
  --title '特定商取引法に基づく表記' --fill-business

node tools/md-to-docx.cjs docs/legal/shikin-kessai-draft.md docs/legal/word \
  --name ピタフレ資金決済法に基づく表示 --variants keep \
  --title '資金決済法に基づく表示' --fill-business

# ガイドライン（事業者情報の差込みは無いので --fill-business 不要）
node tools/md-to-docx.cjs docs/legal/service-standard-guideline.md docs/legal/word \
  --name ピタフレ役務提供に関するガイドライン --variants both \
  --title '役務提供に関するガイドライン'

node tools/md-to-docx.cjs docs/help/service-standard-examples.md docs/legal/word \
  --name ピタフレ運用例_約束と違ったとき --variants both \
  --title 'プレイの内容が約束と違ったとき（運用例）'
```

## 画面と Word で中身を揃えていること

アプリの `src/content/legalDocs.ts` も、表示のときに `〔※ … 〕` を落とします
（`stripNotes`）。**この道具と同じ扱いにしてあります。**
片方だけ注記が出ていると、どちらが本物か分からなくなるためです。

⚠️ 2026-08-04まで、**画面には注記がそのまま出ていました。**
弁護士回答の引用・同種サービスの名前・「なぜこの条文にしたか」の判断の経緯が
利用者に読める状態だったということです。公開前に気づけて幸いでした。

## 資金決済法に基づく表示だけ、注記の扱いが違います

他の3点は `〔※〕` も本文末尾の `>` 注記も**前付け**（`---` より上）にありますが、
資金決済法表示は **`>` の注記が本文の一部**で、**画面にもそのまま出ます**。
切り出しのときにここを前付けへ動かすと、アプリの表示から段落が1つ消えます。
（実際に一度やりかけて、切り出し前後の本文を突き合わせて気づきました。）

**Word 側を直さないでください。** 次の生成で消えます。条文を直すときは Markdown を直して再生成します。

生成のときに、条文のみの版に `〔※` が残っていないか、第3条の2・第10条の2・第16条の6・改定履歴が落ちていないかを検査しています。落ちていれば生成が止まります。

## 条文を変えたときに一緒に直すもの

`../terms-of-service-draft.md` の冒頭に一覧があります。この Word 版の再生成もその1つです。
