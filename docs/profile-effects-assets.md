# プロフィール枠エフェクト — 素材の作り方と指示書

作成日: 2026-08-04

生成ツール（画像AI・After Effects 等）に投げるための仕様と、そのまま貼れるプロンプト。
第1弾は**春夏秋冬の4種**、第2弾は**天使と悪魔の2種**。

---

## 1. ★ 方式の決定 — AIに「完成したループアニメ」を作らせない

いちばん重要なところなので最初に書く。**完成形のアニメーションをAIに作らせようとすると失敗する。**

理由は3つが同時に要求されるため:

1. **透過（アルファチャンネル）** … 出せる生成ツールが限られる
2. **ループの継ぎ目** … 最終フレームと最初のフレームが一致しないと、必ずカクつく
3. **円形の抜き** … 中央にアバターが入るので、真ん中を空けた構図を制御しないといけない

### 採る方式: **パーツ方式**

> **AIには「花びら1枚」「羽根1枚」「雪の結晶1個」を透過PNGで作らせる。**
> **動き（回転・落下・明滅）はコード側で付ける。**

| | パーツ方式（採用） | 完成品アニメをAIで作る |
|---|---|---|
| ループの継ぎ目 | **必ず合う**（コードが動かすので） | 合わない。手直しが要る |
| ファイルサイズ | **1テーマ 30〜60 KB** | APNG 1本で 200 KB〜 |
| 色替え（春→夏） | パーツを差し替えるだけ | 全部作り直し |
| 一覧用の軽量版 | 粒の数を減らすだけ | 別に作る |
| 作り直しのコスト | パーツ1個だけ直せる | 全部やり直し |

### 例外: Lottie を使う場面

**形そのものが変わる動き**だけは、パーツ方式では作れない。

- 天使の羽が**羽ばたく**（形が変形する）
- 悪魔の炎が**揺らめく**（輪郭が変わる）

ここだけ Lottie（After Effects → Bodymovin 書き出し、または LottieFiles）にする。
ライブラリは `lottie-web` の軽量版（約50 KB）で、**必要な画面でだけ読み込む**。

**第1弾（春夏秋冬）は全部パーツ方式でいける。** Lottie は第2弾から検討でよい。

---

## 2. 納品物の仕様

### パーツ画像

| 項目 | 値 |
|---|---|
| 形式 | **PNG（透過）** で納品 → こちらで **WebP** に変換 |
| サイズ | **512 × 512 px**（表示は 8〜24 px。縮小前提で大きく作る） |
| 背景 | **完全な透過**。白背景・市松模様の書き出しは不可 |
| 影 | **付けない**（コード側で付ける。焼き込むと背景色に合わなくなる） |
| 余白 | 上下左右に**8%の余白**。ぴったりだと縮小時にふちが切れる |
| 1テーマあたり | パーツ **3〜6個** |
| 容量 | 1テーマ合計 **60 KB 以内**（WebP変換後） |

### 色

ピタフレの実トークン（`src/index.css`）に合わせる。

| 名前 | 値 | 用途 |
|---|---|---|
| 濃紫 | `#453D5C` | **輪郭線**。全パーツ共通 |
| ラベンダー | `#A78BDF` | 主アクセント |
| ライム | `#E4F0A0` | 副アクセント |
| パステル水 | `#B3E5F2` | 冬・水 |
| パステル橙 | `#FBD79E` | 秋・光 |
| パステル桃 | `#F5B8CE` | 春 |

> **輪郭線は必ず `#453D5C` の太線**にする。アプリ全体がネオブルータリズム
> （1.5px ボーダー＋ハードシャドウ）なので、線が細いと浮く。

### 命名とディレクトリ

```
public/effects/
  spring/  petal-a.webp  petal-b.webp  petal-c.webp  sparkle.webp
  summer/  bubble-a.webp bubble-b.webp ray.webp      sparkle.webp
  autumn/  leaf-maple.webp leaf-ginkgo.webp leaf-c.webp sparkle.webp
  winter/  flake-a.webp  flake-b.webp  flake-c.webp   sparkle.webp
  angel/   feather-a.webp feather-b.webp halo.webp    sparkle.webp
  devil/   horn.webp     batwing.webp   ember.webp    smoke.webp
```

