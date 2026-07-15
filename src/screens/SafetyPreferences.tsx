import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, SectionLabel, Card, ListRow, Toggle } from '../components/Ui'
import { Shield } from '../components/Icon'
import { contactScopeLabel, type ContactScope } from '../flow'
import { usePress } from '../hooks/usePress'

const SCOPES: ContactScope[] = ['verified', 'sameGender', 'all']

export default function SafetyPreferences({ flow }: { flow: Flow }) {
  const p = flow.safetyPrefs
  const cta = usePress(`3px 3px 0 ${C.lavender}`)
  const rec = usePress(`2px 2px 0 ${C.ink}`)

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:46" />
      <SubHeader title="安心設定" onBack={() => flow.go('mypage')} />
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
        {/* イントロ */}
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
            あなたのペースで安心して遊ぶための設定です。ピタフレは<b style={{ color: C.ink }}>ゲームを一緒に楽しむ場</b>で、出会い目的の利用は禁止しています。設定はいつでも変更できます。
          </span>
        </div>

        {/* おすすめ適用 */}
        <div
          className="pita-press"
          onClick={flow.applyRecommendedFemalePrefs}
          {...rec.handlers}
          style={{
            cursor: 'pointer',
            background: C.lime,
            color: C.ink,
            border: `1.5px solid ${C.ink}`,
            borderRadius: 8,
            padding: '11px 0',
            textAlign: 'center',
            fontSize: 12.5,
            ...rec.style,
          }}
        >
          ✓ おすすめの安心設定をまとめて適用
        </div>

        {/* 連絡・誘いを受ける範囲 */}
        <SectionLabel>誘い・連絡を受ける相手</SectionLabel>
        <div
          style={{
            display: 'flex',
            gap: 6,
            background: C.white,
            border: `1.5px solid ${C.ink}`,
            borderRadius: 8,
            padding: 6,
          }}
        >
          {SCOPES.map((s) => {
            const sel = p.contactScope === s
            return (
              <span
                key={s}
                onClick={() => flow.setSafetyPref('contactScope', s)}
                style={{
                  flex: 1,
                  textAlign: 'center',
                  cursor: 'pointer',
                  fontSize: 11.5,
                  color: sel ? C.lime : C.ink,
                  background: sel ? C.ink : 'transparent',
                  borderRadius: 4,
                  padding: '8px 0',
                }}
              >
                {contactScopeLabel[s]}
              </span>
            )
          })}
        </div>
        <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.6, marginTop: -6 }}>
          {p.contactScope === 'verified' && '本人確認を終えた相手だけが、あなたに誘いを送れます。'}
          {p.contactScope === 'sameGender' && '同性の相手だけが、あなたに誘いを送れます。'}
          {p.contactScope === 'all' && 'すべての相手が誘いを送れます(推奨しません)。'}
        </span>

        {/* コントロール */}
        <SectionLabel>あなたのコントロール</SectionLabel>
        <Card>
          <ListRow
            label="誘いを承認制にする"
            sub="届いた誘いは承認するまでトーク・連絡先が開きません"
            right={
              <Toggle
                on={p.approvalRequired}
                onToggle={() => flow.setSafetyPref('approvalRequired', !p.approvalRequired)}
              />
            }
          />
          <ListRow
            label="低マナー・未確認の相手をブロック"
            sub="マナースコアが低い相手からの接触を自動で防ぎます"
            right={
              <Toggle
                on={p.blockLowTrust}
                onToggle={() => flow.setSafetyPref('blockLowTrust', !p.blockLowTrust)}
              />
            }
          />
          <ListRow
            label="オンライン状態を公開"
            right={
              <Toggle
                on={p.showOnline}
                onToggle={() => flow.setSafetyPref('showOnline', !p.showOnline)}
              />
            }
          />
          <ListRow
            label="検索・おすすめに表示する"
            sub="オフにすると自分からだけ誘える完全に受け身の状態になります"
            divider={false}
            right={
              <Toggle
                on={p.discoverable}
                onToggle={() => flow.setSafetyPref('discoverable', !p.discoverable)}
              />
            }
          />
        </Card>

        <div
          style={{
            background: C.white,
            border: `1.5px solid ${C.ink}`,
            borderRadius: 8,
            boxShadow: `2px 2px 0 ${C.ink}`,
            padding: '11px 13px',
            display: 'flex',
            flexDirection: 'column',
            gap: 5,
          }}
        >
          <span style={{ fontSize: 11.5, color: C.ink }}>いつでも使える安全機能</span>
          <span style={{ fontSize: 10.5, lineHeight: 1.7, color: C.body }}>
            ・ワンタップの通報 / ブロック(相手に通知されません)
            <br />
            ・外部アプリ誘導・金銭要求の自動検知
            <br />
            ・違反者は身分証ベースで再登録不可
          </span>
        </div>
      </div>
      <div style={{ padding: '12px 20px 26px', background: C.white, borderTop: `1.5px solid ${C.ink}` }}>
        <div
          className="pita-press"
          onClick={() => flow.go('home')}
          {...cta.handlers}
          style={{
            cursor: 'pointer',
            background: C.ink,
            color: C.lime,
            borderRadius: 8,
            padding: '14px 0',
            textAlign: 'center',
            fontSize: 14,
            ...cta.style,
          }}
        >
          この設定ではじめる ▶
        </div>
      </div>
    </Screen>
  )
}
