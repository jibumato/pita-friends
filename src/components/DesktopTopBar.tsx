/** デスクトップ専用の上部バー(ロゴ/検索導線/コイン残高/通知/アバター)。welcome以外の全画面で共通表示。 */
import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { Search as SearchIcon, Coin, Bell } from './Icon'
import { clickable } from '../hooks/clickable'
import { isBackendConfigured } from '../lib/supabase'
import { fetchUnreadNotificationCount } from '../lib/queries'

export default function DesktopTopBar({ flow }: { flow: Flow }) {
  const [unreadNotifs, setUnreadNotifs] = useState(0)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    const refresh = () =>
      fetchUnreadNotificationCount()
        .then((n) => active && setUnreadNotifs(n))
        .catch(() => {})
    refresh()
    const timer = setInterval(refresh, 5000)
    return () => {
      active = false
      clearInterval(timer)
    }
  }, [])

  return (
    <div
      style={{
        flex: 'none',
        display: 'flex',
        alignItems: 'center',
        gap: 18,
        padding: '10px 24px',
        background: C.white,
        borderBottom: `1.5px solid ${C.border}`,
      }}
    >
      <img
        src="/logo.webp"
        alt="ピタフレ"
        onClick={() => flow.go('home')}
        {...clickable(() => flow.go('home'), 'ホームへ')}
        style={{ cursor: 'pointer', height: 40, display: 'block', flex: 'none' }}
      />
      <div
        onClick={() => flow.screen !== 'search' && flow.go('search')}
        {...clickable(() => flow.go('search'), 'さがす')}
        style={{
          cursor: 'pointer',
          flex: 1,
          maxWidth: 420,
          display: 'flex',
          alignItems: 'center',
          gap: 8,
          background: C.surface,
          border: `1.5px solid ${C.border}`,
          borderRadius: 20,
          padding: '9px 16px',
        }}
      >
        <SearchIcon size={14} color={C.muted} strokeWidth={2.4} />
        <span style={{ fontSize: 12, color: C.muted }}>ゲーム名・プレイスタイルで検索</span>
      </div>
      <div style={{ flex: 1 }} />
      <div
        onClick={() => flow.go('wallet')}
        {...clickable(() => flow.go('wallet'), `コイン残高 ${flow.coinBalance}`)}
        style={{
          cursor: 'pointer',
          display: 'flex',
          alignItems: 'center',
          gap: 6,
          background: C.surfaceLavender,
          border: `1.5px solid ${C.border}`,
          borderRadius: 20,
          padding: '7px 14px',
        }}
      >
        <Coin size={15} color={C.ink} />
        <span style={{ fontSize: 12.5, color: C.ink, fontVariantNumeric: 'tabular-nums' }}>
          {flow.coinBalance.toLocaleString()}
        </span>
      </div>
      <div
        onClick={() => flow.go('notifications')}
        {...clickable(
          () => flow.go('notifications'),
          unreadNotifs > 0 ? `通知 未読${unreadNotifs}件` : '通知',
        )}
        style={{
          cursor: 'pointer',
          position: 'relative',
          width: 38,
          height: 38,
          borderRadius: 8,
          background: C.white,
          border: `1.5px solid ${C.border}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          flex: 'none',
        }}
      >
        <Bell size={17} color={C.ink} />
        {isBackendConfigured && unreadNotifs > 0 && (
          <span
            aria-hidden
            style={{
              position: 'absolute',
              top: -5,
              right: -5,
              minWidth: 16,
              height: 16,
              padding: '0 4px',
              boxSizing: 'border-box',
              borderRadius: 8,
              background: C.badge,
              color: '#fff',
              fontSize: 10,
              lineHeight: '16px',
              textAlign: 'center',
              fontWeight: 700,
              border: `1.5px solid ${C.white}`,
            }}
          >
            {unreadNotifs > 99 ? '99+' : unreadNotifs}
          </span>
        )}
      </div>
      <div
        onClick={() => flow.go('mypage')}
        {...clickable(() => flow.go('mypage'), 'マイページ')}
        style={{
          cursor: 'pointer',
          width: 38,
          height: 38,
          borderRadius: '50%',
          background: C.lime,
          border: `1.5px solid ${C.border}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          fontSize: 15,
          color: C.ink,
          flex: 'none',
        }}
      >
        {flow.nickname.charAt(0) || '?'}
      </div>
    </div>
  )
}
