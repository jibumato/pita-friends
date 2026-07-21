import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader, Toggle, Card, ListRow } from '../components/Ui'
import { Coin, Shield } from '../components/Icon'
import { GAMES } from '../flow'
import { usePress } from '../hooks/usePress'
import { isBackendConfigured } from '../lib/supabase'
import { fetchBankAccount, saveBankAccount, normalizeKanaName, type BankAccount } from '../lib/queries'

const EMPTY_ACCOUNT: BankAccount = {
  bankName: '',
  bankCode: '',
  branchName: '',
  branchCode: '',
  accountType: '普通',
  accountNumber: '',
  accountHolderKana: '',
}

/** 保存前のクライアント側チェック。問題があればメッセージを返す。 */
function validateAccount(a: BankAccount): string | null {
  if (!a.bankName.trim()) return '銀行名を入力してください'
  if (!/^[0-9]{4}$/.test(a.bankCode)) return '銀行コードは数字4桁で入力してください'
  if (!a.branchName.trim()) return '支店名を入力してください'
  if (!/^[0-9]{3}$/.test(a.branchCode)) return '支店コードは数字3桁で入力してください'
  if (!/^[0-9]{7}$/.test(a.accountNumber)) return '口座番号は数字7桁で入力してください(7桁未満は先頭に0を付けてください)'
  const kana = normalizeKanaName(a.accountHolderKana)
  if (!kana) return '口座名義(カナ)を入力してください'
  if (!/^[ァ-ヶー0-9A-Z()（）./\- 　]+$/.test(kana)) return '口座名義はカタカナで入力してください'
  return null
}

