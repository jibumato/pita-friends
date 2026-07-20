/**
 * 規約・ポリシー表示用の軽量Markdownレンダラ。
 * 対応: # ## ### 見出し / > 引用(コールアウト) / - ・1. リスト /
 *       | 表 | / --- 区切り / 段落 / **太字** / [text](url)→text。
 * 外部依存を増やさないため、ドラフトで実際に使う記法だけを最小実装する。
 */
import type { ReactNode } from 'react'
import { color as C } from '../theme/tokens'

/** インライン装飾: **太字** と [text](url)→text、`code`→code。 */
function inline(text: string, keyBase: string): ReactNode[] {
  // リンクとバッククォートを素のテキストへ
  const cleaned = text.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/`([^`]*)`/g, '$1')
  const parts = cleaned.split(/(\*\*[^*]+\*\*)/g)
  return parts.map((p, i) => {
    if (p.startsWith('**') && p.endsWith('**')) {
      return (
        <b key={`${keyBase}-b${i}`} style={{ color: C.ink }}>
          {p.slice(2, -2)}
        </b>
      )
    }
    return <span key={`${keyBase}-s${i}`}>{p}</span>
  })
}

type Block =
  | { t: 'h'; level: number; text: string }
  | { t: 'p'; text: string }
  | { t: 'quote'; lines: string[] }
  | { t: 'list'; items: string[] }
  | { t: 'table'; rows: string[][] }
  | { t: 'hr' }

function parse(md: string): Block[] {
  const lines = md.replace(/\r\n/g, '\n').split('\n')
  const blocks: Block[] = []
  let i = 0
  const isTableRow = (s: string) => /^\s*\|.*\|\s*$/.test(s)
  const isSep = (s: string) => /^\s*\|?[\s:|-]+\|?\s*$/.test(s) && s.includes('-')
  const cells = (s: string) =>
    s.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim())

  while (i < lines.length) {
    const raw = lines[i]
    const line = raw.trim()
    if (line === '') { i++; continue }
    if (line === '---' || line === '***') { blocks.push({ t: 'hr' }); i++; continue }

    const h = line.match(/^(#{1,6})\s+(.*)$/)
    if (h) { blocks.push({ t: 'h', level: h[1].length, text: h[2] }); i++; continue }

    if (line.startsWith('>')) {
      const ls: string[] = []
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        ls.push(lines[i].trim().replace(/^>\s?/, ''))
        i++
      }
      blocks.push({ t: 'quote', lines: ls })
      continue
    }

    if (isTableRow(raw)) {
      const rows: string[][] = []
      while (i < lines.length && isTableRow(lines[i])) {
        if (!isSep(lines[i])) rows.push(cells(lines[i]))
        i++
      }
      blocks.push({ t: 'table', rows })
      continue
    }

    if (/^\s*([-*]|\d+\.)\s+/.test(raw)) {
      const items: string[] = []
      while (i < lines.length && /^\s*([-*]|\d+\.)\s+/.test(lines[i])) {
        items.push(lines[i].trim().replace(/^([-*]|\d+\.)\s+/, ''))
        i++
      }
      blocks.push({ t: 'list', items })
      continue
    }

    // 段落(連続する非空・非特殊行をまとめる)
    const para: string[] = []
    while (
      i < lines.length &&
      lines[i].trim() !== '' &&
      !/^#{1,6}\s/.test(lines[i].trim()) &&
      !lines[i].trim().startsWith('>') &&
      !isTableRow(lines[i]) &&
      !/^\s*([-*]|\d+\.)\s+/.test(lines[i]) &&
      lines[i].trim() !== '---'
    ) {
      para.push(lines[i].trim())
      i++
    }
    blocks.push({ t: 'p', text: para.join(' ') })
  }
  return blocks
}

export default function Markdown({ source }: { source: string }) {
  const blocks = parse(source)
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
      {blocks.map((b, i) => {
        const key = `b${i}`
        if (b.t === 'hr') {
          return <div key={key} style={{ height: 1.5, background: C.divider, margin: '2px 0' }} />
        }
        if (b.t === 'h') {
          const size = b.level <= 1 ? 19 : b.level === 2 ? 15 : 13
          return (
            <span key={key} style={{ fontSize: size, color: C.ink, marginTop: b.level <= 2 ? 6 : 2 }}>
              {inline(b.text, key)}
            </span>
          )
        }
        if (b.t === 'quote') {
          return (
            <div
              key={key}
              style={{
                background: C.surfaceLavender,
                border: `1.5px solid ${C.lavender}`,
                borderRadius: 8,
                padding: '10px 12px',
                display: 'flex',
                flexDirection: 'column',
                gap: 4,
              }}
            >
              {b.lines.map((l, j) => (
                <span key={`${key}-${j}`} style={{ fontSize: 11, lineHeight: 1.7, color: C.body }}>
                  {inline(l, `${key}-${j}`)}
                </span>
              ))}
            </div>
          )
        }
        if (b.t === 'list') {
          return (
            <div key={key} style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {b.items.map((it, j) => (
                <div key={`${key}-${j}`} style={{ display: 'flex', gap: 8 }}>
                  <span style={{ color: C.lavenderText, flex: 'none' }}>・</span>
                  <span style={{ fontSize: 12.5, lineHeight: 1.7, color: C.body }}>
                    {inline(it, `${key}-${j}`)}
                  </span>
                </div>
              ))}
            </div>
          )
        }
        if (b.t === 'table') {
          return (
            <div key={key} style={{ overflowX: 'auto' }}>
              <table style={{ borderCollapse: 'collapse', width: '100%', fontSize: 11.5 }}>
                <tbody>
                  {b.rows.map((row, r) => (
                    <tr key={`${key}-r${r}`}>
                      {row.map((cell, c) => (
                        <td
                          key={`${key}-r${r}-c${c}`}
                          style={{
                            border: `1.5px solid ${C.border}`,
                            padding: '7px 9px',
                            verticalAlign: 'top',
                            color: r === 0 ? C.ink : C.body,
                            background: r === 0 ? C.surfaceLavender : C.white,
                            lineHeight: 1.6,
                          }}
                        >
                          {inline(cell, `${key}-r${r}-c${c}`)}
                        </td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )
        }
        return (
          <span key={key} style={{ fontSize: 12.5, lineHeight: 1.8, color: C.body }}>
            {inline(b.text, key)}
          </span>
        )
      })}
    </div>
  )
}
