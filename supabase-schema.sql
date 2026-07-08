-- ============================================================
-- 广西洪灾互助 · Supabase 数据库结构
-- 使用方法：登录 supabase.com 你的项目 → 左侧菜单 SQL Editor
-- → New query → 把这整份粘贴进去 → Run
-- ============================================================

-- 1) 求助登记表
create table if not exists requests (
  id uuid primary key default gen_random_uuid(),
  reporter_contact   text not null,           -- 求助人联系方式（公开）
  relation           text not null,           -- 与被寻人关系
  person_name        text not null,           -- 被寻人姓名/称呼
  age_range          text not null,           -- 年龄段
  last_contact_time  timestamptz,             -- 最后联系时间
  last_known_location text not null,          -- 最后已知位置（公开，精确到乡镇/村）
  detailed_address   text,                    -- 详细住址（默认不公开）
  address_public     boolean not null default false,
  mobility_impaired  text,                    -- 是否行动不便：是/否/不确定
  chronic_illness    text,                    -- 是否有基础病
  urgent_rescue      text,                    -- 是否需要紧急救援
  status             text not null default '待核实',
  report_count       int  not null default 0,
  auto_hidden        boolean not null default false,
  created_at         timestamptz not null default now()
);

-- 2) 线索表
create table if not exists clues (
  id uuid primary key default gen_random_uuid(),
  request_id   uuid not null references requests(id) on delete cascade,
  seen_time    timestamptz,
  location     text not null,
  description  text not null,
  has_media    boolean not null default false,
  contact      text,                          -- 选填，可留空表示匿名
  report_count int not null default 0,
  created_at   timestamptz not null default now()
);

-- ============================================================
-- 3) 开启行级安全（RLS）—— 默认所有访问都拒绝，逐条放开
-- ============================================================
alter table requests enable row level security;
alter table clues    enable row level security;

-- 任何人（包括没登录的访客）都可以新增一条求助 / 一条线索
create policy "anyone can insert requests" on requests
  for insert to anon with check (true);

create policy "anyone can insert clues" on clues
  for insert to anon with check (true);

-- 线索本身不含敏感字段，允许任何人查看
create policy "anyone can read clues" on clues
  for select to anon using (true);

-- 状态变更（status）只允许"已登录的管理员账号"操作，访客不行
create policy "only admin can update requests" on requests
  for update to authenticated using (true) with check (true);

-- 已登录的管理员可以看到完整数据（包含真实住址），方便核实
create policy "authenticated can read full requests" on requests
  for select to authenticated using (true);
grant select on requests to authenticated;

-- 注意：这里故意不给 anon 加"可以直接 select requests 表"的策略。
-- 公开列表页只能通过下面第4步的视图（view）读取数据，
-- 这样详细住址字段才能被真正"在数据库层面"挡住，而不是只在网页界面上隐藏。

-- ============================================================
-- 4) 公开视图：住址脱敏
-- 未勾选"同意公开住址"的求助，detailed_address 会被视图直接置空，
-- 访客即使打开浏览器开发者工具查看接口返回内容，也看不到真实住址。
-- ============================================================
create or replace view public_requests as
select
  id, relation, person_name, age_range, last_contact_time, last_known_location,
  case when address_public then detailed_address else null end as detailed_address,
  address_public, mobility_impaired, chronic_illness, urgent_rescue,
  status, report_count, auto_hidden, created_at, reporter_contact
from requests;

grant select on public_requests to anon, authenticated;

-- ============================================================
-- 5) 举报函数：允许访客"举报"，但只能做举报这一件事，
-- 不能像管理员一样任意修改状态（最小权限原则）
-- ============================================================
create or replace function report_request(target_id uuid)
returns void
language plpgsql
security definer
as $$
begin
  update requests
  set report_count = report_count + 1,
      status = case when report_count + 1 >= 3 then '已关闭' else status end,
      auto_hidden = case when report_count + 1 >= 3 then true else auto_hidden end
  where id = target_id;
end;
$$;

grant execute on function report_request(uuid) to anon, authenticated;

create or replace function report_clue(target_id uuid)
returns void
language plpgsql
security definer
as $$
begin
  update clues set report_count = report_count + 1 where id = target_id;
end;
$$;

grant execute on function report_clue(uuid) to anon, authenticated;

-- ============================================================
-- 6) 状态自动推进：有人提交线索后，如果这条求助还是"待核实"，
-- 自动推进为"已有线索"。这是访客唯一能触发的状态变化，
-- 除此以外的状态变更都必须走管理员登录。
-- ============================================================
create or replace function mark_has_clue(target_id uuid)
returns void
language plpgsql
security definer
as $$
begin
  update requests
  set status = '已有线索'
  where id = target_id and status = '待核实';
end;
$$;

grant execute on function mark_has_clue(uuid) to anon, authenticated;

-- ============================================================
-- 完成后去 Authentication → Users 手动添加一个管理员账号（邮箱+密码），
-- 网页里的"管理员登录"就是用这个账号登录，登录后才能变更状态。
-- ============================================================
