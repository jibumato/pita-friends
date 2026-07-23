/**
 * PC(デスクトップ/タブレット)向けランディングページ。GameRoomを参考にした
 * 全幅Webレイアウト。スマホの実機モックは使わない。
 * デスクトップで screen==='welcome' のときにアプリの代わりに表示し、
 * 「はじめる」等でアプリ本体(中央パネル)に入る。
 * 文言は「ゲーム仲間」で統一し、出会い系ではない一線を守る。
 */
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import { isBackendConfigured } from '../lib/supabase'

const PC_GAMES = ['Apex Legends', 'VALORANT', 'Overwatch 2', 'League of Legends', 'Fortnite', 'Marvel Rivals', 'Minecraft', 'モンハン']

const DEMO_HOSTS = [
  { initial: 'の', color: '#FFC7D9', name: 'ののか', verified: true, games: ['Apex', 'VALORANT'], rate: 250, rating: 4.9 },
  { initial: 'み', color: '#B3E5F2', name: 'みなと', verified: true, games: ['Overwatch 2'], rate: 300, rating: 4.8 },
  { initial: 'り', color: '#C9F2C7', name: 'りく', verified: false, games: ['LoL'], rate: 200, rating: 4.7 },
  { initial: 'あ', color: '#E3DCFF', name: 'あおい', verified: true, games: ['Fortnite'], rate: 280, rating: 4.8 },
]

const FEATURES = [
  { icon: '🎮', title: '一緒に遊ぶ時間を予約', body: '上手い人・気の合う人と、30分から。コインで完結するので、外部で連絡先を交換する必要はありません。' },
  { icon: '🛡️', title: '女性も安心の設計', body: '誰から誘いを受けるか自分でコントロール。承認制・ワンタップ通報/ブロック・本人確認・みまもり付き。' },
  { icon: '🏆', title: '実力がちゃんと報われる', body: 'プレイ実績・評価・信頼性でランキング。投げ銭や課金額ではありません。ホストは遊んだ時間が報酬コインに。' },
]

const STEPS = [
  { n: '01', title: 'さがす', body: '遊びたいゲーム・時間帯からホストを探す。' },
  { n: '02', title: '予約する', body: '遊ぶ時間をコインで予約。ホストが承諾で成立。' },
  { n: '03', title: '一緒にプレイ', body: 'トークで待ち合わせて合流。終わったら評価。' },
]

