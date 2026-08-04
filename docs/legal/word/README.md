# 法務書類の Word 版（生成物）

このフォルダの `.docx` は **生成物** です。原本は `docs/legal/` の Markdown です。

| ファイル | 原本 | 渡す相手 |
|---|---|---|
| `ご照会_未査読の論点_2026-08-04.docx` | `../lawyer-questions-2026-08-04.md` | **弁護士に送る照会文。まだ誰の査読も受けていない論点だけを抜いたもの** |
| `ピタフレ利用規約_全文.docx` | `../terms-of-service-draft.md` | 弁護士・税理士・第三者。そのまま渡せます |
| `ピタフレ利用規約_全文_注記付き.docx` | 同上 | 弁護士のレビュー用。**なぜその条文があるか**が各条の直後に付きます |
| `ピタフレプライバシーポリシー.docx` | `../privacy-policy-draft.md` | 照会の別紙2 |
| `ピタフレ特定商取引法に基づく表記.docx` | `../tokushoho-draft.md` | 照会の別紙3 |

**資金決済法に基づく表示（別紙4）の Word 版はありません。**
原本が `src/content/legalDocs.ts` の中にあり、Markdown ファイルになっていないためです。
送付が必要になったら、先に Markdown へ切り出してください。

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
  --name 'ご照会_未査読の論点_2026-08-04' --variants keep \
  --title 'ご照会（未査読の論点）— ピタフレ' --require 論点A,論点B,論点C,論点D,論点E

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
```

**Word 側を直さないでください。** 次の生成で消えます。条文を直すときは Markdown を直して再生成します。

生成のときに、条文のみの版に `〔※` が残っていないか、第3条の2・第10条の2・第16条の6・改定履歴が落ちていないかを検査しています。落ちていれば生成が止まります。

## 条文を変えたときに一緒に直すもの

`../terms-of-service-draft.md` の冒頭に一覧があります。この Word 版の再生成もその1つです。
