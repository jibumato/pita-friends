/**
 * 認証ヘルパー。Supabase Auth(メール+パスワード)の薄いラッパー。
 * UI側の結線(サインアップ/ログイン画面)は別途実装する。
 * バックエンド未設定時(デモモード)はすべて例外を投げる —
 * 呼び出し側は `isBackendConfigured` を先に確認すること。
 */
import type { Session, User } from '@supabase/supabase-js'
import { requireSupabase } from './supabase'

export type SignUpResult = {
  user: User
  /** プロジェクト設定でメール確認が必須な場合、サインアップ直後はnull(未ログイン状態)。 */
  session: Session | null
}

export async function signUpWithEmail(email: string, password: string): Promise<SignUpResult> {
  const { data, error } = await requireSupabase().auth.signUp({ email, password })
  if (error) throw error
  if (!data.user) throw new Error('サインアップに失敗しました')
  return { user: data.user, session: data.session }
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

/** 認証まわりのエラーを、画面に出してよい日本語メッセージに変換する。 */
export function authErrorMessage(e: unknown): string {
  const raw = e instanceof Error ? e.message : ''
  if (/Failed to fetch|NetworkError|network/i.test(raw)) {
    return 'ネットワークに接続できませんでした。しばらくしてから再度お試しください。'
  }
  if (/Invalid login credentials/i.test(raw)) {
    return 'メールアドレスまたはパスワードが正しくありません。'
  }
  if (/already registered|already exists/i.test(raw)) {
    return 'このメールアドレスはすでに登録されています。ログインをお試しください。'
  }
  if (/Password should be at least/i.test(raw)) {
    return 'パスワードは6文字以上で設定してください。'
  }
  return raw || '予期しないエラーが発生しました。時間をおいて再度お試しください。'
}
