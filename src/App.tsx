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
  type ReportTarget,
} from './flow'
import type { ReportCategory } from './lib/database.types'
import FlowRail from './components/FlowRail'
import PhoneFrame from './components/PhoneFrame'
import { usePress } from './hooks/usePress'
import { useIsMobile } from './hooks/useMediaQuery'
import { loadPrefs, savePrefs } from './persist'
import { isBackendConfigured } from './lib/supabase'
import { getSession, signOut as supabaseSignOut } from './lib/auth'
import {
  fetchAccountBundle,
  updateProfileRemote,
  updateSafetyPrefsRemote,
  updateHostSettingsRemote,
  createBookingRemote,
  checkIsAdmin,
  submitReport as submitReportRemote,
  blockUser as blockUserRemote,
} from './lib/queries'

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
import AdminVerifications from './screens/AdminVerifications'
import BlockList from './screens/BlockList'

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
  /** 実データのホスト(Supabase)の場合のみ設定される。デモのモックホストにはない。 */
  userId?: string
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
  reportTarget: ReportTarget | null
  sendFailOpen: boolean
  gender: Gender
  safetyPrefs: SafetyPrefs
  theme: Theme
  coinBalance: number
  hostSettings: HostSettings
  bookingHost: BookingHost | null
  bookingDuration: BookingDuration
  bookingInsufficient: boolean
  /** 予約確定の失敗理由(残高不足以外)。実データの予約でのみ発生しうる。 */
  bookingError: string | null
  /** バックエンド接続時、サインイン済みならSupabaseのユーザーID。デモモード/未サインインはnull。 */
  userId: string | null
  nickname: string
  mannerScore: number
  dotakyanCount: number
  confirmedCount: number
  isVerified: boolean
  /** admins テーブルに登録された運営アカウントか(本人確認の審査画面へのアクセス可否)。 */
  isAdmin: boolean
  /** ホスト設定の直近の書き込みエラー(本人確認未完了等)。表示専用、次の操作で上書きされる。 */
  hostSettingsError: string | null
  setNickname: (n: string) => void
  /** サインイン/起動時のセッション復元後に、本人のアカウントデータを読み込む。 */
  hydrateAccount: (userId: string) => Promise<void>
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
  openReport: (target: ReportTarget) => void
  closeReport: () => void
  /** 通報(+任意でブロック)を送信する。実データ対象(userIdあり)ならDBへ、デモなら擬似成功。 */
  submitReport: (category: ReportCategory, alsoBlock: boolean) => Promise<void>
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
  reportTarget: null as ReportTarget | null,
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
  bookingError: null as string | null,
  userId: null as string | null,
  nickname: 'あおい',
  mannerScore: 4.8,
  dotakyanCount: 0,
  confirmedCount: 47,
  isVerified: true,
  isAdmin: false,
  hostSettingsError: null as string | null,
}

export type Theme = 'light' | 'dark'

