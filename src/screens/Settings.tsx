import { useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, SectionLabel, Card, ListRow, Toggle } from '../components/Ui'
import { isBackendConfigured } from '../lib/supabase'

export default function Settings({ flow }: { flow: Flow }) {
  const [sw, setSw] = useState<Record<string, boolean>>({
    dark: false,
    online: true,
    notifDM: true,
    notifOnline: true,
    notifMatch: false,
    verifiedOnly: true,
  })
  const toggle = (k: string) => setSw((s) => ({ ...s, [k]: !s[k] }))

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="設定" onBack={() => flow.go('mypage')} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '4px 20px 24px',
          display: 'flex',
          flexDirection: 'column',
          gap: 14,
        }}
      >
        <SectionLabel>表示</SectionLabel>
        <Card>
          <ListRow
            label="ダークテーマ"
            right={<Toggle on={flow.theme === 'dark'} onToggle={flow.toggleTheme} />}
          />
          <ListRow
            label="オンライン状態を表示"
            divider={false}
            right={<Toggle on={sw.online} onToggle={() => toggle('online')} />}
          />
        </Card>

        <SectionLabel>通知</SectionLabel>
        <Card>
          <ListRow label="誘い・メッセージ" right={<Toggle on={sw.notifDM} onToggle={() => toggle('notifDM')} />} />
          <ListRow
            label="フレンドの「いま遊べる」"
            right={<Toggle on={sw.notifOnline} onToggle={() => toggle('notifOnline')} />}
          />
          <ListRow
            label="おすすめマッチ"
            divider={false}
            right={<Toggle on={sw.notifMatch} onToggle={() => toggle('notifMatch')} />}
          />
        </Card>

        <SectionLabel>プライバシー・安全</SectionLabel>
        <Card>
          <ListRow
            label="安心設定"
            sub="誘いを受ける範囲・承認制・公開範囲"
            onClick={() => flow.go('safetyPrefs')}
          />
          <ListRow
            label="本人確認済みのみから連絡を受ける"
            sub="推奨"
            right={<Toggle on={sw.verifiedOnly} onToggle={() => toggle('verifiedOnly')} />}
          />
          <ListRow label="ブロックリスト" />
          <ListRow label="安全センター" onClick={() => flow.go('safety')} />
          <ListRow label="データのダウンロード請求" divider={false} />
        </Card>

        <SectionLabel>規約・ポリシー</SectionLabel>
        <Card>
          <ListRow label="利用規約" />
          <ListRow label="プライバシーポリシー" />
          <ListRow label="特定商取引法に基づく表記" />
          <ListRow label="みまもり（監視）について" divider={false} />
        </Card>

        <SectionLabel>アカウント</SectionLabel>
        <Card>
          <ListRow label="メール・ログイン方法" />
          {isBackendConfigured && <ListRow label="ログアウト" onClick={flow.signOut} />}
          <ListRow label="アカウントを削除" danger divider={false} />
        </Card>
      </div>
    </Screen>
  )
}
