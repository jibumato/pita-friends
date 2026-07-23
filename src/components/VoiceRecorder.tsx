/**
 * 声の挨拶(ボイスプロフィール)の録音・管理UI。自分のプロフィール用。
 * 15秒まで。B方式(即公開)。録音時に注意書きを表示する。
 */
import { useEffect, useRef, useState } from 'react'
import { color as C } from '../theme/tokens'
import { deleteVoiceGreeting, fetchOwnVoiceGreeting, uploadVoiceGreeting, type OwnVoice } from '../lib/queries'

const MAX_SECONDS = 15

type Rec = { blob: Blob; url: string; seconds: number }

export default function VoiceRecorder() {
  const [saved, setSaved] = useState<OwnVoice>(null)
  const [loading, setLoading] = useState(true)
  const [recording, setRecording] = useState(false)
  const [remaining, setRemaining] = useState(MAX_SECONDS)
  const [draft, setDraft] = useState<Rec | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const mediaRef = useRef<MediaRecorder | null>(null)
  const chunksRef = useRef<Blob[]>([])
  const startedRef = useRef(0)
  const timerRef = useRef<number | null>(null)

  useEffect(() => {
    fetchOwnVoiceGreeting()
      .then(setSaved)
      .catch(() => undefined)
      .finally(() => setLoading(false))
  }, [])

  useEffect(() => {
    return () => {
      if (timerRef.current) window.clearInterval(timerRef.current)
      mediaRef.current?.stream.getTracks().forEach((t) => t.stop())
    }
  }, [])

  async function start() {
    setError(null)
    if (draft) URL.revokeObjectURL(draft.url)
    setDraft(null)
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      const mr = new MediaRecorder(stream)
      chunksRef.current = []
      mr.ondataavailable = (e) => e.data.size > 0 && chunksRef.current.push(e.data)
      mr.onstop = () => {
        stream.getTracks().forEach((t) => t.stop())
        const blob = new Blob(chunksRef.current, { type: mr.mimeType || 'audio/webm' })
        const secs = Math.min(MAX_SECONDS, Math.max(1, Math.round((Date.now() - startedRef.current) / 1000)))
        setDraft({ blob, url: URL.createObjectURL(blob), seconds: secs })
        setRecording(false)
        if (timerRef.current) window.clearInterval(timerRef.current)
      }
      mediaRef.current = mr
      startedRef.current = Date.now()
      mr.start()
      setRecording(true)
      setRemaining(MAX_SECONDS)
      timerRef.current = window.setInterval(() => {
        const left = MAX_SECONDS - Math.floor((Date.now() - startedRef.current) / 1000)
        setRemaining(left)
        if (left <= 0) stop()
      }, 250)
    } catch {
      setError('マイクを使えませんでした。ブラウザのマイク許可を確認してください。')
    }
  }

  function stop() {
    if (mediaRef.current && mediaRef.current.state !== 'inactive') mediaRef.current.stop()
  }

  async function save() {
    if (!draft || busy) return
    setBusy(true)
    setError(null)
    try {
      const url = await uploadVoiceGreeting(draft.blob, draft.seconds)
      setSaved({ url, seconds: draft.seconds })
      URL.revokeObjectURL(draft.url)
      setDraft(null)
    } catch {
      setError('保存に失敗しました。もう一度お試しください。')
    } finally {
      setBusy(false)
    }
  }

  async function removeSaved() {
    if (busy) return
    setBusy(true)
    try {
      await deleteVoiceGreeting()
      setSaved(null)
    } catch {
      setError('削除に失敗しました。')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      <span style={{ fontSize: 10.5, color: C.muted, lineHeight: 1.7 }}>
        15秒までの声の挨拶をプロフィールに載せられます。外部連絡先の交換・出会い目的・不適切な発言は禁止です（違反は削除・利用停止の対象）。
      </span>

      {loading ? (
        <span style={{ fontSize: 12, color: C.muted }}>読み込み中…</span>
      ) : saved && !draft ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <audio src={saved.url} controls style={{ width: '100%', height: 38 }} />
          <div style={{ display: 'flex', gap: 8 }}>
            <span onClick={start} style={btn(C.white)}>録り直す</span>
            <span onClick={removeSaved} style={{ ...btn(C.avatarPink), opacity: busy ? 0.6 : 1 }}>削除</span>
          </div>
        </div>
      ) : draft ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <audio src={draft.url} controls style={{ width: '100%', height: 38 }} />
          <span style={{ fontSize: 10.5, color: C.muted }}>{draft.seconds}秒。この内容で公開しますか？</span>
          <div style={{ display: 'flex', gap: 8 }}>
            <span onClick={save} style={{ ...btn(C.lime), opacity: busy ? 0.6 : 1 }}>{busy ? '保存中…' : 'この挨拶を公開'}</span>
            <span onClick={start} style={btn(C.white)}>録り直す</span>
          </div>
        </div>
      ) : recording ? (
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <span style={{ width: 12, height: 12, borderRadius: '50%', background: C.badge, animation: 'floaty 1s ease-in-out infinite' }} />
          <span style={{ fontSize: 13, color: C.ink }}>録音中… 残り {Math.max(0, remaining)}秒</span>
          <span onClick={stop} style={{ ...btn(C.white), marginLeft: 'auto' }}>停止</span>
        </div>
      ) : (
        <span onClick={start} style={{ ...btn(C.fill), color: '#fff', alignSelf: 'flex-start', padding: '10px 18px' }}>
          🎤 声を録音する
        </span>
      )}

      {error && <span style={{ fontSize: 11, color: C.avatarPink }}>{error}</span>}
    </div>
  )
}

function btn(bg: string): React.CSSProperties {
  return {
    cursor: 'pointer',
    fontSize: 12,
    color: bg === C.fill ? '#fff' : C.ink,
    background: bg,
    border: `1.5px solid ${C.border}`,
    borderRadius: 8,
    padding: '9px 14px',
    textAlign: 'center',
    flex: 1,
  }
}
