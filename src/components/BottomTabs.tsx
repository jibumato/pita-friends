/** 下部タブバー(ホーム/さがす/募集/トーク/マイページ)。現在画面から自動でハイライト。 */
import { useEffect, useState } from 'react'
import { color as C } from '../theme/tokens'
import { Home, Search, PlusCircle, Chat, User } from './Icon'
import { activeTabOf, tabToScreen, type ScreenKey, type TabKey } from '../flow'
import { clickable } from '../hooks/clickable'
import { isBackendConfigured } from '../lib/supabase'
import { fetchUnreadTalkCount } from '../lib/queries'

const TABS: { key: TabKey; label: string; Icon: typeof Home }[] = [
  { key: 'home', label: 'ホーム', Icon: Home },
  { key: 'search', label: 'さがす', Icon: Search },
  { key: 'post', label: '募集', Icon: PlusCircle },
  { key: 'talk', label: 'トーク', Icon: Chat },
  { key: 'mypage', label: 'マイページ', Icon: User },
]

export default function BottomTabs({
  current,
  onNavigate,
}: {
  current: ScreenKey
  onNavigate: (screen: ScreenKey) => void
}) {
  const active = activeTabOf(current)
  // 未読トーク数。画面を移動するたびにこのコンポーネントが再マウントされるので、
  // 都度取り直して最新の未読を反映する。
  const [unread, setUnread] = useState(0)
  useEffect(() => {
    if (!isBackendConfigured) return
    let alive = true
    const refresh = () =>
      fetchUnreadTalkCount()
        .then((n) => alive && setUnread(n))
        .catch(() => {
          /* 取得失敗時はバッジを出さないだけ */
        })
    refresh()
    // 別画面にいる間に届いた新着にも気づけるよう、20秒ごとに取り直す
    const timer = setInterval(refresh, 20000)
    return () => {
      alive = false
      clearInterval(timer)
    }
  }, [current])

  return (
    <div
      style={{
        display: 'flex',
        justifyContent: 'space-around',
        alignItems: 'center',
        padding: '10px 8px 24px',
        background: C.white,
        borderTop: `1.5px solid ${C.border}`,
      }}
    >
      {TABS.map(({ key, label, Icon }) => {
        const on = key === active
        const c = on ? C.lavender : C.placeholder
        const badge = key === 'talk' && unread > 0 ? (unread > 99 ? '99+' : String(unread)) : null
        return (
          <div
            key={key}
            onClick={() => onNavigate(tabToScreen[key])}
            {...clickable(() => onNavigate(tabToScreen[key]), badge ? `${label} 未読${unread}件` : label)}
            aria-current={on || undefined}
            style={{
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 3,
              cursor: 'pointer',
              flex: 1,
            }}
          >
            <div style={{ position: 'relative', display: 'flex' }}>
              <Icon color={c} />
              {badge && (
                <span
                  aria-hidden
                  style={{
                    position: 'absolute',
                    top: -5,
                    left: 'calc(50% + 4px)',
                    minWidth: 16,
                    height: 16,
                    padding: '0 4px',
                    boxSizing: 'border-box',
                    borderRadius: 8,
                    background: C.avatarPink,
                    color: '#fff',
                    fontSize: 10,
                    lineHeight: '16px',
                    textAlign: 'center',
                    fontWeight: 700,
                    border: `1.5px solid ${C.white}`,
                  }}
                >
                  {badge}
                </span>
              )}
            </div>
            <span style={{ fontSize: 10, color: c }}>{label}</span>
          </div>
        )
      })}
    </div>
  )
}
