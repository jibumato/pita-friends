import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import { clickable } from '../hooks/clickable'
import {
  fetchMyAvailability,
  saveMyAvailability,
  type AvailabilitySlot,
} from '../lib/queries'

/**
 * 募集する曜日・時間の設定。
 *
 * 日付ごとではなく**毎週くり返し**にしているのは、毎週メンテナンスする負担を
 * なくすためです。1マス = 1時間で、曜日 × 時間のタイルを塗ります。
 *
 * 1枠も塗らない状態は「いつでも受け付ける」を意味します(サーバ側も同じ扱い)。
 * 塗った瞬間から、その枠の外は申し込めなくなります。
 */
const WD = ['日', '月', '火', '水', '木', '金', '土']

/** 縦に長くなりすぎないよう、既定では夕方〜深夜を出す。全24時間にも切り替えられる。 */
const DEFAULT_HOURS = Array.from({ length: 12 }, (_, i) => i + 12) // 12〜23時
const ALL_HOURS = Array.from({ length: 24 }, (_, i) => i)

function slotId(weekday: number, hour: number): string {
  return `${weekday}-${hour}`
}

export default function AvailabilityEditor() {
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [showAll, setShowAll] = useState(false)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    fetchMyAvailability()
      .then((rows) => {
        if (!active) return
        setSelected(new Set(rows.map((r) => slotId(r.weekday, r.hour))))
        // すでに早朝を含めて設定している人には、その行も見せる
        if (rows.some((r) => r.hour < 12)) setShowAll(true)
      })
      .catch(() => {})
      .finally(() => active && setLoading(false))
    return () => {
      active = false
    }
  }, [])

  function toggle(weekday: number, hour: number) {
    const id = slotId(weekday, hour)
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
    setMsg(null)
  }

  /** 曜日の列をまとめて塗る/消す。1マスずつ押すのは現実的でない。 */
  function toggleColumn(weekday: number, hours: number[]) {
    const allOn = hours.every((h) => selected.has(slotId(weekday, h)))
    setSelected((prev) => {
      const next = new Set(prev)
      for (const h of hours) {
        if (allOn) next.delete(slotId(weekday, h))
        else next.add(slotId(weekday, h))
      }
      return next
    })
    setMsg(null)
  }

  async function save() {
    if (saving) return
    setSaving(true)
    setMsg(null)
    try {
      const slots: AvailabilitySlot[] = [...selected].map((id) => {
        const [w, h] = id.split('-')
        return { weekday: Number(w), hour: Number(h) }
      })
      const n = await saveMyAvailability(slots)
      setMsg(n === 0 ? '募集枠を解除しました(いつでも受け付けます)' : `${n}枠を保存しました`)
    } catch {
      setMsg('保存に失敗しました。時間をおいて再度お試しください。')
    } finally {
      setSaving(false)
    }
  }

  const hours = showAll ? ALL_HOURS : DEFAULT_HOURS

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.6 }}>
        募集する時間を塗ってください。塗った枠の外は申し込まれません。
        <br />
        1枠も塗らない場合は、これまでどおり<b style={{ color: C.ink }}>いつでも</b>申し込まれます。
      </span>

      {loading ? (
        <span style={{ fontSize: 11, color: C.muted }}>読み込み中…</span>
      ) : (
        <>
          <div className="pita-scroll" style={{ overflowX: 'auto', paddingBottom: 2 }}>
            <div
              style={{
                display: 'grid',
                gridTemplateColumns: `34px repeat(7, minmax(34px, 1fr))`,
                gap: 3,
                minWidth: 34 + 7 * 37,
              }}
            >
              <span />
              {WD.map((w, i) => (
                <span
                  key={w}
                  onClick={() => toggleColumn(i, hours)}
                  {...clickable(() => toggleColumn(i, hours), `${w}曜をまとめて切り替え`)}
                  style={{
                    fontSize: 11,
                    cursor: 'pointer',
                    textAlign: 'center',
                    color: i === 0 ? C.avatarOrange : i === 6 ? C.avatarAqua : C.ink,
                    textDecoration: 'underline',
                  }}
                >
                  {w}
                </span>
              ))}

              {hours.map((h) => (
                <Row key={h} hour={h} selected={selected} onToggle={toggle} />
              ))}
            </div>
          </div>

          <span
            onClick={() => setShowAll((v) => !v)}
            {...clickable(() => setShowAll((v) => !v), showAll ? '夕方以降だけ表示' : '24時間ぶん表示')}
            style={{ cursor: 'pointer', fontSize: 10.5, color: C.lavender, textDecoration: 'underline' }}
          >
            {showAll ? '夕方以降だけ表示する' : '早朝・日中も設定する'}
          </span>

          <div
            onClick={save}
            {...clickable(save, '募集枠を保存する')}
            style={{
              cursor: saving ? 'not-allowed' : 'pointer',
              opacity: saving ? 0.6 : 1,
              textAlign: 'center',
              fontSize: 12.5,
              color: C.ink,
              background: C.lime,
              border: `1.5px solid ${C.border}`,
              borderRadius: 6,
              padding: '9px 0',
            }}
          >
            {saving ? '保存中…' : `募集枠を保存する（${selected.size}枠）`}
          </div>
          {msg && <span style={{ fontSize: 10.5, color: C.body }}>{msg}</span>}
        </>
      )}
    </div>
  )
}

function Row({
  hour,
  selected,
  onToggle,
}: {
  hour: number
  selected: Set<string>
  onToggle: (weekday: number, hour: number) => void
}) {
  return (
    <>
      <span
        style={{
          fontSize: 10,
          color: C.muted,
          textAlign: 'right',
          paddingRight: 2,
          alignSelf: 'center',
          fontVariantNumeric: 'tabular-nums',
        }}
      >
        {hour}時
      </span>
      {WD.map((w, i) => {
        const on = selected.has(slotId(i, hour))
        return (
          <span
            key={`${i}-${hour}`}
            onClick={() => onToggle(i, hour)}
            {...clickable(() => onToggle(i, hour), `${w}曜 ${hour}時 ${on ? '募集中' : '募集なし'}`)}
            style={{
              height: 22,
              borderRadius: 4,
              cursor: 'pointer',
              background: on ? C.lime : C.white,
              border: `1px solid ${on ? C.ink : C.border}`,
            }}
          />
        )
      })}
    </>
  )
}
