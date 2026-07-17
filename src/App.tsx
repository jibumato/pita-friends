import { useCallback, useEffect, useRef, useState } from 'react'
import { color as C } from './theme/tokens'
import {
  screenNames,
  stepOf,
  defaultSafetyPrefs,
  recommendedFemalePrefs,
  defaultHostSettings,
  coinsForDuration,
  type ScreenKey,
  type Gender,
  type SafetyPrefs,
  type HostSettings,
  type BookingDuration,
} from './flow'
import FlowRail from './components/FlowRail'
import PhoneFrame from './components/PhoneFrame'
import { usePress } from './hooks/usePress'
import { useIsMobile } from './hooks/useMediaQuery'
import { loadPrefs, savePrefs } from './persist'
import { isBackendConfigured } from './lib/supabase'
import { getSession, signOut as supabaseSignOut } from './lib/auth'

import Welcome from './screens/Welcome'
import SignUp from './screens/SignUp'
import SignIn from './screens/SignIn'
import Consent from './screens/Consent'
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
import SendFailDialog from './screens/SendFailDialog'
import Wallet from './screens/Wallet'
import HostSettingsScreen from './screens/HostSettingsScreen'
import Booking from './screens/Booking'

/** デモ調整パラメータ(ハンドオフの props に対応)。 */
const MATCH_SCORE = 92
const AUTO_ADVANCE_MS = 2400
const SHOW_RAIL = true

/** 予約対象のホスト(さがす画面のカードから渡す最小情報)。 */
export type BookingHost = {
  name: string
  initial: string
  color: string
  hourlyRate: number
}

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
  sendFailOpen: boolean
  gender: Gender
  safetyPrefs: SafetyPrefs
  theme: Theme
  coinBalance: number
  hostSettings: HostSettings
  bookingHost: BookingHost | null
  bookingDuration: BookingDuration
  bookingInsufficient: boolean
  setTheme: (t: Theme) => void
  toggleTheme: () => void
  openSendFail: () => void
  closeSendFail: () => void
  reserveInvite: () => void
  buyCoins: (coins: number) => void
  setHostPref: <K extends keyof HostSettings>(key: K, value: HostSettings[K]) => void
  startBooking: (host: BookingHost) => void
  setBookingDuration: (min: BookingDuration) => void
  confirmBooking: () => void
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
  signOut: () => void
}

const INITIAL = {
  screen: 'welcome' as ScreenKey,
  game: 'Apex',
  when: '今夜 22:00〜',
  dealDone: false,
  reportOpen: false,
  sendFailOpen: false,
  reviewStars: 5,
  reviewTag: '時間ぴったり',
  gender: 'na' as Gender,
  safetyPrefs: defaultSafetyPrefs,
  theme: 'light' as Theme,
  coinBalance: 500,
  hostSettings: defaultHostSettings,
  bookingHost: null as BookingHost | null,
  bookingDuration: 60 as BookingDuration,
  bookingInsufficient: false,
}

export type Theme = 'light' | 'dark'

