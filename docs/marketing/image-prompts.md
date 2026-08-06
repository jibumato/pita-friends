# SNS画像の作り方 — 画像生成AIへの指示書

公開前の告知に添える画像を、GPT Image 等の画像生成AIで作るための指示書です。
文面は [`sns-launch-kit.md`](sns-launch-kit.md) が出典。**この文書は画像だけを扱います。**

> ⚠️ **画像も「非・出会い系」の一線を守る対象です。** 文面だけ気をつけても、
> 画像が「女の子と会える」風だと、そちらが読まれます。§4 の禁止事項は
> 文面の NG表現と同じ重みで守ってください。

---

## 0. 先に結論 — うまくいく指示の形

画像生成AIへの指示は、**次の6つを毎回この順で書く**と安定します。

```
1. 何の画像か（用途・サイズ）
2. 画面に入れる文字（日本語は避ける。理由は §3）
3. 構図（誰が/何が/どこに）
4. 配色（16進数で指定する）
5. 画風（参照する様式を具体名で）
6. 入れないもの（禁止事項）
```

**6が一番効きます。** 生成AIは「入れるもの」より「入れないもの」の指示のほうが
効きにくいので、**短く・具体的に・最後に**書きます。

---

## 1. まず用意するもの

| 用途 | サイズ | 備考 |
|---|---|---|
| **Xのヘッダー** | 1500 × 500 | 中央に寄せる（端はデバイスで切れる） |
| **Xの投稿画像**（横） | 1600 × 900（16:9） | タイムラインで最も大きく出る |
| **Xの投稿画像**（縦） | 1080 × 1350（4:5） | 縦のほうが占有面積が広い。**告知はこちら推奨** |
| **Instagram フィード** | 1080 × 1350（4:5） | 上と共用できる |
| **Instagram ストーリー** | 1080 × 1920（9:16） | 上下200pxはUIで隠れる前提で余白を取る |
| **OGP**（リンクカード） | 1200 × 630 | サイトの `og:image` |

> **1枚で兼用しないこと。** 16:9 の画像を縦枠に入れると上下が切れて文字が消えます。
> 同じ構図で**比率だけ変えて作り直す**のが早いです（§5 のテンプレートを使う）。

---

## 2. ブランドの見た目（毎回そのまま貼る）

```
Color palette (use these exact values):
- background: #F7F6FB (very light lavender-tinted off-white)
- primary text and outlines: #453D5C (deep desaturated purple, almost charcoal)
- accent 1: #A78BDF (soft lavender)
- accent 2: #E4F0A0 (pale lime)
- accent 3: #F5B8CE (soft pink, use sparingly)
Style: flat vector illustration, thick uniform outlines (#453D5C, 3-4px),
rounded corners, soft drop shadow offset 2-3px down-right in #453D5C at low
opacity, no gradients, no photorealism, generous white space.
Overall mood: friendly, calm, safe. Not neon, not aggressive, not "gamer RGB".
```

**「no gradients」と「not gamer RGB」は毎回入れてください。** 何も言わないと、
ゲーム関連の指示に対して**紫と水色のネオングラデーション**が出てきます。
ピタフレの見た目とは違ううえ、**深夜・射幸性の印象**が付きます。

---

## 3. ⚠️ 日本語の文字は画像生成AIに描かせない

**これが最大の落とし穴です。** GPT Image を含め、現行の画像生成AIは
**日本語の文字を正しく描けません**。それらしい形の別の字になります。

| やり方 | 結果 |
|---|---|
| ❌ プロンプトに「"ピタッと合うゲーム仲間" と入れて」 | 崩れた漢字が出る。**必ず** |
| ✅ **文字を入れない絵だけ**を作り、後から Canva 等で載せる | 確実 |
| ◑ 英字だけ（`PITAFURE`）なら比較的正しく出る | それでも要確認 |

したがって、**指示には必ずこれを入れます**。