**`sparkle.webp` は全テーマ共通の形**で、色だけ変える。統一感が出るうえ、
1個作れば使い回せる。

---

## 3. ★ 生成ツールへのプロンプト

### 3-1. 全テーマ共通のひな形

英語で書く（日本語より安定する）。`[ ]` を差し替えて使う。

```
A single [ITEM], flat vector sticker illustration,
bold dark purple outline (#453D5C, thick uniform stroke),
pastel [COLOR] fill, soft cel shading, front view, no perspective,
centered, isolated on a fully transparent background,
no drop shadow, no background, no text, no watermark, no frame,
clean edges, 512x512
```

**ネガティブプロンプト**（対応するツールのみ）:

```
background, white background, checkerboard, gradient background,
shadow, text, letters, watermark, signature, realistic, photo,
3d render, multiple objects, cropped, blurry
```

> **⚠️ 「transparent background」だけでは透けないツールが多い。**
> 書き出し設定で**アルファチャンネル付きPNG**を選ぶこと。透過に対応していない
> ツールで作った場合は、`remove.bg` 等で背景を抜いてから納品する。

### 3-2. 絵柄を6テーマで揃えるコツ

バラバラの絵柄が混ざるのが**いちばんよくある失敗**。対策は3つ。

1. **最初に1個だけ完璧に作る**（例: 桜の花びら）。それを**スタイルの基準**にする
2. 以降はその画像を**参照として渡す**
   - Midjourney … `--sref <画像URL>` を全プロンプトに付ける
   - ChatGPT / Gemini … 基準画像を添付して「この絵柄で」と指示
   - Stable Diffusion … 同じ **seed** と LoRA/スタイル指定を固定
3. **1セッションで6テーマ全部作る**。日をまたぐとモデル側の揺れが乗る

### 3-3. テーマ別のパーツと `[ITEM]` `[COLOR]`

#### 🌸 春（桜）

| ファイル | `[ITEM]` | `[COLOR]` |
|---|---|---|
| `petal-a` | `a single cherry blossom petal, gently curved` | `pale pink (#F5B8CE)` |
| `petal-b` | `a single cherry blossom petal, seen from the side, slightly twisted` | `pale pink (#F5B8CE)` |
| `petal-c` | `a single small cherry blossom flower with five petals` | `pale pink (#F5B8CE) with a lime green (#E4F0A0) center` |
| `sparkle` | `a small four-pointed sparkle star` | `pale pink (#F5B8CE)` |

**動き**: 上からゆっくり舞い落ちて、回転しながら消える。

#### 🌊 夏（海と光）

| ファイル | `[ITEM]` | `[COLOR]` |
|---|---|---|
| `bubble-a` | `a single round soap bubble with a highlight` | `pale aqua (#B3E5F2), translucent` |
| `bubble-b` | `a single small round bubble` | `pale aqua (#B3E5F2), translucent` |
| `ray` | `a single tapered ray of light, like a sunbeam underwater` | `pale lime (#E4F0A0), translucent` |
| `sparkle` | `a small four-pointed sparkle star` | `pale aqua (#B3E5F2)` |

**動き**: 下から上へゆっくり浮上。光は上から差してゆらぐ。

#### 🍁 秋（紅葉）

| ファイル | `[ITEM]` | `[COLOR]` |
|---|---|---|
| `leaf-maple` | `a single Japanese maple leaf (momiji), seven pointed lobes` | `warm orange (#FBD79E) to red gradient` |
| `leaf-ginkgo` | `a single ginkgo leaf, fan shaped` | `golden yellow (#FBD79E)` |
| `leaf-c` | `a single small oval autumn leaf` | `deep amber (#FBD79E)` |
| `sparkle` | `a small four-pointed sparkle star` | `golden yellow (#FBD79E)` |

**動き**: 舞い落ちながら**左右に揺れる**（春より振れ幅を大きく）。

#### ❄️ 冬（雪）

