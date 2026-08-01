// ピタフレ 利用規約 Markdown → Word(.docx)
//
// 2種類つくる:
//   ・条文のみ … そのまま人に渡せる形。〔※〕の内部メモとリポジトリ保守用の注意書きを落とす
//   ・注記付き … 内部メモ入り。弁護士に「なぜこの条文があるか」を一緒に見てもらう用
//
// 使い方(docx は生成のときだけ要るので package.json には入れない):
//   npm i --no-save docx
//   node tools/terms-to-docx.cjs docs/legal/terms-of-service-draft.md docs/legal/word
//
// **Markdown が原本です。** Word 側を直しても次の生成で消えます。
// 条文を変えたら必ず再生成してください。古い Word を弁護士に送るほうが、
// 送らないより事故になります。
'use strict';
const fs = require('fs');
const path = require('path');
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell,
  WidthType, ShadingType, BorderStyle, AlignmentType, HeadingLevel,
  Header, Footer, PageNumber, TabStopType, convertMillimetersToTwip,
} = require('docx');

const SRC = process.argv[2];
const OUT_DIR = process.argv[3];

const MINCHO = { ascii: 'Yu Mincho', eastAsia: 'Yu Mincho', hAnsi: 'Yu Mincho' };
const GOTHIC = { ascii: 'Yu Gothic', eastAsia: 'Yu Gothic', hAnsi: 'Yu Gothic' };
const MONO = { ascii: 'Consolas', eastAsia: 'Yu Gothic', hAnsi: 'Consolas' };

const INK = '1A1A1A';
const NOTE_INK = '4A4A4A';
const RULE = 'B9B2A6';
const NOTE_BG = 'F2EFE9';

// ------------------------------------------------------------------
// インライン記法 → run
// ------------------------------------------------------------------
function runs(text, base = {}) {
  const out = [];
  // [text](link) はリンク先を落として文字だけ残す(配布物にリポジトリのパスを出さない)
  let t = text.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1');
  const re = /(\*\*[^*]+\*\*|`[^`]+`|\*[^*]+\*)/g;
  let last = 0, m;
  const push = (s, extra) => { if (s) out.push(new TextRun({ text: s, ...base, ...extra })); };
  while ((m = re.exec(t)) !== null) {
    push(t.slice(last, m.index));
    const tok = m[0];
    if (tok.startsWith('**')) push(tok.slice(2, -2), { bold: true });
    else if (tok.startsWith('`')) push(tok.slice(1, -1), { font: MONO, size: (base.size || 21) - 2 });
    else push(tok.slice(1, -1), { italics: true });
    last = m.index + tok.length;
  }
  push(t.slice(last));
  return out.length ? out : [new TextRun({ text: '', ...base })];
}

const body = (extra = {}) => ({ font: MINCHO, size: 21, color: INK, ...extra });

// ------------------------------------------------------------------
// ブロック要素
// ------------------------------------------------------------------
function para(text, opts = {}) {
  const { indent, spacing, align, base, ...rest } = opts;
  return new Paragraph({
    children: runs(text, base || body()),
    spacing: spacing || { before: 60, after: 60, line: 300 },
    indent, alignment: align, ...rest,
  });
}

function heading(text) {
  return new Paragraph({
    children: runs(text, { font: GOTHIC, size: 24, bold: true, color: INK }),
    spacing: { before: 320, after: 140 },
    keepNext: true,
    border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: RULE, space: 4 } },
  });
}

// 〔※…〕 の内部メモ。地の文と混ざらないよう、地色を敷いて一段落とす
function noteBlock(text) {
  return new Paragraph({
    children: runs(text, { font: GOTHIC, size: 17, color: NOTE_INK }),
    spacing: { before: 120, after: 160, line: 260 },
    indent: { left: convertMillimetersToTwip(4), right: convertMillimetersToTwip(2) },
    shading: { type: ShadingType.CLEAR, fill: NOTE_BG, color: 'auto' },
    border: {
      top: { style: BorderStyle.SINGLE, size: 2, color: NOTE_BG, space: 6 },
      bottom: { style: BorderStyle.SINGLE, size: 2, color: NOTE_BG, space: 6 },
      left: { style: BorderStyle.SINGLE, size: 12, color: RULE, space: 6 },
      right: { style: BorderStyle.SINGLE, size: 2, color: NOTE_BG, space: 6 },
    },
  });
}