```
Do not render any text, letters, numbers, or logos in the image.
Leave clean empty space in the [upper third / left half] for text to be
added later.
```

**「文字を入れるな」だけでなく「どこを空けるか」まで言う**のがコツです。
言わないと画面いっぱいに絵が来て、あとから文字を載せる場所がなくなります。

---

## 4. 🚫 画像で絶対に避けるもの

文面の NG表現（`sns-launch-kit.md` §6）と**同じ重み**で守ってください。

| ❌ 避ける | なぜ |
|---|---|
| **1人の女性キャラを大きく主役に置く** | 「女の子と会える」サービスに見える。**最も危険** |
| 露出の多い服装・胸や脚の強調・上目遣い・頬の赤み | 同上。性的訴求と受け取られる |
| **男女2人が向き合う／寄り添う構図** | 恋愛・デートの文脈になる |
| 現実の部屋で2人が並んで座っている絵 | 対面での同伴を想起させる（規約で禁止している態様） |
| 札束・お金が舞う・「稼げる」を思わせる演出 | 射幸性の煽り。景品表示法の観点でも避ける |
| 実在ゲームのキャラクター・ロゴ・UIの引用 | 著作権・商標 |
| 深夜のベッド・薄暗い個室 | 「深夜に遊ぶ」は訴求点だが、**寝室は使わない** |

**推奨する構図はこちらです。**

- **画面越しに2〜4人がつながっている**（並んで座っているのではなく、
  それぞれ別の場所からつながっている、と分かる絵）
- **キャラクターは出さず、UIとアイコンだけ**で構成する
- 人を出す場合は**性別が読み取れない・複数人・小さめ**にする
- **手元とコントローラー**、**ヘッドセット**、**吹き出し**、**盾**（安心）などの記号

> **迷ったら人を出さない。** ピタフレの訴求の中心は「安心して一緒に遊べる仕組み」で、
> 人物の魅力ではありません。**UI とアイコンだけのほうが、訴求とも合致します。**

---

## 5. そのまま使えるプロンプト

英語で書きます（日本語より指示が通ります）。**`[ ]` を差し替えて**使ってください。

### ① ティザー用（何のサービスか伏せる）

```
A flat vector illustration for a social media announcement, 4:5 portrait,
1080x1350.

Composition: two game controllers seen from above, floating apart on a plain
background, connected by a soft dotted line that forms a gentle arc between
them. Small sparkle marks along the line. The controllers are simple,
generic, rounded — not any real product.

Color palette (use these exact values):
- background: #F7F6FB
- outlines and dark shapes: #453D5C
- accent 1: #A78BDF
- accent 2: #E4F0A0
Style: flat vector, thick uniform 3px outlines in #453D5C, rounded corners,
soft drop shadow offset 3px down-right at low opacity, no gradients,
no photorealism, generous white space, friendly and calm.

Do not render any text, letters, numbers, or logos.
Leave the upper third of the image as clean empty background for text to be
added later.
Not neon, not "gamer RGB", no dark background, no human faces.
```

### ② サービス紹介用（つながりを見せる）

```
A flat vector illustration for a social media post, 4:5 portrait, 1080x1350.

Composition: four small smartphone screens arranged in a loose circle, each
tilted at a slightly different angle, connected to each other by soft curved
dotted lines passing through the centre. Inside each screen is a simple
abstract avatar shape — a rounded square with a dot and a curve, no facial
features, no gender cues. Small speech bubbles and a shield icon float in the
gaps between the screens.

[ここに §2 の Color palette と Style をそのまま貼る]

Do not render any text, letters, numbers, or logos.
Leave clean empty space at the top for a headline to be added later.
No human faces, no realistic people, no romantic pairing, no neon.
```

### ③ 安全設計の訴求用

