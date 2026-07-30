/**
 * `supabase/migrations/*.sql` と手動で対応させたDB型定義。
 * 実際のSupabaseプロジェクトに接続後は `supabase gen types typescript`
 * で生成し直すことを推奨(スキーマとのズレを防ぐため)。
 *
 * 注記: `@supabase/supabase-js` の型解決は各テーブルが `Relationships`
 * フィールドを持つこと、スキーマが `Views` を持つことを要求する
 * (postgrest-js の `GenericTable` / `GenericSchema` 制約)。欠けていると
 * `SupabaseClient<Database>` のジェネリクスが `never` に落ちて
 * `.select()`/`.update()` の戻り値が軒並み `never` になり、実害の大きい
 * サイレント型崩壊を起こすため、埋め込みリレーションを使わない場合も
 * 空配列で明示する。
 */

export type Gender = 'female' | 'male' | 'na'
/** 本人が選ぶオンライン時の状態。ready=今すぐ遊べる / online=オンライン / busy=取り込み中。 */
export type PresenceStatus = 'ready' | 'online' | 'busy'
export type ContactScope = 'verified' | 'sameGender' | 'all'
export type VerificationStatus = 'pending' | 'verified' | 'rejected'
export type CoinTxType =
  | 'purchase'
  | 'booking_spend'
  | 'refund'
  | 'bonus'
  | 'booking_earned'
  | 'payout'
  | 'expire'
export type CoinLotKind = 'paid' | 'bonus'
export type PayoutStatus = 'pending' | 'paid' | 'failed'
export type BankAccountType = '普通' | '当座'
export type BookingStatus =
  | 'requested'
  | 'confirmed'
  | 'completed'
  | 'cancelled_by_guest'
  | 'cancelled_by_host'
  | 'declined_by_host'
  | 'no_show_host'
  | 'no_show_guest'
export type InviteStatus = 'pending' | 'approved' | 'declined' | 'expired'
export type PromiseStatus = 'scheduled' | 'joined' | 'completed' | 'cancelled'
export type ReportCategory =
  | 'external_invite'
  | 'money_request'
  | 'dating_solicitation'
  | 'harassment'
  | 'impersonation'
  | 'no_show'
  | 'other'
export type ReportSeverity = 'low' | 'high' | 'critical'
export type ReportStatus = 'open' | 'reviewing' | 'resolved'
export type BoardMood = 'エンジョイ' | 'ランク上げ' | 'ガチ'
export type BoardVc = '必須' | 'どちらでも' | 'なし'
export type BoardAudience = '全員' | '同性のみ'
export type BoardStatus = 'open' | 'closed' | 'cancelled'
export type NotificationType =
  | 'invite_received'
  | 'invite_approved'
  | 'message_received'
  | 'verification_approved'
  | 'verification_rejected'
  | 'board_joined'
  | 'booking_cancelled'
  | 'booking_completed'
  | 'booking_requested'
  | 'booking_approved'
  | 'gift_received'
  | 'booking_extended'
  | 'board_cancelled'
  | 'integrity_alert'
  | 'booking_no_show'
  /** 0054: お気に入りのピタメイトが募集枠を開けた */
  | 'host_slots_opened'
export type AccountRequestType = 'data_export' | 'account_deletion'
export type AccountRequestStatus = 'pending' | 'processing' | 'completed'

