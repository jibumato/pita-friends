// リポジトリの Markdown → 人に渡せる Word(.docx)
//
// `〔※…〕` を**内部メモ**として扱い、落とすか残すかを選べる。
//
//   --variants both  … 2本つくる(メモ無し / メモ入り)。利用規約はこれ
//   --variants strip … メモを落とした1本
//   --variants keep  … メモも入れた1本(既定)。事業計画書はこれ——
//                       メモ自体が「なぜそう決めたか」の記録で、外にも出せる内容
//
// 使い方(docx は生成のときだけ要るので package.json には入れない):
//   npm i --no-save docx
//   node tools/md-to-docx.cjs docs/legal/terms-of-service-draft.md docs/legal/word \
//     --name ピタフレ利用規約_全文 --variants both --title 'ピタフレ 利用規約' \
//     --fill-business --require 第16条の6,第10条の2,改定履歴
//
// `--fill-business` は【…：公開前に記入】に事業者情報の実値を差し込む。
// **規約・プライバシー・特商法・資金決済法の4点では必ず付けること。**
// 付け忘れると、他の箇所には実値が入っているのに一部だけ
// 「公開前に記入」のまま、という書類が出来る（実際に一度やりました）。
//
// `--require` は、メモを落とした版から**消えてはいけない見出し**の検査。
// 落ちていれば生成を止める。
//
// **Markdown が原本です。** Word 側を直しても次の生成で消えます。
// 内容を変えたら必ず再生成してください。
// 古い Word を人に送るほうが、送らないより事故になります。
'use strict';
const fs = require('fs');
const path = require('path');
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell,
  WidthType, ShadingType, BorderStyle, AlignmentType, HeadingLevel,
  Header, Footer, PageNumber, TabStopType, convertMillimetersToTwip,
} = require('docx');

const ARGV = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = ARGV.indexOf(`--${name}`);
  return i >= 0 && ARGV[i + 1] ? ARGV[i + 1] : fallback;
};
const positional = ARGV.filter((a, i) => !a.startsWith('--') && !(ARGV[i - 1] || '').startsWith('--'));

const SRC = positional[0];
const OUT_DIR = positional[1];
const BASE_NAME = flag('name', path.basename(SRC || '', '.md'));
const VARIANTS = flag('variants', 'keep');
/** 【…：公開前に記入】に businessInfo.ts の実値を差し込む(下の fillBusiness) */
const FILL_BUSINESS = ARGV.includes('--fill-business');
const DOC_TITLE = flag('title', BASE_NAME);
const REQUIRED = flag('require', '').split(',').map((s) => s.trim()).filter(Boolean);

if (!SRC || !OUT_DIR) {
  console.error('使い方: node tools/md-to-docx.cjs <src.md> <outdir> [--name N] [--variants both|strip|keep] [--title T] [--require A,B]');
  process.exit(2);
}

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

