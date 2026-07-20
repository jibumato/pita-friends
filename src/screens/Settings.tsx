import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, SectionLabel, Card, ListRow, Toggle } from '../components/Ui'
import { isBackendConfigured, supabase } from '../lib/supabase'
import {
  fetchNotificationPrefs,
  updateNotificationPrefs,
  submitAccountRequest,
  type NotificationPrefs,
} from '../lib/queries'

export default function Settings({ flow }: { flow: Flow }) {
  const [email, setEmail] = useState<string | null>(null)
  const [prefs, setPrefs] = useState<NotificationPrefs | null>(null)
  const [prefsError, setPrefsError] = useState<string | null>(null)
  const [requestBusy, setRequestBusy] = useState<'data_export' | 'account_deletion' | null>(null)
  const [requestMessage, setRequestMessage] = useState<string | null>(null)
  const [confirmingDelete, setConfirmingDelete] = useState(false)

  useEffect(() => {
    if (!isBackendConfigured || !supabase) return
    let active = true
    supabase.auth.getUser().then(({ data }) => {
      if (active) setEmail(data.user?.email ?? null)
    })
    fetchNotificationPrefs()
      .then((p) => active && setPrefs(p))
      .catch((e) => active && setPrefsError(e instanceof Error ? e.message : '取得に失敗しました'))
    return () => {
      active = false
    }
  }, [])

  async function togglePref(key: keyof NotificationPrefs) {
    if (!prefs) return
    const next = { ...prefs, [key]: !prefs[key] }
    setPrefs(next)
    try {
      await updateNotificationPrefs({ [key]: next[key] })
    } catch (e) {
      setPrefs(prefs) // 失敗したら元に戻す
      setPrefsError(e instanceof Error ? e.message : '更新に失敗しました')
    }
  }

  async function handleDataExport() {
    if (requestBusy) return
    setRequestBusy('data_export')
    setRequestMessage(null)
    try {
      await submitAccountRequest('data_export')
      setRequestMessage('データのダウンロード請求を受け付けました。準備でき次第、登録メールアドレス宛にご連絡します。')
    } catch (e) {
      setRequestMessage(e instanceof Error ? e.message : '請求に失敗しました')
    } finally {
      setRequestBusy(null)
    }
  }

  async function handleAccountDeletion() {
    if (requestBusy) return
    if (!confirmingDelete) {
      setConfirmingDelete(true)
      return
    }
    setRequestBusy('account_deletion')
    setRequestMessage(null)
    try {
      await submitAccountRequest('account_deletion')
      setRequestMessage('アカウント削除の請求を受け付けました。運営が確認のうえ対応します。')
      setConfirmingDelete(false)
    } catch (e) {
      setRequestMessage(e instanceof Error ? e.message : '請求に失敗しました')
    } finally {
      setRequestBusy(null)
    }
  }

  const verifiedOnlyOn = flow.safetyPrefs.contactScope === 'verified'

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
            sub="オンにすると「いま遊べる」に表示されます"
            divider={false}
            right={
              <Toggle
                on={flow.safetyPrefs.showOnline}
                onToggle={() => flow.setSafetyPref('showOnline', !flow.safetyPrefs.showOnline)}
              />
            }
          />
        </Card>

        <SectionLabel>通知</SectionLabel>
        <Card>
          <ListRow
            label="誘い・メッセージ"
            right={
              <Toggle
                on={isBackendConfigured ? (prefs?.notifyInvites ?? true) : true}
                onToggle={isBackendConfigured ? () => togglePref('notifyInvites') : undefined}
              />
            }
          />
          <ListRow
            label="フレンドの「いま遊べる」"
            right={
              <Toggle
                on={isBackendConfigured ? (prefs?.notifyOnlineFriends ?? true) : true}
                onToggle={isBackendConfigured ? () => togglePref('notifyOnlineFriends') : undefined}
              />
            }
          />
          <ListRow
            label="おすすめマッチ"
            divider={false}
            right={
              <Toggle
                on={isBackendConfigured ? (prefs?.notifyRecommendations ?? false) : false}
                onToggle={isBackendConfigured ? () => togglePref('notifyRecommendations') : undefined}
              />
            }
          />
        </Card>
        {prefsError && <span style={{ fontSize: 10.5, color: C.avatarPink, marginTop: -8 }}>{prefsError}</span>}

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
            right={
              <Toggle
                on={verifiedOnlyOn}
                onToggle={() => flow.setSafetyPref('contactScope', verifiedOnlyOn ? 'all' : 'verified')}
              />
            }
          />
          <ListRow label="ブロックリスト" onClick={() => flow.go('blockList')} />
          <ListRow label="安全センター" onClick={() => flow.go('safety')} />
          <ListRow
            label="データのダウンロード請求"
            divider={false}
            onClick={isBackendConfigured ? handleDataExport : undefined}
            right={requestBusy === 'data_export' ? <span style={{ fontSize: 10, color: C.muted }}>送信中…</span> : undefined}
          />
        </Card>

        <SectionLabel>規約・ポリシー</SectionLabel>
        <Card>
          <ListRow label="利用規約" onClick={() => flow.openLegalDoc('terms')} />
          <ListRow label="プライバシーポリシー" onClick={() => flow.openLegalDoc('privacy')} />
          <ListRow label="特定商取引法に基づく表記" onClick={() => flow.openLegalDoc('tokushoho')} />
          <ListRow label="資金決済法に基づく表示" onClick={() => flow.openLegalDoc('shikin')} />
          <ListRow
            label="みまもり（監視）について"
            divider={false}
            onClick={() => flow.openLegalDoc('mimamori')}
          />
        </Card>

        <SectionLabel>アカウント</SectionLabel>
        <Card>
          <ListRow
            label="メール・ログイン方法"
            sub={isBackendConfigured ? email ?? undefined : undefined}
            divider={isBackendConfigured}
            right={<></>}
          />
          {isBackendConfigured && <ListRow label="ログアウト" onClick={flow.signOut} />}
          <ListRow
            label={confirmingDelete ? 'もう一度タップで削除を請求' : 'アカウントを削除'}
            danger
            divider={false}
            onClick={isBackendConfigured ? handleAccountDeletion : undefined}
            right={requestBusy === 'account_deletion' ? <span style={{ fontSize: 10, color: C.muted }}>送信中…</span> : undefined}
          />
        </Card>
        {requestMessage && (
          <div
            style={{
              background: C.surfaceLavender,
              border: `1.5px solid ${C.lavender}`,
              borderRadius: 8,
              padding: '10px 12px',
              fontSize: 11.5,
              color: C.body,
              lineHeight: 1.6,
            }}
          >
            {requestMessage}
          </div>
        )}

        {isBackendConfigured && flow.isAdmin && (
          <>
            <SectionLabel>管理者メニュー</SectionLabel>
            <Card>
              <ListRow
                label="本人確認の審査"
                sub="提出された書類・顔写真を確認して承認/却下"
                divider={false}
                onClick={() => flow.go('adminVerifications')}
              />
            </Card>
          </>
        )}
      </div>
    </Screen>
  )
}
