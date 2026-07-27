/**
 * 公開前(事前登録のみ)か、公開済み(アカウント登録を受け付ける)かの切り替え。
 *
 * ============================================================
 *  公開するときは、下の IS_PRE_LAUNCH を false にするだけ。
 * ============================================================
 *
 * 公開前に「はじめる」を出したままにすると、コイン購入も換金もできない状態で
 * アカウントだけが増える。本人確認の審査もその分だけ発生してしまうので、
 * 公開までは事前登録の一本に絞る。
 *
 * **ログインは塞がない。** アカウントが無ければ入れないので塞ぐ意味が無く、
 * むしろ公開前の動作確認ができなくなる。
 *
 * 環境変数にしていないのは、切り替えを見落としたときに「どちらが本当か」が
 * 分からなくなるため。ここを見れば現在どちらの状態かが必ず分かる。
 */
import { isBackendConfigured } from './lib/supabase'

export const IS_PRE_LAUNCH = true

/**
 * 登録導線を実際に隠すか。
 *
 * デモモード(バックエンド未設定＝ローカルでの画面確認)では隠さない。
 * ここまで塞ぐと、公開前に画面を見て回ることすらできなくなる。
 * デモモードは本番では起こらない(環境変数が入っているため)。
 */
export const HIDE_SIGNUP = IS_PRE_LAUNCH && isBackendConfigured

/** 事前登録フォームまで送る(ランディング内のアンカー)。 */
export const PRE_REGISTER_ANCHOR = 'preregister'

/** ランディング内で事前登録フォームまでスクロールする。 */
export function scrollToPreRegister() {
  document.getElementById(PRE_REGISTER_ANCHOR)?.scrollIntoView({ behavior: 'smooth', block: 'center' })
}
