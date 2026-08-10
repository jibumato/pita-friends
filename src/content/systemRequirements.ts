/**
 * 推奨環境。**利用規約 第3条7項が「本サービス上に表示します」と約束している。**
 *
 * ■ なぜこのファイルがあるか
 *   第3条7項はこう書いてある:
 *     「本サービスの利用に必要な通信機器・ソフトウェアおよび通信回線は、
 *      ユーザーの費用と責任において用意するものとします。**当社は、推奨する
 *      動作環境を本サービス上に表示します。**推奨環境以外での動作は保証しません」
 *
 *   条文を外出しした以上、画面に出さないと守れない約束になる
 *   （`docs/legal/terms-implementation-matrix.md` の考え方。G2 と同じ形）。
 *   2026-08-07 の時点で、アプリのどこにも推奨環境の記載が無かった。
 *
 * ■ 数字の出どころ
 *   憶測で書かない。**実装から辿れるものだけを書く。**
 *     ・下限のブラウザ … Vite 5 の既定ビルドターゲット `modules`
 *       （ES2020 が通る版＝Safari 14 / Chrome 87 / Edge 88 / Firefox 78）
 *     ・iOS の通知 … `src/lib/push.ts`。Safari のタブで開いているあいだは
 *       `PushManager` そのものが無く、ホーム画面に追加しないと使えない。
 *       Web Push が iOS に来たのは 16.4
 *     ・常時接続 … Realtime（WebSocket）でトークと通知を受けている
 *
 * ■ 変えたら
 *   ビルドターゲットを変えたとき、対応ブラウザを絞ったとき、
 *   通知の仕組みを変えたときは、**ここも直す。**
 *   ここが古いと、規約の約束のほうが嘘になる。
 */

export type RequirementGroup = {
  title: string
  rows: { label: string; body: string }[]
}

export const SYSTEM_REQUIREMENTS: RequirementGroup[] = [
  {
    title: '対応する環境',
    rows: [
      {
        label: 'iPhone / iPad',
        body: 'iOS・iPadOS 16.4 以降の Safari（最新版を推奨します）',
      },
      {
        label: 'Android',
        body: 'Android 10 以降の Google Chrome（最新版を推奨します）',
      },
      {
        label: 'パソコン',
        body: 'Google Chrome / Microsoft Edge / Safari / Firefox の最新版',
      },
      {
        label: '通信環境',
        body: 'インターネットへの常時接続が必要です。トークと通知は接続中のみ届きます。',
      },
    ],
  },
  {
    title: '必要な設定',
    rows: [
      { label: 'JavaScript', body: '有効にしてください。無効では利用できません。' },
      {
        label: 'Cookie',
        body: 'ログイン状態の保持に使います。有効にしてください。',
      },
    ],
  },
  {
    title: '通知について',
    rows: [
      {
        label: 'iPhone / iPad',
        body: 'ホーム画面に追加した場合にのみ通知を受け取れます。Safari のタブで開いているあいだは、iOS の仕様により通知を利用できません。',
      },
      {
        label: 'Android・パソコン',
        body: 'ブラウザで通知を許可すると受け取れます。',
      },
    ],
  },
]

/**
 * 動作の下限。これを下回る版では表示が崩れる、または動きません。
 * 「推奨」ではなく「ここから下は動かない」線なので、分けて出す。
 */
export const MINIMUM_BROWSERS =
  'Safari 14 以降 ／ Google Chrome 87 以降 ／ Microsoft Edge 88 以降 ／ Firefox 78 以降'

/** 規約 第3条7項の文言に合わせた但し書き。 */
export const REQUIREMENTS_NOTE =
  '推奨環境以外での動作は保証しません。本サービスの利用に必要な通信機器・ソフトウェア・通信回線は、お客さまの費用と責任においてご用意ください（利用規約 第3条7項）。'