export default function App() {
  // 保存済みのユーザー設定(テーマ/性別/安心設定)で初期状態を上書き
  const [state, setState] = useState(() => ({ ...INITIAL, ...loadPrefs() }))
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  // バックエンド接続時のみ、既存セッションの有無を確認してから初期画面を決める
  // (未接続=デモモードでは常にfalseなので、この確認自体をスキップする)
  const [authChecking, setAuthChecking] = useState(isBackendConfigured)

  // サインイン/起動時のセッション復元後に、本人のアカウントデータ(プロフィール/
  // 安心設定/ホスト設定/コイン残高/信頼スタッツ)をSupabaseから読み込み、
  // デモ用のローカル状態を実データで上書きする。
  const hydrateAccount = useCallback(async (userId: string) => {
    try {
      const bundle = await fetchAccountBundle(userId)
      if (!bundle) return
      setState((p) => ({
        ...p,
        userId,
        nickname: bundle.profile.nickname || p.nickname,
        gender: bundle.profile.gender,
        safetyPrefs: {
          contactScope: bundle.safetyPrefs.contact_scope,
          approvalRequired: bundle.safetyPrefs.approval_required,
          showOnline: bundle.safetyPrefs.show_online,
          discoverable: bundle.safetyPrefs.discoverable,
          blockLowTrust: bundle.safetyPrefs.block_low_trust,
        },
        hostSettings: {
          isHost: bundle.hostSettings.is_host,
          hourlyRate: bundle.hostSettings.hourly_rate,
          games: bundle.hostSettings.games,
          bio: bundle.hostSettings.bio,
        },
        coinBalance: bundle.wallet.balance,
        mannerScore: bundle.trustStats.manner_score,
        dotakyanCount: bundle.trustStats.dotakyan_count,
        confirmedCount: bundle.trustStats.confirmed_count,
        isVerified: bundle.trustStats.is_verified,
      }))
    } catch (err) {
      console.warn('[pita-friends] アカウントデータの取得に失敗しました:', err)
    }
    try {
      const isAdmin = await checkIsAdmin(userId)
      setState((p) => ({ ...p, isAdmin }))
    } catch (err) {
      console.warn('[pita-friends] 管理者判定の取得に失敗しました:', err)
    }
  }, [])

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    getSession()
      .then(async (session) => {
        if (active && session) {
          await hydrateAccount(session.user.id)
          if (active) setState((p) => ({ ...p, screen: 'home' }))
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
  }, [hydrateAccount])

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
      setState((p) => ({ ...p, screen: s, reportTarget: null, sendFailOpen: false }))
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

  const confirmBooking = useCallback(async () => {
    const host = state.bookingHost
    if (!host) return

    // 実データのホスト(Supabase側にuserIdを持つ)は、コイン消費と予約作成を
    // アトミックに行うcreate_booking RPCを呼ぶ。デモのモックホストは
    // これまでどおりローカル計算のみで進める。
    if (isBackendConfigured && host.userId && state.userId) {
      setState((p) => ({ ...p, bookingInsufficient: false, bookingError: null }))
      try {
        await createBookingRemote(host.userId, state.bookingDuration)
        const cost = coinsForDuration(host.hourlyRate, state.bookingDuration)
        clearTimer()
        setState((p) => ({ ...p, coinBalance: p.coinBalance - cost, screen: 'sending' }))
        timer.current = setTimeout(() => setState((p) => ({ ...p, screen: 'match' })), AUTO_ADVANCE_MS)
      } catch (err) {
        const message = err instanceof Error ? err.message : ''
        if (message.includes('INSUFFICIENT_COINS')) {
          setState((p) => ({ ...p, bookingInsufficient: true }))
        } else if (message.includes('HOST_NOT_AVAILABLE')) {
          setState((p) => ({ ...p, bookingError: 'このホストは現在、予約を受け付けていません。' }))
        } else {
          setState((p) => ({
            ...p,
            bookingError: '予約の確定に失敗しました。時間をおいて再度お試しください。',
          }))
        }
        console.warn('[pita-friends] create_bookingに失敗:', err)
      }
      return
    }

    const cost = coinsForDuration(host.hourlyRate, state.bookingDuration)
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
  }, [state.bookingHost, state.bookingDuration, state.coinBalance, state.userId, clearTimer])

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
    openReport: (target) => setState((p) => ({ ...p, reportTarget: target })),
    closeReport: () => setState((p) => ({ ...p, reportTarget: null })),
    submitReport: async (category, alsoBlock) => {
      const target = state.reportTarget
      // 実データの相手(userIdあり)かつバックエンド接続時のみDBへ送信。
      // デモのモック相手(userId=null)は擬似成功にしてUXを確認できるようにする。
      if (isBackendConfigured && target?.userId) {
        await submitReportRemote(target.userId, category)
        if (alsoBlock) await blockUserRemote(target.userId)
      }
    },
    setGender: (g) => {
      setState((p) => ({ ...p, gender: g }))
      if (isBackendConfigured && state.userId) {
        updateProfileRemote(state.userId, { gender: g }).catch((err) =>
          console.warn('[pita-friends] gender更新に失敗:', err),
        )
      }
    },
    setNickname: (n) => {
      setState((p) => ({ ...p, nickname: n }))
      if (isBackendConfigured && state.userId) {
        updateProfileRemote(state.userId, { nickname: n }).catch((err) =>
          console.warn('[pita-friends] nickname更新に失敗:', err),
        )
      }
    },
    hydrateAccount,
    setSafetyPref: (key, value) => {
      setState((p) => ({ ...p, safetyPrefs: { ...p.safetyPrefs, [key]: value } }))
      if (isBackendConfigured && state.userId) {
        const dbKey =
          key === 'contactScope'
            ? 'contact_scope'
            : key === 'approvalRequired'
              ? 'approval_required'
              : key === 'showOnline'
                ? 'show_online'
                : key === 'discoverable'
                  ? 'discoverable'
                  : 'block_low_trust'
        updateSafetyPrefsRemote(state.userId, { [dbKey]: value }).catch((err) =>
          console.warn('[pita-friends] safety_prefs更新に失敗:', err),
        )
      }
    },
    applyRecommendedFemalePrefs: () => {
      setState((p) => ({ ...p, safetyPrefs: recommendedFemalePrefs }))
      if (isBackendConfigured && state.userId) {
        updateSafetyPrefsRemote(state.userId, {
          contact_scope: recommendedFemalePrefs.contactScope,
          approval_required: recommendedFemalePrefs.approvalRequired,
          show_online: recommendedFemalePrefs.showOnline,
          discoverable: recommendedFemalePrefs.discoverable,
          block_low_trust: recommendedFemalePrefs.blockLowTrust,
        }).catch((err) => console.warn('[pita-friends] safety_prefs更新に失敗:', err))
      }
    },
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
    setHostPref: (key, value) => {
      const previous = state.hostSettings[key]
      setState((p) => ({
        ...p,
        hostSettings: { ...p.hostSettings, [key]: value },
        hostSettingsError: null,
      }))
      if (isBackendConfigured && state.userId) {
        const dbKey =
          key === 'isHost' ? 'is_host' : key === 'hourlyRate' ? 'hourly_rate' : key === 'games' ? 'games' : 'bio'
        updateHostSettingsRemote(state.userId, { [dbKey]: value }).catch((err) => {
          const message =
            err instanceof Error && err.message.includes('HOST_REQUIRES_VERIFICATION')
              ? 'ホストとして掲載するには、本人確認の完了が必要です。「本人確認ステータス」から書類を提出してください(審査完了まで数日かかる場合があります)。'
              : 'ホスト設定の保存に失敗しました。時間をおいて再度お試しください。'
          console.warn('[pita-friends] host_settings更新に失敗:', err)
          // 反映できなかった場合は表示上も元に戻す
          setState((p) => ({
            ...p,
            hostSettings: { ...p.hostSettings, [key]: previous },
            hostSettingsError: message,
          }))
        })
      }
    },
    startBooking: (host) =>
      setState((p) => ({
        ...p,
        bookingHost: host,
        bookingDuration: 60,
        bookingInsufficient: false,
        bookingError: null,
        screen: 'booking',
      })),
    setBookingDuration: (min) =>
      setState((p) => ({ ...p, bookingDuration: min, bookingInsufficient: false, bookingError: null })),
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
        {state.screen === 'adminVerifications' && <AdminVerifications flow={flow} />}
        {state.screen === 'blockList' && <BlockList flow={flow} />}
        {flow.reportTarget && <ReportSheet flow={flow} />}
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
