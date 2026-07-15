import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import Avatar from '../components/Avatar'
import { ChevronLeft, Upload, Shield } from '../components/Icon'
import { GAMES, genderLabel, type Gender } from '../flow'
import { usePress } from '../hooks/usePress'

function ChipRow({
  options,
  value,
  onPick,
}: {
  options: readonly string[]
  value: string
  onPick: (v: string) => void
}) {
  return (
    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
      {options.map((o) => {
        const sel = value === o
        return (
          <span
            key={o}
            onClick={() => onPick(o)}
            style={{
              cursor: 'pointer',
              fontSize: 12,
              color: sel ? C.lime : C.ink,
              background: sel ? C.fill : C.white,
              border: `1.5px solid ${C.border}`,
              padding: '7px 13px',
              borderRadius: 4,
            }}
          >
            {o}
          </span>
        )
      })}
    </div>
  )
}

export default function Setup({ flow }: { flow: Flow }) {
  const [style, setStyle] = useState('エンジョイ')
  const cta = usePress(`3px 3px 0 ${C.shadowCol}`)
  return (
    <Screen background={C.surface}>
      <StatusBar time="21:45" />
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 20px 0' }}>
        <div onClick={() => flow.go('verify')} style={{ cursor: 'pointer' }}>
          <ChevronLeft />
        </div>
        <span style={{ fontSize: 11, color: C.muted }}>STEP 2 / 2</span>
      </div>
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          display: 'flex',
          flexDirection: 'column',
          padding: '14px 22px 0',
          gap: 18,
        }}
      >
        <span style={{ fontSize: 22, color: C.ink }}>プロフィールをつくる</span>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8 }}>
          <div style={{ position: 'relative' }}>
            <Avatar initial="あ" color={C.lime} size={80} />
            <div
              style={{
                position: 'absolute',
                right: -4,
                bottom: -4,
                width: 28,
                height: 28,
                borderRadius: 8,
                background: C.fill,
                border: `1.5px solid ${C.border}`,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
              }}
            >
              <Upload />
            </div>
          </div>
          <span style={{ fontSize: 10, color: C.placeholder }}>アイコンを選ぶ</span>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <span style={{ fontSize: 12, color: C.muted }}>ニックネーム</span>
          <div
            style={{
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '12px 14px',
              boxShadow: `2px 2px 0 ${C.shadowCol}`,
            }}
          >
            <span style={{ fontSize: 13, color: C.ink }}>あおい</span>
          </div>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 12, color: C.muted }}>よく遊ぶゲーム</span>
          <ChipRow options={GAMES} value={flow.game} onPick={flow.setGame} />
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 12, color: C.muted }}>プレイスタイル</span>
          <ChipRow options={['エンジョイ', 'ガチ', 'まったり']} value={style} onPick={setStyle} />
        </div>
        {/* 性別(安心設計のための任意項目) */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 12, color: C.muted }}>性別</span>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {(['female', 'male', 'na'] as Gender[]).map((g) => {
              const sel = flow.gender === g
              return (
                <span
                  key={g}
                  onClick={() => flow.setGender(g)}
                  style={{
                    cursor: 'pointer',
                    fontSize: 12,
                    color: sel ? C.lime : C.ink,
                    background: sel ? C.fill : C.white,
                    border: `1.5px solid ${C.border}`,
                    padding: '7px 13px',
                    borderRadius: 4,
                  }}
                >
                  {genderLabel[g]}
                </span>
              )
            })}
          </div>
          <span style={{ fontSize: 10, color: C.placeholder, lineHeight: 1.6 }}>
            性別は、あなたが選んだ範囲だけに表示されます。いつでも「安心設定」で変更できます。
          </span>
        </div>
        {/* 女性向けの安心設定への導線 */}
        {flow.gender === 'female' && (
          <div
            style={{
              background: C.surfaceLavender,
              border: `1.5px solid ${C.lavender}`,
              borderRadius: 8,
              padding: '11px 12px',
              display: 'flex',
              gap: 8,
              alignItems: 'flex-start',
            }}
          >
            <Shield style={{ flex: 'none', marginTop: 1 }} />
            <span style={{ fontSize: 10.5, lineHeight: 1.6, color: C.body }}>
              次のステップで<b style={{ color: C.ink }}>「安心設定」</b>を用意しました。誰から誘いを受けるか・誘いの承認制など、あなたのペースで安心して遊べる設定ができます。
            </span>
          </div>
        )}
      </div>
      <div style={{ padding: '12px 22px 30px' }}>
        <div
          className="pita-press"
          onClick={() => flow.go(flow.gender === 'female' ? 'safetyPrefs' : 'home')}
          {...cta.handlers}
          style={{
            cursor: 'pointer',
            background: C.lime,
            color: C.ink,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '15px 0',
            textAlign: 'center',
            fontSize: 15,
            ...cta.style,
          }}
        >
          {flow.gender === 'female' ? '安心設定へ ▶' : 'はじめる ▶'}
        </div>
      </div>
    </Screen>
  )
}
