import { useEffect, useRef, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { ChevronLeft, Shield } from '../components/Icon'
import { usePress } from '../hooks/usePress'
import { isBackendConfigured } from '../lib/supabase'
import {
  fetchLatestVerificationStatus,
  submitIdentityVerification,
  declareResidency,
  fetchMyResidencyDeclaration,
} from '../lib/queries'

/**
 * 居住地の自己申告(規約 第3条3項・突合表G4)。
 *
 * 条文には「日本国内に居住する個人に限る」と書いてあったのに、
 * **申告欄も確認も無かった。** 弁護士は自己申告で足るとしたが、
 * 「尋ねた」という事実が残らなければ利用条件として機能しない。
 *
 * ここに置いたのは、**本人確認と同じ場面で聞くのが自然**だから。
 * 登録の入口に増やすと、何の話か分からないまま押す欄になる。
 *
 * ⚠️ 国籍は尋ねない。条文どおり居住地だけを扱う。
 */
function ResidencyCheck({
  checked,
  onChange,
}: {
  checked: boolean
  onChange: (v: boolean) => void
}) {
  return (
    <label
      style={{
        display: 'flex',
        gap: 9,
        alignItems: 'flex-start',
        cursor: 'pointer',
        background: C.surface,
        border: `1.5px solid ${C.border}`,
        borderRadius: 10,
        padding: '11px 13px',
      }}
    >
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        style={{ marginTop: 2, flex: 'none' }}
      />
      <span style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
        <span style={{ fontSize: 11.5, color: C.ink, lineHeight: 1.6 }}>
          <b>日本国内に住んでいます</b>
        </span>
        <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.75 }}>
          ピタフレは日本国内にお住まいの方に限りご利用いただけます。
          適用される法律・裁判所、本人確認のしかた、使えるお支払いと振込の方法が
          国ごとに違うためで、
          <b style={{ color: C.ink }}>国籍によるものではありません</b>。
          旅行や出張で一時的に海外にいる間も、そのままお使いいただけます。
        </span>
      </span>
    </label>
  )
}

function StepRow({
  n,
  title,
  sub,
  status,
}: {
  n: number
  title: string
  sub: string
  status: 'done' | 'pending'
}) {
  return (
    <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
      <div
        style={{
          width: 36,
          height: 36,
          borderRadius: 8,
          background: C.lavender,
          border: `1.5px solid ${C.border}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          color: '#fff',
          fontSize: 15,
        }}
      >
        {n}
      </div>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
        <span style={{ fontSize: 13, color: C.ink }}>{title}</span>
        <span style={{ fontSize: 10.5, color: C.muted }}>{sub}</span>
      </div>
      <span style={{ fontSize: 16, color: status === 'done' ? C.lime : C.placeholder }}>
        {status === 'done' ? '✓' : '…'}
      </span>
    </div>
  )
}

/**
 * 提出前の注意書き。本人確認の目的では取得してはならない情報(本籍地・個人番号・
 * 健康保険証の記号番号等)を、ユーザー側で隠してもらうための案内。
 * マイナンバーカードは裏面に個人番号があるため、書類の例示からは外している。
 */
function MaskingNotice() {
  return (
    <div
      style={{
        background: C.surface,
        border: `1.5px solid ${C.border}`,
        borderRadius: 10,
        padding: '11px 13px',
        display: 'flex',
        flexDirection: 'column',
        gap: 5,
      }}
    >
      <span style={{ fontSize: 11.5, color: C.ink }}>撮影前におねがいします</span>
      <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.75 }}>
        次の情報は本人確認に使わないため、
        <b style={{ color: C.ink }}>付箋や指で隠して撮影</b>
        してください。
      </span>
      <ul style={{ margin: 0, paddingLeft: 17, display: 'flex', flexDirection: 'column', gap: 3 }}>
        <li style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>本籍地(旧い運転免許証に記載があります)</li>
        <li style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>マイナンバー(個人番号)</li>
        <li style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>健康保険証の記号・番号・保険者番号</li>
      </ul>
      <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.75 }}>
        <b style={{ color: C.ink }}>マイナンバーカードは表面のみ</b>
        ご利用ください(裏面は個人番号が記載されているためお預かりできません)。写り込んでいた場合は、確認前に運営で消去します。
      </span>
    </div>
  )
}

/** 書類/顔写真を撮影・選択させるカード。ファイル選択後はファイル名を表示する。 */
function PhotoPicker({
  n,
  title,
  sub,
  file,
  capture,
  onPick,
}: {
  n: number
  title: string
  sub: string
  file: File | null
  capture: 'environment' | 'user'
  onPick: (f: File) => void
}) {
  const inputRef = useRef<HTMLInputElement>(null)
  return (
    <div
      onClick={() => inputRef.current?.click()}
      style={{ display: 'flex', gap: 12, alignItems: 'center', cursor: 'pointer' }}
    >
      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        capture={capture}
        style={{ display: 'none' }}
        onChange={(e) => {
          const f = e.target.files?.[0]
          if (f) onPick(f)
        }}
      />
      <div
        style={{
          width: 36,
          height: 36,
          borderRadius: 8,
          background: file ? C.lime : C.lavender,
          border: `1.5px solid ${C.border}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          color: file ? C.ink : '#fff',
          fontSize: 15,
        }}
      >
        {n}
      </div>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
        <span style={{ fontSize: 13, color: C.ink }}>{title}</span>
        <span style={{ fontSize: 10.5, color: C.muted }}>{file ? file.name : sub}</span>
      </div>
      <span style={{ fontSize: 16, color: file ? C.lime : C.placeholder }}>{file ? '✓' : '📷'}</span>
    </div>
  )
}

