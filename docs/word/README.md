# Word 版（生成物）

このフォルダの `.docx` は **生成物** です。原本は `docs/` の Markdown です。

| ファイル | 原本 |
|---|---|
| `事業計画書_TypeAndCo_2026-08.docx` | [`../business-plan-2026-08.md`](../business-plan-2026-08.md) |

利用規約の Word 版は [`../legal/word/`](../legal/word/) にあります。

## 再生成

```bash
npm i --no-save docx
node tools/md-to-docx.cjs docs/business-plan-2026-08.md docs/word \
  --name '事業計画書_TypeAndCo_2026-08' --variants keep --title '事業計画書（Type&Co）'
```

`--variants keep` は `〔※〕` の注記も入れる指定です。事業計画書では**注記そのものが
「なぜそう決めたか」の記録**（税理士のどの回答を受けて数字を直したか等）なので、
落とさずに出します。逆に利用規約は `--variants both` で、注記を落とした版と
入れた版の2本を出します。

**Word 側を直さないでください。** 次の生成で消えます。Markdown を直して再生成します。

## 版を消さないこと

事業計画書は**版を積み重ねること自体が証拠**です（税理士 Q18-c）。
`business-plan-2026-08.md` の「版の履歴」から行を消さないでください。
2027年版を作るときは、このファイルを上書きするのではなく、
**新しい月版の Markdown を別ファイルで起こします。**
