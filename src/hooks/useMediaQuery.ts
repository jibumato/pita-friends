import { useEffect, useState } from 'react'

/** メディアクエリのマッチ状態を返す(リサイズに追従)。 */
export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(
    () => typeof window !== 'undefined' && window.matchMedia(query).matches,
  )

  useEffect(() => {
    const mql = window.matchMedia(query)
    const onChange = () => setMatches(mql.matches)
    onChange()
    mql.addEventListener('change', onChange)
    return () => mql.removeEventListener('change', onChange)
  }, [query])

  return matches
}

/** 全画面(実機)表示にするモバイル幅かどうか。 */
export function useIsMobile(): boolean {
  return useMediaQuery('(max-width: 640px)')
}
