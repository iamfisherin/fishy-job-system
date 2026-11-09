-- Shared source documents and health metadata contain no account credentials.
create table public.feishu_sync_resources (
  resource_id text primary key check (resource_id in ('company-catalog', 'interview-experiences')),
  source_url text not null,
  status text not null check (status in ('success', 'error')),
  checked_at timestamptz not null,
  last_success_at timestamptz,
  error_code text,
  data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object')
);
alter table public.feishu_sync_resources enable row level security;
revoke all on public.feishu_sync_resources from anon, authenticated;
grant select on public.feishu_sync_resources to anon, authenticated;
grant all on public.feishu_sync_resources to service_role;
create policy feishu_resources_read on public.feishu_sync_resources for select to anon, authenticated using (true);
comment on table public.feishu_sync_resources is 'Read-only shared Feishu source snapshots; writes require signed cloud sync.';
