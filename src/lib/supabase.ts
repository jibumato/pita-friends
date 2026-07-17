/**
 * Supabaseクライアント初期化。
 *
 * 重要: このアプリはPhase 1〜2の間、バックエンドなしでも全画面を
 * モック駆動で操作できるプロトタイプとして作られてきた(README参照)。
 * その体験を壊さないよう、環境変数が未設定の場合は `supabase` を
 * `null` にしてデモモードにフォールバックする。バックエンド機能を
 * 使う画面側は必ず `isBackendConfigured` を確認してから `supabase`
 * を使うこと。
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import type { Database } from './database.types'

const url = import.meta.env.VITE_SUPABASE_URL
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

export const isBackendConfigured = Boolean(url && anonKey)

export const supabase: SupabaseClient<Database> | null = isBackendConfigured
  ? createClient<Database>(url as string, anonKey as string, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
      },
    })
  : null

if (!isBackendConfigured && import.meta.env.DEV) {
  // eslint-disable-next-line no-console
  console.info(
    '[pita-friends] VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY が未設定のため、デモモード(モックデータ)で起動します。バックエンド接続手順は docs/backend-setup.md を参照。',
  )
}

/** バックエンド未接続時に呼ばれた場合、原因が分かるエラーを投げる。 */
export function requireSupabase(): SupabaseClient<Database> {
  if (!supabase) {
    throw new Error(
      'Supabaseが設定されていません。.env.local に VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY を設定してください(docs/backend-setup.md参照)。',
    )
  }
  return supabase
}
