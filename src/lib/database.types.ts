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
export type ContactScope = 'verified' | 'sameGender' | 'all'
export type VerificationStatus = 'pending' | 'verified' | 'rejected'
export type CoinTxType = 'purchase' | 'booking_spend' | 'refund' | 'bonus'
export type BookingStatus =
  | 'confirmed'
  | 'completed'
  | 'cancelled_by_guest'
  | 'cancelled_by_host'
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
export type AccountRequestType = 'data_export' | 'account_deletion'
export type AccountRequestStatus = 'pending' | 'processing' | 'completed'

export type Database = {
  public: {
    Tables: {
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
        Row: { user_id: string; balance: number; updated_at: string }
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
          updated_at: string
        }
        Insert: Record<string, never>
        Update: Partial<
          Pick<Database['public']['Tables']['host_settings']['Row'], 'is_host' | 'hourly_rate' | 'games' | 'bio'>
        >
        Relationships: []
      }
      bookings: {
        Row: {
          id: string
          guest_id: string
          host_id: string
          duration_minutes: 30 | 60 | 120
          coins: number
          status: BookingStatus
          scheduled_at: string
          cancel_reason: string | null
          created_at: string
          cancelled_at: string | null
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
        Args: { p_host_id: string; p_duration_minutes: 30 | 60 | 120 }
        Returns: string
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
      approve_identity_verification: {
        Args: { p_verification_id: string; p_is_adult?: boolean }
        Returns: void
      }
      reject_identity_verification: {
        Args: { p_verification_id: string; p_reason?: string | null }
        Returns: void
      }
    }
  }
}