```
A flat vector illustration for a social media post, 4:5 portrait, 1080x1350.

Composition: a large rounded shield in the centre, drawn with a thick outline,
filled with pale lime. Around it, four small icons float evenly spaced: a
speech bubble with a check mark, a bell, a lock, and a hand raised in a stop
gesture. The shield casts a soft offset shadow.

[§2 の Color palette と Style]

Do not render any text, letters, numbers, or logos.
Keep the lower quarter of the image as clean empty background.
No human figures, no weapons, no aggressive imagery, no neon.
```

### ④ ピタメイト募集用（⚠️ 人を出さない構図で）

```
A flat vector illustration for a social media post, 4:5 portrait, 1080x1350.

Composition: a pair of hands holding a game controller, seen from the player's
own point of view, at the bottom of the frame. Above the hands, a small clock
icon and a coin icon float, connected by a soft arrow curving from the clock
to the coin. The hands are simple flat shapes with no skin texture and no
visible skin tone detail — outline and flat fill only.

[§2 の Color palette と Style]

Do not render any text, letters, numbers, or logos.
Leave the upper half as clean empty background.
No faces, no full human figures, no money stacks, no cash, no luxury imagery.
```

> ④で**時計 → コイン**の矢印にしているのは、「稼げる」ではなく
> **「時間が報酬になる」**という事実に沿った表現だからです。
> 札束を出すと `sns-launch-kit.md` §6 の「稼げる（過度な煽り）」に触れます。

### ⑤ Xヘッダー用（1500 × 500）

```
A flat vector banner illustration, 3:1 wide, 1500x500.

Composition: a horizontal band. On the right third, three small smartphone
screens overlap slightly, tilted. Soft dotted lines flow from them toward the
left, fading out. Scattered small sparkles and one shield icon along the
lines. The left two thirds is almost empty background.

[§2 の Color palette と Style]

Do not render any text, letters, numbers, or logos.
The left two thirds must stay clean and empty for a headline and logo.
Keep all important elements away from the outer 60px on every edge, because
the edges may be cropped.
No human faces, no neon, no dark background.
```

---

## 6. 出てきた画像の確認

**生成できたら、載せる前に必ずこの順で見てください。**

- [ ] **文字が写り込んでいないか**（崩れた漢字・英字が紛れることがあります）
- [ ] **人物が出ていないか。** 出ている場合、性別が読み取れないか
- [ ] **2人が寄り添う構図になっていないか**
- [ ] 色が指定どおりか（勝手にネオン化していないか）
- [ ] **実在のゲームに似たUI・キャラクターが混ざっていないか**
- [ ] 4:5 の場合、**上下が切れても意味が通るか**（タイムラインでは一部しか見えません）
- [ ] 文字を載せる余白が、指示どおり空いているか

## 7. 文字は後から載せる

**Canva（無料）で足ります。**

1. §1 のサイズで新規作成
2. 生成した画像を背景に敷く
3. 文字を載せる。フォントは**太めのゴシック**（M PLUS Rounded 1c、Zen Maru Gothic
   など丸ゴシックがブランドと合います）
4. 文字色は `#453D5C`、強調に `#A78BDF`

> **文字は少なく。** タイムラインでは1秒しか見られません。
> **1枚につき、大きな文字は1行だけ**にしてください。
> 詳しい説明はツイート本文が受け持ちます。

## 8. 同じ絵柄で揃える

複数枚を作ると、**1枚ずつ絵柄が変わって並びがちぐはぐ**になります。

- **1枚目に気に入ったものができたら、その画像を添付して**
  「この画像と同じスタイル・同じ配色で、構図だけ〇〇に変えて」と指示する
- それでもずれるときは、§2 の Color palette と Style の段落を
  **一字一句同じまま**貼り直す（言い換えると変わります）

---

## 9. ロゴは生成しない

`docs/marketing/assets/` に既にあります。

| ファイル | 用途 |
|---|---|
| `logo-transparent.png` | 背景が明るいとき |
| `logo-white-border.png` | 背景が濃いとき・写真に重ねるとき |
| `hero-original.png` | ヘッダーの素材 |

**生成AIにロゴを作らせないこと。** 毎回違うものが出てきて、ブランドが定まりません。
