// フロント(ブラウザ)から呼ぶ Edge Function 用の CORS ヘッダー。
// APP_URL を許可オリジンにする(未設定時はワイルドカード)。
export const corsHeaders = {
  'Access-Control-Allow-Origin': Deno.env.get('APP_URL') ?? '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
