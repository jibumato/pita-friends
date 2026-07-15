/**
 * ユーザー設定の永続化(localStorage)。
 * デモのフロー状態(screen/dealDone 等)は保存せず、ユーザーの好み
 * (テーマ / 性別 / 安心設定)だけを保存・復元する。
 */
import { defaultSafetyPrefs, type Gender, type SafetyPrefs } from './flow'
import type { Theme } from './App'

const KEY = 'pita:prefs:v1'

export type PersistedPrefs = {
  theme: Theme
  gender: Gender
  safetyPrefs: SafetyPrefs
}

/** 保存済みの設定を読み出す(壊れていれば無視)。 */
export function loadPrefs(): Partial<PersistedPrefs> {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return {}
    const data = JSON.parse(raw) as Partial<PersistedPrefs>
    const out: Partial<PersistedPrefs> = {}
    if (data.theme === 'light' || data.theme === 'dark') out.theme = data.theme
    if (data.gender === 'female' || data.gender === 'male' || data.gender === 'na') {
      out.gender = data.gender
    }
    if (data.safetyPrefs && typeof data.safetyPrefs === 'object') {
      // 既知キーのみ既定値にマージ(将来のキー追加に耐える)
      out.safetyPrefs = { ...defaultSafetyPrefs, ...data.safetyPrefs }
    }
    return out
  } catch {
    return {}
  }
}

/** 設定を保存する(失敗は握りつぶす)。 */
export function savePrefs(prefs: PersistedPrefs): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(prefs))
  } catch {
    /* プライベートモード等で失敗しても致命的ではない */
  }
}