export default function LandingDesktop({ flow }: { flow: Flow }) {
  const start = () => flow.go(isBackendConfigured ? 'signUp' : 'consent')

  return (
    <div className="lp-wrap" style={{ width: '100%', minHeight: '100vh', background: C.surface, color: C.ink }}>
      {/* ===== ナビ ===== */}
      <header
        style={{
          position: 'sticky', top: 0, zIndex: 20,
          background: 'rgba(247,246,251,.86)', backdropFilter: 'blur(8px)',
          borderBottom: `1.5px solid ${C.border}`,
        }}
      >
        <div style={{ maxWidth: 1120, margin: '0 auto', padding: '12px 24px', display: 'flex', alignItems: 'center', gap: 20 }}>
          <img src="/logo.webp" alt="ピタフレ" style={{ height: 40 }} />
          <nav className="lp-nav" style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 22 }}>
            <a className="lp-navlink" href="#features">特長</a>
            <a className="lp-navlink" href="#how">遊び方</a>
            <a className="lp-navlink" href="#safety">安全</a>
            <a className="lp-navlink" href="#host">ホスト</a>
          </nav>
          <button className="lp-cta" onClick={() => flow.go(isBackendConfigured ? 'signIn' : 'home')} style={ctaGhostSm}>
            ログイン
          </button>
          <button className="lp-cta" onClick={start} style={ctaPrimary}>▶ はじめる</button>
        </div>
      </header>

      {/* ===== ヒーロー ===== */}
      <section style={{ background: `radial-gradient(1200px 500px at 80% -10%, ${C.surfaceLavender}, transparent 60%)` }}>
        <div style={{ maxWidth: 1120, margin: '0 auto', padding: '56px 24px 44px' }}>
          <div className="lp-hero">
            <div style={{ display: 'flex', flexDirection: 'column', gap: 22 }}>
              <span style={pill}>近日公開 🔜</span>
              <h1 style={{ fontSize: 'clamp(34px, 4.4vw, 56px)', lineHeight: 1.15, margin: 0, letterSpacing: '.01em' }}>
                ピタッと合う、
                <br />
                <span style={{ position: 'relative', display: 'inline-block' }}>
                  ゲーム仲間。
                  <span style={{ position: 'absolute', left: 0, right: 0, bottom: 6, height: 14, background: C.lime, zIndex: -1, borderRadius: 8 }} />
                </span>
              </h1>
              <p style={{ fontSize: 17, color: C.body, lineHeight: 1.8, margin: 0, maxWidth: '46ch' }}>
                PCゲーム中心。ランクを回したい、まったり遊びたい、深夜の“あと一人”がほしい——
                そんな時間を、<b style={{ color: C.ink }}>安心して</b>見つけられるゲーム仲間マッチングです。
              </p>
              <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
                <button className="lp-cta" onClick={start} style={{ ...ctaPrimary, padding: '14px 26px', fontSize: 15 }}>▶ はじめる（無料）</button>
                <button className="lp-cta" onClick={() => flow.go(isBackendConfigured ? 'signIn' : 'home')} style={ctaGhost}>ログイン</button>
              </div>
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                {['🛡 承認制', '通報・ブロック', '本人確認', 'みまもり'].map((t) => <span key={t} style={chip}>{t}</span>)}
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginTop: 4 }}>
                <span style={{ fontSize: 11.5, color: C.muted }}>対応ゲーム例（PC中心）</span>
                <div style={{ display: 'flex', gap: 7, flexWrap: 'wrap' }}>
                  {PC_GAMES.map((g) => <span key={g} style={gameBadge}>{g}</span>)}
                  <span style={{ ...gameBadge, borderStyle: 'dashed' }}>ほか</span>
                </div>
              </div>
            </div>

            {/* GameRoom型: ホストのカードグリッド(デモ) */}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                <span style={{ fontSize: 14, color: C.ink }}>▶ いま遊べるホスト</span>
                <span style={{ fontSize: 11.5, color: C.lavender }}>もっと見る ›</span>
              </div>
              <div className="lp-hostgrid">
                {DEMO_HOSTS.map((hStr) => (
                  <div key={hStr.name} className="lp-card" style={hostCard}>
                    <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
                      <div style={{ width: 44, height: 44, flex: 'none', borderRadius: 10, background: hStr.color, border: `1.5px solid ${C.border}`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 19, color: C.ink }}>{hStr.initial}</div>
                      <div style={{ minWidth: 0 }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
                          <span style={{ fontSize: 14, color: C.ink }}>{hStr.name}</span>
                          {hStr.verified && <span style={{ fontSize: 8.5, color: C.ink, background: C.lime, border: `1.5px solid ${C.border}`, padding: '1px 4px', borderRadius: 4 }}>✓</span>}
                        </div>
                        <span style={{ fontSize: 10.5, color: C.muted }}>★{hStr.rating.toFixed(1)}・マナー◎</span>
                      </div>
                    </div>
                    <div style={{ display: 'flex', gap: 5, flexWrap: 'wrap' }}>
                      {hStr.games.map((g) => <span key={g} style={{ fontSize: 10, color: C.body, background: C.surface, border: `1.5px solid ${C.border}`, padding: '2px 7px', borderRadius: 5 }}>{g}</span>)}
                    </div>
                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 2 }}>
                      <span style={{ fontSize: 12.5, color: C.ink }}>30分 <b>{hStr.rate}</b> コイン</span>
                      <span onClick={start} style={{ cursor: 'pointer', fontSize: 11.5, color: C.ink, background: C.lime, border: `1.5px solid ${C.border}`, padding: '5px 12px', borderRadius: 6 }}>予約 ▶</span>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* ===== 特長 ===== */}
      <section id="features" style={sectionWrap}>
        <div style={{ maxWidth: 1120, margin: '0 auto', padding: '0 24px' }}>
          <h2 style={h2}>ピタフレでできること</h2>
          <div className="lp-grid3" style={{ marginTop: 26 }}>
            {FEATURES.map((f) => (
              <div key={f.title} className="lp-card" style={card}>
                <span style={{ fontSize: 30 }}>{f.icon}</span>
                <span style={{ fontSize: 18, color: C.ink, marginTop: 10, display: 'block' }}>{f.title}</span>
                <p style={{ fontSize: 13.5, color: C.body, lineHeight: 1.8, margin: '8px 0 0' }}>{f.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ===== 遊び方 ===== */}
      <section id="how" style={{ ...sectionWrap, background: C.surfaceLavender }}>
        <div style={{ maxWidth: 1120, margin: '0 auto', padding: '0 24px' }}>
          <h2 style={h2}>遊び方はかんたん</h2>
          <div className="lp-grid3" style={{ marginTop: 26 }}>
            {STEPS.map((s) => (
              <div key={s.n} style={{ ...card, background: C.white }}>
                <span style={{ fontSize: 13, color: C.lavender, letterSpacing: '.1em' }}>STEP {s.n}</span>
                <span style={{ fontSize: 20, color: C.ink, marginTop: 6, display: 'block' }}>{s.title}</span>
                <p style={{ fontSize: 13.5, color: C.body, lineHeight: 1.8, margin: '8px 0 0' }}>{s.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ===== 安全 ===== */}
      <section id="safety" style={sectionWrap}>
        <div style={{ maxWidth: 1120, margin: '0 auto', padding: '40px 32px', background: C.fill, borderRadius: 22, border: `2px solid ${C.border}`, boxShadow: `8px 8px 0 ${C.lavender}` }}>
          <h2 style={{ ...h2, color: '#fff', textAlign: 'center' }}>ここは、ゲームを楽しむ場所です</h2>
          <p style={{ fontSize: 15, color: '#E3DCFF', textAlign: 'center', lineHeight: 1.9, margin: '14px auto 0', maxWidth: '52ch' }}>
            出会い・恋愛目的の利用は禁止しています。誰もが安心して遊べるよう、女性の安全を最優先に設計しました。
            みんなが気持ちよく遊べる場を、運営とユーザーで一緒に守ります。
          </p>
          <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap', justifyContent: 'center', marginTop: 22 }}>
            {['連絡先を自分でコントロール', '承認制で勝手に始まらない', '通報・ブロックは相手に通知なし', '本人確認で18歳未満を排除', 'メッセージの自動みまもり'].map((t) => (
              <span key={t} style={{ ...chip, background: C.white }}>{t}</span>
            ))}
          </div>
        </div>
      </section>

      {/* ===== ホスト募集 ===== */}
      <section id="host" style={{ ...sectionWrap, background: C.surfaceLavender }}>
        <div style={{ maxWidth: 1120, margin: '0 auto', padding: '0 24px', display: 'flex', gap: 24, alignItems: 'center', flexWrap: 'wrap', justifyContent: 'space-between' }}>
          <div style={{ maxWidth: '52ch' }}>
            <h2 style={h2}>得意なゲームで、ホストにも。</h2>
            <p style={{ fontSize: 15, color: C.body, lineHeight: 1.9, marginTop: 12 }}>
              あなたの遊ぶ時間が報酬コインに。料金は30分ごとに自分で設定。スキマ時間・在宅でOK。
              マナーよく楽しめる人を歓迎します。
            </p>
          </div>
          <button className="lp-cta" onClick={start} style={{ ...ctaPrimary, padding: '15px 28px', fontSize: 15 }}>ホストとして始める ▶</button>
        </div>
      </section>

      {/* ===== フッター ===== */}
      <footer style={{ background: C.fill, color: '#fff' }}>
        <div style={{ maxWidth: 1120, margin: '0 auto', padding: '40px 24px 32px', display: 'flex', flexDirection: 'column', gap: 20 }}>
          <div style={{ display: 'flex', gap: 20, alignItems: 'center', flexWrap: 'wrap' }}>
            <img src="/logo.webp" alt="ピタフレ" style={{ height: 44 }} />
            <span style={{ ...pill, marginLeft: 'auto' }}>近日公開 🔜</span>
          </div>
          <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap' }}>
            {([
              ['利用規約', 'terms'],
              ['プライバシーポリシー', 'privacy'],
              ['特定商取引法に基づく表記', 'tokushoho'],
              ['資金決済法に基づく表示', 'shikin'],
            ] as const).map(([label, key]) => (
              <span key={key} onClick={() => flow.openLegalDoc(key)} style={{ cursor: 'pointer', fontSize: 12.5, color: '#E3DCFF', textDecoration: 'underline' }}>{label}</span>
            ))}
          </div>
          <span style={{ fontSize: 11.5, color: '#B3ABC9' }}>© 2026 ピタフレ — ゲーム仲間マッチングサービス</span>
        </div>
      </footer>
    </div>
  )
}

/* ---- インラインスタイル ---- */
const ctaPrimary: React.CSSProperties = { cursor: 'pointer', background: C.lime, color: C.ink, border: `2px solid ${C.border}`, borderRadius: 10, boxShadow: `3px 3px 0 ${C.border}`, padding: '10px 18px', fontSize: 14, fontFamily: 'inherit' }
const ctaGhost: React.CSSProperties = { cursor: 'pointer', background: C.white, color: C.ink, border: `2px solid ${C.border}`, borderRadius: 10, padding: '14px 26px', fontSize: 15, fontFamily: 'inherit' }
const ctaGhostSm: React.CSSProperties = { cursor: 'pointer', background: 'transparent', color: C.ink, border: `1.5px solid ${C.border}`, borderRadius: 8, padding: '8px 14px', fontSize: 13, fontFamily: 'inherit' }
const pill: React.CSSProperties = { alignSelf: 'flex-start', fontSize: 12, color: C.ink, background: C.lime, border: `1.5px solid ${C.border}`, padding: '5px 13px', borderRadius: 20 }
const chip: React.CSSProperties = { fontSize: 12.5, color: C.ink, background: C.white, border: `1.5px solid ${C.border}`, padding: '7px 13px', borderRadius: 20 }
const gameBadge: React.CSSProperties = { fontSize: 11.5, color: C.body, background: C.white, border: `1.5px solid ${C.border}`, padding: '5px 11px', borderRadius: 6 }
const sectionWrap: React.CSSProperties = { padding: '64px 0' }
const h2: React.CSSProperties = { fontSize: 'clamp(22px, 2.6vw, 30px)', margin: 0, color: C.ink, textAlign: 'center' }
const card: React.CSSProperties = { background: C.white, border: `1.5px solid ${C.border}`, borderRadius: 16, boxShadow: `4px 4px 0 ${C.shadowCol}`, padding: '22px 20px' }
const hostCard: React.CSSProperties = { background: C.white, border: `1.5px solid ${C.border}`, borderRadius: 14, boxShadow: `3px 3px 0 ${C.shadowCol}`, padding: '13px 14px', display: 'flex', flexDirection: 'column', gap: 9 }
