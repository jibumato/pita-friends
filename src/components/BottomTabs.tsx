/** 下部タブバー(ホーム/さがす/募集/トーク/マイページ)。active でハイライト。 */
import { color as C } from '../theme/tokens'
import { Home, Search, PlusCircle, Chat, User } from './Icon'

type TabKey = 'home' | 'search' | 'post' | 'talk' | 'mypage'

const TABS: { key: TabKey; label: string; Icon: typeof Home }[] = [
  { key: 'home', label: 'ホーム', Icon: Home },
  { key: 'search', label: 'さがす', Icon: Search },
  { key: 'post', label: '募集', Icon: PlusCircle },
  { key: 'talk', label: 'トーク', Icon: Chat },
  { key: 'mypage', label: 'マイページ', Icon: User },
]

export default function BottomTabs({
  active = 'home',
  onSelect,
}: {
  active?: TabKey
  onSelect?: (key: TabKey) => void
}) {
  return (
    <div
      style={{
        display: 'flex',
        justifyContent: 'space-around',
        alignItems: 'center',
        padding: '10px 8px 24px',
        background: C.white,
        borderTop: `1.5px solid ${C.ink}`,
      }}
    >
      {TABS.map(({ key, label, Icon }) => {
        const on = key === active
        const c = on ? C.lavender : C.placeholder
        return (
          <div
            key={key}
            onClick={() => onSelect?.(key)}
            style={{
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: 3,
              cursor: onSelect ? 'pointer' : 'default',
            }}
          >
            <Icon color={c} />
            <span style={{ fontSize: 10, color: c }}>{label}</span>
          </div>
        )
      })}
    </div>
  )
}