/** 振込先口座の登録フォーム。振込エラー(名義相違等)を防ぐため入力時に検証する。 */
function BankAccountSection() {
  const [account, setAccount] = useState<BankAccount>(EMPTY_ACCOUNT)
  const [registered, setRegistered] = useState(false)
  const [editing, setEditing] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    fetchBankAccount()
      .then((a) => {
        if (!active) return
        if (a) {
          setAccount(a)
          setRegistered(true)
        } else {
          setEditing(true)
        }
      })
      .catch(() => active && setEditing(true))
    return () => {
      active = false
    }
  }, [])

  const set = (patch: Partial<BankAccount>) => setAccount((a) => ({ ...a, ...patch }))

  async function handleSave() {
    if (busy) return
    const problem = validateAccount(account)
    if (problem) {
      setError(problem)
      return
    }
    setBusy(true)
    setError(null)
    setMessage(null)
    try {
      await saveBankAccount(account)
      setAccount((a) => ({ ...a, accountHolderKana: normalizeKanaName(a.accountHolderKana) }))
      setRegistered(true)
      setEditing(false)
      setMessage('振込先を保存しました')
    } catch (e) {
      setError(e instanceof Error ? e.message : '振込先の保存に失敗しました')
    } finally {
      setBusy(false)
    }
  }

  const inputStyle = {
    background: C.surface,
    border: `1.5px solid ${C.border}`,
    borderRadius: 6,
    padding: '9px 12px',
    fontSize: 12.5,
    color: C.ink,
    outline: 'none',
    fontFamily: 'inherit',
    minWidth: 0,
  } as const

  return (
    <>
      <span style={{ fontSize: 12, color: C.muted }}>振込先口座(報酬の受け取り)</span>
      <div
        style={{
          background: C.white,
          border: `1.5px solid ${C.border}`,
          borderRadius: 8,
          padding: '13px 14px',
          display: 'flex',
          flexDirection: 'column',
          gap: 8,
        }}
      >
        {registered && !editing ? (
          <>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span
                style={{
                  fontSize: 10,
                  color: C.ink,
                  background: C.lime,
                  border: `1.5px solid ${C.border}`,
                  padding: '2px 8px',
                  borderRadius: 4,
                }}
              >
                登録済み
              </span>
              <span style={{ fontSize: 11.5, color: C.body }}>
                {account.bankName} {account.branchName} {account.accountType} •••{account.accountNumber.slice(-3)}
              </span>
            </div>
            <span
              onClick={() => {
                setEditing(true)
                setMessage(null)
              }}
              style={{ cursor: 'pointer', fontSize: 11.5, color: C.lavenderText, textDecoration: 'underline' }}
            >
              口座情報を変更する
            </span>
          </>
        ) : (
          <>
            <span style={{ fontSize: 11, color: C.body, lineHeight: 1.6 }}>
              報酬コインの換金(銀行振込)に使う口座です。名義はご本人のものに限ります。
            </span>
            <div style={{ display: 'flex', gap: 8 }}>
              <input
                value={account.bankName}
                onChange={(e) => set({ bankName: e.target.value })}
                placeholder="銀行名"
                style={{ ...inputStyle, flex: 2 }}
              />
              <input
                value={account.bankCode}
                onChange={(e) => set({ bankCode: e.target.value.replace(/[^0-9]/g, '').slice(0, 4) })}
                placeholder="コード4桁"
                inputMode="numeric"
                style={{ ...inputStyle, flex: 1 }}
              />
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              <input
                value={account.branchName}
                onChange={(e) => set({ branchName: e.target.value })}
                placeholder="支店名"
                style={{ ...inputStyle, flex: 2 }}
              />
              <input
                value={account.branchCode}
                onChange={(e) => set({ branchCode: e.target.value.replace(/[^0-9]/g, '').slice(0, 3) })}
                placeholder="コード3桁"
                inputMode="numeric"
                style={{ ...inputStyle, flex: 1 }}
              />
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              <div style={{ flex: 1, display: 'flex', gap: 6 }}>
                {(['普通', '当座'] as const).map((t) => (
                  <span
                    key={t}
                    onClick={() => set({ accountType: t })}
                    style={{
                      cursor: 'pointer',
                      flex: 1,
                      textAlign: 'center',
                      fontSize: 11.5,
                      padding: '9px 0',
                      borderRadius: 6,
                      border: `1.5px solid ${C.border}`,
                      color: account.accountType === t ? C.lime : C.ink,
                      background: account.accountType === t ? C.fill : C.white,
                    }}
                  >
                    {t}
                  </span>
                ))}
              </div>
              <input
                value={account.accountNumber}
                onChange={(e) => set({ accountNumber: e.target.value.replace(/[^0-9]/g, '').slice(0, 7) })}
                placeholder="口座番号7桁"
                inputMode="numeric"
                style={{ ...inputStyle, flex: 1.4 }}
              />
            </div>
            <input
              value={account.accountHolderKana}
              onChange={(e) => set({ accountHolderKana: e.target.value })}
              placeholder="口座名義(カナ) 例: ヤマダ ハナコ"
              style={inputStyle}
            />
            <div
              onClick={handleSave}
              style={{
                cursor: busy ? 'not-allowed' : 'pointer',
                opacity: busy ? 0.6 : 1,
                textAlign: 'center',
                fontSize: 12.5,
                color: C.ink,
                background: C.lime,
                border: `1.5px solid ${C.border}`,
                borderRadius: 6,
                padding: '9px 0',
              }}
            >
              {busy ? '保存中…' : 'この口座を保存する'}
            </div>
          </>
        )}
        {error && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{error}</span>}
        {message && <span style={{ fontSize: 10.5, color: C.lavenderText }}>{message}</span>}
      </div>
    </>
  )
}

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

        {flow.hostSettingsError && (
          <div
            style={{
              background: C.avatarPink,
              border: `1.5px solid ${C.border}`,
              borderRadius: 8,
              padding: '10px 12px',
              fontSize: 11.5,
              color: C.ink,
              lineHeight: 1.6,
            }}
          >
            {flow.hostSettingsError}
          </div>
        )}

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

        {isBackendConfigured && <BankAccountSection />}

        <span style={{ fontSize: 12, color: C.muted }}>ひとことメッセージ</span>
        <textarea
          value={h.bio}
          onChange={(e) => flow.setHostPref('bio', e.target.value)}
          maxLength={200}
          placeholder="ゴールド帯でまったり回してます。初心者さんも歓迎です！"
          style={{
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            padding: '12px 14px',
            minHeight: 60,
            fontSize: 12.5,
            color: C.ink,
            resize: 'none',
            fontFamily: 'inherit',
            outline: 'none',
          }}
        />

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
