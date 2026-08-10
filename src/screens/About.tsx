/**
 * サービス紹介（`/about`）。**ログイン不要で読めることが要件**。
 *
 * 銀行の口座開設審査で「ホームページの情報量が少なく、実際に事業活動を
 * 行っていることが確認できない」という不備通知を受けて作った画面
 * （2026-08-07。`docs/銀行_書類不備の対応.txt` 3(b)）。
 * 通知が名指しで求めているのは **価格・購入方法・サービスの流れ** の3つで、
 * それまではどれもログインの内側にしか無かった。
 *
 * ■ 数字は必ず出典から出す
 *   コインのパックは `COIN_PACKS`、あんしんサポート料は `safetyFeeYen`、
 *   手数料の率はサーバの `fee_rates`。**この画面に定数を置かない。**
 *   ここに写した瞬間、料率を変えたときにこのページだけ古い数字を出し続ける。
 *   申込前の価格表示なので、ずれると景表法の問題になる。
 *
 * ■ 手数料が取れなかったときは、率を出さずに構造だけ書く
 *   「20%」を保険の定数で出すと、サーバの段が変わったときに嘘になる。
 *   出せないなら**出さない**。読む人にとっては率の不在より誤りのほうが重い。
 *
 * ■ 「20%から」とだけ言い、下限だけを単独で出さない
 *   下限（10%）を上限のように書くのは有利誤認（`sns-launch-kit.md` §6-2）。
 *   段の一覧とリピート割を、条件ごと並べて出す。
 */
import { useEffect, useState } from 'react'
import type { Flow } from '../App'
import { color as C } from '../theme/tokens'
import Screen from '../components/Screen'
import StatusBar from '../components/StatusBar'
import { SubHeader } from '../components/Ui'
import LegalLinks from '../components/LegalLinks'
import { COIN_PACKS } from '../flow'
import { safetyFeeYen } from '../content/pricing'
import { isBackendConfigured } from '../lib/supabase'
import { fetchFeeRates, type FeeRates } from '../lib/queries'
import {
  SYSTEM_REQUIREMENTS,
  MINIMUM_BROWSERS,
  REQUIREMENTS_NOTE,
} from '../content/systemRequirements'
import {
  OVERVIEW_LEAD,
  OVERVIEW_SCOPE,
  OVERVIEW_STEPS,
  OVERVIEW_PAYMENT,
  OVERVIEW_HOST,
  OVERVIEW_SAFETY,
} from '../content/serviceOverview'

const yen = (n: number) => `${n.toLocaleString('ja-JP')}円`

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      <h2
        style={{
          margin: 0,
          fontSize: 15,
          fontWeight: 800,
          color: C.ink,
          borderLeft: `4px solid ${C.lavender}`,
          paddingLeft: 8,
          lineHeight: 1.4,
        }}
      >
        {title}
      </h2>
      {children}
    </section>
  )
}

/** ラベルと説明の2列。狭い幅では縦に積む。 */
function DefRows({ rows }: { rows: { label: string; body: string }[] }) {
  return (
    <dl style={{ margin: 0, display: 'flex', flexDirection: 'column', gap: 8 }}>
      {rows.map((r) => (
        <div
          key={r.label}
          style={{
            display: 'flex',
            flexWrap: 'wrap',
            gap: '2px 12px',
            padding: '8px 10px',
            background: C.white,
            border: `1.5px solid ${C.border}`,
            borderRadius: 8,
          }}
        >
          <dt style={{ flex: '0 0 140px', fontSize: 11.5, fontWeight: 700, color: C.ink }}>
            {r.label}
          </dt>
          <dd style={{ flex: '1 1 220px', margin: 0, fontSize: 11.5, lineHeight: 1.8, color: C.body }}>
            {r.body}
          </dd>
        </div>
      ))}
    </dl>
  )
}

