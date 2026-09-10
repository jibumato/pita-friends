#!/usr/bin/env node
/**
 * 淡い固定色の上に、テーマで反転する文字色を載せていないか検査する。
 *
 * ■ なぜ要るか
 *   `lime` `avatarOrange` `avatarAqua` `avatarPink` は**ライトとダークで同じ値**の
 *   淡い色。一方 `ink` はライト #453d5c / ダーク #ffffff に**反転する。**
 *   つまり `background: C.lime; color: C.ink` は、ダークで
 *   「淡い黄緑の上に白文字」になる。コントラスト比は 1.22:1 で、
 *   WCAG AA の 4.5:1 どころか、事実上読めない。
 *
 *   2026-09 のレビュー時点で、この形が **141 箇所**あった。
 *   アバターの頭文字・「本人確認済み」バッジ・「チャージ」ボタン・
 *   選択中のチップ——ダークテーマの主要な要素がほぼ全部これだった。
 *   **誰も検出していなかったから、ここまで広がった。**
 *
 *   淡色の上には `C.onPale`（両テーマ #453D5C）を使うこと。
 *
 * ■ 使い方
 *     node scripts/check-theme-contrast.mjs
 *   `npm run lint` から呼ばれる。見つかったら 1 を返して落ちる。
 *
 * ■ 拾えないもの
 *   背景を props で受け取る形（`background: color`）は、変数名からは
 *   淡色かどうか判定できない。**アバターの色を受けるコンポーネントを
 *   足すときは、頭文字の色を `onPale` にすること**（`Avatar.tsx` を参照）。
 */
import fs from 'fs'
import path from 'path'

const PALE = ['lime', 'avatarOrange', 'avatarAqua', 'avatarPink']
const paleRe = new RegExp(`C\\.(?:${PALE.join('|')})\\b`)

const files = []
;(function walk(d) {
  for (const f of fs.readdirSync(d)) {
    const p = path.join(d, f)
    fs.statSync(p).isDirectory() ? walk(p) : /\.tsx?$/.test(f) && files.push(p)
  }
})('src')

/** style={{ ... }} の中身を、括弧の対応を見て取り出す */
function styleObjects(t) {
  const out = []
  const re = /style=\{\{/g
  let m
  while ((m = re.exec(t))) {
    let i = m.index + m[0].length
    let depth = 2
    while (i < t.length && depth > 0) {
      if (t[i] === '{') depth++
      else if (t[i] === '}') depth--
      i++
    }
    out.push(t.slice(m.index + m[0].length, i - 2))
  }
  return out
}

/** オブジェクト直下の key の値を取る（ネストの中は見ない） */
function topProp(body, key) {
  const re = new RegExp(`(^|[,{\\s])${key}:\\s*`, 'g')
  let m
  while ((m = re.exec(body))) {
    const start = m.index + m[0].length
    let d = 0
    for (let k = 0; k < start; k++) {
      const c = body[k]
      if ('{(['.includes(c)) d++
      else if ('})]'.includes(c)) d--
    }
    if (d !== 0) continue
    let depth = 0
    let i = start
    while (i < body.length) {
      const c = body[i]
      if ('{(['.includes(c)) depth++
      else if ('})]'.includes(c)) {
        if (depth === 0) break
        depth--
      } else if (c === ',' && depth === 0) break
      else if (c === '`') { i++; while (i < body.length && body[i] !== '`') i++ }
      else if (c === "'") { i++; while (i < body.length && body[i] !== "'") i++ }
      i++
    }
    return body.slice(start, i).trim()
  }
  return null
}

/** トップレベルの三項を [cond, then, else] に割る */
function splitTernary(e) {
  let depth = 0
  for (let i = 0; i < e.length; i++) {
    const c = e[i]
    if ('{(['.includes(c)) depth++
    else if ('})]'.includes(c)) depth--
    else if (c === '?' && depth === 0 && e[i + 1] !== '.' && e[i + 1] !== '?') {
      let d = 0
      for (let j = i + 1; j < e.length; j++) {
        const k = e[j]
        if ('{(['.includes(k)) d++
        else if ('})]'.includes(k)) d--
        else if (k === '?' && d === 0) d++
        else if (k === ':' && d === 0) return [e.slice(0, i), e.slice(i + 1, j), e.slice(j + 1)]
      }
    }
  }
  return null
}

/** 式を「枝のパス → 値」に展開する */
function branches(e, prefix = '') {
  const s = splitTernary(e)
  if (!s) return [[prefix, e.trim()]]
  return [...branches(s[1], prefix + 'T'), ...branches(s[2], prefix + 'F')]
}

const problems = []
for (const f of files) {
  const t = fs.readFileSync(f, 'utf8')

  for (const body of styleObjects(t)) {
    const bg = topProp(body, 'background')
    if (!bg || !paleRe.test(bg)) continue
    const col = topProp(body, 'color')
    if (!col || !/C\.ink\b/.test(col)) continue

    const B = branches(bg)
    const K = branches(col)
    if (B.length === K.length && B.every((b, i) => b[0] === K[i][0])) {
      // 枝が対応するなら、淡色の枝が ink を使っているかだけ見る
      B.forEach((b, i) => {
        if (paleRe.test(b[1]) && /C\.ink\b/.test(K[i][1])) {
          problems.push(`${f}\n      background: ${b[1].trim()}  ←→  color: ${K[i][1].trim()}`)
        }
      })
    } else if (B.some((b) => paleRe.test(b[1]))) {
      // 枝の形が違うので機械的に判定できない。人が見る
      problems.push(`${f}\n      background: ${bg}  ←→  color: ${col}   （枝の形が違うので要確認）`)
    }
  }

  // { bg: C.lime, fg: C.ink } のような設定マップ
  const mapRe = /\{[^{}]*\b(?:bg|tileColor)\s*:\s*C\.(?:lime|avatarOrange|avatarAqua|avatarPink)\b[^{}]*\}/g
  let m
  while ((m = mapRe.exec(t))) {
    if (/\b(?:fg|color)\s*:\s*C\.ink\b/.test(m[0])) {
      problems.push(`${f}\n      ${m[0].trim().slice(0, 120)}`)
    }
  }
}

if (problems.length) {
  console.error(`\n❌ 淡い固定色の上に C.ink を載せている箇所が ${problems.length} 件あります。`)
  console.error('   ダークテーマでは白文字になり、読めません（コントラスト比 1.2〜1.7:1）。')
  console.error('   C.onPale を使ってください（src/theme/tokens.ts のコメント参照）。\n')
  problems.forEach((p) => console.error('   ' + p + '\n'))
  process.exit(1)
}
console.log('✓ 淡色の上の文字色: 問題なし')
