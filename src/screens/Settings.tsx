import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, SectionLabel, Card, ListRow, Toggle } from '../components/Ui'
import { isBackendConfigured, supabase } from '../lib/supabase'
import { clickable } from '../hooks/clickable'
import {
  fetchNotificationPrefs,
  updateNotificationPrefs,
  submitAccountRequest,
  fetchMonitoringConsent,
  revokeMonitoringConsent,
  recordMonitoringConsent,
  type NotificationPrefs,
  type MonitoringConsentState,
} from '../lib/queries'
import { MONITORING_CONSENT_VERSION } from '../content/consentText'
import { installGuideAvailable, openInstallGuide } from '../lib/install'
import PushSettingsRows from '../components/PushSettingsRows'

/**
 * みまもりへの同意の撤回・再同意。
 *
 * 規約 第4条6項(弁護士回答 Q16 の文言):
 *   「撤回された場合、当社はメッセージ機能その他の利用者間のやりとりに関する
 *     機能の提供を停止します。この場合も、既に成立した予約の履行および換金の
 *     手続については、本規約の定めに従います。」
 *
 * **止まる範囲を画面に正確に書くこと。** 「一部機能が使えなくなります」のような
 * ぼかした書き方では、撤回するかどうかを判断できない。撤回は同意の任意性を支える
 * 導線なので、選べる形にしておく必要がある(Q19)。
 * 実際に止める範囲は 0074 のトリガが決めている。**片方を変えたら両方直すこと。**
 */
function MonitoringConsentRows() {
  const [state, setState] = useState<MonitoringConsentState | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [confirming, setConfirming] = useState(false)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchMonitoringConsent()
      .then((s) => active && setState(s))
      .catch(() => {
        /* 取得できなくても設定画面は開ける。撤回の導線だけ出さない */
      })
    return () => {
      active = false
    }
  }, [])

  async function apply(next: 'revoke' | 'agree') {
    if (busy) return
    setBusy(true)
    setError(null)
    try {
      if (next === 'revoke') await revokeMonitoringConsent()
      else await recordMonitoringConsent(MONITORING_CONSENT_VERSION)
      setState(await fetchMonitoringConsent())
      setConfirming(false)
    } catch (e) {
      setError(e instanceof Error ? e.message : '変更に失敗しました')
    } finally {
      setBusy(false)
    }
  }

  if (!isBackendConfigured || !state) {
    return <ListRow label="みまもりへの同意" sub="ログイン後に確認できます" />
  }

  if (!state.active) {
    return (
      <>
        <ListRow
          label="みまもりへの同意（撤回中）"
          sub={
            state.revokedAt
              ? `${state.revokedAt.toLocaleDateString('ja-JP')}に撤回。メッセージ・誘い・募集・新しい予約が停止中です`
              : 'メッセージ・誘い・募集・新しい予約が停止中です'
          }
          right={
            <span style={{ fontSize: 11, color: C.lavenderText, whiteSpace: 'nowrap' }}>
              {busy ? '…' : '再開する'}
            </span>
          }
          onClick={() => void apply('agree')}
        />
        {error && (
          <div style={{ padding: '0 14px 10px' }}>
            <span style={{ fontSize: 10.5, color: C.avatarPink }}>{error}</span>
          </div>
        )}
      </>
    )
  }

  return (
    <>
      <ListRow
        label="みまもりへの同意"
        sub={
          state.unrecorded
            ? '同意いただいています'
            : state.agreedAt
              ? `${state.agreedAt.toLocaleDateString('ja-JP')}に同意（版 ${state.version}）`
              : '同意いただいています'
        }
        right={
          <span style={{ fontSize: 11, color: C.muted, whiteSpace: 'nowrap' }}>
            {confirming ? '' : '撤回する'}
          </span>
        }
        onClick={() => setConfirming(true)}
      />
      {confirming && (
        <div
          style={{
            padding: '4px 14px 14px',
            display: 'flex',
            flexDirection: 'column',
            gap: 8,
            borderBottom: `1.5px solid ${C.divider}`,
          }}
        >
          <span style={{ fontSize: 11.5, color: C.body, lineHeight: 1.8 }}>
            みまもりは、ピタフレの安全を守るための仕組みです。同意を撤回すると、
            <b style={{ color: C.ink }}>
              メッセージの送受信・誘いの送受信・募集の投稿と参加・新しい予約
            </b>
            がご利用いただけなくなります。
            <br />
            <b style={{ color: C.ink }}>
              すでに成立している予約の進行（チェックイン・完了・キャンセル）と、換金の手続は
              そのまま続けられます。
            </b>
            <br />
            いつでもこの画面から同意して、再開できます。
          </span>
          <div style={{ display: 'grid', gridAutoFlow: 'column', gap: 8 }}>
            <div
              onClick={() => setConfirming(false)}
              {...clickable(() => setConfirming(false), 'やめる')}
              style={{
                cursor: 'pointer',
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '10px 0',
                textAlign: 'center',
                fontSize: 12.5,
                color: C.ink,
                background: C.white,
              }}
            >
              やめる
            </div>
            <div
              onClick={() => void apply('revoke')}
              {...clickable(() => void apply('revoke'), '同意を撤回する')}
              style={{
                cursor: 'pointer',
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '10px 0',
                textAlign: 'center',
                fontSize: 12.5,
                color: '#E5484D',
                background: C.white,
              }}
            >
              {busy ? '…' : '同意を撤回する'}
            </div>
          </div>
          {error && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{error}</span>}
        </div>
      )}
    </>
  )
}

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
          {/* 自動の案内は抑制されると出なくなるので、ここには常に置いておく。
              すでに追加済み・PCでは行そのものを出さない。 */}
          {installGuideAvailable() && (
            <ListRow
              label="ホーム画面に追加"
              sub="アイコンから開けるようにする"
              onClick={openInstallGuide}
            />
          )}
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
          {/* ロック画面へのプッシュ(0064)。下の3つは「何を」の設定で、
              これは「どうやって」の設定。混ぜると
              「アプリ内では見たいがロック画面には出したくない」が表現できない */}
          <PushSettingsRows />
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
          <MonitoringConsentRows />
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
              {/* 締切のある作業(保留の解除・換金・通報)はこちら。
                  以前はすべて Supabase の SQL Editor でやっていた */}
              <ListRow
                label="運営コンソール"
                sub="保留・通報・換金・請求・健全性・操作記録"
                onClick={() => flow.go('adminConsole')}
              />
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