export default function About({ flow }: { flow: Flow }) {
  const [rates, setRates] = useState<FeeRates | null>(null)

  useEffect(() => {
    if (!isBackendConfigured) return
    let active = true
    fetchFeeRates()
      .then((r) => {
        if (active) setRates(r)
      })
      .catch(() => {
        /* 率が出せなくても、ページの他の内容は読める。構造だけ出す */
      })
    return () => {
      active = false
    }
  }, [])

  return (
    <Screen background={C.surface}>
      <StatusBar time="21:47" />
      <SubHeader title="ピタフレとは" onBack={() => flow.go('home')} />
      <div
        className="pita-scroll"
        style={{
          flex: 1,
          overflowY: 'auto',
          padding: '4px 20px 40px',
          display: 'flex',
          flexDirection: 'column',
          gap: 26,
        }}
      >
        <p style={{ margin: 0, fontSize: 12.5, lineHeight: 1.9, color: C.body }}>{OVERVIEW_LEAD}</p>

        <Section title="このサービスで扱うもの">
          <DefRows rows={OVERVIEW_SCOPE} />
        </Section>

        <Section title="ご利用の流れ">
          <ol style={{ margin: 0, padding: 0, listStyle: 'none', display: 'flex', flexDirection: 'column', gap: 8 }}>
            {OVERVIEW_STEPS.map((s) => (
              <li
                key={s.step}
                style={{
                  display: 'flex',
                  gap: 10,
                  padding: '10px 12px',
                  background: C.white,
                  border: `1.5px solid ${C.border}`,
                  borderRadius: 8,
                }}
              >
                <span
                  style={{
                    flex: 'none',
                    width: 22,
                    height: 22,
                    borderRadius: '50%',
                    background: C.lime,
                    border: `1.5px solid ${C.border}`,
                    display: 'grid',
                    placeItems: 'center',
                    fontSize: 11,
                    fontWeight: 800,
                    color: C.ink,
                  }}
                >
                  {s.step}
                </span>
                <span style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
                  <strong style={{ fontSize: 12, color: C.ink }}>{s.title}</strong>
                  <span style={{ fontSize: 11.5, lineHeight: 1.8, color: C.body }}>{s.body}</span>
                </span>
              </li>
            ))}
          </ol>
        </Section>

        <Section title="料金">
          <DefRows rows={OVERVIEW_PAYMENT} />

          <p style={{ margin: 0, fontSize: 11.5, lineHeight: 1.8, color: C.body }}>
            コインは次の単位で購入できます。あんしんサポート料は、購入のたびにコインの
            価格に応じてお支払いいただくものです（コインの代金ではありません）。
          </p>

          <div style={{ overflowX: 'auto' }}>
            <table style={{ borderCollapse: 'collapse', fontSize: 11.5, minWidth: 320 }}>
              <thead>
                <tr>
                  {['コイン', 'コインの価格', 'あんしんサポート料', 'お支払い総額'].map((h) => (
                    <th
                      key={h}
                      style={{
                        textAlign: 'right',
                        padding: '6px 10px',
                        borderBottom: `1.5px solid ${C.border}`,
                        color: C.ink,
                        whiteSpace: 'nowrap',
                      }}
                    >
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody style={{ fontVariantNumeric: 'tabular-nums' }}>
                {COIN_PACKS.map((p) => {
                  const fee = safetyFeeYen(p.priceYen)
                  return (
                    <tr key={p.id}>
                      <td style={{ textAlign: 'right', padding: '6px 10px', color: C.ink }}>
                        {p.coins.toLocaleString('ja-JP')}
                      </td>
                      <td style={{ textAlign: 'right', padding: '6px 10px', color: C.body }}>
                        {yen(p.priceYen)}
                      </td>
                      <td style={{ textAlign: 'right', padding: '6px 10px', color: C.body }}>
                        {yen(fee)}
                      </td>
                      <td style={{ textAlign: 'right', padding: '6px 10px', fontWeight: 700, color: C.ink }}>
                        {yen(p.priceYen + fee)}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
          <span style={{ fontSize: 10.5, lineHeight: 1.7, color: C.muted }}>
            価格はすべて消費税込みです。予約に必要なコインは、ピタメイトが設定した
            30分あたりの料金と、予約する時間の長さで決まります。
          </span>
        </Section>

        <Section title="ピタメイトとしてご利用の方へ">
          <DefRows rows={OVERVIEW_HOST} />

          <p style={{ margin: 0, fontSize: 11.5, lineHeight: 1.8, color: C.body }}>
            予約が完了すると、対価から当社のプラットフォーム利用料を差し引いた額が
            報酬コインとして確定します。利用料の率は、その月の予約売上の累計に応じて
            段階的に下がります。
          </p>

          {rates ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <div style={{ overflowX: 'auto' }}>
                <table style={{ borderCollapse: 'collapse', fontSize: 11.5, minWidth: 300 }}>
                  <thead>
                    <tr>
                      {['その月の予約売上の累計', '利用料の率'].map((h) => (
                        <th
                          key={h}
                          style={{
                            textAlign: 'left',
                            padding: '6px 10px',
                            borderBottom: `1.5px solid ${C.border}`,
                            color: C.ink,
                            whiteSpace: 'nowrap',
                          }}
                        >
                          {h}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody style={{ fontVariantNumeric: 'tabular-nums' }}>
                    {rates.bookingTiers.map((t, i) => (
                      <tr key={i}>
                        <td style={{ padding: '6px 10px', color: C.body }}>
                          {t.upperBound === null
                            ? `${rates.bookingTiers[i - 1]?.upperBound?.toLocaleString('ja-JP') ?? 0}コインを超える部分`
                            : `${t.upperBound.toLocaleString('ja-JP')}コインまでの部分`}
                        </td>
                        <td style={{ padding: '6px 10px', fontWeight: 700, color: C.ink }}>{t.percent}%</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <span style={{ fontSize: 11, lineHeight: 1.8, color: C.body }}>
                同じゲストからの2回目以降のご予約は、上の率からさらに
                {rates.repeatDiscountPoints}ポイント下がります（{rates.floorPercent}%を下回りません）。
                ありがとうギフトの利用料は一律{rates.giftPercent}%です。
              </span>
            </div>
          ) : (
            <span style={{ fontSize: 11, lineHeight: 1.8, color: C.body }}>
              率は段階制で、その月の予約売上の累計が増えるほど下がります。同じゲストからの
              2回目以降のご予約は、さらに引き下げられます。具体的な率は、ピタメイト設定の
              画面に表示しています。
            </span>
          )}
        </Section>

        <Section title="安心して遊ぶための仕組み">
          <ul style={{ margin: 0, paddingLeft: 18, display: 'flex', flexDirection: 'column', gap: 6 }}>
            {OVERVIEW_SAFETY.map((s) => (
              <li key={s} style={{ fontSize: 11.5, lineHeight: 1.8, color: C.body }}>
                {s}
              </li>
            ))}
          </ul>
        </Section>

        {/* 推奨環境は**規約 第3条7項が表示を約束している**もの。
            紹介ページに置くのは、購入や登録より前に読める場所がここだけだから
            （設定画面はログインの内側にある）。 */}
        <Section title="推奨環境">
          {SYSTEM_REQUIREMENTS.map((g) => (
            <div key={g.title} style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <strong style={{ fontSize: 12, color: C.ink }}>{g.title}</strong>
              <DefRows rows={g.rows} />
            </div>
          ))}
          <p style={{ margin: 0, fontSize: 11.5, lineHeight: 1.8, color: C.body }}>
            <strong style={{ color: C.ink }}>動作の下限：</strong>
            {MINIMUM_BROWSERS}
          </p>
          <span style={{ fontSize: 10.5, lineHeight: 1.7, color: C.muted }}>
            {REQUIREMENTS_NOTE}
          </span>
        </Section>

        <Section title="事業者情報・規約">
          <p style={{ margin: 0, fontSize: 11.5, lineHeight: 1.8, color: C.body }}>
            事業者の名称・所在地・連絡先は「特定商取引法に基づく表記」に、コインの
            取扱いは「資金決済法に基づく表示」に記載しています。
          </p>
          <LegalLinks flow={flow} align="flex-start" size={11.5} gap="8px 18px" showAbout={false} />
        </Section>
      </div>
    </Screen>
  )
}
