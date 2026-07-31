-- ============================================================
-- 0084: 通知設定の行が無いユーザーを救済する
--
-- ■ 何が起きていたか
--   設定画面の「通知」3つのトグルが、押しても何も起きない。
--   画面には「取得に失敗しました」とだけ出る。
--
--   原因は notification_prefs の**行が無い**こと。この表(0012)は
--   auth.users への INSERT トリガでしか行を作らないので、
--   **0012 を当てる前に登録したユーザーには行が存在しない。**
--
--   フロントは .single() で1行を取りに行くため、行が無いと
--   PGRST116 で失敗し、状態が null のままになる。トグルの押下は
--   `if (!prefs) return` で捨てられる。だから「押しても無反応」。
--
--   さらに悪いことに、更新は update … where user_id = auth.uid() で、
--   **行が無ければ0行更新でエラーにならない。** 仮に読み取りだけ
--   直しても、書き込みが静かに消える経路が残っていた。
--
-- ■ どう直すか
--   ①既存ユーザー全員に行を作る(取りこぼしの解消)
--   ②**読み書きを「無ければ作る」関数に寄せる。**
--     トリガに依存する作りだと、今後もどこかの経路で行が無いユーザーが
--     生まれたときに同じ壊れ方をする。**行の有無を呼び出し側の
--     関心事から外す。**
--
--   INSERT ポリシーは 0012 の判断どおり作らない。行の作成は
--   SECURITY DEFINER のこの2本だけが行い、user_id は必ず
--   auth.uid() で固定する(他人の行は作れない)。
--
-- ■ 既定値をここに書かない
--   insert … on conflict do nothing → update の2段にしてある。
--   coalesce(p_invites, true) のように既定値を関数側へ写すと、
--   表の default と二重管理になり、片方だけ変えたときに食い違う。
-- ============================================================

-- ------------------------------------------------------------
-- 1. 取りこぼしを埋める
-- ------------------------------------------------------------
insert into public.notification_prefs (user_id)
select u.id from auth.users u
left join public.notification_prefs p on p.user_id = u.id
where p.user_id is null;

-- ------------------------------------------------------------
-- 2. 読み取り: 無ければ作ってから返す
-- ------------------------------------------------------------
-- 戻り値は jsonb。1行だけを返す設定系は 0062 my_fast_release と同じ形に揃える
create or replace function public.get_notification_prefs()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  insert into public.notification_prefs (user_id) values (v_uid)
  on conflict (user_id) do nothing;

  select jsonb_build_object(
    'notify_invites', p.notify_invites,
    'notify_online_friends', p.notify_online_friends,
    'notify_recommendations', p.notify_recommendations)
  into v_out
  from public.notification_prefs p
  where p.user_id = v_uid;

  return v_out;
end;
$$;

comment on function public.get_notification_prefs() is
  '自分の通知設定。行が無ければ既定値で作ってから返す。';

-- ------------------------------------------------------------
-- 3. 更新: null は「変更しない」
-- ------------------------------------------------------------
-- 画面はトグル1つだけを送ってくる。3つまとめて送る形にすると、
-- 別の端末で先に変えた設定を**知らないうちに上書きする。**
create or replace function public.set_notification_prefs(
  p_invites boolean default null,
  p_online_friends boolean default null,
  p_recommendations boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  insert into public.notification_prefs (user_id) values (v_uid)
  on conflict (user_id) do nothing;

  update public.notification_prefs p set
    notify_invites         = coalesce(p_invites,         p.notify_invites),
    notify_online_friends  = coalesce(p_online_friends,  p.notify_online_friends),
    notify_recommendations = coalesce(p_recommendations, p.notify_recommendations)
  where p.user_id = v_uid;

  -- **更新後の値を返す。** 画面は返ってきた値で状態を作り直すので、
  -- 送った値と保存された値がずれたままにならない
  select jsonb_build_object(
    'notify_invites', p.notify_invites,
    'notify_online_friends', p.notify_online_friends,
    'notify_recommendations', p.notify_recommendations)
  into v_out
  from public.notification_prefs p
  where p.user_id = v_uid;

  return v_out;
end;
$$;

comment on function public.set_notification_prefs(boolean, boolean, boolean) is
  '自分の通知設定を変更する。null の項目は変更しない。保存後の値を返す。';

-- ------------------------------------------------------------
-- 4. 権限。SECURITY DEFINER なので PUBLIC から必ず剥がす(74_anon_surface)
-- ------------------------------------------------------------
revoke all on function public.get_notification_prefs() from public, anon;
revoke all on function public.set_notification_prefs(boolean, boolean, boolean) from public, anon;
grant execute on function public.get_notification_prefs() to authenticated;
grant execute on function public.set_notification_prefs(boolean, boolean, boolean) to authenticated;
