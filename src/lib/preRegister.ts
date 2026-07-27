/**
 * 公開前の事前登録。SNSの告知から来た人に、公開時のお知らせを送るための名簿。
 *
 * アカウント登録(Supabase Auth)とは別物。ここではパスワードも本人確認も
 * 求めない。集めるのはメールアドレスだけで、使い道も「公開のお知らせ」に限る。
 *
 * **登録済みかどうかは呼び出し側に返らない。** DB側(pre_register)が
 * 重複を握りつぶすため、成功=新規とは限らない。画面もそのつもりで
 * 「登録しました」ではなく「お知らせします」と出すこと。
 */
import { requireSupabase, isBackendConfigured } from './supabase'

/** 事前登録が使えるか(バックエンド未設定のデモモードでは使えない)。 */
export const canPreRegister = isBackendConfigured

/**
 * 事前登録する。
 *
 * @param email 入力されたメールアドレス。正規化(小文字化・空白除去)はDB側で行う
 * @param source 流入元の目印。SNSごとの効き目を見るのに使う(例: 'x')
 */
export async function preRegister(email: string, source?: string): Promise<void> {
  const { error } = await requireSupabase().rpc('pre_register', {
    p_email: email,
    p_source: source,
  })
  if (error) throw error
}

/** 送信前の軽い形式チェック。ここを通っても最終判断はDB側が行う。 */
export function looksLikeEmail(v: string): boolean {
  const s = v.trim()
  return s.length > 0 && s.length <= 254 && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s)
}

/** 事前登録のエラーを、画面に出してよい日本語に変換する。 */
export function preRegisterErrorMessage(e: unknown): string {
  const raw = e instanceof Error ? e.message : ''
  if (/INVALID_EMAIL/i.test(raw)) {
    return 'メールアドレスの形式をご確認ください。'
  }
  if (/Failed to fetch|NetworkError|network/i.test(raw)) {
    return 'ネットワークに接続できませんでした。しばらくしてから再度お試しください。'
  }
  return '送信できませんでした。時間をおいて再度お試しください。'
}
