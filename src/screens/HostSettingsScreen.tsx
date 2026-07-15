import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, Toggle, Card, ListRow } from '../components/Ui'
import { Coin, Shield } from '../components/Icon'
import { GAMES } from '../flow'
import { usePress } from '../hooks/usePress'

export default function HostSettingsScreen({ flow }: { flow: Flow }) {
  const h = flow.hostSettings
  const save = usePress(`3px 3px 0 ${C.lavender}`)

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="ホスト設定" onBack={() => flow.go('mypage')} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '4px 20px 0',
          display: 'flex',
          flexDirection: 'column',
          gap: 14,
        }}
      >
        <div
          style={{
            background: C.surfaceLavender,
            border: `1.5px solid ${C.lavender}`,
            borderRadius: 12,
            padding: '13px 14px',
            display: 'flex',
            gap: 10,
            alignItems: 'flex-start',
          }}
        >
          <Shield size={18} style={{ flex: 'none', marginTop: 1 }} />
          <span style={{ fontSize: 11.5, lineHeight: 1.7, color: C.body }}>
            ホストになると、あなたと一緒に遊ぶ時間をコインで提供できます。掲載は本人確認済みの方のみ。安心設定（誘いを受ける範囲・承認制）は掲載中も有効です。
          </span>
        </div>

        <Card>
          <ListRow
            label="ホストとして掲載する"
            sub={h.isHost ? '「さがす」に表示されます' : 'オフの間は表示されません'}
            divider={false}
            right={
              <Toggle
                on={h.isHost}
                onToggle={() => flow.setHostPref('isHost', !h.isHost)}
                label="ホストとして掲載する"
              />
            }
          />
        </Card>

        <span style={{ fontSize: 12, color: C.muted }}>時給レート</span>
        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '13px 14px',
            display: 'flex',
            alignItems: 'center',
            gap: 10,
          }}
        >
          <Coin size={18} />
          <span
            onClick={() => flow.setHostPref('hourlyRate', Math.max(50, h.hourlyRate - 50))}
            style={{ cursor: 'pointer', fontSize: 18, color: C.ink, userSelect: 'none', padding: '0 6px' }}
          >
            −
          </span>
          <span style={{ flex: 1, textAlign: 'center', fontSize: 16, color: C.ink }}>
            {h.hourlyRate} / 1時間
          </span>
          <span
            onClick={() => flow.setHostPref('hourlyRate', Math.min(2000, h.hourlyRate + 50))}
            style={{ cursor: 'pointer', fontSize: 18, color: C.ink, userSelect: 'none', padding: '0 6px' }}
          >
            ＋
          </span>
        </div>

        <span style={{ fontSize: 12, color: C.muted }}>対応ゲーム</span>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          {GAMES.map((g) => {
            const sel = h.games.includes(g)
            return (
              <span
                key={g}
                onClick={() =>
                  flow.setHostPref(
                    'games',
                    sel ? h.games.filter((x) => x !== g) : [...h.games, g],
                  )
                }
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
                {g}
              </span>
            )
          })}
        </div>

        <span style={{ fontSize: 12, color: C.muted }}>ひとことメッセージ</span>
        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '12px 14px',
            minHeight: 60,
          }}
        >
          <span style={{ fontSize: 12.5, color: h.bio ? C.ink : C.placeholder }}>
            {h.bio || 'ゴールド帯でまったり回してます。初心者さんも歓迎です！'}
          </span>
        </div>

        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            boxShadow: `2px 2px 0 ${C.shadowCol}`,
            padding: '11px 13px',
            display: 'flex',
            flexDirection: 'column',
            gap: 5,
            marginBottom: 10,
          }}
        >
          <span style={{ fontSize: 11.5, color: C.ink }}>ホストとして遊ぶときのルール</span>
          <span style={{ fontSize: 10.5, lineHeight: 1.7, color: C.body }}>
            ・提供するのは「ゲームを一緒に遊ぶ時間」です。出会い・恋愛目的の勧誘は禁止
            <br />
            ・受け取りはコイン決済のみ。アプリ外での金銭要求は禁止
            <br />
            ・ドタキャン・無断キャンセルはマナースコアに反映されます
            <br />
            ・不適切な要求を受けたら、その場で通報してください
          </span>
        </div>
      </div>
      <div style={{ padding: '12px 20px 26px', background: C.white, borderTop: `1.5px solid ${C.border}` }}>
        <div
          className="pita-press"
          onClick={() => flow.go('mypage')}
          {...save.handlers}
          style={{
            cursor: 'pointer',
            background: C.ctaBg,
            color: C.ctaFg,
            borderRadius: 8,
            padding: '14px 0',
            textAlign: 'center',
            fontSize: 14,
            ...save.style,
          }}
        >
          この設定で保存する ▶
        </div>
      </div>
    </Screen>
  )
}
