/**
 * 認証ヘルパー。Supabase Auth(メール+パスワード)の薄いラッパー。
 * UI側の結線(サインアップ/ログイン画面)は別途実装する。
 * バックエンド未設定時(デモモード)はすべて例外を投げる —
 * 呼び出し側は `isBackendConfigured` を先に確認すること。
 */
import type { Session, User } from '@supabase/supabase-js'
import { requireSupabase } from './supabase'

/**
 * パスワードの最小文字数。**アカウント作成と再設定で同じ値を使うこと。**
 * 画面ごとに別々の数字を書くと、片方だけ直したときに食い違う。
 *
 * Supabase 側の既定は6文字だが、コインと換金を扱うので8文字にしている。
 * 既存の6〜7文字のパスワードでログインすること自体は妨げない
 * (長さの検査はこの画面の入力時にだけ行う)。
 */
export const PASSWORD_MIN_LENGTH = 8

/**
 * パスワードの最大バイト数。Supabase Auth は bcrypt を使っており、
 * 72バイトを超える部分は無視される(実質的な上限)。**文字数ではなくバイト数**
 * であることに注意 — 日本語のような3バイト文字は約24文字で上限に達する。
 */
export const PASSWORD_MAX_BYTES = 72

/** UTF-8でのバイト数を数える。日本語などのマルチバイト文字を正しく数えるため。 */
export function byteLength(s: string): number {
  return new TextEncoder().encode(s).length
}

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

/**
 * パスワード再設定のメールを送る。
 *
 * 戻り先は `/reset-password`。クエリではなくパスにしているのは、Supabase の
 * リダイレクト許可リスト(`https://pitafure.com/**`)がパスのワイルドカードで
 * 書かれているため。SPAなので、この URL でも index.html が返る
 * (wrangler.jsonc の not_found_handling: single-page-application)。
 *
 * **アカウントの有無は呼び出し側に伝わりません。** 未登録のアドレスでも
 * エラーになりません(Supabaseの仕様)。画面側も「登録があれば送りました」と
 * 出して、アドレスの存在を漏らさないこと。
 */
export async function sendPasswordReset(email: string): Promise<void> {
  const { error } = await requireSupabase().auth.resetPasswordForEmail(email, {
    redirectTo: `${window.location.origin}/reset-password`,
  })
  if (error) throw error
}

/**
 * 新しいパスワードを設定する。メールのリンクから来た「復旧セッション」の
 * 状態で呼ぶ。
 *
 * 設定後に**他の端末のセッションを切ります**。パスワードを忘れる状況には
 * 「乗っ取られたので変えたい」も含まれるため、変えたのに相手のセッションが
 * 生き続けるのは危険です(コインと換金を扱うので特に)。
 */
export async function updatePassword(newPassword: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.auth.updateUser({ password: newPassword })
  if (error) throw error
  // 自分の端末は残し、他は落とす。失敗しても本人の再設定は完了しているので握る。
  try {
    await sb.auth.signOut({ scope: 'others' })
  } catch {
    /* 他端末の失効に失敗しても、パスワードの変更自体は成立している */
  }
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

/**
 * パスワード再設定のリンクから戻ってきたことを検知する。
 *
 * 戻り先のパスだけでも判定できるが、こちらは保険。リンクを開いた直後は
 * URLのハッシュからセッションが復元され、その際に PASSWORD_RECOVERY が
 * 飛ぶ。これを拾わないと、**復旧セッションのまま普通にログイン済みとして
 * ホームに入ってしまい、パスワードを変えないまま終わる**。
 */
export function onPasswordRecovery(callback: () => void): () => void {
  const {
    data: { subscription },
  } = requireSupabase().auth.onAuthStateChange((event) => {
    if (event === 'PASSWORD_RECOVERY') callback()
  })
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
  if (/Password.*(too long|at most|should be at most|exceed)/i.test(raw)) {
    return 'パスワードが長すぎます。短くしてください。'
  }
  if (/For security purposes|rate limit|too many requests/i.test(raw)) {
    return '短い間隔で繰り返し送信されています。しばらく待ってから再度お試しください。'
  }
  if (/should be different from the old password/i.test(raw)) {
    return '以前と同じパスワードは設定できません。別のパスワードにしてください。'
  }
  if (/Auth session missing|session_not_found|invalid claim/i.test(raw)) {
    return 'リンクの有効期限が切れています。もう一度メールを送ってください。'
  }
  return raw || '予期しないエラーが発生しました。時間をおいて再度お試しください。'
}
