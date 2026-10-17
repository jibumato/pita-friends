#!/usr/bin/env python3
"""未適用のマイグレーションを、SQL Editor に貼れる大きさに分けてまとめる。

    python3 tools/bundle-migrations.py 0096 0128
      → supabase/apply/0096-0128/part1_0096-0105.sql …

SQL Editor は大きすぎる入力を拒否する(schema-all.sql は 1.4MB で拒否された)。
1ファイルを貼ると中身は1つのトランザクションとして流れるので、途中でエラーに
なればそのパートは何も当たらない。

各パートの先頭には関所を置く。**順番を飛ばしても多くのパートはエラーにならずに
通ってしまう**(実測)ので、docs/check-migrations.sql と同じ目印で
「直前の番号が当たっている」「このパートの最初の番号がまだ当たっていない」を
確かめ、満たさなければ例外で止める(＝そのパートは何も当たらない)。
"""
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIMIT = int(os.environ.get('LIMIT_BYTES', '120000'))


def markers():
    """docs/check-migrations.sql の expected から 番号 → (名前, kind, obj, needle)。"""
    text = open(os.path.join(ROOT, 'docs/check-migrations.sql'), encoding='utf-8').read()
    block = text.split('with expected(seq, migration, kind, obj, needle) as (', 1)[1].split('\n)', 1)[0]
    block = '\n'.join(l.split('--', 1)[0] for l in block.splitlines())  # コメントを落とす
    lit = r"('(?:[^']|'')*'|null)"
    out = {}
    for m in re.finditer(r"\(\s*(\d+)\s*,\s*'([^']+)'\s*,\s*'(\w+)'\s*,\s*" + lit + r"\s*,\s*" + lit + r"\s*\)", block):
        out[int(m.group(1))] = (m.group(2), m.group(3), m.group(4), m.group(5))
    return out


def applied_expr(kind, obj, needle):
    """check-migrations.sql の applied と同じ判定。表が無くても例外にならない形にする。"""
    rel = f"to_regclass('public.' || {obj})"
    return {
        'table': f"exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = {obj})",
        'column': f"exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = {obj} and column_name = {needle})",
        'view': f"exists (select 1 from pg_views where schemaname = 'public' and viewname = {obj} and definition like '%' || {needle} || '%')",
        'funcsrc': f"exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = {obj} and pg_get_functiondef(p.oid) like '%' || {needle} || '%')",
        'noexec': f"(to_regprocedure('public.' || {obj}) is not null and not has_function_privilege('anon', to_regprocedure('public.' || {obj}), 'execute'))",
        'constraint': f"exists (select 1 from pg_constraint c where c.conrelid = {rel} and c.conname = {needle})",
        'tcomment': f"coalesce(obj_description({rel}) like '%' || {needle} || '%', false)",
        'trigger': f"exists (select 1 from pg_trigger t where t.tgrelid = {rel} and not t.tgisinternal and t.tgname = {needle})",
    }[kind]


def guard(mk, prev_no, first_no):
    lines = ['do $guard$', 'begin']
    if prev_no in mk:
        name, kind, obj, needle = mk[prev_no]
        lines += [
            f"  if not ({applied_expr(kind, obj, needle)}) then",
            f"    raise exception '順番が違います: {name} がまだ当たっていません。前のパートから流してください';",
            '  end if;',
        ]
    name, kind, obj, needle = mk[first_no]
    lines += [
        f"  if {applied_expr(kind, obj, needle)} then",
        f"    raise exception 'このパートは適用済みです({name} が当たっています)。docs/check-migrations.sql で次に流すファイルを確かめてください';",
        '  end if;',
        'end $guard$;',
    ]
    return '\n'.join(lines)


def main():
    lo, hi = sys.argv[1], sys.argv[2]
    mk = markers()
    mig_dir = os.path.join(ROOT, 'supabase/migrations')
    files = sorted(f for f in os.listdir(mig_dir) if f.endswith('.sql') and lo <= f[:4] <= hi)
    if not files:
        sys.exit('該当するマイグレーションがありません')
    missing = [f for f in files if int(f[:4]) not in mk]
    if missing:
        sys.exit(f'docs/check-migrations.sql に目印が無い: {missing}')

    parts, cur, size = [], [], 0
    for f in files:
        s = os.path.getsize(os.path.join(mig_dir, f))
        if cur and size + s > LIMIT:
            parts.append(cur)
            cur, size = [], 0
        cur.append(f)
        size += s
    parts.append(cur)

    out = os.path.join(ROOT, 'supabase/apply', f'{lo}-{hi}')
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    for i, part in enumerate(parts, 1):
        first, last = part[0][:4], part[-1][:4]
        body = [
            '-- ============================================================',
            f'-- 本番への適用 パート {i}/{len(parts)}({first}〜{last})',
            '-- tools/bundle-migrations.py で生成。手で直さないこと。',
            '--',
            '-- 1. このファイルの中身を全部 SQL Editor に貼って Run する',
            '-- 2. docs/check-migrations.sql を流し、「次に適用するファイル」が',
            f'--    {last} の次(最後のパートなら「すべて適用済み」)になったことを確かめる',
            '-- 3. エラーが出たら、そこで止めて内容を知らせる',
            '--    (このパートの変更はまるごと取り消されている)',
            '--',
            '-- 先頭の関所は、順番の飛ばしと二重適用を止めるためのもの。',
            '-- ============================================================',
            '',
            guard(mk, int(first) - 1, int(first)),
        ]
        for f in part:
            body += ['', f'-- >>>>>>>> {f}', open(os.path.join(mig_dir, f), encoding='utf-8').read()]
        dest = os.path.join(out, f'part{i}_{first}-{last}.sql')
        open(dest, 'w', encoding='utf-8').write('\n'.join(body))
        print(f'{os.path.basename(dest)}  {os.path.getsize(dest):6d} bytes  {len(part)} files')


main()