// > で始まる引用。規約本文の補足なので、注記とは別の見た目にする
function quoteBlock(lines) {
  return lines.map((l, i) => new Paragraph({
    children: runs(l, body({ size: 20 })),
    spacing: { before: i === 0 ? 140 : 40, after: i === lines.length - 1 ? 140 : 40, line: 290 },
    indent: { left: convertMillimetersToTwip(5) },
    border: { left: { style: BorderStyle.SINGLE, size: 12, color: RULE, space: 6 } },
  }));
}

const PAGE_W = convertMillimetersToTwip(210 - 22 - 22); // A4 − 左右余白

function table(rows) {
  const cols = rows[0].length;
  const widths = cols === 2 ? [Math.round(PAGE_W * 0.42), PAGE_W - Math.round(PAGE_W * 0.42)]
                            : Array.from({ length: cols }, (_, i) =>
                                i === cols - 1 ? PAGE_W - Math.floor(PAGE_W / cols) * (cols - 1)
                                               : Math.floor(PAGE_W / cols));
  return new Table({
    columnWidths: widths,
    width: { size: PAGE_W, type: WidthType.DXA },
    rows: rows.map((cells, r) => new TableRow({
      tableHeader: r === 0,
      children: cells.map((c, i) => new TableCell({
        width: { size: widths[i], type: WidthType.DXA },
        shading: r === 0 ? { type: ShadingType.CLEAR, fill: NOTE_BG, color: 'auto' } : undefined,
        margins: { top: 90, bottom: 90, left: 120, right: 120 },
        children: [new Paragraph({
          children: runs(c, body({ size: 19, ...(r === 0 ? { font: GOTHIC, bold: true } : {}) })),
          spacing: { before: 0, after: 0, line: 280 },
        })],
      })),
    })),
  });
}

// ------------------------------------------------------------------
// Markdown → ブロック列
// ------------------------------------------------------------------
function parse(md, { withNotes }) {
  const lines = md.split('\n');
  const out = [];
  let i = 0;

  while (i < lines.length) {
    const raw = lines[i];
    const line = raw.trim();

    if (line === '') { i++; continue; }

    // 水平線
    if (/^-{3,}$/.test(line)) {
      out.push(new Paragraph({
        children: [new TextRun({ text: '', size: 2 })],
        spacing: { before: 200, after: 200 },
        border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: RULE, space: 2 } },
      }));
      i++; continue;
    }

    // タイトル
    if (line.startsWith('# ')) {
      out.push(new Paragraph({
        children: runs(line.slice(2), { font: GOTHIC, size: 34, bold: true, color: INK }),
        spacing: { before: 0, after: 240 },
        alignment: AlignmentType.CENTER,
      }));
      i++; continue;
    }

    if (line.startsWith('## ')) { out.push(heading(line.slice(3))); i++; continue; }

    // 引用ブロック(表を含むことがある)
    if (line.startsWith('>')) {
      const buf = [];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        buf.push(lines[i].trim().replace(/^>\s?/, ''));
        i++;
      }
      const tbl = buf.filter((l) => l.startsWith('|'));
      const txt = buf.filter((l) => !l.startsWith('|') && l !== '');
      if (txt.length) out.push(...quoteBlock(txt));
      if (tbl.length) out.push(...renderTable(tbl));
      continue;
    }

    // 表
    if (line.startsWith('|')) {
      const buf = [];
      while (i < lines.length && lines[i].trim().startsWith('|')) { buf.push(lines[i].trim()); i++; }
      out.push(...renderTable(buf));
      continue;
    }

    // 〔※ … 〕 の内部メモ(複数行にまたがる)
    if (line.startsWith('〔※')) {
      const buf = [];
      while (i < lines.length) {
        buf.push(lines[i].trim());
        if (lines[i].includes('〕')) { i++; break; }
        i++;
      }
      if (withNotes) {
        // メモ内の空行は段落の切れ目として残す
        const chunks = buf.join('\n').split(/\n\s*\n/);
        chunks.forEach((c) => out.push(noteBlock(c.replace(/\n/g, ''))));
      }
      continue;
    }

    // 通常の段落。条番号("1." "5の2." など)は文字として持っているので、
    // 自動採番は使わずぶら下げインデントだけ付ける
    const indented = /^\s{2,}/.test(raw);
    const numbered = /^(\d+(の\d+)?\.)\s/.test(line);
    const bullet = /^[-•]\s/.test(line);

    let text = line;
    let indent;
    if (bullet) {
      text = '・' + line.replace(/^[-•]\s/, '');
      indent = { left: convertMillimetersToTwip(indented ? 11 : 6), hanging: convertMillimetersToTwip(4) };
    } else if (numbered) {
      indent = indented
        ? { left: convertMillimetersToTwip(13), hanging: convertMillimetersToTwip(6) }
        : { left: convertMillimetersToTwip(7), hanging: convertMillimetersToTwip(7) };
    } else if (indented) {
      indent = { left: convertMillimetersToTwip(7) };
    }
    out.push(para(text, { indent }));
    i++;
  }
  return out;
}