| ファイル | `[ITEM]` | `[COLOR]` |
|---|---|---|
| `flake-a` | `a single six-fold symmetric snowflake, delicate crystal` | `pale ice blue (#B3E5F2)` |
| `flake-b` | `a single simple six-pointed snowflake` | `pale ice blue (#B3E5F2)` |
| `flake-c` | `a single tiny snowflake crystal` | `white with pale blue (#B3E5F2) edges` |
| `sparkle` | `a small four-pointed sparkle star` | `pale ice blue (#B3E5F2)` |

**動き**: ゆっくり降る。結晶自体もゆっくり自転する。

#### 😇 天使

| ファイル | `[ITEM]` | `[COLOR]` |
|---|---|---|
| `feather-a` | `a single angel wing, feathered, seen from the side, pointing up-left` | `white with pale lavender (#A78BDF) shading` |
| `feather-b` | `a single small floating feather` | `white with pale lavender (#A78BDF) shading` |
| `halo` | `a single thin elliptical halo ring, tilted, hollow center` | `pale gold (#FBD79E)` |
| `sparkle` | `a small four-pointed sparkle star` | `pale gold (#FBD79E)` |

**動き**: 光輪はアバターの上で**ゆっくり回転**（CSSの疑似3D）。羽根はふわりと落ちる。

> `feather-a` は**左向きを1枚だけ**作る。右翼は CSS の `scaleX(-1)` で反転して使う。
> 2枚作ると微妙に形が違って左右非対称になる。

#### 😈 悪魔

| ファイル | `[ITEM]` | `[COLOR]` |
|---|---|---|
| `horn` | `a single curved demon horn, pointing up, ridged` | `deep purple (#453D5C) with red highlight` |
| `batwing` | `a single bat wing, membrane with three finger bones, pointing up-left` | `deep purple (#453D5C)` |
| `ember` | `a single small flame ember, teardrop shaped` | `orange-red gradient` |
| `smoke` | `a single soft wisp of smoke, curling` | `dark purple (#453D5C), translucent` |

**動き**: 火の粉は下から上へ舞い上がって消える。角は静止、翼はわずかに揺れる。

> **⚠️ 怖くしすぎない。** ピタフレはパステルのやさしい世界観なので、
> **「いたずらっ子」くらいの可愛い悪魔**にする。プロンプトに `cute, chibi, friendly`
> を足すとよい。ホラー寄りになると、アプリ全体から浮く。

---

## 4. 納品時のチェックリスト

- [ ] **透過が本当に抜けているか**（濃い色の背景に置いて確認する。白背景だと気づけない）
- [ ] 輪郭線が `#453D5C` の太線になっているか
- [ ] 影が焼き込まれていないか
- [ ] 上下左右に余白があるか（ふちが切れていない）
- [ ] **6テーマで絵柄が揃っているか**（並べて見る）
- [ ] 512×512 か
- [ ] **16px に縮小しても形が分かるか** ← これがいちばん見落とされる
- [ ] 1テーマ合計 60 KB 以内（WebP変換後）

### WebP への変換

```bash
# 品質85・透過を保持。だいたい PNG の 1/3 になる
cwebp -q 85 -alpha_q 100 petal-a.png -o petal-a.webp
```

---

## 5. 実装側で決まっていること（素材づくりの前提）

- 動きは**コード側**で付ける。素材は静止画
- **一覧（さがす画面）では粒の数を減らす**。同じ素材のまま軽量版になる
- `prefers-reduced-motion` と設定トグルで**止められる**
- 装飾は**順位・表示の大きさ・表示回数に影響しない**（見た目だけ）
- **購入コインでのみ買える**。報酬コインでは買えない（前払式支払手段の議論を立てないため）

---

## 6. 段階

| 弾 | テーマ | 備考 |
|---|---|---|
| 第1弾 | 🌸春 / 🌊夏 / 🍁秋 / ❄️冬 | 全部パーツ方式。季節で入れ替えると継続の理由になる |
| 第2弾 | 😇天使 / 😈悪魔 | 羽ばたき・炎の揺らぎだけ Lottie を検討 |

季節ものは**その季節だけ販売**にすると、Twitchのサブスクバッジと同じ
「持っていることに意味が出る」構造になる。ただし**買った人が翌年も使える**ことは
先に明記する（買ったものが消えるのは、後から揉める）。
