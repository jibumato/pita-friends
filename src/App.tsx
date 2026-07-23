import { useCallback, useEffect, useRef, useState } from 'react'
import { color as C } from './theme/tokens'
import {
  defaultSafetyPrefs,
  recommendedFemalePrefs,
  defaultHostSettings,
  coinsForDuration,
  SEARCH_VERIFIED_FILTER,
  type ScreenKey,
  type Gender,
  type SafetyPrefs,
  type HostSettings,
  type BookingDuration,
  type ReportTarget,
} from './flow'
import type { ReportCategory } from './lib/database.types'
import type { LegalDocKey } from './content/legalDocs'
import PhoneFrame from './components/PhoneFrame'
import LandingDesktop from './components/LandingDesktop'
import DesktopTopBar from './components/DesktopTopBar'
import DesktopSidebar from './components/DesktopSidebar'
import DesktopHero from './components/DesktopHero'
import { useIsMobile } from './hooks/useMediaQuery'
import { loadPrefs, savePrefs } from './persist'
import { isBackendConfigured } from './lib/supabase'
import { getSession, signOut as supabaseSignOut } from './lib/auth'
import { trackMyPresence } from './lib/presence'
import {
  fetchAccountBundle,
  updateProfileRemote,
  updateSafetyPrefsRemote,
  updateHostSettingsRemote,
  createBookingRemote,
  checkIsAdmin,
  submitReport as submitReportRemote,
  blockUser as blockUserRemote,
  createInvite as createInviteRemote,
  recordDevice,
  recordIp,
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
import BookingRequested from './screens/BookingRequested'
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
import Ranking from './screens/Ranking'
import AdminVerifications from './screens/AdminVerifications'
import BlockList from './screens/BlockList'
import LegalDoc from './screens/LegalDoc'

/** デモ調整パラメータ(ハンドオフの props に対応)。 */
const MATCH_SCORE = 92
const AUTO_ADVANCE_MS = 2400

/**
 * デスクトップのメイン列の幅を画面種別ごとに決める。
 *  - FULL_BLEED : 一覧・ダッシュボード系。メイン列いっぱいに広げる(さがすと同じ)。
 *  - WIDE(760) : カード/設定リストだが読みやすさのため上限を設ける画面。
 *  - それ以外(560): オンボーディング・チャット・確認・お祝いなど単一導線の画面。
 * 手のひらサイズの端末幅(旧440px)のまま据え置かれて見えないようにする。
 */
const DESKTOP_FULL_BLEED_SCREENS = new Set<ScreenKey>([
  'home',
  'search',
  'board',
  'mypage',
  'talkList',
  'notifications',
  'requests',
  'ranking',
  'blockList',
  'adminVerifications',
])
const DESKTOP_WIDE_SCREENS = new Set<ScreenKey>([
  'profile',
  'settings',
  'safety',
  'safetyPrefs',
  'wallet',
  'hostSettings',
  'legalDoc',
  'boardCreate',
])

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
  legalDocKey: LegalDocKey | null
  legalDocReturn: ScreenKey
  profileUserId: string | null
  profileReturn: ScreenKey
  inviteTarget: { userId: string; name: string } | null
  activeThreadId: string | null
  /** トークを閉じたときに戻る画面(通知から開いたら通知に戻る等)。 */
  threadReturn: ScreenKey
  sendFailOpen: boolean
  gender: Gender
  safetyPrefs: SafetyPrefs
  theme: Theme
  coinBalance: number
  hostSettings: HostSettings
  /** さがす画面の検索語・絞り込みチップ。デスクトップではトップバー/サイドバーからも操作する共通状態。 */
  searchQuery: string
  searchFilters: Record<string, boolean>
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
  setSearchQuery: (q: string) => void
  toggleSearchFilter: (f: string) => void
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
  /** 規約・ポリシー画面を開く。 */
  openLegalDoc: (key: LegalDocKey) => void
  /** 指定ユーザーの公開プロフィールを開く(実データ)。 */
  openProfile: (userId: string) => void
  /** 指定ユーザーへの誘いシートを開く(実データ)。 */
  openInvite: (userId: string, name: string) => void
  /** 誘いを実際に送信する(実データ)。成功でresolve。 */
  submitInvite: (game: string, whenText: string, message: string) => Promise<void>
  /** 実データのトークルーム(約束/promise)を開く。 */
  openThread: (promiseId: string) => void
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
  legalDocKey: null as LegalDocKey | null,
  legalDocReturn: 'settings' as ScreenKey,
  profileUserId: null as string | null,
  profileReturn: 'search' as ScreenKey,
  inviteTarget: null as { userId: string; name: string } | null,
  activeThreadId: null as string | null,
  threadReturn: 'talkList' as ScreenKey,
  sendFailOpen: false,
  reviewStars: 5,
  reviewTag: '時間ぴったり',
  gender: 'na' as Gender,
  safetyPrefs: defaultSafetyPrefs,
  theme: 'light' as Theme,
  coinBalance: 500,
  hostSettings: defaultHostSettings,
  searchQuery: '',
  searchFilters: (isBackendConfigured
    ? {}
    : { 今夜あそべる: true, Apex: true, [SEARCH_VERIFIED_FILTER]: true }) as Record<string, boolean>,
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
    // Stripe決済からの戻り(success_url/cancel_url の ?checkout=...)を検出
    const params = new URLSearchParams(window.location.search)
    const checkoutParam = params.get('checkout')
    // Stripe Connect オンボーディングからの戻り(?connect=return/refresh)を検出
    const connectParam = params.get('connect')
    if (checkoutParam || connectParam) {
      // URLからパラメータを消す(リロードで二重処理されないように)
      window.history.replaceState({}, '', window.location.pathname)
    }
    getSession()
      .then(async (session) => {
        if (active && session) {
          await hydrateAccount(session.user.id)
          if (!active) return
          if (checkoutParam) {
            // 決済後はウォレットに着地。付与はwebhookで非同期なので少し遅れて再取得する。
            setState((p) => ({ ...p, screen: 'wallet' }))
            if (checkoutParam === 'success') {
              const uid = session.user.id
              setTimeout(() => {
                if (active) void hydrateAccount(uid)
              }, 2500)
            }
          } else if (connectParam) {
            // オンボーディング完了はaccount.updated Webhookで反映されるため、
            // ホスト設定画面に戻して(その画面が自分で状況を再取得する)
            setState((p) => ({ ...p, screen: 'hostSettings' }))
          } else {
            setState((p) => ({ ...p, screen: 'home' }))
          }
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

  // 「いま遊べる」オンライン表示: 安心設定でオンライン状態の公開をオンに
  // している間だけ、自分の在席をRealtime Presenceでブロードキャストする。
  useEffect(() => {
    if (!isBackendConfigured || !state.userId || !state.safetyPrefs.showOnline) return
    const stop = trackMyPresence({
      userId: state.userId,
      nickname: state.nickname,
      avatarInitial: state.nickname.charAt(0) || '?',
      avatarColor: '#B3E5F2',
    })
    return stop
  }, [state.userId, state.safetyPrefs.showOnline, state.nickname])

  // 端末ID・IPを記録(ギフトの自己取引/IP共有検知に使う)。ログイン後に一度だけ。
  useEffect(() => {
    if (!isBackendConfigured || !state.userId) return
    void recordDevice()
    void recordIp()
  }, [state.userId])

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
      // openProfile 以外(plain go)でプロフィールへ来た場合は実データ対象を持たない=デモ表示
      setState((p) => ({
        ...p,
        screen: s,
        reportTarget: null,
        sendFailOpen: false,
        profileUserId: s === 'profile' ? null : p.profileUserId,
        inviteTarget: s === 'invite' ? null : p.inviteTarget,
      }))
    },
    [clearTimer],
  )

  const sendInvite = useCallback(() => {
    clearTimer()
    // デモの誘いフロー: 前回の実データのトークルームが残っていると
    // Talk画面がそれを表示してしまうため、ここで必ずクリアする
    setState((p) => ({ ...p, screen: 'sending', activeThreadId: null }))
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
        // 予約はリクエスト(承諾待ち)として作られる。ホストが承諾するまで
        // トークは開かないので、送信完了→承諾待ち画面に遷移する。
        await createBookingRemote(host.userId, state.bookingDuration)
        const cost = coinsForDuration(host.hourlyRate, state.bookingDuration)
        clearTimer()
        setState((p) => ({
          ...p,
          coinBalance: p.coinBalance - cost,
          screen: 'bookingRequested',
          activeThreadId: null,
        }))
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
      activeThreadId: null,
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
    openLegalDoc: (key) =>
      setState((p) => ({ ...p, legalDocKey: key, legalDocReturn: p.screen, screen: 'legalDoc' })),
    openProfile: (userId) =>
      setState((p) => ({ ...p, profileUserId: userId, profileReturn: p.screen, screen: 'profile' })),
    openInvite: (userId, name) =>
      setState((p) => ({ ...p, inviteTarget: { userId, name }, screen: 'invite' })),
    submitInvite: async (game, whenText, message) => {
      const target = state.inviteTarget
      if (!target) throw new Error('送信先が不明です')
      await createInviteRemote(target.userId, game, whenText, message)
    },
    openThread: (promiseId) =>
      setState((p) => ({
        ...p,
        activeThreadId: promiseId,
        // いま居る画面を戻り先として覚える(通知→トークなら通知に戻る)。
        // ただしトーク画面同士の遷移では talkList を戻り先に保つ。
        threadReturn: p.screen === 'talk' ? p.threadReturn : p.screen,
        screen: 'talk',
      })),
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
    setSearchQuery: (q) => setState((p) => ({ ...p, searchQuery: q })),
    toggleSearchFilter: (f) =>
      setState((p) => ({ ...p, searchFilters: { ...p.searchFilters, [f]: !p.searchFilters[f] } })),
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

  const mobile = useIsMobile()

  const deviceEl = (
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
        {state.screen === 'bookingRequested' && <BookingRequested flow={flow} />}
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
        {state.screen === 'ranking' && <Ranking flow={flow} />}
        {state.screen === 'adminVerifications' && <AdminVerifications flow={flow} />}
        {state.screen === 'blockList' && <BlockList flow={flow} />}
        {state.screen === 'legalDoc' && <LegalDoc flow={flow} />}
        {flow.reportTarget && <ReportSheet flow={flow} />}
        {flow.sendFailOpen && <SendFailDialog flow={flow} />}
          </>
        )}
      </PhoneFrame>
  )

  if (mobile) {
    return <div style={{ display: 'flex', flexDirection: 'column' }}>{deviceEl}</div>
  }

  // デスクトップ: ようこそ画面はGameRoom型のLP。入ったらアプリ本体(トップバー+サイドナビ+中央パネル)。
  if (state.screen === 'welcome') {
    return <LandingDesktop flow={flow} />
  }
  // ヒーローはホームの上部にのみ表示(さがすは検索結果に集中させる)。
  // コイン残高/ランキング/安心して遊べるは右レールではなくトップバーのハンバーガーメニューから開く。
  const showHero = state.screen === 'home'
  // 一覧・ダッシュボード系はメイン列いっぱいのフラットな全幅(モックアップ準拠)。
  // フォーム・詳細・ホームは読みやすい幅で中央寄せ。カード風の枠・影は付けず地の面に馴染ませる。
  const fullBleed = DESKTOP_FULL_BLEED_SCREENS.has(state.screen)
  const maxContentWidth = fullBleed ? undefined : DESKTOP_WIDE_SCREENS.has(state.screen) ? 760 : 560
  return (
    <div style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column', background: C.canvas }}>
      <DesktopTopBar flow={flow} />
      <div style={{ flex: 1, display: 'flex', alignItems: 'flex-start' }}>
        <DesktopSidebar flow={flow} />
        <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column' }}>
          {/* ヒーローはメイン列の先頭に置き、ページと一緒にスクロールして流れていく。 */}
          {showHero && <DesktopHero flow={flow} />}
          <div
            style={{
              flex: 1,
              display: 'flex',
              justifyContent: 'center',
              padding: fullBleed ? 0 : '28px 24px 60px',
              boxSizing: 'border-box',
            }}
          >
            <div
              style={{
                position: 'relative',
                width: '100%',
                maxWidth: maxContentWidth,
                minHeight: 320,
                background: C.surface,
              }}
            >
              {(deviceEl.props as { children: React.ReactNode }).children}
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
