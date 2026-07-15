import { useCallback, useEffect, useRef, useState } from 'react'
import { color as C } from './theme/tokens'
import {
  screenNames,
  stepOf,
  defaultSafetyPrefs,
  recommendedFemalePrefs,
  type ScreenKey,
  type Gender,
  type SafetyPrefs,
} from './flow'
import FlowRail from './components/FlowRail'
import PhoneFrame from './components/PhoneFrame'
import { usePress } from './hooks/usePress'
import { useIsMobile } from './hooks/useMediaQuery'

import Welcome from './screens/Welcome'
import Verify from './screens/Verify'
import Setup from './screens/Setup'
import HomeScreen from './screens/Home'
import Profile from './screens/Profile'
import InviteSheet from './screens/InviteSheet'
import Sending from './screens/Sending'
import Match from './screens/Match'
import Party from './screens/Party'
import Talk from './screens/Talk'
import Reminder from './screens/Reminder'
import Joining from './screens/Joining'
import Review from './screens/Review'
import Result from './screens/Result'
import ReportSheet from './screens/ReportSheet'
import Search from './screens/Search'
import Board from './screens/Board'
import BoardCreate from './screens/BoardCreate'
import TalkList from './screens/TalkList'
import MyPage from './screens/MyPage'
import Settings from './screens/Settings'
import SafetyCenter from './screens/SafetyCenter'
import Notifications from './screens/Notifications'
import SafetyPreferences from './screens/SafetyPreferences'
import Requests from './screens/Requests'

/** デモ調整パラメータ(ハンドオフの props に対応)。 */
const MATCH_SCORE = 92
const AUTO_ADVANCE_MS = 2400
const SHOW_RAIL = true

/** 全画面が受け取るフローコンテキスト。 */
export type Flow = {
  screen: ScreenKey
  game: string
  when: string
  dealDone: boolean
  reviewStars: number
  reviewTag: string
  score: number
  reportOpen: boolean
  gender: Gender
  safetyPrefs: SafetyPrefs
  theme: Theme
  setTheme: (t: Theme) => void
  toggleTheme: () => void
  setGame: (g: string) => void
  setWhen: (w: string) => void
  setReviewStars: (n: number) => void
  setReviewTag: (t: string) => void
  confirmDeal: () => void
  openReport: () => void
  closeReport: () => void
  setGender: (g: Gender) => void
  setSafetyPref: <K extends keyof SafetyPrefs>(key: K, value: SafetyPrefs[K]) => void
  applyRecommendedFemalePrefs: () => void
  go: (s: ScreenKey) => void
  sendInvite: () => void
  goJoin: () => void
  restart: () => void
}

const INITIAL = {
  screen: 'welcome' as ScreenKey,
  game: 'Apex',
  when: '今夜 22:00〜',
  dealDone: false,
  reportOpen: false,
  reviewStars: 5,
  reviewTag: '時間ぴったり',
  gender: 'na' as Gender,
  safetyPrefs: defaultSafetyPrefs,
  theme: 'light' as Theme,
}

export type Theme = 'light' | 'dark'