export default function Verify({ flow }: { flow: Flow }) {
  const cta = usePress(`3px 3px 0 ${C.shadowCol}`)
  const [statusChecked, setStatusChecked] = useState(!isBackendConfigured)
  const [existingStatus, setExistingStatus] = useState<'pending' | 'verified' | 'rejected' | null>(null)
  const [documentFile, setDocumentFile] = useState<File | null>(null)
  const [selfieFile, setSelfieFile] = useState<File | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const [submitted, setSubmitted] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // 規約 第3条3項の自己申告。バックエンド未接続のときは true にしておく
  // (ハリボテ状態で押せないボタンを作らない)
  const [residency, setResidency] = useState(!isBackendConfigured)

  useEffect(() => {
    if (!isBackendConfigured || !flow.userId) {
      setStatusChecked(true)
      return
    }
    let active = true
    fetchLatestVerificationStatus(flow.userId)
      .then((info) => {
        if (active) setExistingStatus(info?.status ?? null)
      })
      .catch((err) => console.warn('[pita-friends] 本人確認ステータスの取得に失敗:', err))
      .finally(() => {
        if (active) setStatusChecked(true)
      })
    // 再提出のときに、前回の申告を毎回入れ直させない
    fetchMyResidencyDeclaration()
      .then((d) => {
        if (active && d.declaredJapan) setResidency(true)
      })
      .catch((err) => console.warn('[pita-friends] 居住地の申告の取得に失敗:', err))
    return () => {
      active = false
    }
  }, [flow.userId])

  async function handleSubmit() {
    if (!documentFile || !selfieFile || !flow.userId || !residency) return
    setSubmitting(true)
    setError(null)
    try {
      // **書類より先に申告を記録する。** 0081 のトリガが本人確認の
      // INSERT を止めるので、順序を逆にすると画像だけが残る
      await declareResidency(true)
      await submitIdentityVerification(flow.userId, documentFile, selfieFile)
      setSubmitted(true)
    } catch (e) {
      setError(e instanceof Error ? e.message : '提出に失敗しました。時間をおいて再度お試しください。')
    } finally {
      setSubmitting(false)
    }
  }

  const showUploadForm = isBackendConfigured && statusChecked && !submitted && existingStatus !== 'pending' && existingStatus !== 'verified'
  const canSubmit = !!documentFile && !!selfieFile && residency && !submitting

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:44" />
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 20px 0' }}>
        <div onClick={() => flow.go('consent')} style={{ cursor: 'pointer' }}>
          <ChevronLeft />
        </div>
        <span style={{ fontSize: 11, color: C.muted }}>STEP 1 / 2</span>
      </div>
      <div
        style={{
          flex: 1,
          display: 'flex',
          flexDirection: 'column',
          padding: '16px 22px 0',
          gap: 18,
        }}
      >
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={{ fontSize: 22, color: C.ink, lineHeight: 1.4 }}>
            まず本人確認を
            <br />
            おねがいします
          </span>
          <span style={{ fontSize: 12, color: C.muted, lineHeight: 1.7 }}>
            {isBackendConfigured
              ? '安心して遊べる場をつくるため、全員に本人確認をお願いしています。現在は運営が一件ずつ内容を確認しており、確認までに数日いただく場合があります。'
              : '安心して遊べる場をつくるため、全員に本人確認をお願いしています。確認済みバッジが付き、マッチ率も上がります。'}
          </span>
        </div>

        {!isBackendConfigured && (
          <div
            style={{
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 12,
              boxShadow: `4px 4px 0 ${C.shadowCol}`,
              padding: 16,
              display: 'flex',
              flexDirection: 'column',
              gap: 14,
            }}
          >
            <StepRow n={1} title="本人確認書類を撮影" sub="運転免許証・パスポート等" status="done" />
            <div style={{ height: 1.5, background: C.divider }} />
            <StepRow n={2} title="顔写真で本人照合" sub="1分で完了 · 書類は暗号化保存" status="pending" />
          </div>
        )}

        {isBackendConfigured && showUploadForm && (
          <div
            style={{
              background: C.white,
              border: `1.5px solid ${C.border}`,
              borderRadius: 12,
              boxShadow: `4px 4px 0 ${C.shadowCol}`,
              padding: 16,
              display: 'flex',
              flexDirection: 'column',
              gap: 14,
            }}
          >
            <PhotoPicker
              n={1}
              title="本人確認書類を撮影"
              sub="運転免許証・パスポート等(タップして撮影/選択)"
              file={documentFile}
              capture="environment"
              onPick={setDocumentFile}
            />
            <MaskingNotice />
            <div style={{ height: 1.5, background: C.divider }} />
            <PhotoPicker
              n={2}
              title="顔写真を撮影"
              sub="本人照合用(タップして撮影/選択)"
              file={selfieFile}
              capture="user"
              onPick={setSelfieFile}
            />
            <div style={{ height: 1.5, background: C.divider }} />
            <ResidencyCheck checked={residency} onChange={setResidency} />
            {existingStatus === 'rejected' && (
              <span style={{ fontSize: 10.5, color: C.avatarPink, lineHeight: 1.6 }}>
                前回の申請は承認されませんでした。書類・写真を選び直して再提出してください。
              </span>
            )}
            {error && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{error}</span>}
          </div>
        )}

        {isBackendConfigured && (submitted || existingStatus === 'pending') && (
          <div
            style={{
              background: C.surfaceLavender,
              border: `1.5px solid ${C.lavender}`,
              borderRadius: 12,
              padding: 16,
              display: 'flex',
              flexDirection: 'column',
              gap: 6,
            }}
          >
            <span style={{ fontSize: 13, color: C.ink }}>📋 審査中です</span>
            <span style={{ fontSize: 10.5, color: C.body, lineHeight: 1.7 }}>
              運営が内容を確認しています。通常1〜3営業日ほどお時間をいただきます。審査中もアプリの利用は続けられます(ピタメイト掲載のみ審査完了までお待ちください)。
            </span>
          </div>
        )}

        {isBackendConfigured && existingStatus === 'verified' && (
          <div
            style={{
              background: C.lime,
              border: `1.5px solid ${C.border}`,
              borderRadius: 12,
              padding: 16,
              display: 'flex',
              alignItems: 'center',
              gap: 10,
            }}
          >
            <span style={{ fontSize: 18 }}>✓</span>
            <span style={{ fontSize: 12.5, color: C.ink }}>本人確認が完了しています</span>
          </div>
        )}

        <div
          style={{
            background: C.surfaceLavender,
            border: `1.5px solid ${C.lavender}`,
            borderRadius: 8,
            padding: '10px 12px',
            display: 'flex',
            gap: 8,
            alignItems: 'flex-start',
          }}
        >
          <Shield style={{ flex: 'none', marginTop: 1 }} />
          <span style={{ fontSize: 10.5, lineHeight: 1.6, color: C.body }}>
            年齢確認を兼ねています。18歳未満はご利用いただけません。
            {isBackendConfigured
              ? '審査完了後、書類・顔写真の画像は運営が削除します。'
              : '書類・顔写真の画像は照合が終わりしだい削除し、確認結果だけを保存します。'}
          </span>
        </div>
      </div>
      <div style={{ padding: '12px 22px 30px' }}>
        <div
          className="pita-press"
          onClick={() => {
            if (!isBackendConfigured) {
              flow.go('setup')
              return
            }
            if (showUploadForm) {
              if (canSubmit) void handleSubmit()
              return
            }
            flow.go('setup')
          }}
          {...cta.handlers}
          style={{
            cursor: isBackendConfigured && showUploadForm && !canSubmit ? 'not-allowed' : 'pointer',
            opacity: isBackendConfigured && showUploadForm && !canSubmit ? 0.55 : 1,
            background: C.ctaBg,
            color: C.ctaFg,
            borderRadius: 8,
            padding: '15px 0',
            textAlign: 'center',
            fontSize: 15,
            ...cta.style,
          }}
        >
          {isBackendConfigured && showUploadForm
            ? submitting
              ? '提出中…'
              : '提出して審査へ ▶'
            : isBackendConfigured && submitted
              ? 'つづける ▶'
              : '本人確認を始める ▶'}
        </div>
      </div>
    </Screen>
  )
}
