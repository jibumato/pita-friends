/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL?: string
  readonly VITE_SUPABASE_ANON_KEY?: string
  /**
   * プッシュ通知(0064)のVAPID公開鍵。**公開されて問題ない値。**
   * 秘密鍵(VAPID_PRIVATE_KEY)はSupabaseのSecretsにだけ置く。
   * 未設定ならプッシュの導線そのものを出さない。
   */
  readonly VITE_VAPID_PUBLIC_KEY?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}

/** ビルド時刻。`YYYYMMDDHHMM` の数字だけ(UTC・分まで)。vite.config.ts の define で埋め込む。 */
declare const __BUILD_ID__: string
