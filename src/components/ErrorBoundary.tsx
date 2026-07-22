import { Component, type ReactNode } from 'react'

/**
 * 描画中の例外を捕捉して、真っ白ではなくエラー内容を画面に表示する。
 * 原因調査のため、メッセージとスタックを見せる(本番でも一時的に表示)。
 */
export default class ErrorBoundary extends Component<
  { children: ReactNode },
  { error: Error | null }
> {
  state = { error: null as Error | null }

  static getDerivedStateFromError(error: Error) {
    return { error }
  }

  componentDidCatch(error: Error) {
    console.error('[pita-friends] 画面の描画でエラー:', error)
  }

  render() {
    if (this.state.error) {
      return (
        <div
          style={{
            padding: 20,
            fontFamily: 'monospace',
            fontSize: 12,
            lineHeight: 1.7,
            color: '#1A1A2E',
            background: '#fff',
            minHeight: '100vh',
            boxSizing: 'border-box',
            whiteSpace: 'pre-wrap',
            wordBreak: 'break-word',
          }}
        >
          <div style={{ fontSize: 15, fontWeight: 700, marginBottom: 10 }}>
            画面の表示中にエラーが発生しました
          </div>
          <div style={{ color: '#C0392B', marginBottom: 12 }}>
            {this.state.error.message}
          </div>
          <details open>
            <summary style={{ cursor: 'pointer', marginBottom: 8 }}>詳細（スタックトレース）</summary>
            <div style={{ fontSize: 10.5, color: '#555' }}>{this.state.error.stack}</div>
          </details>
          <div style={{ marginTop: 16 }}>
            <button
              onClick={() => window.location.reload()}
              style={{
                fontSize: 13,
                padding: '8px 16px',
                borderRadius: 8,
                border: '1.5px solid #1A1A2E',
                background: '#D8F26B',
                cursor: 'pointer',
              }}
            >
              再読み込み
            </button>
          </div>
        </div>
      )
    }
    return this.props.children
  }
}
