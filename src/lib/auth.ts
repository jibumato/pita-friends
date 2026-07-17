/**
 * 認証ヘルパー。Supabase Auth(メール+パスワード)の薄いラッパー。
 * UI側の結線(サインアップ/ログイン画面)は別途実装する。
 * バックエンド未設定時(デモモード)はすべて例外を投げる —
 * 呼び出し側は `isBackendConfigured` を先に確認すること。
 */
import type { Session, User } from '@supabase/supabase-js'
import { requireSupabase } from './supabase'

export async function signUpWithEmail(email: string, password: string): Promise<User> {
  const { data, error } = await requireSupabase().auth.signUp({ email, password })
  if (error) throw error
  if (!data.user) throw new Error('サインアップに失敗しました(確認メールの確認が必要な場合があります)')
  return data.user
}

export async function signInWithEmail(email: string, password: string): Promise<User> {
  const { data, error } = await requireSupabase().auth.signInWithPassword({ email, password })
  if (error) throw error
  return data.user
}

export async function signOut(): Promise<void> {
  const { error } = await requireSupabase().auth.signOut()
  if (error) throw error
}

export async function getSession(): Promise<Session | null> {
  const { data, error } = await requireSupabase().auth.getSession()
  if (error) throw error
  return data.session
}

/** セッション変化(サインイン/サインアウト/トークン更新)を購読する。解除関数を返す。 */
export function onAuthStateChange(callback: (session: Session | null) => void): () => void {
  const {
    data: { subscription },
  } = requireSupabase().auth.onAuthStateChange((_event, session) => callback(session))
  return () => subscription.unsubscribe()
}