// level 2 = ## (章)、level 3 = ### (節)。節は罫線を引かず、字を一段小さくする
function heading(text, level = 2) {
  return new Paragraph({
    children: runs(text, { font: GOTHIC, size: level >= 3 ? 21 : 24, bold: true, color: INK }),
    spacing: { before: level >= 3 ? 240 : 320, after: level >= 3 ? 100 : 140 },
    keepNext: true,
    border: level >= 3
      ? undefined
      : { bottom: { style: BorderStyle.SINGLE, size: 6, color: RULE, space: 4 } },
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
// 折り返された行をつなぎ直す
// ------------------------------------------------------------------
// リポジトリの Markdown は読みやすさのために手で折り返してある。1行ずつ段落に
// すると、**強調が行をまたいでいるときに `**` が文字として出てしまう**
// (`**当事業はピタメイトの…` / `…整合しないから**である。`)。
// Markdown の本来の解釈どおり、続きの行は前の行につなぐ。
const BLOCK_START = /^(#{1,6}\s|>|\||-{3,}$|〔※|[-•]\s|\d+(の\d+)?\.\s)/;

function fold(lines) {
  const out = [];
  for (const raw of lines) {
    const t = raw.trim();
    const prev = out.length ? out[out.length - 1] : null;
    // 字下げの無い **…** 始まりは、続きではなく独立した行として扱う
    // (「**制定日**: …」のようなラベル行が1段落にまとまってしまうため)
    const labelLine = /^\*\*/.test(raw);
    if (prev !== null && prev.trim() !== '' && t !== '' && !BLOCK_START.test(t) && !labelLine) {
      out[out.length - 1] = prev + t;
      continue;
    }
    out.push(raw);
  }
  return out;
}

// ------------------------------------------------------------------
// Markdown → ブロック列
// ------------------------------------------------------------------
function parse(md, { withNotes }) {
  const lines = fold(md.split('\n'));
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

    const h = /^(#{2,6})\s+(.*)$/.exec(line);
    if (h) { out.push(heading(h[2], h[1].length)); i++; continue; }

    // 引用ブロック(表を含むことがある)
    if (line.startsWith('>')) {
      const buf = [];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        buf.push(lines[i].trim().replace(/^>\s?/, ''));
        i++;
      }
      // 引用の中も折り返しをつなぐ(**強調が行をまたぐ**のは引用でも起きる)
      const joined = fold(buf);
      const tbl = joined.filter((l) => l.startsWith('|'));
      const txt = joined.filter((l) => !l.startsWith('|') && l !== '');
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
    creator: 'Type&Co',
    title: DOC_TITLE,
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
            children: [new TextRun({ text: subtitle ? `${DOC_TITLE}　${subtitle}` : DOC_TITLE, font: GOTHIC, size: 16, color: NOTE_INK })],
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

/**
 * 条文中の【…：公開前に記入】に、事業者情報の実値を差し込む。
 *
 * アプリは `src/content/legalDocs.ts` の `fillBusiness()` が同じことを表示時に
 * やっている。**Word を素の Markdown から作ると、そこだけ差し込まれない。**
 * 実際 2026-08-03 に出した利用規約の Word には
 * 【事業者名（屋号）：公開前に記入】が4か所残ったまま、他の箇所には実値が
 * 入っている、という状態で出来ていた。**弁護士に渡す前に気づけてよかった。**
 *
 * 値の出どころは `src/content/businessInfo.ts` の1か所だけ。ここでも
 * 書き写さず、そのファイルから読む(書き写した瞬間にずれ始める)。
 */
function fillBusiness(text) {
  const ts = fs.readFileSync(path.join(__dirname, '..', 'src/content/businessInfo.ts'), 'utf8');
  const pick = (key) => {
    const m = ts.match(new RegExp(`\\n\\s*${key}:\\s*'([^']*)'`));
    if (!m) throw new Error(`businessInfo.ts から ${key} を読めない`);
    return m[1];
  };
  const b = {
    name: pick('name'), tradeName: pick('tradeName'), postalCode: pick('postalCode'),
    address: pick('address'), phone: pick('phone'), email: pick('email'),
  };
  const open = /ADDRESS_DISCLOSURE[^=]*=\s*'public'/.test(ts);
  const onRequest = 'ご請求があれば遅滞なく開示します（下記のメールアドレスへご連絡ください）';
  const pairs = [
    ['【事業者名（屋号）：公開前に記入】', b.tradeName],
    ['【氏名（個人事業主本人）：公開前に記入】', b.name],
    ['【氏名（個人事業主）：公開前に記入】', b.name],
    ['【サービス専用の問い合わせ用メールアドレス：公開前に記入】', b.email],
    ['【所在地：公開前に記入】', open ? `〒${b.postalCode} ${b.address}` : onRequest],
    ['【電話番号：公開前に記入】', open ? b.phone : onRequest],
  ];
  const out = pairs.reduce((acc, [from, to]) => acc.split(from).join(to), text);

  // **差し込み漏れは黙って通さない。**「公開前に記入」が残ったまま人に渡すと、
  // 未確定の書類だと思われるか、そこだけ古い情報のまま出る。
  const left = out.match(/【[^】]*記入】/g);
  if (left) throw new Error(`差し込めなかった箇所があります: ${[...new Set(left)].join(' / ')}`);
  return out;
}

const md = FILL_BUSINESS ? fillBusiness(fs.readFileSync(SRC, 'utf8')) : fs.readFileSync(SRC, 'utf8');
const jobs = [];

if (VARIANTS === 'both' || VARIANTS === 'strip') {
  const clean = stripNotes(md);

  // 取りこぼしの検査。**メモが本文に残る**のが一番まずいので落ちるようにする
  if (clean.includes('〔※')) throw new Error('メモを落とした版に〔※が残っている');
  // 〔監視〕のような通常の亀甲括弧まで巻き込んでいないか
  const kakko = (md.match(/〔(?!※)/g) || []).length;
  if ((clean.match(/〔(?!※)/g) || []).length !== kakko) {
    throw new Error('〔※ でない亀甲括弧まで消してしまっている');
  }
  for (const k of REQUIRED) {
    if (!clean.includes(k)) throw new Error(`メモを落とした版から ${k} が消えている`);
  }

  jobs.push(build(clean, {
    withNotes: false,
    subtitle: VARIANTS === 'both' ? '条文' : '',
    file: `${BASE_NAME}.docx`,
  }));
}

if (VARIANTS === 'both') {
  jobs.push(build(md, { withNotes: true, subtitle: '注記付き（内部・確認用）', file: `${BASE_NAME}_注記付き.docx` }));
} else if (VARIANTS === 'keep') {
  jobs.push(build(md, { withNotes: true, subtitle: '', file: `${BASE_NAME}.docx` }));
}

Promise.all(jobs).catch((e) => { console.error(e); process.exit(1); });