function renderTable(buf) {
  const rows = buf
    .filter((l) => !/^\|[\s|:-]+\|$/.test(l))
    .map((l) => l.replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim()));
  if (!rows.length) return [];
  return [
    table(rows),
    new Paragraph({ children: [new TextRun({ text: '', size: 2 })], spacing: { after: 160 } }),
  ];
}

// ------------------------------------------------------------------
// 条文のみの版をつくる
// ------------------------------------------------------------------
function stripNotes(md) {
  let t = md;

  // リポジトリ保守用の注意書き(⚠️ の引用ブロック)は配布物には要らない
  t = t.replace(/\n> ⚠️[\s\S]*?\n(?=\n---)/, '');

  // 〔※ … 〕 を落とす。〔監視〕のような通常の亀甲括弧には触れない
  t = t.replace(/〔※[^〕]*〕/g, '');

  // メモだけの行が空になったので掃除する
  t = t.split('\n').filter((l, idx, arr) => !(l.trim() === '' && (arr[idx - 1] || '').trim() === '')).join('\n');
  t = t.replace(/[ 　]+$/gm, '');

  // 末尾の「AIが作ったたたき台」の断り書き
  t = t.replace(/\n\*本ドラフトはAI[\s\S]*?\*\n?/, '\n');

  return t;
}

// ------------------------------------------------------------------
function build(md, { withNotes, subtitle, file }) {
  const children = parse(md, { withNotes });
  const doc = new Document({
    creator: 'ピタフレ',
    title: 'ピタフレ 利用規約',
    description: subtitle,
    sections: [{
      properties: {
        page: {
          margin: {
            top: convertMillimetersToTwip(20), bottom: convertMillimetersToTwip(20),
            left: convertMillimetersToTwip(22), right: convertMillimetersToTwip(22),
          },
        },
      },
      headers: {
        default: new Header({
          children: [new Paragraph({
            children: [new TextRun({ text: `ピタフレ 利用規約　${subtitle}`, font: GOTHIC, size: 16, color: NOTE_INK })],
            alignment: AlignmentType.RIGHT,
            spacing: { after: 80 },
            border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: RULE, space: 3 } },
          })],
        }),
      },
      footers: {
        default: new Footer({
          children: [new Paragraph({
            alignment: AlignmentType.CENTER,
            children: [new TextRun({ children: ['— ', PageNumber.CURRENT, ' / ', PageNumber.TOTAL_PAGES, ' —'],
                                    font: GOTHIC, size: 16, color: NOTE_INK })],
          })],
        }),
      },
      children,
    }],
  });
  return Packer.toBuffer(doc).then((buf) => {
    const p = path.join(OUT_DIR, file);
    fs.writeFileSync(p, buf);
    console.log(`${file}  ${(buf.length / 1024).toFixed(0)} KB  / ${children.length} blocks`);
  });
}

const md = fs.readFileSync(SRC, 'utf8');
const clean = stripNotes(md);

// 取りこぼしの検査。**メモが本文に残る**のが一番まずいので落ちるようにする
if (clean.includes('〔※')) throw new Error('条文のみの版に〔※が残っている');
if (!clean.includes('〔監視〕')) throw new Error('第4条の〔監視〕まで消してしまっている');
for (const k of ['第16条の6', '第10条の2', '第3条の2', '第11条', '改定履歴']) {
  if (!clean.includes(k)) throw new Error(`条文のみの版から ${k} が消えている`);
}

Promise.all([
  build(clean, { withNotes: false, subtitle: '条文', file: 'ピタフレ利用規約_全文.docx' }),
  build(md, { withNotes: true, subtitle: '注記付き（内部・弁護士確認用）', file: 'ピタフレ利用規約_全文_注記付き.docx' }),
]).catch((e) => { console.error(e); process.exit(1); });
