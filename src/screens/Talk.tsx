import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { ChevronLeft, Shield, Phone, Send } from '../components/Icon'
import { usePress } from '../hooks/usePress'

export default function Talk({ flow }: { flow: Flow }) {
  const goDay = usePress(`3px 3px 0 ${C.ink}`)
  return (
    <Screen background={C.surface}>
      <StatusBar time="21:49" />
      {/* 相手ヘッダー */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          padding: '10px 20px',
          borderBottom: `1.5px solid ${C.ink}`,
          background: C.white,
        }}
      >
        <div onClick={() => flow.go('party')} style={{ cursor: 'pointer' }}>
          <ChevronLeft />
        </div>
        <div
          style={{
            width: 36,
            height: 36,
            borderRadius: 8,
            background: C.avatarAqua,
            border: `1.5px solid ${C.ink}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: 15,
            color: C.ink,
          }}
        >
          み
        </div>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span style={{ fontSize: 14, color: C.ink }}>みなと</span>
            <span
              style={{
                fontSize: 9,
                color: C.ink,
                background: C.lime,
                border: `1.5px solid ${C.ink}`,
                padding: '1px 5px',
                borderRadius: 4,
              }}
            >
              ✓
            </span>
          </div>
          <span style={{ fontSize: 10, color: C.lavender }}>オンライン</span>
        </div>
        <div
          style={{
            width: 38,
            height: 38,
            borderRadius: 8,
            background: C.lime,
            border: `1.5px solid ${C.ink}`,
            boxShadow: `2px 2px 0 ${C.ink}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <Phone />
        </div>
      </div>
      {/* 安全性の帯(通報起動) */}
      <div
        onClick={flow.openReport}
        style={{
          cursor: 'pointer',
          background: C.surfaceLavender,
          borderBottom: `1.5px solid ${C.lavender}`,
          padding: '8px 20px',
          display: 'flex',
          gap: 8,
          alignItems: 'center',
        }}
      >
        <Shield size={13} style={{ flex: 'none' }} />
        <span style={{ flex: 1, fontSize: 10, color: C.body }}>
          通話はアプリ内が安全です。外部アプリへの誘導・金銭の話が出たら通報してください。
        </span>
        <span style={{ fontSize: 10, color: C.lavender }}>通報 ›</span>
      </div>
      {/* メッセージ */}
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '16px 20px',
          display: 'flex',
          flexDirection: 'column',
          gap: 12,
        }}
      >
        <Bubble side="left">はじめまして！誘いありがとうございます。今夜22時から大丈夫です🙌</Bubble>
        <Bubble side="right">よろしくお願いします！ゴールド帯でランク回しましょ〜</Bubble>

        {/* あそぶ約束カード */}
        <div
          style={{
            alignSelf: 'center',
            width: '100%',
            background: C.lavender,
            border: `1.5px solid ${C.ink}`,
            borderRadius: 10,
            boxShadow: `3px 3px 0 ${C.ink}`,
            padding: '13px 14px',
            display: 'flex',
            flexDirection: 'column',
            gap: 9,
          }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span style={{ fontSize: 12, color: C.lavenderText }}>あそぶ約束</span>
            <span
              style={{
                fontSize: 10,
                color: C.ink,
                background: flow.dealDone ? C.lime : C.avatarOrange,
                border: `1.5px solid ${C.ink}`,
                padding: '2px 8px',
                borderRadius: 4,
              }}
            >
              {flow.dealDone ? '確定済み' : '確定待ち'}
            </span>
          </div>
          <span style={{ fontSize: 14, color: '#fff' }}>
            {flow.when} · {flow.game} ランク
          </span>
          {!flow.dealDone && (
            <div style={{ display: 'flex', gap: 8 }}>
              <span
                onClick={flow.confirmDeal}
                style={{
                  cursor: 'pointer',
                  flex: 1,
                  textAlign: 'center',
                  fontSize: 12,
                  color: C.ink,
                  background: C.lime,
                  border: `1.5px solid ${C.ink}`,
                  padding: '9px 0',
                  borderRadius: 4,
                }}
              >
                ✓ 確定する
              </span>
              <span
                style={{
                  flex: 1,
                  textAlign: 'center',
                  fontSize: 12,
                  color: '#fff',
                  background: 'transparent',
                  border: '1.5px solid #fff',
                  padding: '9px 0',
                  borderRadius: 4,
                }}
              >
                変更を提案
              </span>
            </div>
          )}
          {flow.dealDone && (
            <div
              style={{
                background: C.ink,
                borderRadius: 6,
                padding: '8px 10px',
                display: 'flex',
                gap: 7,
                alignItems: 'center',
                justifyContent: 'center',
              }}
            >
              <span style={{ fontSize: 12, color: C.lime }}>✓ 約束が確定しました</span>
            </div>
          )}
        </div>

        {/* 確定後の追加表示 */}
        {flow.dealDone && (
          <>
            <div style={{ animation: 'scrIn .3s ease both' }}>
              <Bubble side="left">確定しました！フレンドコード送りますね🎮</Bubble>
            </div>
            <div
              style={{
                alignSelf: 'center',
                background: C.deepCard,
                borderRadius: 8,
                padding: '8px 14px',
                animation: 'scrIn .3s .15s ease both',
              }}
            >
              <span style={{ fontSize: 10.5, color: C.lime }}>
                🔓 フレンドコード交換が解放されました
              </span>
            </div>
            <div
              className="pita-press"
              onClick={() => flow.go('reminder')}
              {...goDay.handlers}
              style={{
                cursor: 'pointer',
                alignSelf: 'center',
                width: '100%',
                boxSizing: 'border-box',
                background: C.lime,
                color: C.ink,
                border: `1.5px solid ${C.ink}`,
                borderRadius: 8,
                padding: '12px 0',
                textAlign: 'center',
                fontSize: 13,
                animation: 'scrIn .3s .3s ease both',
                ...goDay.style,
              }}
            >
              ▶ 約束当日にすすむ(デモ)
            </div>
          </>
        )}
      </div>
      {/* 入力バー */}
      <div
        style={{
          display: 'flex',
          gap: 8,
          padding: '12px 16px 26px',
          background: C.white,
          borderTop: `1.5px solid ${C.ink}`,
          alignItems: 'center',
        }}
      >
        <div
          style={{
            flex: 1,
            background: C.surface,
            border: `1.5px solid ${C.ink}`,
            borderRadius: 8,
            padding: '11px 14px',
          }}
        >
          <span style={{ fontSize: 12.5, color: C.placeholder }}>メッセージを入力</span>
        </div>
        <div
          style={{
            width: 44,
            height: 44,
            borderRadius: 8,
            background: C.ink,
            boxShadow: `2px 2px 0 ${C.lavender}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <Send />
        </div>
      </div>
    </Screen>
  )
}

function Bubble({ side, children }: { side: 'left' | 'right'; children: React.ReactNode }) {
  const left = side === 'left'
  return (
    <div
      style={{
        alignSelf: left ? 'flex-start' : 'flex-end',
        maxWidth: '75%',
        background: left ? C.white : C.lime,
        border: `1.5px solid ${C.ink}`,
        borderRadius: left ? '2px 10px 10px 10px' : '10px 2px 10px 10px',
        padding: '10px 13px',
      }}
    >
      <span style={{ fontSize: 12.5, lineHeight: 1.6, color: C.ink }}>{children}</span>
    </div>
  )
}
