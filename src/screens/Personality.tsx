/**
 * ゲーム相性診断(プレイスタイル診断)。イントロ → 12問 → 結果 を1画面内で進める。
 * 結果は flow.personalityResult に保存(localStorageにも永続化)。
 * 恋愛相性ではなく「一緒に遊ぶときの楽しみ方の相性」を見る、あくまで目安の診断。
 */
import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import { SubHeader } from '../components/Ui'
import { usePress } from '../hooks/usePress'
import {
  QUESTIONS,
  AXES,
  TYPES,
  GOOD_MATCH_TYPES,
  buildResult,
  axisPercent,
  type PersonalityResult,
} from '../content/personality'

type Step = 'intro' | 'quiz' | 'result'

export default function Personality({ flow }: { flow: Flow }) {
  const [step, setStep] = useState<Step>(flow.personalityResult ? 'result' : 'intro')
  const [answers, setAnswers] = useState<(boolean | null)[]>(Array(QUESTIONS.length).fill(null))
  const [current, setCurrent] = useState(0)

  const cta = usePress(`3px 3px 0 ${C.shadowCol}`)

  function startQuiz() {
    setAnswers(Array(QUESTIONS.length).fill(null))
    setCurrent(0)
    setStep('quiz')
  }

  function answer(pickA: boolean) {
    const next = [...answers]
    next[current] = pickA
    setAnswers(next)
    if (current < QUESTIONS.length - 1) {
      setCurrent(current + 1)
    } else {
      const result = buildResult(next.map((v) => v ?? false))
      flow.setPersonalityResult(result)
      setStep('result')
    }
  }

  return (
    <Screen background={C.surface}>
      <SubHeader title="ゲーム相性診断" onBack={() => flow.go('mypage')} />
      {step === 'intro' && <Intro onStart={startQuiz} cta={cta} hasResult={!!flow.personalityResult} onSeeResult={() => setStep('result')} />}
      {step === 'quiz' && (
        <Quiz
          index={current}
          onAnswer={answer}
          onBack={() => (current > 0 ? setCurrent(current - 1) : setStep('intro'))}
        />
      )}
      {step === 'result' && flow.personalityResult && (
        <Result result={flow.personalityResult} onRetake={startQuiz} onDone={() => flow.go('mypage')} cta={cta} />
      )}
    </Screen>
  )
}

/* ---------- イントロ ---------- */
function Intro({
  onStart,
  cta,
  hasResult,
  onSeeResult,
}: {
  onStart: () => void
  cta: ReturnType<typeof usePress>
  hasResult: boolean
  onSeeResult: () => void
}) {
  return (
    <div
      className="pita-scroll"
      style={{ flex: 1, overflowY: 'auto', padding: '10px 22px 24px', display: 'flex', flexDirection: 'column', gap: 18 }}
    >
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, padding: '10px 0' }}>
        <span style={{ fontSize: 44 }}>🎮</span>
        <span style={{ fontSize: 20, color: C.ink }}>あなたのゲーム相性は？</span>
        <span style={{ fontSize: 12.5, color: C.body, lineHeight: 1.8, textAlign: 'center' }}>
          12問の質問で、あなたの<b style={{ color: C.ink }}>遊び方タイプ</b>と
          <br />
          ピタッと合う人がわかります。約1分で完了。
        </span>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {[
          ['🕹️', '通話やゲームの楽しみ方のクセがわかる'],
          ['🤝', '一緒に遊ぶと合いそうなタイプがわかる'],
          ['✨', 'プロフィールに載せてきっかけ作りに'],
        ].map(([icon, text]) => (
          <div
            key={text}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 10,
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 10,
              padding: '11px 13px',
            }}
          >
            <span style={{ fontSize: 17, flex: 'none' }}>{icon}</span>
            <span style={{ fontSize: 12.5, color: C.ink }}>{text}</span>
          </div>
        ))}
      </div>

      <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
        ※ 楽しむための目安です。ピタフレはゲームを一緒に楽しむ場で、出会い目的の利用は禁止しています。
      </span>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <div
          className="pita-press"
          onClick={onStart}
          {...cta.handlers}
          style={{
            cursor: 'pointer',
            background: C.ctaBg,
            color: C.ctaFg,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '15px 0',
            textAlign: 'center',
            fontSize: 15,
            ...cta.style,
          }}
        >
          {hasResult ? 'もう一度診断する ▶' : '診断をはじめる ▶'}
        </div>
        {hasResult && (
          <span
            onClick={onSeeResult}
            style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.lavender, fontWeight: 700 }}
          >
            前回の結果を見る
          </span>
        )}
      </div>
    </div>
  )
}

