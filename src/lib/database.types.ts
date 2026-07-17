/**
 * `supabase/migrations/*.sql` と手動で対応させたDB型定義。
 * 実際のSupabaseプロジェクトに接続後は `supabase gen types typescript`
 * で生成し直すことを推奨(スキーマとのズレを防ぐため)。
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
        Insert: never
        Update: never
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
        }
        Insert: { id?: string; user_id: string; status?: 'pending' }
        Update: never
      }
      coin_wallets: {
        Row: { user_id: string; balance: number; updated_at: string }
        Insert: never
        Update: never
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
        Insert: never
        Update: never
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
        Insert: never
        Update: Partial<
          Pick<Database['public']['Tables']['host_settings']['Row'], 'is_host' | 'hourly_rate' | 'games' | 'bio'>
        >
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
        Insert: never
        Update: never
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
        Update: never
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
        Insert: never
        Update: never
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
        Update: never
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
        Update: never
      }
      blocks: {
        Row: { blocker_id: string; blocked_id: string; reason: string | null; created_at: string }
        Insert: { blocker_id: string; blocked_id: string; reason?: string | null }
        Update: never
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
        Insert: never
        Update: never
      }
    }
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
    }
  }
}
