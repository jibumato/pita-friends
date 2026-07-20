import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { ChevronLeft, Shield } from '../components/Icon'
import { usePress } from '../hooks/usePress'
import { clickable } from '../hooks/clickable'

/**
 * メッセージ等のモニタリング(自動検知)への同意画面。
 * 通信の秘密(電気通信事業法4条)との関係で、規約への埋め込みではなく
 * 「独立した画面で目的・方法・範囲を明示して個別に同意を取得する」
 * という法務レビューの推奨(運用Q&A Q11)に基づく。
 */

function InfoCard({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div
      style={{
        background: C.white,
        border: `1.5px solid ${C.border}`,
        borderRadius: 10,
        boxShadow: `2px 2px 0 ${C.shadowCol}`,
        padding: '12px 14px',
        display: 'flex',
        flexDirection: 'column',
        gap: 6,
      }}
    >
      <span style={{ fontSize: 11, color: C.lavender }}>▶ {label}</span>
      <span style={{ fontSize: 11.5, lineHeight: 1.75, color: C.body }}>{children}</span>
    </div>
  )
}

export default function Consent({ flow }: { flow: Flow }) {
  const [agreed, setAgreed] = useState(false)
  const cta = usePress(`3px 3px 0 ${C.lavender}`)

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:43" />
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 20px 0' }}>
        <div
          onClick={() => flow.go('welcome')}
          {...clickable(() => flow.go('welcome'), 'もどる')}
          style={{ cursor: 'pointer' }}
        >
          <ChevronLeft />
        </div>
        <span style={{ fontSize: 11, color: C.muted }}>はじめる前に</span>
      </div>
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          display: 'flex',
          flexDirection: 'column',
          padding: '14px 22px 0',
          gap: 12,
        }}
      >
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 22, color: C.ink, lineHeight: 1.4 }}>
            安全のための
            <br />
            「みまもり」について
          </span>
          <span style={{ fontSize: 12, color: C.muted, lineHeight: 1.7 }}>
            ピタフレを安心して使えるよう、アプリ内のやり取りを見守っています。内容をご確認のうえ、同意をお願いします。
          </span>
        </div>

        <InfoCard label="なんのため？(目的)">
          外部アプリへの誘導、アプリ外での直接の金銭要求、出会い・恋愛目的の勧誘を見つけて、みんなの安全を守るためです。この目的以外には使いません。
        </InfoCard>

        <InfoCard label="どうやって？(方法)">
          メッセージなどは、原則として<b style={{ color: C.ink }}>プログラムが自動でチェック</b>します。運営スタッフが内容を確認するのは、<b style={{ color: C.ink }}>通報があったとき・違反の兆候を検知したときだけ</b>で、確認する範囲も該当箇所の前後に限ります。
        </InfoCard>

        <InfoCard label="どこまで？(範囲)">
          対象は、アプリ内のメッセージ・募集文・プロフィール文です。アプリの外でのやり取りは対象ではありません。
        </InfoCard>

        {/* 明示的な同意アクション */}
        <div
          onClick={() => setAgreed((a) => !a)}
          role="checkbox"
          aria-checked={agreed}
          tabIndex={0}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault()
              setAgreed((a) => !a)
            }
          }}
          style={{
            cursor: 'pointer',
            background: agreed ? C.lime : C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 10,
            boxShadow: `2px 2px 0 ${C.shadowCol}`,
            padding: '13px 14px',
            display: 'flex',
            gap: 10,
            alignItems: 'center',
            marginBottom: 4,
          }}
        >
          <div
            style={{
              width: 22,
              height: 22,
              flex: 'none',
              borderRadius: 6,
              border: `1.5px solid ${C.border}`,
              background: agreed ? C.ink : C.white,
              color: C.lime,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 13,
            }}
          >
            {agreed ? '✓' : ''}
          </div>
          <span style={{ fontSize: 12.5, color: C.ink, lineHeight: 1.6 }}>
            上記の目的・方法・範囲での「みまもり」に同意します
          </span>
        </div>

        <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', paddingBottom: 8 }}>
          <Shield size={13} style={{ flex: 'none', marginTop: 2 }} />
          <span style={{ fontSize: 10, color: C.muted, lineHeight: 1.6 }}>
            この同意はピタフレの利用に必要です。詳細は
            <span
              onClick={() => flow.openLegalDoc('privacy')}
              style={{ color: C.lavenderText, textDecoration: 'underline', cursor: 'pointer' }}
            >
              プライバシーポリシー
            </span>
            をご覧ください。
          </span>
        </div>
      </div>
      <div style={{ padding: '12px 22px 30px' }}>
        <div
          className="pita-press"
          onClick={() => agreed && flow.go('verify')}
          {...(agreed ? cta.handlers : {})}
          {...clickable(agreed ? () => flow.go('verify') : undefined, '同意して本人確認へ')}
          aria-disabled={!agreed}
          style={{
            cursor: agreed ? 'pointer' : 'not-allowed',
            background: agreed ? C.ctaBg : C.fill,
            color: agreed ? C.ctaFg : C.placeholder,
            opacity: agreed ? 1 : 0.55,
            borderRadius: 8,
            padding: '15px 0',
            textAlign: 'center',
            fontSize: 15,
            ...(agreed ? cta.style : {}),
          }}
        >
          同意して本人確認へ ▶
        </div>
      </div>
    </Screen>
  )
}
