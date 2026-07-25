# アイコン画像のアップロードで `new row violates row-level security policy` が出るとき

Storage(`storage.objects`)への INSERT が RLS で弾かれています。
まず下の診断SQLで、どこが欠けているかを確認してください。

## 1. 診断

Supabase ダッシュボードの SQL Editor で実行します。

```sql
-- (a) バケットがあるか・公開か・MIME制限
select id, public, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'avatars';

-- (b) ポリシーが3つ揃っているか(insert/update/delete)
select policyname, cmd
from pg_policies
where schemaname = 'storage'
  and tablename = 'objects'
  and policyname like 'avatars%'
order by policyname;

-- (c) 列と関数があるか
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'profiles' and column_name = 'avatar_path';

select proname from pg_proc
where pronamespace = 'public'::regnamespace and proname in ('set_avatar', 'clear_avatar');
```

期待する結果:

| 確認 | 期待 |
| --- | --- |
| (a) | 1行。`public = true`、`file_size_limit = 3145728` |
| (b) | 3行。`avatars_insert_own` / `avatars_update_own` / `avatars_delete_own` |
| (c) | `avatar_path` が1行、関数が2行 |

**(b) が0行または3行未満なら、それが原因です。**
0025 の `create policy` が「同名ポリシーが既にある」等で中断し、
列だけ作られてポリシーが作られていない状態になっています。
アプリの表示は動くため、アップロード時にだけ表面化します。

## 2. 修復

`supabase/migrations/0027_avatar_policies_repair.sql` を SQL Editor に貼って実行してください。
`drop policy if exists` → `create policy` の順なので、**何度実行しても安全**です。
バケット・列・関数も「無ければ作る」ようになっています。

実行後、もう一度 1. の (b) を流して3行返ることを確認してから、アプリでアップロードを試してください。

## 3. それでも直らないとき

以下を確認してください。

- **ログインしているか**（未ログインだと `auth.uid()` が null になり、必ず弾かれます）
- **保存先パスが `{自分のuid}/avatar.webp` になっているか**
  アプリは `auth.getUser()` の id を使って組み立てるので通常はズレませんが、
  ブラウザに古いセッションが残っていると別uidになることがあります。
  一度ログアウト → ログインし直してから試してください。
- **画像の形式・サイズ**
  アプリ側で 512px の WebP に変換してから送るため通常は問題になりませんが、
  MIMEが合わない場合は RLS ではなく `mime type ... is not supported` という別のエラーになります。

## 補足: なぜ「列はあるのにポリリシーが無い」が起きるか

`schema-all.sql` は**まっさらなDBに一括で流す用**です。
既に適用済みのDBに全体を流すと、途中の `create table` や `create policy` が
「already exists」で失敗し、そこで**トランザクションごと中断**します。
そのため「先に流れた分だけ適用され、後半が入っていない」状態になり得ます。

適用済みのDBに追加分を入れるときは、**`supabase/migrations/` の該当ファイルだけ**を
番号順に流してください。