export type Database = {
  public: {
    Tables: {
      /** 0051: ピタメイトの募集枠(曜日×時・日本時間・毎週くり返し) */
      host_availability: {
        Row: { user_id: string; weekday: number; hour: number }
        Insert: { user_id: string; weekday: number; hour: number }
        Update: { user_id?: string; weekday?: number; hour?: number }
        Relationships: []
      }
      profiles: {
        Row: {
          id: string
          nickname: string
          gender: Gender
          avatar_initial: string
          avatar_color: string
          favorite_games: string[]
          play_style: string
          bio: string
          voice_path: string | null
          voice_seconds: number | null
          avatar_path: string | null
          last_seen_at: string | null
          presence_status: PresenceStatus
          created_at: string
          updated_at: string
        }
        Insert: Partial<Omit<Database['public']['Tables']['profiles']['Row'], 'id'>> & { id: string }
        Update: Partial<Database['public']['Tables']['profiles']['Row']>
        Relationships: []
      }
      profile_trust_stats: {
        Row: {
          user_id: string
          manner_score: number
          review_count: number
          confirmed_count: number
          dotakyan_count: number
          is_verified: boolean
          updated_at: string
        }
        Insert: Record<string, never>
        Update: Record<string, never>
        Relationships: []
      }
      safety_prefs: {
        Row: {
          user_id: string
          contact_scope: ContactScope
          approval_required: boolean
          show_online: boolean
          discoverable: boolean
          block_low_trust: boolean
          updated_at: string
        }
        Insert: Partial<Omit<Database['public']['Tables']['safety_prefs']['Row'], 'user_id'>> & {
          user_id: string
        }
        Update: Partial<Database['public']['Tables']['safety_prefs']['Row']>
        Relationships: []
      }
      identity_verifications: {
        Row: {
          id: string
          user_id: string
          status: VerificationStatus
          provider: string | null
          provider_reference: string | null
          is_adult: boolean | null
          rejected_reason: string | null
          created_at: string
          verified_at: string | null
          document_path: string | null
          selfie_path: string | null
        }
        Insert: {
          id?: string
          user_id: string
          status?: 'pending'
          document_path?: string | null
          selfie_path?: string | null
        }
        Update: Record<string, never>
        Relationships: []
      }
      coin_wallets: {
        Row: { user_id: string; balance: number; bonus_balance: number; earned_balance: number; updated_at: string }
        Insert: Record<string, never>
        Update: Record<string, never>
        Relationships: []
      }
      host_bank_accounts: {
        Row: {
          user_id: string
          bank_name: string
          bank_code: string
          branch_name: string
          branch_code: string
          account_type: BankAccountType
          account_number: string
          account_holder_kana: string
          created_at: string
          updated_at: string
        }
        Insert: {
          user_id: string
          bank_name: string
          bank_code: string
          branch_name: string
          branch_code: string
          account_type: BankAccountType
          account_number: string
          account_holder_kana: string
        }
        Update: {
          bank_name?: string
          bank_code?: string
          branch_name?: string
          branch_code?: string
          account_type?: BankAccountType
          account_number?: string
          account_holder_kana?: string
        }
        Relationships: []
      }
      payouts: {
        Row: {
          id: string
          user_id: string
          coins: number
          amount_yen: number
          fee_yen: number
          status: PayoutStatus
          failure_reason: string | null
          bank_name: string | null
          bank_code: string | null
          branch_name: string | null
          branch_code: string | null
          account_type: string | null
          account_number: string | null
          account_holder_kana: string | null
          paid_at: string | null
          created_at: string
        }
        Insert: Record<string, never>
        Update: Record<string, never>
        Relationships: []
      }
      coin_lots: {
        Row: {
          id: string
          user_id: string
          kind: CoinLotKind
          remaining: number
          expires_at: string
          created_at: string
        }
        Insert: Record<string, never>
        Update: Record<string, never>
        Relationships: []
      }
      coin_transactions: {
        Row: {
          id: string
          user_id: string
          amount: number
          type: CoinTxType
          related_booking_id: string | null
          note: string | null
          created_at: string
        }
        Insert: Record<string, never>
        Update: Record<string, never>
        Relationships: []
      }
      coin_packs: {
        Row: {
          id: string
          coins: number
          bonus_coins: number
          price_yen: number
          sort: number
          active: boolean
        }
        Insert: Record<string, never>
        Update: Record<string, never>
        Relationships: []
      }
      coin_purchases: {
        Row: {
          id: string
          user_id: string
          pack_id: string | null
          coins_credited: number
          price_yen: number
          stripe_session_id: string
          stripe_payment_intent: string | null
          created_at: string
        }
        Insert: Record<string, never>
        Update: Record<string, never>
        Relationships: []
      }
      host_settings: {
        Row: {
          user_id: string
          is_host: boolean
          hourly_rate: number
          games: string[]
          bio: string
          trial_discount_percent: number
          updated_at: string
          /** 0057: 常連への先行予約。開始までこの時間数より先の枠は常連だけが取れる。0で無効。 */
          regulars_first_hours: number
          /** 0056: ピタメイトの「ひとこと」(近況)。60字まで。 */
          status_text: string | null
          status_updated_at: string | null
        }
        Insert: Record<string, never>
        Update: Partial<
          Pick<
            Database['public']['Tables']['host_settings']['Row'],
            | 'is_host'
            | 'hourly_rate'
            | 'games'
            | 'bio'
            | 'trial_discount_percent'
            | 'regulars_first_hours'
          >
        >
        Relationships: []
      }
      bookings: {
        Row: {
          id: string
          guest_id: string
          host_id: string
          duration_minutes: number
          coins: number
          paid_coins: number
          bonus_coins: number
          status: BookingStatus
          scheduled_at: string
          cancel_reason: string | null
          created_at: string
          cancelled_at: string | null
          /** 割引前の定価(0038)。割引が無い場合は coins と同じ。 */
          list_coins: number | null
          /** 適用した初回お試し割引の割引率(%)(0038)。 */
          discount_percent: number
        }
        Insert: Record<string, never>
        Update: Record<string, never>
        Relationships: []
      }
      invites: {
        Row: {
          id: string
          from_user: string
          to_user: string
          game: string
          when_text: string
          message: string
          status: InviteStatus
          created_at: string
          responded_at: string | null
        }
        Insert: {
          id?: string
          from_user: string
          to_user: string
          game: string
          when_text: string
          message?: string
        }
        Update: Record<string, never>
        Relationships: []
      }
      promises: {
        Row: {
          id: string
          invite_id: string | null
          booking_id: string | null
          user_a: string
          user_b: string
          scheduled_at: string
          status: PromiseStatus
          friend_code_revealed: boolean
          created_at: string
        }
        Insert: Record<string, never>
        Update: Record<string, never>
        Relationships: []
      }
      messages: {
        Row: {
          id: string
          promise_id: string
          sender_id: string
          body: string
          created_at: string
        }
        Insert: {
          id?: string
          promise_id: string
          sender_id: string
          body: string
        }
        Update: Record<string, never>
        Relationships: []
      }
      message_reads: {
        Row: { promise_id: string; user_id: string; last_read_at: string }
        Insert: { promise_id: string; user_id: string; last_read_at?: string }
        Update: { last_read_at?: string }
        Relationships: []
      }
      board_posts: {
        Row: {
          id: string
          creator_id: string
          game: string
          mood: BoardMood
          when_text: string
          capacity: number
          vc: BoardVc
          audience: BoardAudience
          verified_only: boolean
          note: string
          status: BoardStatus
          created_at: string
        }
        Insert: {
          id?: string
          creator_id: string
          game: string
          mood?: BoardMood
          when_text: string
          capacity?: number
          vc?: BoardVc
          audience?: BoardAudience
          verified_only?: boolean
          note?: string
        }
        Update: { status?: BoardStatus }
        Relationships: []
      }
      board_participants: {
        Row: { post_id: string; user_id: string; joined_at: string }
        Insert: Record<string, never>
        Update: Record<string, never>
        Relationships: []
      }
      notifications: {
        Row: {
          id: string
          user_id: string
          type: NotificationType
          title: string
          body: string
          related_id: string | null
          read: boolean
          created_at: string
        }
        Insert: Record<string, never>
        Update: { read?: boolean }
        Relationships: []
      }
      notification_prefs: {
        Row: {
          user_id: string
          notify_invites: boolean
          notify_online_friends: boolean
          notify_recommendations: boolean
        }
        Insert: Record<string, never>
        Update: {
          notify_invites?: boolean
          notify_online_friends?: boolean
          notify_recommendations?: boolean
        }
        Relationships: []
      }
      account_requests: {
        Row: {
          id: string
          user_id: string
          type: AccountRequestType
          status: AccountRequestStatus
          created_at: string
        }
        Insert: { id?: string; user_id: string; type: AccountRequestType }
        Update: Record<string, never>
        Relationships: []
      }
      reviews: {
        Row: {
          id: string
          promise_id: string
          reviewer_id: string
          reviewee_id: string
          stars: 1 | 2 | 3 | 4 | 5
          tags: string[]
          created_at: string
        }
        Insert: {
          id?: string
          promise_id: string
          reviewer_id: string
          reviewee_id: string
          stars: 1 | 2 | 3 | 4 | 5
          tags?: string[]
        }
        Update: Record<string, never>
        Relationships: []
      }
      reports: {
        Row: {
          id: string
          reporter_id: string
          reported_id: string
          category: ReportCategory
          severity: ReportSeverity
          message_snapshot: Record<string, unknown> | null
          status: ReportStatus
          resolution: string | null
          created_at: string
          resolved_at: string | null
        }
        Insert: {
          id?: string
          reporter_id: string
          reported_id: string
          category: ReportCategory
          message_snapshot?: Record<string, unknown> | null
        }
        Update: Record<string, never>
        Relationships: []
      }
      blocks: {
        Row: { blocker_id: string; blocked_id: string; reason: string | null; created_at: string }
        Insert: { blocker_id: string; blocked_id: string; reason?: string | null }
        Update: Record<string, never>
        Relationships: []
      }
      manner_penalties: {
        Row: {
          id: string
          user_id: string
          report_id: string | null
          points: number
          reason: string | null
          created_at: string
        }
        Insert: Record<string, never>
        Update: Record<string, never>
        Relationships: []
      }
      admins: {
        Row: { user_id: string; created_at: string }
        Insert: Record<string, never>
        Update: Record<string, never>
        Relationships: []
      }
    }
    Views: Record<string, never>
    Functions: {
      create_booking: {
        Args: {
          p_host_id: string
          /** 30分刻み。上限は platform_pricing.max_duration_minutes。 */
          p_duration_minutes: number
          p_policy_version?: string
          /** ISO文字列。null なら「今すぐ」(承諾時点が開始時刻)。 */
          p_scheduled_at?: string | null
        }
        Returns: string
      }
      approve_booking: {
        Args: { p_booking_id: string }
        Returns: string
      }
      decline_booking: {
        Args: { p_booking_id: string }
        Returns: void
      }
      cancel_booking: {
        Args: { p_booking_id: string; p_reason?: string | null }
        Returns: void
      }
      approve_invite: {
        Args: { p_invite_id: string }
        Returns: string
      }
      decline_invite: {
        Args: { p_invite_id: string }
        Returns: void
      }
      join_board_post: {
        Args: { p_post_id: string }
        Returns: void
      }
      complete_booking: {
        Args: { p_booking_id: string }
        Returns: void
      }
      request_bank_payout: {
        Args: { p_coins: number }
        Returns: string
      }
      send_gift: {
        Args: {
          p_promise_id: string
          p_coins: number
          p_message?: string | null
          p_device_id?: string | null
        }
        Returns: string
      }
      record_device: {
        Args: { p_device_id: string }
        Returns: void
      }
      record_ip: {
        Args: { p_ip: string }
        Returns: void
      }
      set_voice_greeting: {
        Args: { p_path: string; p_seconds: number }
        Returns: void
      }
      clear_voice_greeting: {
        Args: Record<string, never>
        Returns: void
      }
      admin_clear_voice_greeting: {
        Args: { p_user_id: string }
        Returns: void
      }
      set_avatar: {
        Args: { p_path: string }
        Returns: void
      }
      clear_avatar: {
        Args: Record<string, never>
        Returns: void
      }
      admin_clear_avatar: {
        Args: { p_user_id: string }
        Returns: void
      }
      touch_presence: {
        Args: Record<string, never>
        Returns: void
      }
      set_presence_status: {
        Args: { p_status: PresenceStatus }
        Returns: void
      }
      record_content_flag: {
        Args: {
          p_category: 'contact' | 'money' | 'dating'
          p_surface: 'message' | 'board' | 'profile'
          p_matched: string
          p_proceeded?: boolean
        }
        Returns: void
      }
      cancel_board_post: {
        Args: { p_post_id: string; p_reason?: string | null }
        Returns: void
      }
      my_trial_discount: {
        Args: { p_host_id: string }
        Returns: number
      }
      my_booking_refund_percent: {
        Args: { p_booking_id: string }
        Returns: number
      }
      /** 0048: 没収の上限が入ったため、率ではなく実額を返すこちらを使う */
      my_booking_refund_quote: {
        Args: { p_booking_id: string }
        Returns: Record<string, unknown>
      }
      /** 0049: 予約で埋まっている時間帯(そのピタメイト + 自分) */
      booking_busy_slots: {
        Args: { p_host_id: string; p_days?: number }
        Returns: Record<string, unknown>[]
      }
      /** 0050: プレイ開始の申告 */
      check_in_booking: {
        Args: { p_booking_id: string }
        Returns: void
      }
      my_booking_checkin_state: {
        Args: { p_booking_id: string }
        Returns: Record<string, unknown>
      }
      /** 0051: 募集枠と公開スケジュール */
      set_host_availability: {
        Args: { p_slots: { weekday: number; hour: number }[] }
        Returns: number
      }
      host_schedule: {
        Args: { p_host_id: string; p_days?: number }
        Returns: Record<string, unknown>[]
      }
      /** 0053: お気に入り登録の追加・解除。 */
      set_favorite: {
        Args: { p_host_id: string; p_on: boolean }
        Returns: void
      }
      /** 0053: 自分がお気に入りにしているピタメイトの一覧。 */
      my_favorites: {
        Args: Record<string, never>
        Returns: {
          host_id: string
          nickname: string
          avatar_initial: string
          avatar_color: string
          avatar_path: string | null
          hourly_rate: number
          games: string[] | null
          manner_score: number
          review_count: number
          is_verified: boolean
          is_active: boolean
          favorited_at: string
          /** 0056: 14日以内のひとことだけが入る(古いものは null)。 */
          status_text: string | null
          status_updated_at: string | null
        }[]
      }
      /** 0053: 自分をお気に入りにしている人数(誰かは返らない)。 */
      my_favorite_count: {
        Args: Record<string, never>
        Returns: number
      }
      /** 0061: 同じ時刻を毎週くり返して2〜4回まとめて予約する。全部通るか、1件も作らないか。 */
      create_booking_series: {
        Args: {
          p_host_id: string
          p_duration_minutes: number
          p_policy_version: string | null
          p_first_start: string
          p_count: number
        }
        Returns: string[]
      }
      /** 0062: この相手との自動確定を24〜71時間に短くする。nullまたは72で既定に戻す。 */
      set_fast_release: {
        Args: { p_host_id: string; p_hours: number | null }
        Returns: undefined
      }
      /** 0062: いまの設定と、設定できる状態か。 */
      my_fast_release: {
        Args: { p_host_id: string }
        Returns: { hours: number | null; eligible: boolean }
      }
      /** 0056: 自分の「ひとこと」を書き換える。空文字で消える。 */
      set_host_status: {
        Args: { p_text: string }
        Returns: string | null
      }
      /** 0055: 自分とこの相手が一緒に遊んだ回数。{ count, last_played_at }。 */
      my_play_history_with: {
        Args: { p_other: string }
        Returns: {
          count: number
          last_played_at: string | null
          /** 0059: 前回の長さと開始時刻(「前回と同じで予約」の材料)。 */
          last_duration_minutes: number | null
          last_scheduled_at: string | null
        }
      }
      /** 0052: 未ログインでも見える「掲載中のピタメイト」カード。 */
      public_host_cards: {
        Args: { p_limit?: number }
        Returns: {
          host_id: string
          nickname: string
          avatar_initial: string
          avatar_color: string
          avatar_path: string | null
          hourly_rate: number
          games: string[] | null
          bio: string | null
          manner_score: number
          review_count: number
          is_verified: boolean
          /** 0056: 14日以内のひとことだけが入る(古いものは null)。 */
          status_text: string | null
          status_updated_at: string | null
          /** 0058: 2回以上遊んだ人の数(誰かは返らない)。 */
          repeat_guests: number
        }[]
      }
      /** 0058: そのピタメイトと2回以上遊んだ人の数。 */
      host_repeat_guests: {
        Args: { p_host_id: string }
        Returns: number
      }
      /**
       * 0060: 一覧向けの「来た人数・戻った人数・丸めたリピート率」。
       * repeat_score は母数が小さいと 0.25 へ寄る(始めたばかりの人を沈めない)。
       */
      host_repeat_stats: {
        Args: { p_host_ids: string[] }
        Returns: { host_id: string; guests: number; repeat_guests: number; repeat_score: number }[]
      }
      host_open_now: {
        Args: { p_host_id: string }
        Returns: boolean
      }
      host_dashboard: {
        Args: { p_at?: string }
        Returns: Record<string, unknown>
      }
      extend_booking: {
        Args: { p_booking_id: string; p_additional_minutes: 30 | 60 }
        Returns: number
      }
      record_monitoring_consent: {
        Args: { p_version: string }
        Returns: void
      }
      revoke_monitoring_consent: {
        Args: Record<string, never>
        Returns: void
      }
      my_monitoring_consent: {
        Args: Record<string, never>
        Returns: unknown
      }
      host_ranking: {
        Args: { p_period?: string; p_limit?: number }
        Returns: {
          rank: number
          host_id: string
          nickname: string
          avatar_initial: string
          avatar_color: string
          avatar_path: string | null
          completed_count: number
          manner_score: number
          score: number
          is_verified: boolean
        }[]
      }
      approve_identity_verification: {
        Args: { p_verification_id: string; p_is_adult?: boolean }
        Returns: void
      }
      reject_identity_verification: {
        Args: { p_verification_id: string; p_reason?: string | null }
        Returns: void
      }
      /** 0064: この端末をプッシュの宛先として登録する(起動ごとに呼んでよい)。 */
      save_push_subscription: {
        Args: { p_endpoint: string; p_p256dh: string; p_auth: string; p_ua?: string | null }
        Returns: void
      }
      /** 0064: この端末をプッシュの宛先から外す。 */
      delete_push_subscription: {
        Args: { p_endpoint: string }
        Returns: void
      }
      /** 0064: プッシュの設定と、登録してある端末の数。 */
      my_push_settings: {
        Args: Record<string, never>
        Returns: {
          enabled: boolean
          quietFrom: number | null
          quietTo: number | null
          devices: number
        }
      }
      /** 0064: プッシュの受け取りと、静かにする時間(JSTの時)。 */
      set_push_settings: {
        Args: { p_enabled: boolean; p_quiet_from?: number | null; p_quiet_to?: number | null }
        Returns: void
      }

      // ---- 0066: 運営コンソール。すべて管理者判定つき(NOT_ADMINで落ちる) ----
      /** 「今日やること」の件数。キーは日本語のまま返る。 */
      admin_console_summary: {
        Args: Record<string, never>
        Returns: Record<string, number | null>
      }
      admin_reports: {
        Args: { p_status?: string; p_limit?: number }
        Returns: {
          id: string
          reporter_name: string
          reported_id: string
          reported_name: string
          category: string
          severity: string
          message_snapshot: unknown
          status: string
          resolution: string | null
          created_at: string
          reported_manner: number | null
          reported_report_count: number
        }[]
      }
      admin_held_bookings: {
        Args: { p_limit?: number }
        Returns: {
          id: string
          guest_id: string
          guest_name: string
          host_id: string
          host_name: string
          coins: number
          paid_coins: number
          duration_minutes: number
          scheduled_at: string
          held_at: string
          held_days: number
          hold_reason: string | null
          report_count: number
        }[]
      }
      /** ⚠️ 口座情報を返す。呼び出し自体が admin_actions に記録される。 */
      admin_pending_payouts: {
        Args: { p_limit?: number }
        Returns: {
          id: string
          user_id: string
          nickname: string
          coins: number
          amount_yen: number
          fee_yen: number
          created_at: string
          bank_name: string
          bank_code: string
          branch_name: string
          branch_code: string
          account_type: string
          account_number: string
          account_holder_kana: string
          is_verified: boolean
        }[]
      }
      admin_account_requests: {
        Args: { p_limit?: number }
        Returns: {
          id: string
          user_id: string
          nickname: string
          type: string
          status: string
          created_at: string
          waiting_days: number
        }[]
      }
      /** 整合性チェック・台帳バックアップ・プッシュの状況。 */
      admin_health: {
        Args: Record<string, never>
        Returns: {
          integrity: {
            check_name: string
            severity: string
            affected_count: number
            total_gap: number | null
            ran_at: string
            detail: unknown
          }[]
          ledgerExport: { ran_at: string; ok: boolean; row_count: number; error: string | null } | null
          push: { pending: number; givenUp: number; devices: number; disabled: number; lastError: string | null }
        }
      }
      /** 手数料の率(表示用)。規約 第8条の2第3項の「本サービス上に表示」を満たすための口。 */
      fee_rates: {
        Args: Record<string, never>
        Returns: unknown
      }
      admin_recent_actions: {
        Args: { p_limit?: number }
        Returns: {
          id: string
          actor_name: string
          kind: string
          target_id: string | null
          note: string | null
          at: string
        }[]
      }
      /** 通報の処分。理由は必須。 */
      admin_resolve_report: {
        Args: {
          p_report_id: string
          p_resolution: string
          p_status?: string
          p_penalty_points?: number | null
        }
        Returns: void
      }
      admin_release_hold_complete: {
        Args: { p_booking_id: string; p_note?: string | null }
        Returns: void
      }
      admin_release_hold_refund: {
        Args: { p_booking_id: string; p_refund_percent: number; p_note?: string | null }
        Returns: void
      }
      /** ⚠️ 実際に振り込んだ後にだけ呼ぶ。取り消せない。 */
      admin_mark_payout_paid: {
        Args: { p_payout_id: string; p_note?: string | null }
        Returns: void
      }
      admin_mark_payout_failed: {
        Args: { p_payout_id: string; p_reason: string }
        Returns: void
      }
      admin_set_account_request_status: {
        Args: { p_request_id: string; p_status: string }
        Returns: void
      }
    }
  }
}
