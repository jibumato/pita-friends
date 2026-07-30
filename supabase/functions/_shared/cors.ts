// フロント(ブラウザ)から呼ぶ Edge Function 用の CORS ヘッダー。
// APP_URL を許可オリジンにする(未設定時はワイルドカード)。
//
// 末尾スラッシュは剥がす。APP_URL を "https://例.com/" と設定すると、
// ブラウザが送る Origin("https://例.com"・末尾スラッシュ無し)と一致せず、
// 許可オリジンが合致しないため決済を含む全リクエストが CORS で弾かれる。
// 設定ミスに強くするため、ここで正規化しておく。
export const corsHeaders = {
  'Access-Control-Allow-Origin': (Deno.env.get('APP_URL') ?? '*').replace(/\/+$/, ''),
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
