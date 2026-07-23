/** デスクトップ専用の左サイドナビ。BottomTabsのデスクトップ表示を置き換える縦型ナビ。 */
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { Home, Search, PlusCircle, Chat, User } from './Icon'
import { activeTabOf, tabToScreen, SEARCH_DEMO_FILTERS, SEARCH_REAL_FILTERS, type TabKey } from '../flow'
import { clickable } from '../hooks/clickable'
import { isBackendConfigured } from '../lib/supabase'

const TABS: { key: TabKey; label: string; Icon: typeof Home }[] = [
  { key: 'home', label: 'ホーム', Icon: Home },
  { key: 'search', label: 'さがす', Icon: Search },
  { key: 'post', label: '募集', Icon: PlusCircle },
  { key: 'talk', label: 'トーク', Icon: Chat },
  { key: 'mypage', label: 'マイページ', Icon: User },
]

export default function DesktopSidebar({ flow }: { flow: Flow }) {
  const active = activeTabOf(flow.screen)

  return (
    <div
      style={{
        flex: 'none',
        width: 224,
        display: 'flex',
        flexDirection: 'column',
        gap: 4,
        padding: '18px 14px',
        borderRight: `1.5px solid ${C.border}`,
        background: C.white,
        overflowY: 'auto',
      }}
    >
      {TABS.map(({ key, label, Icon }) => {
        const on = key === active
        const c = on ? C.lavender : C.body
        return (
          <div
            key={key}
            onClick={() => flow.go(tabToScreen[key])}
            {...clickable(() => flow.go(tabToScreen[key]), label)}
            aria-current={on || undefined}
            style={{
              cursor: 'pointer',
              display: 'flex',
              alignItems: 'center',
              gap: 10,
              padding: '10px 12px',
              borderRadius: 8,
              background: on ? C.surfaceLavender : 'transparent',
            }}
          >
            <Icon size={17} color={c} />
            <span style={{ fontSize: 13, color: c }}>{label}</span>
          </div>
        )
      })}

      {flow.screen === 'search' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4, marginTop: 10 }}>
          <span style={{ fontSize: 11, color: C.muted, letterSpacing: '.06em', padding: '0 4px' }}>絞り込み</span>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, padding: '4px 2px' }}>
            {(isBackendConfigured ? SEARCH_REAL_FILTERS : SEARCH_DEMO_FILTERS).map((f) => {
              const sel = !!flow.searchFilters[f]
              return (
                <span
                  key={f}
                  onClick={() => flow.toggleSearchFilter(f)}
                  {...clickable(() => flow.toggleSearchFilter(f), f)}
                  style={{
                    cursor: 'pointer',
                    fontSize: 11.5,
                    color: C.ink,
                    background: sel ? C.lime : C.surface,
                    border: `1.5px solid ${C.border}`,
                    padding: '5px 10px',
                    borderRadius: 6,
                  }}
                >
                  {f}
                </span>
              )
            })}
          </div>
        </div>
      )}

      <div style={{ marginTop: 'auto', paddingTop: 14 }}>
        <div
          onClick={() => flow.go('hostSettings')}
          {...clickable(() => flow.go('hostSettings'), 'ホストになる')}
          style={{
            cursor: 'pointer',
            textAlign: 'center',
            fontSize: 12.5,
            color: C.ink,
            background: C.lime,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
            boxShadow: `2px 2px 0 ${C.shadowCol}`,
            padding: '10px 0',
          }}
        >
          ＋ ホストになる
        </div>
      </div>
    </div>
  )
}
