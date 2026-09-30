-- =====================================================
-- 冰箱菜谱 · Supabase 初始化脚本
-- 用法：Supabase 控制台 → SQL Editor → 粘贴整段运行
-- 依赖：需开启 Anonymous 匿名登录（Auth → Providers）
-- 说明：口令的 SHA-256 由浏览器端算好传入（p_sha256），
--       不需要 pgcrypto 扩展，避免环境不兼容问题。
-- =====================================================
-- 0) 清理旧函数（参数名曾为 p_pwd，改名为 p_sha256 后 CREATE OR REPLACE
--    不允许改参数名，必须先 DROP 再建，保证整段可重复执行）
drop function if exists public.create_room(text, text);
drop function if exists public.join_room(text, text);
drop function if exists public.get_room_doc(uuid);
drop function if exists public.save_room_doc(uuid, jsonb);
drop function if exists public.hash_pwd(text);
drop function if exists public.touch_room() cascade; -- 连带删除依赖它的触发器 rooms_touch

-- 1) 房间表：每户/每位一家 一行，保存共享文档 + 口令哈希
create table if not exists public.rooms (
  id         uuid primary key default gen_random_uuid(),
  code       text unique not null,      -- 房间码（如 FJKL-2026）
  pwd_hash   text not null,             -- 口令的 SHA-256（hex）
  doc        jsonb not null default '{}',-- 共享数据：ingredients / history / settings
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 2) 成员表：记录哪些匿名用户加入了哪个房间（用于行级权限）
create table if not exists public.room_members (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references auth.users (id) on delete cascade,
  room_id    uuid references public.rooms (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (user_id, room_id)
);

-- 3) 建房函数：校验码唯一，存入口令哈希（浏览器算好的 SHA-256），并挂成员
create or replace function public.create_room(p_code text, p_sha256 text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_room public.rooms;
begin
  if nullif(trim(p_code), '') is null or nullif(trim(p_sha256), '') is null then
    raise exception 'CODE_OR_PWD_EMPTY';
  end if;
  if exists (select 1 from public.rooms where code = trim(p_code)) then
    raise exception 'CODE_EXISTS';
  end if;
  insert into public.rooms (code, pwd_hash, doc, updated_at)
  values (trim(p_code), trim(p_sha256), jsonb_build_object(
      'ingredients', jsonb '[]',
      'history', jsonb '[]',
      'settings', jsonb '{}'
    ), now())
  returning * into v_room;

  insert into public.room_members (user_id, room_id) values (auth.uid(), v_room.id);
  return jsonb_build_object('id', v_room.id, 'code', v_room.code, 'doc', v_room.doc);
end $$;

-- 4) 加入函数：比对哈希，通过则挂成员
create or replace function public.join_room(p_code text, p_sha256 text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_room public.rooms;
begin
  select * into v_room from public.rooms where code = trim(p_code);
  if v_room.id is null then raise exception 'ROOM_NOT_FOUND'; end if;
  if v_room.pwd_hash <> trim(p_sha256) then raise exception 'WRONG_PWD'; end if;
  insert into public.room_members (user_id, room_id)
  values (auth.uid(), v_room.id)
  on conflict (user_id, room_id) do nothing;
  return jsonb_build_object('id', v_room.id, 'code', v_room.code, 'doc', v_room.doc);
end $$;
alter table public.rooms        enable row level security;
alter table public.room_members enable row level security;

-- 5) 行级权限策略
--    房间：本人（成员）可读，成员可更新（改 doc），任何人不可删
drop policy if exists "rooms_select_for_member" on public.rooms;
create policy "rooms_select_for_member" on public.rooms
  for select using (
    exists (select 1 from public.room_members m
            where m.room_id = rooms.id and m.user_id = auth.uid())
  );

drop policy if exists "rooms_update_for_member" on public.rooms;
create policy "rooms_update_for_member" on public.rooms
  for update using (
    exists (select 1 from public.room_members m
            where m.room_id = rooms.id and m.user_id = auth.uid())
  );

--    成员表：本人可读自己的成员关系；写入由下方 SECURITY DEFINER 函数完成
drop policy if exists "members_select_own"  on public.room_members;
create policy "members_select_own" on public.room_members
  for select using (user_id = auth.uid());

-- 8) 抓取房间当前 doc（供客户端拉快照）
create or replace function public.get_room_doc(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.rooms;
begin
  select * into v from public.rooms where id = p_room_id;
  -- 校验成员资格
  if not exists (select 1 from public.room_members where room_id = p_room_id and user_id = auth.uid()) then
    raise exception 'NOT_MEMBER';
  end if;
  return jsonb_build_object('doc', v.doc, 'updated_at', to_char(v.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));
end $$;

-- 9) 更新房间 doc（数据库内合并旧新，减冲突）
create or replace function public.save_room_doc(p_room_id uuid, p_new_doc jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.room_members where room_id = p_room_id and user_id = auth.uid()) then
    raise exception 'NOT_MEMBER';
  end if;
  update public.rooms set
    doc = p_new_doc,
    updated_at = now()
  where id = p_room_id;
  return jsonb '{"ok":true}';
end $$;

-- 10) 启用 Realtime（幂等：仅当 rooms 尚不在 supabase_realtime 中时才加入，
--     避免整段脚本重复执行时报"already member of publication"）
do $$
begin
  if not exists (
    select 1 from pg_publication_tables t
    where t.pubname = 'supabase_realtime' and t.schemaname = 'public' and t.tablename = 'rooms'
  ) then
    alter publication supabase_realtime add table public.rooms;
  end if;
end $$;

-- 可选：更新时间触发器（幂等，可重复运行）
drop trigger if exists rooms_touch on public.rooms;
create or replace function public.touch_room() returns trigger language plpgsql as $$
begin
  new.updated_at = now(); return new;
end $$;
create trigger rooms_touch before update on public.rooms
  for each row execute function public.touch_room();