/* ---------- 質問 ---------- */
function Quiz({ index, onAnswer, onBack }: { index: number; onAnswer: (a: boolean) => void; onBack: () => void }) {
  const q = QUESTIONS[index]
  const progress = ((index + 1) / QUESTIONS.length) * 100

  return (
    <div style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: '6px 22px 24px' }}>
      {/* 進捗 */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 24 }}>
        <span onClick={onBack} style={{ cursor: 'pointer', fontSize: 13, color: C.muted }}>
          ‹
        </span>
        <div style={{ flex: 1, height: 8, background: C.surfaceLavender, borderRadius: 99, overflow: 'hidden', border: `1.5px solid ${C.border}` }}>
          <div style={{ width: `${progress}%`, height: '100%', background: C.lavender, transition: 'width .2s ease' }} />
        </div>
        <span style={{ fontSize: 11, color: C.muted, fontVariantNumeric: 'tabular-nums' }}>
          {index + 1}/{QUESTIONS.length}
        </span>
      </div>

      <span style={{ fontSize: 18, color: C.ink, lineHeight: 1.6, marginBottom: 22 }}>{q.text}</span>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        {[
          { pick: true, label: q.a },
          { pick: false, label: q.b },
        ].map(({ pick, label }) => (
          <div
            key={label}
            onClick={() => onAnswer(pick)}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => (e.key === 'Enter' || e.key === ' ') && onAnswer(pick)}
            style={{
              cursor: 'pointer',
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 12,
              boxShadow: `3px 3px 0 ${C.shadowCol}`,
              padding: '16px 16px',
              fontSize: 14,
              color: C.ink,
              lineHeight: 1.6,
            }}
          >
            {label}
          </div>
        ))}
      </div>
    </div>
  )
}

/* ---------- 結果 ---------- */
function Result({
  result,
  onRetake,
  onDone,
  cta,
}: {
  result: PersonalityResult
  onRetake: () => void
  onDone: () => void
  cta: ReturnType<typeof usePress>
}) {
  const type = TYPES[result.typeId]
  const typeColor = C[type.colorToken]
  // fill(濃紫)/lavender は暗いので文字は白、明るい色(lime/aqua)は濃い文字。
  const onType = type.colorToken === 'fill' || type.colorToken === 'lavender' ? '#fff' : C.ink

  return (
    <div
      className="pita-scroll"
      style={{ flex: 1, overflowY: 'auto', padding: '8px 22px 24px', display: 'flex', flexDirection: 'column', gap: 18 }}
    >
      {/* タイプカード */}
      <div
        style={{
          background: typeColor,
          border: `1.5px solid ${C.border}`,
          borderRadius: 16,
          boxShadow: `4px 4px 0 ${C.shadowCol}`,
          padding: '22px 18px',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          gap: 6,
          textAlign: 'center',
        }}
      >
        <span style={{ fontSize: 11, color: onType, opacity: 0.8 }}>あなたの遊び方タイプは</span>
        <span style={{ fontSize: 40 }}>{type.emoji}</span>
        <span style={{ fontSize: 22, color: onType, fontWeight: 700 }}>{type.name}</span>
        <span style={{ fontSize: 12.5, color: onType }}>{type.tagline}</span>
      </div>

      {/* 4軸バー */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        <span style={{ fontSize: 13, color: C.ink }}>▶ あなたのプレイスタイル</span>
        {AXES.map((ax) => {
          const pct = axisPercent(result.scores[ax.key]) // +側(pos)の割合
          const posDominant = result.scores[ax.key] >= 0
          return (
            <div key={ax.key} style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11.5 }}>
                <span style={{ color: posDominant ? C.ink : C.muted, fontWeight: posDominant ? 700 : 400 }}>{ax.pos}</span>
                <span style={{ color: !posDominant ? C.ink : C.muted, fontWeight: !posDominant ? 700 : 400 }}>{ax.neg}</span>
              </div>
              <div style={{ position: 'relative', height: 10, background: C.surfaceLavender, borderRadius: 99, border: `1.5px solid ${C.border}`, overflow: 'hidden' }}>
                <div style={{ width: `${pct}%`, height: '100%', background: C.lavender }} />
              </div>
            </div>
          )
        })}
      </div>

      {/* 得意な遊び方 */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        <span style={{ fontSize: 13, color: C.ink }}>▶ 得意な遊び方</span>
        {type.strengths.map((s) => (
          <div
            key={s}
            style={{
              display: 'flex',
              gap: 8,
              alignItems: 'flex-start',
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 10,
              padding: '10px 12px',
            }}
          >
            <span style={{ fontSize: 12, flex: 'none' }}>✓</span>
            <span style={{ fontSize: 12, color: C.ink, lineHeight: 1.6 }}>{s}</span>
          </div>
        ))}
      </div>

      {/* 合いそうなタイプ */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        <span style={{ fontSize: 13, color: C.ink }}>▶ 合いそうなタイプ</span>
        <div style={{ display: 'flex', gap: 10 }}>
          {GOOD_MATCH_TYPES[result.typeId].map((tid) => {
            const t = TYPES[tid]
            return (
              <div
                key={tid}
                style={{
                  flex: 1,
                  background: C.white,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 12,
                  padding: '12px 8px',
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  gap: 4,
                  textAlign: 'center',
                }}
              >
                <span style={{ fontSize: 24 }}>{t.emoji}</span>
                <span style={{ fontSize: 11.5, color: C.ink }}>{t.name}</span>
              </div>
            )
          })}
        </div>
      </div>

      <span style={{ fontSize: 10, color: C.muted, lineHeight: 1.7 }}>
        ※ 診断は楽しむための目安です。相性は一緒に遊ぶ中で育つもの。気になる人には気軽に声をかけてみましょう。
      </span>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <div
          className="pita-press"
          onClick={onDone}
          {...cta.handlers}
          style={{
            cursor: 'pointer',
            background: C.ctaBg,
            color: C.ctaFg,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '15px 0',
            textAlign: 'center',
            fontSize: 15,
            ...cta.style,
          }}
        >
          マイページに戻る ▶
        </div>
        <span onClick={onRetake} style={{ cursor: 'pointer', textAlign: 'center', fontSize: 12, color: C.lavender, fontWeight: 700 }}>
          もう一度診断する
        </span>
      </div>
    </div>
  )
}
