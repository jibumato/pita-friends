/**
 * AvatarEditor — アイコン画像のアップロード・削除UI(自分用)。
 * 画像を選ぶと正方形に中央クロップし、512pxのWebPへ変換して即公開(B方式)。
 * avatar_path が null のときは頭文字＋カラーの既定アバターを表示する。
 * バックエンド未設定(デモ)時はローカルプレビューのみ反映する。
 *
 * - 通常表示: アイコン＋撮影バッジ＋変更/既定に戻す＋注意書き(Setup編集画面用)
 * - compact:  アイコン＋撮影バッジのみ。タップで即ファイル選択(マイページのアイコン用)
 */
import { useRef, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Avatar from './Avatar'
import { Upload } from './Icon'
import { isBackendConfigured } from '../lib/supabase'
import { uploadAvatar, deleteAvatar } from '../lib/queries'

const OUTPUT_SIZE = 512

/** 選んだ画像を正方形に中央クロップし、512pxのWebP Blobに変換する。 */
async function toSquareWebp(file: File): Promise<Blob> {
  const url = URL.createObjectURL(file)
  try {
    const img = await new Promise<HTMLImageElement>((resolve, reject) => {
      const el = new Image()
      el.onload = () => resolve(el)
      el.onerror = () => reject(new Error('画像を読み込めませんでした'))
      el.src = url
    })
    const side = Math.min(img.width, img.height)
    const sx = (img.width - side) / 2
    const sy = (img.height - side) / 2
    const canvas = document.createElement('canvas')
    canvas.width = OUTPUT_SIZE
    canvas.height = OUTPUT_SIZE
    const ctx = canvas.getContext('2d')
    if (!ctx) throw new Error('画像を変換できませんでした')
    ctx.drawImage(img, sx, sy, side, side, 0, 0, OUTPUT_SIZE, OUTPUT_SIZE)
    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, 'image/webp', 0.85),
    )
    if (!blob) throw new Error('画像を変換できませんでした')
    return blob
  } finally {
    URL.revokeObjectURL(url)
  }
}

export default function AvatarEditor({
  flow,
  size = 80,
  compact = false,
}: {
  flow: Flow
  size?: number
  compact?: boolean
}) {
  const inputRef = useRef<HTMLInputElement | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const initial = flow.nickname.charAt(0) || 'あ'
  const badge = Math.max(20, Math.round(size * 0.34))

  async function onPick(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    e.target.value = '' // 同じファイルを選び直せるようにリセット
    if (!file) return
    setError(null)
    if (!file.type.startsWith('image/')) {
      setError('画像ファイルを選んでください。')
      return
    }
    setBusy(true)
    try {
      const blob = await toSquareWebp(file)
      if (isBackendConfigured) {
        const url = await uploadAvatar(blob)
        flow.setAvatarUrl(url)
      } else {
        // デモ環境: アップロードせずローカルプレビューだけ反映する
        flow.setAvatarUrl(URL.createObjectURL(blob))
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : '画像をアップロードできませんでした。')
    } finally {
      setBusy(false)
    }
  }

  async function onRemove() {
    if (busy) return
    setBusy(true)
    setError(null)
    try {
      if (isBackendConfigured) await deleteAvatar()
      flow.setAvatarUrl(null)
    } catch {
      setError('削除に失敗しました。')
    } finally {
      setBusy(false)
    }
  }

  const pickable = (
    <div
      onClick={() => !busy && inputRef.current?.click()}
      role="button"
      aria-label="アイコン画像を選ぶ"
      style={{ position: 'relative', cursor: busy ? 'default' : 'pointer', display: 'inline-flex' }}
    >
      <Avatar initial={initial} color={C.lime} size={size} url={flow.avatarUrl} />
      <div
        style={{
          position: 'absolute',
          right: -4,
          bottom: -4,
          width: badge,
          height: badge,
          borderRadius: 8,
          background: C.fill,
          border: `1.5px solid ${C.border}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          opacity: busy ? 0.6 : 1,
        }}
      >
        <Upload size={Math.round(badge * 0.55)} color="#fff" />
      </div>
    </div>
  )

  if (compact) {
    return (
      <div style={{ display: 'inline-flex', flexDirection: 'column', alignItems: 'center', gap: 4 }}>
        <input ref={inputRef} type="file" accept="image/*" onChange={onPick} style={{ display: 'none' }} />
        {pickable}
        {error && <span style={{ fontSize: 9, color: C.avatarPink, maxWidth: size + 40, textAlign: 'center' }}>{error}</span>}
      </div>
    )
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8 }}>
      <input ref={inputRef} type="file" accept="image/*" onChange={onPick} style={{ display: 'none' }} />
      {pickable}
      <div style={{ display: 'flex', gap: 14, alignItems: 'center' }}>
        <span
          onClick={() => !busy && inputRef.current?.click()}
          style={{ fontSize: 11, color: C.lavender, cursor: busy ? 'default' : 'pointer' }}
        >
          {busy ? '処理中…' : flow.avatarUrl ? '画像を変更' : 'アイコン画像を選ぶ'}
        </span>
        {flow.avatarUrl && !busy && (
          <span onClick={onRemove} style={{ fontSize: 11, color: C.placeholder, cursor: 'pointer' }}>
            既定に戻す
          </span>
        )}
      </div>
      <span
        style={{
          fontSize: 9.5,
          color: C.placeholder,
          lineHeight: 1.6,
          textAlign: 'center',
          maxWidth: 260,
        }}
      >
        他人の写真や不適切な画像の使用は禁止です（違反は削除・利用停止の対象）。
      </span>
      {error && <span style={{ fontSize: 10.5, color: C.avatarPink }}>{error}</span>}
    </div>
  )
}
