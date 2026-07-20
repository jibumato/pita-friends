import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import Markdown from '../components/Markdown'
import { LEGAL_DOCS } from '../content/legalDocs'

export default function LegalDoc({ flow }: { flow: Flow }) {
  const key = flow.legalDocKey
  const doc = key ? LEGAL_DOCS[key] : null

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title={doc?.title ?? '規約・ポリシー'} onBack={() => flow.go(flow.legalDocReturn)} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '4px 20px 32px',
          display: 'flex',
          flexDirection: 'column',
          gap: 12,
        }}
      >
        {!doc ? (
          <span style={{ fontSize: 12, color: C.muted }}>ドキュメントが見つかりませんでした。</span>
        ) : (
          <>
            <div
              style={{
                background: C.lime,
                border: `1.5px solid ${C.border}`,
                borderRadius: 8,
                padding: '10px 12px',
                fontSize: 10.5,
                lineHeight: 1.7,
                color: C.ink,
              }}
            >
              これは施行前のドラフトです。内容は弁護士レビューを経て確定します。「【　】」は確定前の項目です。
            </div>
            <Markdown source={doc.markdown} />
          </>
        )}
      </div>
    </Screen>
  )
}