export default function App() {
  // 保存済みのユーザー設定(テーマ/性別/安心設定)で初期状態を上書き
  const [state, setState] = useState(() => ({ ...INITIAL, ...loadPrefs() }))
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  // バックエンド接続時のみ、既存セッションの有無を確認してから初期画面を決める
  // (未接続=デモモードでは常にfalseなので、この確認自体をスキップする)
  const [authChecking, setAuthChecking] = useState(isBackendConfigured)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    getSession()
      .then((session) => {
        if (active && session) {
          setState((p) => ({ ...p, screen: 'home' }))
        }
      })
      .catch(() => {
        /* セッション確認に失敗しても、ようこそ画面から始められれば問題ない */
      })
      .finally(() => {
        if (active) setAuthChecking(false)
      })
    return () => {
      active = false
    }
  }, [])

  // テーマを <html data-theme> に反映(CSS変数が切替わる)
  useEffect(() => {
    document.documentElement.dataset.theme = state.theme
  }, [state.theme])

  // ユーザー設定を永続化(変わったときだけ書き込み)
  useEffect(() => {
    savePrefs({
      theme: state.theme,
      gender: state.gender,
      safetyPrefs: state.safetyPrefs,
      coinBalance: state.coinBalance,
      hostSettings: state.hostSettings,
    })
  }, [state.theme, state.gender, state.safetyPrefs, state.coinBalance, state.hostSettings])

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
      setState((p) => ({ ...p, screen: s, reportOpen: false, sendFailOpen: false }))
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

  const confirmBooking = useCallback(() => {
    if (!state.bookingHost) return
    const cost = coinsForDuration(state.bookingHost.hourlyRate, state.bookingDuration)
    if (cost > state.coinBalance) {
      setState((p) => ({ ...p, bookingInsufficient: true }))
      return
    }
    clearTimer()
    setState((p) => ({
      ...p,
      coinBalance: p.coinBalance - cost,
      bookingInsufficient: false,
      screen: 'sending',
    }))
    // 決済成功後は、誘い送信と同じ自動遷移(返事待ち→マッチ)につなげる
    timer.current = setTimeout(() => setState((p) => ({ ...p, screen: 'match' })), AUTO_ADVANCE_MS)
  }, [state.bookingHost, state.bookingDuration, state.coinBalance, clearTimer])

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
    // ユーザー設定(テーマ/性別/安心設定)はデモのリスタートでも保持
    setState((p) => ({
      ...INITIAL,
      theme: p.theme,
      gender: p.gender,
      safetyPrefs: p.safetyPrefs,
      coinBalance: p.coinBalance,
      hostSettings: p.hostSettings,
    }))
  }, [clearTimer])

  const signOut = useCallback(() => {
    clearTimer()
    if (isBackendConfigured) {
      // 失敗しても(セッション切れ等)、ローカル状態は必ずリセットして
      // ようこそ画面へ戻す
      void supabaseSignOut().catch(() => {})
    }
    // 実アカウントのログアウトなので、デモ用の設定保持はせず完全に初期化する
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
    openSendFail: () => setState((p) => ({ ...p, sendFailOpen: true })),
    closeSendFail: () => setState((p) => ({ ...p, sendFailOpen: false })),
    reserveInvite: () => {
      clearTimer()
      setState((p) => ({ ...p, sendFailOpen: false, screen: 'home' }))
    },
    buyCoins: (coins) => setState((p) => ({ ...p, coinBalance: p.coinBalance + coins })),
    setHostPref: (key, value) =>
      setState((p) => ({ ...p, hostSettings: { ...p.hostSettings, [key]: value } })),
    startBooking: (host) =>
      setState((p) => ({
        ...p,
        bookingHost: host,
        bookingDuration: 60,
        bookingInsufficient: false,
        screen: 'booking',
      })),
    setBookingDuration: (min) =>
      setState((p) => ({ ...p, bookingDuration: min, bookingInsufficient: false })),
    confirmBooking,
    go,
    sendInvite,
    goJoin,
    restart,
    signOut,
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
        {authChecking ? (
          <div
            style={{
              flex: 1,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              background: C.surface,
            }}
          >
            <div
              style={{
                width: 22,
                height: 22,
                borderRadius: '50%',
                border: '2.5px solid #E3DEF0',
                borderTopColor: C.lavender,
                borderRightColor: C.lavender,
                animation: 'ringSpin .9s linear infinite',
              }}
            />
          </div>
        ) : (
          <>
        {state.screen === 'welcome' && <Welcome flow={flow} />}
        {state.screen === 'signUp' && <SignUp flow={flow} />}
        {state.screen === 'signIn' && <SignIn flow={flow} />}
        {state.screen === 'consent' && <Consent flow={flow} />}
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
        {state.screen === 'wallet' && <Wallet flow={flow} />}
        {state.screen === 'hostSettings' && <HostSettingsScreen flow={flow} />}
        {state.screen === 'booking' && <Booking flow={flow} />}
        {flow.reportOpen && <ReportSheet flow={flow} />}
        {flow.sendFailOpen && <SendFailDialog flow={flow} />}
          </>
        )}
      </PhoneFrame>

      {!mobile && (
        <span style={{ marginTop: 20, fontSize: 11, color: C.placeholder }}>
          現在: {screenNames[state.screen]}
        </span>
      )}
    </div>
  )
}