export default function App() {
  const [state, setState] = useState(INITIAL)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)

  // テーマを <html data-theme> に反映(CSS変数が切替わる)
  useEffect(() => {
    document.documentElement.dataset.theme = state.theme
  }, [state.theme])

  const clearTimer = useCallback(() => {
    if (timer.current) {
      clearTimeout(timer.current)
      timer.current = null
    }
  }, [])

  useEffect(() => () => clearTimer(), [clearTimer])

  const go = useCallback(
    (s: ScreenKey) => {
      clearTimer()
      setState((p) => ({ ...p, screen: s, reportOpen: false }))
    },
    [clearTimer],
  )

  const sendInvite = useCallback(() => {
    clearTimer()
    setState((p) => ({ ...p, screen: 'sending' }))
    timer.current = setTimeout(
      () => setState((p) => ({ ...p, screen: 'match' })),
      AUTO_ADVANCE_MS,
    )
  }, [clearTimer])

  const goJoin = useCallback(() => {
    clearTimer()
    setState((p) => ({ ...p, screen: 'joining' }))
    timer.current = setTimeout(
      () => setState((p) => ({ ...p, screen: 'review' })),
      AUTO_ADVANCE_MS,
    )
  }, [clearTimer])

  const restart = useCallback(() => {
    clearTimer()
    // テーマはユーザー設定なのでリスタートでも保持
    setState((p) => ({ ...INITIAL, theme: p.theme }))
  }, [clearTimer])

  const flow: Flow = {
    ...state,
    score: MATCH_SCORE,
    setGame: (g) => setState((p) => ({ ...p, game: g })),
    setWhen: (w) => setState((p) => ({ ...p, when: w })),
    setReviewStars: (n) => setState((p) => ({ ...p, reviewStars: n })),
    setReviewTag: (t) => setState((p) => ({ ...p, reviewTag: t })),
    confirmDeal: () => setState((p) => ({ ...p, dealDone: true })),
    openReport: () => setState((p) => ({ ...p, reportOpen: true })),
    closeReport: () => setState((p) => ({ ...p, reportOpen: false })),
    setGender: (g) => setState((p) => ({ ...p, gender: g })),
    setSafetyPref: (key, value) =>
      setState((p) => ({ ...p, safetyPrefs: { ...p.safetyPrefs, [key]: value } })),
    applyRecommendedFemalePrefs: () =>
      setState((p) => ({ ...p, safetyPrefs: recommendedFemalePrefs })),
    setTheme: (t) => setState((p) => ({ ...p, theme: t })),
    toggleTheme: () =>
      setState((p) => ({ ...p, theme: p.theme === 'dark' ? 'light' : 'dark' })),
    go,
    sendInvite,
    goJoin,
    restart,
  }

  const restartBtn = usePress(`2px 2px 0 ${C.shadowCol}`)
  const mobile = useIsMobile()

  return (
    <div
      style={
        mobile
          ? { display: 'flex', flexDirection: 'column' }
          : {
              minHeight: '100vh',
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              padding: '34px 20px 60px',
              boxSizing: 'border-box',
            }
      }
    >
      {/* ヘッダー(ショーケースのデモ枠。実機幅では非表示) */}
      {!mobile && (
        <div
          style={{
            width: '100%',
            maxWidth: 720,
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'flex-end',
            marginBottom: 22,
          }}
        >
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
              <div
                style={{
                  width: 30,
                  height: 30,
                  borderRadius: 6,
                  background: C.lime,
                  border: `1.5px solid ${C.border}`,
                  boxShadow: `2px 2px 0 ${C.lavender}`,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  color: C.ink,
                  fontSize: 14,
                }}
              >
                ピ
              </div>
              <span style={{ fontSize: 18, color: C.ink, letterSpacing: '.04em' }}>
                ピタフレ コアフロー
              </span>
            </div>
            <span style={{ fontSize: 11, color: C.muted }}>
              準備 → 探す → 約束 → 合流 → 評価 ／ タップで進める完全フロー
            </span>
          </div>
          <div
            className="pita-press"
            onClick={restart}
            {...restartBtn.handlers}
            style={{
              cursor: 'pointer',
              fontSize: 12,
              color: C.ink,
              background: C.white,
              border: `1.5px solid ${C.border}`,
              padding: '9px 14px',
              borderRadius: 6,
              userSelect: 'none',
              ...restartBtn.style,
            }}
          >
            ↺ 最初から
          </div>
        </div>
      )}

      {/* フローレール(信頼ループの画面のみ・ショーケース時のみ表示) */}
      {!mobile && SHOW_RAIL && stepOf[state.screen] >= 0 && <FlowRail step={stepOf[state.screen]} />}

      {/* 端末 */}
      <PhoneFrame>
        {state.screen === 'welcome' && <Welcome flow={flow} />}
        {state.screen === 'verify' && <Verify flow={flow} />}
        {state.screen === 'setup' && <Setup flow={flow} />}
        {state.screen === 'home' && <HomeScreen flow={flow} />}
        {state.screen === 'profile' && <Profile flow={flow} />}
        {state.screen === 'invite' && <InviteSheet flow={flow} />}
        {state.screen === 'sending' && <Sending flow={flow} />}
        {state.screen === 'match' && <Match flow={flow} />}
        {state.screen === 'party' && <Party flow={flow} />}
        {state.screen === 'talk' && <Talk flow={flow} />}
        {state.screen === 'reminder' && <Reminder flow={flow} />}
        {state.screen === 'joining' && <Joining flow={flow} />}
        {state.screen === 'review' && <Review flow={flow} />}
        {state.screen === 'result' && <Result flow={flow} />}
        {state.screen === 'search' && <Search flow={flow} />}
        {state.screen === 'board' && <Board flow={flow} />}
        {state.screen === 'boardCreate' && <BoardCreate flow={flow} />}
        {state.screen === 'talkList' && <TalkList flow={flow} />}
        {state.screen === 'mypage' && <MyPage flow={flow} />}
        {state.screen === 'settings' && <Settings flow={flow} />}
        {state.screen === 'safety' && <SafetyCenter flow={flow} />}
        {state.screen === 'notifications' && <Notifications flow={flow} />}
        {state.screen === 'safetyPrefs' && <SafetyPreferences flow={flow} />}
        {state.screen === 'requests' && <Requests flow={flow} />}
        {flow.reportOpen && <ReportSheet flow={flow} />}
      </PhoneFrame>

      {!mobile && (
        <span style={{ marginTop: 20, fontSize: 11, color: C.placeholder }}>
          現在: {screenNames[state.screen]}
        </span>
      )}
    </div>
  )
}
