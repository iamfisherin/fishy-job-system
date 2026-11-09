

-- ===================== schema.sql =====================
-- ============================================================
-- Sugar 求职系统 Supabase schema
-- Run this in Supabase SQL Editor.
-- Each signed-in user can only read/write rows whose user_id = auth.uid().
-- ============================================================

create extension if not exists "pgcrypto";

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- 1. 投递记录
create table if not exists public.applications (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  company_name  text not null,
  position_name text not null,
  city          text,
  channel       text,
  apply_date    date,
  status        text not null default '待投递',
  salary_range  text,
  job_url       text,
  notes         text,
  jd_text       text,
  jd_keywords   text[],
  match_score   int check (match_score is null or (match_score >= 0 and match_score <= 100)),
  match_summary text,
  next_action   text,
  next_action_at timestamptz,
  deadline_at   timestamptz,
  priority      text not null default 'normal' check (priority in ('low', 'normal', 'high', 'urgent')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists applications_user_id_idx on public.applications (user_id);

-- 2. 公司库
create table if not exists public.companies (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  company_name  text not null,
  industry      text,
  city          text,
  scale         text,
  website       text,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists companies_user_id_idx on public.companies (user_id);

-- 投递与公司一对多关联；保存投递时由触发器自动匹配或创建公司。
alter table public.applications
  add column if not exists company_id uuid references public.companies (id) on delete restrict;
create index if not exists applications_company_id_idx on public.applications (company_id);

create or replace function public.normalize_company_name(input_name text)
returns text
language sql
immutable
parallel safe
security invoker
set search_path = ''
as $$
  select lower(regexp_replace(
    regexp_replace(btrim(coalesce(input_name, '')), '\s+', '', 'g'),
    '(股份有限责任公司|有限责任公司|股份有限公司|集团有限公司|集团公司|有限公司|公司)$', '', 'g'
  ));
$$;

create unique index if not exists companies_user_normalized_name_uidx
  on public.companies (user_id, public.normalize_company_name(company_name));

create or replace function public.link_application_to_company()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare linked_company_id uuid;
begin
  new.company_name := btrim(new.company_name);
  if new.company_name = '' then raise exception 'company_name must not be empty'; end if;
  insert into public.companies (user_id, company_name, city)
  values (new.user_id, new.company_name, nullif(btrim(new.city), ''))
  on conflict (user_id, public.normalize_company_name(company_name))
  do update set city = coalesce(nullif(public.companies.city, ''), excluded.city)
  returning id into linked_company_id;
  new.company_id := linked_company_id;
  return new;
end;
$$;

create or replace function public.sync_company_name_to_applications()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  new.company_name := btrim(new.company_name);
  if new.company_name = '' then raise exception 'company_name must not be empty'; end if;
  update public.applications set company_name = new.company_name
  where company_id = new.id and company_name is distinct from new.company_name;
  return new;
end;
$$;

-- 2.1 内推码管理
create table if not exists public.referral_codes (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  company_id    uuid references public.companies (id) on delete set null,
  company_name  text not null,
  industry      text,
  position_name text,
  city          text,
  referral_code text not null,
  referrer_name text,
  source        text,
  status        text not null default '可用' check (status in ('可用', '即将过期', '已使用')),
  expires_at    date,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists referral_codes_user_id_idx on public.referral_codes (user_id);
create index if not exists referral_codes_company_id_idx on public.referral_codes (company_id);
create index if not exists referral_codes_user_status_idx on public.referral_codes (user_id, status);
create index if not exists referral_codes_user_company_name_idx on public.referral_codes (user_id, company_name);
create index if not exists referral_codes_expires_at_idx on public.referral_codes (expires_at);

-- 3. 简历库
create table if not exists public.resumes (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users (id) on delete cascade,
  resume_name     text not null,
  target_position text,
  file_url        text,
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists resumes_user_id_idx on public.resumes (user_id);

-- 投递关联简历。旧库执行本脚本时会自动补列。
alter table public.applications
  add column if not exists resume_id uuid references public.resumes (id) on delete set null;
create index if not exists applications_resume_id_idx on public.applications (resume_id);

-- 4. 简历/面试附件
create table if not exists public.resume_files (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  resume_id  uuid not null references public.resumes (id) on delete cascade,
  file_name  text not null,
  file_path  text,
  kind       text not null check (kind in ('resume', 'script')),
  size       bigint,
  content    text,
  source     text not null default 'upload' check (source in ('upload', 'ai')),
  created_at timestamptz not null default now()
);
create index if not exists resume_files_user_id_idx on public.resume_files (user_id);
create index if not exists resume_files_resume_id_idx on public.resume_files (resume_id);

-- 5. AI 服务商 API Key。API Key 受账号权限保护，不在前端写入 service_role key。
create table if not exists public.user_api_keys (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  provider   text not null,
  api_key    text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, provider)
);
create index if not exists user_api_keys_user_id_idx on public.user_api_keys (user_id);

-- 6. 面试日历
create table if not exists public.interviews (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  company_name   text not null,
  position_name  text,
  interview_time timestamptz,
  round          text,
  interview_type text,
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists interviews_user_id_idx on public.interviews (user_id);

-- 面试可关联当前用户的一条投递记录；删除投递时保留面试。
create unique index if not exists applications_id_user_id_uidx on public.applications (id, user_id);
alter table public.interviews add column if not exists application_id uuid;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'interviews_application_owner_fk' and conrelid = 'public.interviews'::regclass) then
    alter table public.interviews add constraint interviews_application_owner_fk
      foreign key (application_id, user_id) references public.applications (id, user_id)
      on delete set null (application_id);
  end if;
end $$;
create index if not exists interviews_application_id_idx on public.interviews (application_id);

-- updated_at triggers
drop trigger if exists trg_applications_updated on public.applications;
create trigger trg_applications_updated before update on public.applications
  for each row execute function public.set_updated_at();

drop trigger if exists trg_companies_updated on public.companies;
create trigger trg_companies_updated before update on public.companies
  for each row execute function public.set_updated_at();

drop trigger if exists trg_link_application_company on public.applications;
create trigger trg_link_application_company
  before insert or update of company_name, user_id, city on public.applications
  for each row execute function public.link_application_to_company();

drop trigger if exists trg_sync_company_name_to_applications on public.companies;
create trigger trg_sync_company_name_to_applications
  after update of company_name on public.companies
  for each row execute function public.sync_company_name_to_applications();

drop trigger if exists trg_referral_codes_updated on public.referral_codes;
create trigger trg_referral_codes_updated before update on public.referral_codes
  for each row execute function public.set_updated_at();

drop trigger if exists trg_resumes_updated on public.resumes;
create trigger trg_resumes_updated before update on public.resumes
  for each row execute function public.set_updated_at();

drop trigger if exists trg_interviews_updated on public.interviews;
create trigger trg_interviews_updated before update on public.interviews
  for each row execute function public.set_updated_at();

drop trigger if exists trg_user_api_keys_updated on public.user_api_keys;
create trigger trg_user_api_keys_updated before update on public.user_api_keys
  for each row execute function public.set_updated_at();

-- Row Level Security
alter table public.applications enable row level security;
alter table public.companies enable row level security;
alter table public.referral_codes enable row level security;
alter table public.resumes enable row level security;
alter table public.resume_files enable row level security;
alter table public.user_api_keys enable row level security;
alter table public.interviews enable row level security;

-- applications
drop policy if exists "applications_select_own" on public.applications;
create policy "applications_select_own" on public.applications for select using (auth.uid() = user_id);
drop policy if exists "applications_insert_own" on public.applications;
create policy "applications_insert_own" on public.applications for insert with check (auth.uid() = user_id);
drop policy if exists "applications_update_own" on public.applications;
create policy "applications_update_own" on public.applications for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "applications_delete_own" on public.applications;
create policy "applications_delete_own" on public.applications for delete using (auth.uid() = user_id);

-- companies
drop policy if exists "companies_select_own" on public.companies;
create policy "companies_select_own" on public.companies for select using (auth.uid() = user_id);
drop policy if exists "companies_insert_own" on public.companies;
create policy "companies_insert_own" on public.companies for insert with check (auth.uid() = user_id);
drop policy if exists "companies_update_own" on public.companies;
create policy "companies_update_own" on public.companies for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "companies_delete_own" on public.companies;
create policy "companies_delete_own" on public.companies for delete using (auth.uid() = user_id);

-- referral_codes
drop policy if exists "referral_codes_select_own" on public.referral_codes;
create policy "referral_codes_select_own" on public.referral_codes for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "referral_codes_insert_own" on public.referral_codes;
create policy "referral_codes_insert_own" on public.referral_codes for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "referral_codes_update_own" on public.referral_codes;
create policy "referral_codes_update_own" on public.referral_codes for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists "referral_codes_delete_own" on public.referral_codes;
create policy "referral_codes_delete_own" on public.referral_codes for delete to authenticated using ((select auth.uid()) = user_id);

revoke all on table public.referral_codes from anon, authenticated;
grant select, insert, update, delete on table public.referral_codes to authenticated;

-- resumes
drop policy if exists "resumes_select_own" on public.resumes;
create policy "resumes_select_own" on public.resumes for select using (auth.uid() = user_id);
drop policy if exists "resumes_insert_own" on public.resumes;
create policy "resumes_insert_own" on public.resumes for insert with check (auth.uid() = user_id);
drop policy if exists "resumes_update_own" on public.resumes;
create policy "resumes_update_own" on public.resumes for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "resumes_delete_own" on public.resumes;
create policy "resumes_delete_own" on public.resumes for delete using (auth.uid() = user_id);

-- resume_files metadata
drop policy if exists "resume_files_select_own" on public.resume_files;
create policy "resume_files_select_own" on public.resume_files for select using (auth.uid() = user_id);
drop policy if exists "resume_files_insert_own" on public.resume_files;
create policy "resume_files_insert_own" on public.resume_files for insert with check (auth.uid() = user_id);
drop policy if exists "resume_files_update_own" on public.resume_files;
create policy "resume_files_update_own" on public.resume_files for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "resume_files_delete_own" on public.resume_files;
create policy "resume_files_delete_own" on public.resume_files for delete using (auth.uid() = user_id);

-- user_api_keys
drop policy if exists "user_api_keys_select_own" on public.user_api_keys;
create policy "user_api_keys_select_own" on public.user_api_keys for select using (auth.uid() = user_id);
drop policy if exists "user_api_keys_insert_own" on public.user_api_keys;
create policy "user_api_keys_insert_own" on public.user_api_keys for insert with check (auth.uid() = user_id);
drop policy if exists "user_api_keys_update_own" on public.user_api_keys;
create policy "user_api_keys_update_own" on public.user_api_keys for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "user_api_keys_delete_own" on public.user_api_keys;
create policy "user_api_keys_delete_own" on public.user_api_keys for delete using (auth.uid() = user_id);

-- interviews
drop policy if exists "interviews_select_own" on public.interviews;
create policy "interviews_select_own" on public.interviews for select using (auth.uid() = user_id);
drop policy if exists "interviews_insert_own" on public.interviews;
create policy "interviews_insert_own" on public.interviews for insert with check (auth.uid() = user_id);
drop policy if exists "interviews_update_own" on public.interviews;
create policy "interviews_update_own" on public.interviews for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "interviews_delete_own" on public.interviews;
create policy "interviews_delete_own" on public.interviews for delete using (auth.uid() = user_id);

-- Explicit Data API privileges for new Supabase projects.
-- anon remains blocked; authenticated users are still restricted by RLS.
revoke all on table public.applications from anon, authenticated;
revoke all on table public.companies from anon, authenticated;
revoke all on table public.referral_codes from anon, authenticated;
revoke all on table public.resumes from anon, authenticated;
revoke all on table public.resume_files from anon, authenticated;
revoke all on table public.user_api_keys from anon, authenticated;
revoke all on table public.interviews from anon, authenticated;
grant select, insert, update, delete on table public.applications to authenticated;
grant select, insert, update, delete on table public.companies to authenticated;
grant select, insert, update, delete on table public.referral_codes to authenticated;
grant select, insert, update, delete on table public.resumes to authenticated;
grant select, insert, update, delete on table public.resume_files to authenticated;
grant select, insert, update, delete on table public.user_api_keys to authenticated;
grant select, insert, update, delete on table public.interviews to authenticated;

-- Private storage bucket for uploaded resumes and interview scripts.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'resumes',
  'resumes',
  false,
  10485760,
  array[
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "resumes_storage_select_own" on storage.objects;
create policy "resumes_storage_select_own" on storage.objects
  for select using (bucket_id = 'resumes' and auth.uid()::text = (storage.foldername(name))[1]);

drop policy if exists "resumes_storage_insert_own" on storage.objects;
create policy "resumes_storage_insert_own" on storage.objects
  for insert with check (bucket_id = 'resumes' and auth.uid()::text = (storage.foldername(name))[1]);

drop policy if exists "resumes_storage_update_own" on storage.objects;
create policy "resumes_storage_update_own" on storage.objects
  for update using (bucket_id = 'resumes' and auth.uid()::text = (storage.foldername(name))[1])
  with check (bucket_id = 'resumes' and auth.uid()::text = (storage.foldername(name))[1]);

drop policy if exists "resumes_storage_delete_own" on storage.objects;
create policy "resumes_storage_delete_own" on storage.objects
  for delete using (bucket_id = 'resumes' and auth.uid()::text = (storage.foldername(name))[1]);

-- Curated campus referral codes. Existing referral_codes remain owner-only.
-- No account IDs or recommender identities are stored in this shared catalog.
create table if not exists public.shared_referral_codes (
  id uuid primary key default gen_random_uuid(),
  company_name text not null check (length(btrim(company_name)) > 0),
  referral_code text not null check (length(btrim(referral_code)) > 0),
  referrer_name text not null default '保密' check (referrer_name = '保密'),
  recruitment_year integer not null default 2027,
  status text not null default '待核实' check (status in ('待核实', '已核实', '已失效')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_name, referral_code, recruitment_year)
);

alter table public.shared_referral_codes enable row level security;
drop policy if exists shared_referral_codes_read_authenticated on public.shared_referral_codes;
create policy shared_referral_codes_read_authenticated
  on public.shared_referral_codes for select to authenticated using (true);
revoke all on public.shared_referral_codes from public, anon, authenticated;
grant select on public.shared_referral_codes to authenticated;

-- Personal records remain owner-only. Sharing publishes only a safe projection.
alter table public.referral_codes
  add column if not exists visibility text not null default 'private'
  check (visibility in ('private', 'public'));

alter table public.shared_referral_codes
  add column if not exists owner_referral_id uuid unique
  references public.referral_codes(id) on delete cascade;
alter table public.shared_referral_codes alter column recruitment_year drop not null;

-- Trigger-only privilege elevation: clients cannot call this function or write
-- the shared catalog, and personal names, sources and notes are never copied.
create schema if not exists referral_internal;
revoke all on schema referral_internal from public, anon, authenticated;

create or replace function referral_internal.sync_shared_referral_code()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  record_owner uuid;
begin
  if TG_OP = 'DELETE' then
    record_owner := OLD.user_id;
  else
    record_owner := NEW.user_id;
  end if;
  if current_setting('role', true) in ('authenticated', 'anon')
    and (select auth.uid()) is distinct from record_owner then
    raise insufficient_privilege using message = 'Only the owner can change referral visibility';
  end if;

  if TG_OP = 'DELETE' then
    delete from public.shared_referral_codes where owner_referral_id = OLD.id;
    return OLD;
  end if;

  if NEW.visibility = 'public' then
    insert into public.shared_referral_codes
      (company_name, referral_code, referrer_name, recruitment_year, status, notes, owner_referral_id)
    values (NEW.company_name, NEW.referral_code, '保密', null, '待核实', null, NEW.id)
    on conflict (owner_referral_id) do update set
      company_name = excluded.company_name,
      referral_code = excluded.referral_code,
      referrer_name = '保密',
      recruitment_year = null,
      status = '待核实',
      notes = null,
      updated_at = now();
  else
    delete from public.shared_referral_codes where owner_referral_id = NEW.id;
  end if;
  return NEW;
end;
$$;

revoke execute on function referral_internal.sync_shared_referral_code() from public, anon, authenticated;
drop trigger if exists sync_shared_referral_code on public.referral_codes;
create trigger sync_shared_referral_code
  after insert or update or delete on public.referral_codes
  for each row execute function referral_internal.sync_shared_referral_code();


-- ===================== migration_user_profiles.sql =====================
-- Keep profile data out of auth user_metadata because that metadata is copied
-- into every access-token JWT. Large data URLs can exceed gateway header limits.
create table if not exists public.user_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  avatar_url text,
  updated_at timestamptz not null default now(),
  constraint user_profiles_display_name_length check (display_name is null or length(display_name) <= 100),
  constraint user_profiles_avatar_length check (avatar_url is null or length(avatar_url) <= 100000)
);

alter table public.user_profiles enable row level security;

drop policy if exists user_profiles_select_own on public.user_profiles;
create policy user_profiles_select_own
on public.user_profiles for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists user_profiles_insert_own on public.user_profiles;
create policy user_profiles_insert_own
on public.user_profiles for insert to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists user_profiles_update_own on public.user_profiles;
create policy user_profiles_update_own
on public.user_profiles for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists user_profiles_delete_own on public.user_profiles;
create policy user_profiles_delete_own
on public.user_profiles for delete to authenticated
using ((select auth.uid()) = user_id);

grant select, insert, update, delete on table public.user_profiles to authenticated;

-- Preserve every existing cloud avatar before removing it from JWT metadata.
insert into public.user_profiles (user_id, avatar_url, updated_at)
select id, raw_user_meta_data ->> 'avatar_url', now()
from auth.users
where jsonb_typeof(raw_user_meta_data -> 'avatar_url') = 'string'
  and length(raw_user_meta_data ->> 'avatar_url') > 0
on conflict (user_id) do update
set avatar_url = excluded.avatar_url,
    updated_at = excluded.updated_at;

update auth.users
set raw_user_meta_data = raw_user_meta_data - 'avatar_url',
    updated_at = now()
where raw_user_meta_data ? 'avatar_url';


-- ===================== migration_phase2_career_modules.sql =====================
-- Sugar phase 2 career modules. Safe to re-run; no destructive table/column operations.
create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger language plpgsql security invoker set search_path = public
as $$ begin new.updated_at = now(); return new; end; $$;

alter table public.applications add column if not exists jd_text text;
alter table public.applications add column if not exists jd_keywords text[];
alter table public.applications add column if not exists match_score integer check (match_score between 0 and 100);
alter table public.applications add column if not exists match_summary text;
alter table public.applications add column if not exists next_action text;
alter table public.applications add column if not exists next_action_at timestamptz;
alter table public.applications add column if not exists deadline_at timestamptz;
alter table public.applications add column if not exists priority text default 'normal';
alter table public.applications add column if not exists resume_id uuid references public.resumes(id) on delete set null;

create table if not exists public.offers (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  application_id uuid references public.applications(id) on delete set null, company_name text not null,
  position_name text not null, city text, department text, manager_or_contact text, workplace text, work_schedule text,
  join_date date, reply_deadline timestamptz, offer_status text not null default '待考虑'
    check (offer_status in ('待考虑','谈薪中','已接受','已拒绝','已过期')),
  base_salary numeric, salary_months numeric, bonus numeric, subsidy numeric, annual_package numeric,
  social_security text, housing_fund text, stock_or_options text, probation_months numeric, probation_ratio numeric,
  overtime_policy text, salary_score int check (salary_score between 0 and 100),
  match_score int check (match_score between 0 and 100), growth_score int check (growth_score between 0 and 100),
  stability_score int check (stability_score between 0 and 100), city_score int check (city_score between 0 and 100),
  workload_score int check (workload_score between 0 and 100), total_score numeric, hr_offer text, expect text,
  negotiation_notes text, next_action text, next_action_at timestamptz, is_big_week boolean not null default false,
  is_overtime boolean not null default false, is_remote boolean not null default false,
  probation_cut boolean not null default false, has_penalty boolean not null default false, risk_notes text,
  decision_notes text, final_decision text, notes text, created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.interview_reviews (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  application_id uuid references public.applications(id) on delete set null,
  interview_id uuid references public.interviews(id) on delete set null, company_name text not null, position_name text,
  round text check (round is null or round in ('一面','二面','技术面','主管面','HR面')), interviewer_role text,
  interview_time timestamptz, interview_form text check (interview_form is null or interview_form in ('电话','视频','现场')),
  result text not null default '待通知' check (result in ('通过','未通过','待通知','主动放弃')),
  reviewed boolean not null default false, mistake_tags text[], performance_score int check (performance_score between 0 and 100),
  clarity_score int check (clarity_score between 0 and 100), matching_score int check (matching_score between 0 and 100),
  storytelling_score int check (storytelling_score between 0 and 100), logic_score int check (logic_score between 0 and 100),
  confidence_score int check (confidence_score between 0 and 100),
  question_quality_score int check (question_quality_score between 0 and 100), star_s text, star_t text, star_a text,
  star_r text, star_resume_ref text, good_points text, weak_points text, improve_knowledge text, improve_answers text,
  improve_prep text, improvement_plan text, next_action text, next_action_at timestamptz, notes text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.interview_review_questions (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  review_id uuid not null references public.interview_reviews(id) on delete cascade, question_text text not null,
  question_type text check (question_type is null or question_type in ('自我介绍','项目经历','实习经历','专业问题','行为面试','HR问题','反问','其他')),
  my_answer text, better_answer text, answer_score int check (answer_score between 0 and 100), problem text,
  issue_tags text[], add_to_question_bank boolean not null default false, mastery_status text not null default '需练习'
    check (mastery_status in ('需练习','已掌握','高频题')), star_situation text, star_task text, star_action text,
  star_result text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.jd_matches (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
  application_id uuid references public.applications(id) on delete set null,
  resume_id uuid references public.resumes(id) on delete set null, company_name text, position_name text, city text,
  salary_range text, jd_text text not null, job_url text, channel text, jd_duties text[], jd_requirements text[],
  skill_keywords text[], industry_keywords text[], exp_required text, edu_required text, hidden_requirements text[],
  match_score int check (match_score between 0 and 100),
  match_level text check (match_level is null or match_level in ('高匹配','中匹配','低匹配')),
  recommend_action text check (recommend_action is null or recommend_action in ('建议投递','建议修改后投递','不建议优先投递')),
  matched_keywords text[], missing_keywords text[], strong_exp text[], weak_exp text[], risk_note text,
  suggestions jsonb, interview_prep jsonb, analysis_summary text, analysis_method text not null default '基础规则分析',
  applied boolean not null default false, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create index if not exists offers_user_id_idx on public.offers(user_id);
create index if not exists offers_application_id_idx on public.offers(application_id);
create index if not exists offers_status_idx on public.offers(offer_status);
create index if not exists offers_deadline_idx on public.offers(reply_deadline);
create index if not exists offers_annual_idx on public.offers(annual_package);
create index if not exists offers_score_idx on public.offers(total_score);
create index if not exists interview_reviews_user_idx on public.interview_reviews(user_id);
create index if not exists interview_reviews_application_idx on public.interview_reviews(application_id);
create index if not exists interview_reviews_interview_idx on public.interview_reviews(interview_id);
create index if not exists interview_reviews_time_idx on public.interview_reviews(interview_time);
create index if not exists interview_reviews_result_idx on public.interview_reviews(result);
create index if not exists interview_reviews_reviewed_idx on public.interview_reviews(reviewed);
create index if not exists review_questions_user_idx on public.interview_review_questions(user_id);
create index if not exists review_questions_review_idx on public.interview_review_questions(review_id);
create index if not exists review_questions_type_idx on public.interview_review_questions(question_type);
create index if not exists review_questions_bank_idx on public.interview_review_questions(add_to_question_bank);
create index if not exists review_questions_mastery_idx on public.interview_review_questions(mastery_status);
create index if not exists jd_matches_user_idx on public.jd_matches(user_id);
create index if not exists jd_matches_resume_idx on public.jd_matches(resume_id);
create index if not exists jd_matches_application_idx on public.jd_matches(application_id);
create index if not exists jd_matches_score_idx on public.jd_matches(match_score);
create index if not exists jd_matches_created_idx on public.jd_matches(created_at);
create index if not exists jd_matches_applied_idx on public.jd_matches(applied);

alter table public.offers enable row level security;
alter table public.interview_reviews enable row level security;
alter table public.interview_review_questions enable row level security;
alter table public.jd_matches enable row level security;

do $$ declare t text; op text; begin
  foreach t in array array['offers','interview_reviews','interview_review_questions','jd_matches'] loop
    foreach op in array array['select','insert','update','delete'] loop
      execute format('drop policy if exists %I on public.%I', t || '_' || op || '_own', t);
      if op = 'insert' then
        execute format('create policy %I on public.%I for insert with check ((select auth.uid()) = user_id)', t || '_' || op || '_own', t);
      elsif op = 'update' then
        execute format('create policy %I on public.%I for update using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)', t || '_' || op || '_own', t);
      else
        execute format('create policy %I on public.%I for %s using ((select auth.uid()) = user_id)', t || '_' || op || '_own', t, op);
      end if;
    end loop;
  end loop;
end $$;

-- Supabase projects created after 2026-04-28 may not expose new public tables
-- to the Data API automatically. Keep anon blocked and allow signed-in users;
-- RLS policies above still enforce per-user row access.
revoke all on table public.offers from anon, authenticated;
revoke all on table public.interview_reviews from anon, authenticated;
revoke all on table public.interview_review_questions from anon, authenticated;
revoke all on table public.jd_matches from anon, authenticated;
grant select, insert, update, delete on table public.offers to authenticated;
grant select, insert, update, delete on table public.interview_reviews to authenticated;
grant select, insert, update, delete on table public.interview_review_questions to authenticated;
grant select, insert, update, delete on table public.jd_matches to authenticated;

drop trigger if exists offers_set_updated_at on public.offers;
create trigger offers_set_updated_at before update on public.offers for each row execute function public.set_updated_at();
drop trigger if exists interview_reviews_set_updated_at on public.interview_reviews;
create trigger interview_reviews_set_updated_at before update on public.interview_reviews for each row execute function public.set_updated_at();
drop trigger if exists review_questions_set_updated_at on public.interview_review_questions;
create trigger review_questions_set_updated_at before update on public.interview_review_questions for each row execute function public.set_updated_at();
drop trigger if exists jd_matches_set_updated_at on public.jd_matches;
create trigger jd_matches_set_updated_at before update on public.jd_matches for each row execute function public.set_updated_at();


-- ===================== migration_autofill_extension.sql =====================
-- Smart resume autofill assistant. This migration is additive and deliberately
-- does not alter or drop interview_reviews / interview_review_questions.
create extension if not exists pgcrypto;

create table if not exists public.autofill_profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  profile jsonb not null default '{}'::jsonb,
  revision integer not null default 1 check (revision > 0),
  profile_hash text not null default '',
  schema_version integer not null default 4,
  sync_scope jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id)
);
create index if not exists autofill_profiles_user_id_idx on public.autofill_profiles(user_id);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'autofill_profiles_no_sensitive_cloud_fields') then
    alter table public.autofill_profiles add constraint autofill_profiles_no_sensitive_cloud_fields check (
      profile #>> '{personal,idNumber}' is null and profile #>> '{personal,passportNumber}' is null and
      profile #>> '{personal,detailedAddress}' is null and profile #>> '{personal,addressLine1}' is null and
      profile #>> '{personal,addressLine2}' is null and profile #>> '{personal,streetAddress}' is null and
      profile #>> '{identity,idNumber}' is null and profile #>> '{identity,passportNumber}' is null and
      profile #>> '{contact,detailedAddress}' is null
    );
  end if;
end $$;

create table if not exists public.extension_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null default 'Chrome',
  browser text,
  platform text,
  extension_version text,
  protocol_version integer not null default 1,
  last_seen_at timestamptz,
  last_sync_revision integer,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists extension_devices_user_active_idx on public.extension_devices(user_id, revoked_at);

create table if not exists public.extension_pairing_codes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  code_hash text not null,
  expires_at timestamptz not null,
  max_attempts integer not null default 5 check (max_attempts between 1 and 10),
  attempts integer not null default 0 check (attempts >= 0),
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists extension_pairing_codes_hash_idx on public.extension_pairing_codes(code_hash, expires_at) where consumed_at is null;

create table if not exists public.extension_device_tokens (
  id uuid primary key default gen_random_uuid(),
  device_id uuid not null references public.extension_devices(id) on delete cascade,
  token_hash text not null unique,
  scopes text[] not null default array['profile:read','ai:invoke','run:write','device:heartbeat'],
  revoked_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
create index if not exists extension_device_tokens_device_idx on public.extension_device_tokens(device_id, revoked_at);

create table if not exists public.ai_credentials (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null,
  encrypted_secret text not null,
  model text,
  last4 text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, provider)
);
create index if not exists ai_credentials_user_id_idx on public.ai_credentials(user_id);

create table if not exists public.autofill_runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid references public.extension_devices(id) on delete set null,
  origin_host text not null,
  page_path_hash text,
  status text not null check (status in ('success','partial','failed','cancelled')),
  fields_total integer not null default 0 check (fields_total >= 0),
  fields_filled integer not null default 0 check (fields_filled >= 0),
  fields_manual integer not null default 0 check (fields_manual >= 0),
  error_codes text[] not null default '{}',
  adapter_names text[] not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists autofill_runs_user_created_idx on public.autofill_runs(user_id, created_at desc);

drop trigger if exists trg_autofill_profiles_updated on public.autofill_profiles;
create trigger trg_autofill_profiles_updated before update on public.autofill_profiles for each row execute function public.set_updated_at();
drop trigger if exists trg_extension_devices_updated on public.extension_devices;
create trigger trg_extension_devices_updated before update on public.extension_devices for each row execute function public.set_updated_at();
drop trigger if exists trg_ai_credentials_updated on public.ai_credentials;
create trigger trg_ai_credentials_updated before update on public.ai_credentials for each row execute function public.set_updated_at();

alter table public.autofill_profiles enable row level security;
alter table public.extension_devices enable row level security;
alter table public.extension_pairing_codes enable row level security;
alter table public.extension_device_tokens enable row level security;
alter table public.ai_credentials enable row level security;
alter table public.autofill_runs enable row level security;

drop policy if exists autofill_profiles_select_own on public.autofill_profiles;
create policy autofill_profiles_select_own on public.autofill_profiles for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists autofill_profiles_insert_own on public.autofill_profiles;
create policy autofill_profiles_insert_own on public.autofill_profiles for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists autofill_profiles_update_own on public.autofill_profiles;
create policy autofill_profiles_update_own on public.autofill_profiles for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
drop policy if exists autofill_profiles_delete_own on public.autofill_profiles;
create policy autofill_profiles_delete_own on public.autofill_profiles for delete to authenticated using ((select auth.uid()) = user_id);

drop policy if exists extension_devices_select_own on public.extension_devices;
create policy extension_devices_select_own on public.extension_devices for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists extension_devices_update_own on public.extension_devices;
create policy extension_devices_update_own on public.extension_devices for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists autofill_runs_select_own on public.autofill_runs;
create policy autofill_runs_select_own on public.autofill_runs for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists autofill_runs_delete_own on public.autofill_runs;
create policy autofill_runs_delete_own on public.autofill_runs for delete to authenticated using ((select auth.uid()) = user_id);

-- Private gateway-only tables: browsers never read or write these directly.
revoke all on table public.extension_pairing_codes from anon, authenticated;
revoke all on table public.extension_device_tokens from anon, authenticated;
revoke all on table public.ai_credentials from anon, authenticated;
revoke all on table public.extension_devices from anon;
revoke all on table public.autofill_runs from anon, authenticated;
grant select, insert, update, delete on table public.autofill_profiles to authenticated;
grant select, update on table public.extension_devices to authenticated;
grant select, delete on table public.autofill_runs to authenticated;


-- ===================== migration_campus_recruitment_status.sql =====================
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create table if not exists public.campus_recruitment_statuses (
  company_key text primary key,
  company_name text not null,
  official_url text not null,
  status text not null default 'pending'
    check (status in ('pending', 'not_started', 'started', 'error')),
  evidence_text text,
  evidence_url text,
  last_checked_at timestamptz,
  next_check_at timestamptz default now(),
  started_at timestamptz,
  error_message text,
  check_count integer not null default 0 check (check_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists campus_recruitment_due_idx
  on public.campus_recruitment_statuses (next_check_at)
  where status <> 'started';

alter table public.campus_recruitment_statuses enable row level security;

drop policy if exists "Authenticated users can read campus recruitment statuses"
  on public.campus_recruitment_statuses;
create policy "Authenticated users can read campus recruitment statuses"
  on public.campus_recruitment_statuses
  for select
  to authenticated
  using (true);

revoke all on public.campus_recruitment_statuses from anon;
revoke insert, update, delete, truncate, references, trigger
  on public.campus_recruitment_statuses from authenticated;
grant select on public.campus_recruitment_statuses to authenticated;

comment on table public.campus_recruitment_statuses is
  'Shared 2027 campus recruitment status sourced from official company recruitment pages.';


-- ===================== migration_mailbox_accounts.sql =====================
-- ============================================================
-- 网易 163 邮箱账号（面试邮件）
-- Safe to re-run. No destructive operations. RLS by user_id.
-- 授权码仅本人可读；请勿把 service_role 放到前端。
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists public.mailbox_accounts (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users (id) on delete cascade,
  provider        text not null default 'netease163'
    check (provider in ('netease163')),
  email           text not null,
  auth_code       text not null,
  display_name    text,
  last_synced_at  timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (user_id, provider, email)
);

create index if not exists mailbox_accounts_user_id_idx
  on public.mailbox_accounts (user_id);

alter table public.mailbox_accounts enable row level security;

drop policy if exists mailbox_accounts_select_own on public.mailbox_accounts;
create policy mailbox_accounts_select_own on public.mailbox_accounts
  for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists mailbox_accounts_insert_own on public.mailbox_accounts;
create policy mailbox_accounts_insert_own on public.mailbox_accounts
  for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists mailbox_accounts_update_own on public.mailbox_accounts;
create policy mailbox_accounts_update_own on public.mailbox_accounts
  for update to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists mailbox_accounts_delete_own on public.mailbox_accounts;
create policy mailbox_accounts_delete_own on public.mailbox_accounts
  for delete to authenticated
  using (auth.uid() = user_id);

revoke all on table public.mailbox_accounts from anon, authenticated;
grant select, insert, update, delete on table public.mailbox_accounts to authenticated;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists mailbox_accounts_set_updated_at on public.mailbox_accounts;
create trigger mailbox_accounts_set_updated_at
  before update on public.mailbox_accounts
  for each row execute function public.set_updated_at();


-- ===================== migration_mailbox_providers.sql =====================
-- ============================================================
-- 扩展邮箱服务商：网易 / QQ / Gmail / Outlook / 自定义（学校邮箱）
-- Safe to re-run. 不删除数据。保留 RLS。
-- ============================================================

alter table public.mailbox_accounts
  drop constraint if exists mailbox_accounts_provider_check;

alter table public.mailbox_accounts
  add constraint mailbox_accounts_provider_check
  check (provider in ('netease163', 'qq', 'gmail', 'outlook', 'custom'));

alter table public.mailbox_accounts
  add column if not exists imap_host text;

alter table public.mailbox_accounts
  add column if not exists imap_port integer default 993;

comment on column public.mailbox_accounts.imap_host is '自定义/学校邮箱 IMAP 主机；预设服务商可为空';
comment on column public.mailbox_accounts.imap_port is 'IMAP 端口，默认 993 SSL';


-- ===================== migrations/20260812052749_job_assist_mvp.sql =====================
-- Sugar 求职辅助 MVP。
-- 仅增加表和字段；不删除、不重写现有简历、投递、面试稿件或 JD 数据。

create table if not exists public.job_assist_campaigns (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  resume_id uuid not null references public.resumes(id) on delete cascade,
  resume_file_id uuid references public.resume_files(id) on delete set null,
  route text not null check (route in ('campus', 'social')),
  profile jsonb not null default '{}'::jsonb,
  profile_confirmed boolean not null default false,
  confirmed_facts jsonb not null default '[]'::jsonb,
  preferences jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, resume_id)
);

-- 复用现有 JD 匹配表，补齐 job-copilot 的硬门槛、证据覆盖和三类缺口。
alter table public.jd_matches
  add column if not exists campaign_id uuid references public.job_assist_campaigns(id) on delete set null,
  add column if not exists eligible boolean,
  add column if not exists hard_requirements jsonb not null default '[]'::jsonb,
  add column if not exists score_breakdown jsonb not null default '{}'::jsonb,
  add column if not exists evidence jsonb not null default '[]'::jsonb,
  add column if not exists coverage integer check (coverage is null or coverage between 0 and 100),
  add column if not exists confidence text check (confidence is null or confidence in ('high', 'medium', 'low')),
  add column if not exists presentation_gaps jsonb not null default '[]'::jsonb,
  add column if not exists information_gaps jsonb not null default '[]'::jsonb,
  add column if not exists capability_gaps jsonb not null default '[]'::jsonb,
  add column if not exists next_steps jsonb not null default '[]'::jsonb,
  add column if not exists tailoring_suggestions jsonb not null default '[]'::jsonb,
  add column if not exists tailored_draft text;

create table if not exists public.job_assist_interview_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  campaign_id uuid not null references public.job_assist_campaigns(id) on delete cascade,
  resume_id uuid not null references public.resumes(id) on delete cascade,
  jd_match_id uuid references public.jd_matches(id) on delete set null,
  application_id uuid references public.applications(id) on delete set null,
  status text not null default 'in_progress' check (status in ('in_progress', 'completed', 'abandoned')),
  current_question integer not null default 1 check (current_question between 1 and 20),
  total_questions integer not null default 3 check (total_questions between 3 and 20),
  plan jsonb not null default '[]'::jsonb,
  summary jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 明确不保存用户逐字回答或完整润色答案，只保存结构化评分和简短改进摘要。
create table if not exists public.job_assist_interview_questions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null references public.job_assist_interview_sessions(id) on delete cascade,
  question_index integer not null check (question_index between 1 and 20),
  question_type text,
  question_text text not null,
  scores jsonb not null default '{}'::jsonb,
  total_score integer check (total_score is null or total_score between 0 and 100),
  issue_tags text[] not null default '{}',
  improvement_summary text,
  created_at timestamptz not null default now(),
  unique (session_id, question_index)
);

create index if not exists job_assist_campaigns_user_idx on public.job_assist_campaigns(user_id);
create index if not exists job_assist_campaigns_resume_idx on public.job_assist_campaigns(resume_id);
create index if not exists jd_matches_campaign_idx on public.jd_matches(campaign_id);
create index if not exists job_assist_interview_sessions_user_idx on public.job_assist_interview_sessions(user_id);
create index if not exists job_assist_interview_sessions_resume_idx on public.job_assist_interview_sessions(resume_id);
create index if not exists job_assist_interview_questions_session_idx on public.job_assist_interview_questions(session_id);

alter table public.job_assist_campaigns enable row level security;
alter table public.job_assist_interview_sessions enable row level security;
alter table public.job_assist_interview_questions enable row level security;

do $$
declare
  table_name text;
  operation text;
begin
  foreach table_name in array array[
    'job_assist_campaigns',
    'job_assist_interview_sessions',
    'job_assist_interview_questions'
  ] loop
    foreach operation in array array['select', 'insert', 'update', 'delete'] loop
      execute format('drop policy if exists %I on public.%I', table_name || '_' || operation || '_own', table_name);
      if operation = 'insert' then
        execute format(
          'create policy %I on public.%I for insert to authenticated with check ((select auth.uid()) = user_id)',
          table_name || '_' || operation || '_own', table_name
        );
      elsif operation = 'update' then
        execute format(
          'create policy %I on public.%I for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)',
          table_name || '_' || operation || '_own', table_name
        );
      else
        execute format(
          'create policy %I on public.%I for %s to authenticated using ((select auth.uid()) = user_id)',
          table_name || '_' || operation || '_own', table_name, operation
        );
      end if;
    end loop;
  end loop;
end $$;

-- 外键 ID 也必须属于当前账号，防止只靠 user_id 造成跨账号关联。
drop policy if exists job_assist_campaigns_relationships_own on public.job_assist_campaigns;
create policy job_assist_campaigns_relationships_own
  on public.job_assist_campaigns as restrictive for all to authenticated
  using (
    (select auth.uid()) = user_id
    and exists (select 1 from public.resumes r where r.id = resume_id and r.user_id = (select auth.uid()))
  )
  with check (
    (select auth.uid()) = user_id
    and exists (select 1 from public.resumes r where r.id = resume_id and r.user_id = (select auth.uid()))
    and (resume_file_id is null or exists (
      select 1 from public.resume_files rf
      where rf.id = resume_file_id and rf.resume_id = resume_id and rf.user_id = (select auth.uid())
    ))
  );

drop policy if exists job_assist_interview_sessions_relationships_own on public.job_assist_interview_sessions;
create policy job_assist_interview_sessions_relationships_own
  on public.job_assist_interview_sessions as restrictive for all to authenticated
  using (
    (select auth.uid()) = user_id
    and exists (select 1 from public.job_assist_campaigns c where c.id = campaign_id and c.user_id = (select auth.uid()))
  )
  with check (
    (select auth.uid()) = user_id
    and exists (select 1 from public.job_assist_campaigns c where c.id = campaign_id and c.resume_id = resume_id and c.user_id = (select auth.uid()))
    and (jd_match_id is null or exists (select 1 from public.jd_matches j where j.id = jd_match_id and j.user_id = (select auth.uid())))
    and (application_id is null or exists (select 1 from public.applications a where a.id = application_id and a.user_id = (select auth.uid())))
  );

drop policy if exists job_assist_interview_questions_relationships_own on public.job_assist_interview_questions;
create policy job_assist_interview_questions_relationships_own
  on public.job_assist_interview_questions as restrictive for all to authenticated
  using (
    (select auth.uid()) = user_id
    and exists (select 1 from public.job_assist_interview_sessions s where s.id = session_id and s.user_id = (select auth.uid()))
  )
  with check (
    (select auth.uid()) = user_id
    and exists (select 1 from public.job_assist_interview_sessions s where s.id = session_id and s.user_id = (select auth.uid()))
  );

drop policy if exists jd_matches_job_assist_relationships_own on public.jd_matches;
create policy jd_matches_job_assist_relationships_own
  on public.jd_matches as restrictive for all to authenticated
  using (
    (select auth.uid()) = user_id
    and (resume_id is null or exists (select 1 from public.resumes r where r.id = resume_id and r.user_id = (select auth.uid())))
    and (campaign_id is null or exists (select 1 from public.job_assist_campaigns c where c.id = campaign_id and c.user_id = (select auth.uid())))
    and (application_id is null or exists (select 1 from public.applications a where a.id = application_id and a.user_id = (select auth.uid())))
  )
  with check (
    (select auth.uid()) = user_id
    and (resume_id is null or exists (select 1 from public.resumes r where r.id = resume_id and r.user_id = (select auth.uid())))
    and (campaign_id is null or exists (select 1 from public.job_assist_campaigns c where c.id = campaign_id and c.user_id = (select auth.uid())))
    and (application_id is null or exists (select 1 from public.applications a where a.id = application_id and a.user_id = (select auth.uid())))
  );

-- 2026-05 起新表可能不会自动暴露到 Data API；显式授权，RLS 仍负责账号隔离。
revoke all on table public.job_assist_campaigns from anon, authenticated;
revoke all on table public.job_assist_interview_sessions from anon, authenticated;
revoke all on table public.job_assist_interview_questions from anon, authenticated;
grant select, insert, update, delete on table public.job_assist_campaigns to authenticated;
grant select, insert, update, delete on table public.job_assist_interview_sessions to authenticated;
grant select, insert, update, delete on table public.job_assist_interview_questions to authenticated;

drop trigger if exists job_assist_campaigns_set_updated_at on public.job_assist_campaigns;
create trigger job_assist_campaigns_set_updated_at
  before update on public.job_assist_campaigns
  for each row execute function public.set_updated_at();

drop trigger if exists job_assist_interview_sessions_set_updated_at on public.job_assist_interview_sessions;
create trigger job_assist_interview_sessions_set_updated_at
  before update on public.job_assist_interview_sessions
  for each row execute function public.set_updated_at();


-- ===================== migrations/20260812065000_job_assist_foreign_key_indexes.sql =====================
-- Cover job-assist foreign keys that are used by ownership checks and joins.
create index if not exists job_assist_campaigns_resume_file_idx
  on public.job_assist_campaigns(resume_file_id);

create index if not exists job_assist_interview_sessions_campaign_idx
  on public.job_assist_interview_sessions(campaign_id);

create index if not exists job_assist_interview_sessions_jd_match_idx
  on public.job_assist_interview_sessions(jd_match_id);

create index if not exists job_assist_interview_sessions_application_idx
  on public.job_assist_interview_sessions(application_id);

create index if not exists job_assist_interview_questions_user_idx
  on public.job_assist_interview_questions(user_id);


-- ===================== migrations/20260813090000_resume_company_finder.sql =====================
-- Private resume-to-company recommendation feature.
-- The public standard company catalogue remains in the deployed client data;
-- only a user's uploads, preferences and recommendations are stored here.

create table if not exists public.company_recommendation_runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  resume_file_name text not null,
  resume_file_path text not null,
  preferences text[] not null default '{}'::text[],
  created_at timestamptz not null default now()
);

create index if not exists company_recommendation_runs_user_created_idx
  on public.company_recommendation_runs (user_id, created_at desc);

create table if not exists public.company_recommendations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  run_id uuid references public.company_recommendation_runs(id) on delete set null,
  source text not null check (source in ('resume', 'ai_search')),
  recommendation_type text not null check (recommendation_type in ('standard', 'private')),
  company_name text not null,
  industry text,
  city text,
  company_type text,
  website text,
  match_score smallint check (match_score is null or match_score between 0 and 100),
  reason text,
  created_at timestamptz not null default now()
);

create index if not exists company_recommendations_user_created_idx
  on public.company_recommendations (user_id, created_at desc);
create index if not exists company_recommendations_user_type_idx
  on public.company_recommendations (user_id, recommendation_type);

alter table public.company_recommendation_runs enable row level security;
alter table public.company_recommendations enable row level security;

drop policy if exists "company_recommendation_runs_select_own" on public.company_recommendation_runs;
create policy "company_recommendation_runs_select_own" on public.company_recommendation_runs
  for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "company_recommendation_runs_insert_own" on public.company_recommendation_runs;
create policy "company_recommendation_runs_insert_own" on public.company_recommendation_runs
  for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "company_recommendation_runs_delete_own" on public.company_recommendation_runs;
create policy "company_recommendation_runs_delete_own" on public.company_recommendation_runs
  for delete to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "company_recommendations_select_own" on public.company_recommendations;
create policy "company_recommendations_select_own" on public.company_recommendations
  for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "company_recommendations_insert_own" on public.company_recommendations;
create policy "company_recommendations_insert_own" on public.company_recommendations
  for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "company_recommendations_delete_own" on public.company_recommendations;
create policy "company_recommendations_delete_own" on public.company_recommendations
  for delete to authenticated using ((select auth.uid()) = user_id);

revoke all on public.company_recommendation_runs from anon, authenticated;
revoke all on public.company_recommendations from anon, authenticated;
grant select, insert, delete on public.company_recommendation_runs to authenticated;
grant select, insert, delete on public.company_recommendations to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'company-resumes',
  'company-resumes',
  false,
  10485760,
  array[
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "company_resumes_select_own" on storage.objects;
create policy "company_resumes_select_own" on storage.objects
  for select to authenticated using (
    bucket_id = 'company-resumes'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  );
drop policy if exists "company_resumes_insert_own" on storage.objects;
create policy "company_resumes_insert_own" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'company-resumes'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and storage.extension(name) in ('pdf', 'docx')
  );
drop policy if exists "company_resumes_delete_own" on storage.objects;
create policy "company_resumes_delete_own" on storage.objects
  for delete to authenticated using (
    bucket_id = 'company-resumes'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  );


-- ===================== migrations/20260813093000_company_resume_extension_case.sql =====================
-- Files selected by Windows may have an upper-case extension (for example PDF).
-- Treat the extension case-insensitively while keeping the private user folder rule.
drop policy if exists "company_resumes_insert_own" on storage.objects;
create policy "company_resumes_insert_own" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'company-resumes'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
    and lower(storage.extension(name)) in ('pdf', 'docx')
  );


-- ===================== migrations/20260813123000_allow_extension_validated_company_resume_uploads.sql =====================
-- Browser-provided MIME metadata is not reliable for otherwise valid PDF/DOCX
-- files. Keep the private bucket, 10MB cap and extension/ownership RLS policy;
-- remove only the Storage MIME allow-list that rejects those browser uploads.
update storage.buckets
set public = false,
    file_size_limit = 10485760,
    allowed_mime_types = null
where id = 'company-resumes';


-- ===================== migrations/20260818045500_standard_company_catalog.sql =====================
-- Shared standard-company catalogue overlay.
-- Seed companies stay in the deployed client data; imported Excel rows
-- add new companies or fill/update name-matched fields.

create table if not exists public.standard_companies (
  company_key text primary key,
  company_name text not null,
  source_update_date date,
  company_type text not null default '',
  industry text not null default '其他',
  city text not null default '',
  deadline_text text not null default '',
  notice_url text not null default '',
  apply_url text not null default '',
  url text not null default '',
  group_name text not null default '飞书导入',
  source text not null default 'excel_import',
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint standard_companies_name_len check (char_length(company_name) between 1 and 80),
  constraint standard_companies_notice_url_http check (notice_url = '' or notice_url ~* '^https?://'),
  constraint standard_companies_apply_url_http check (apply_url = '' or apply_url ~* '^https?://'),
  constraint standard_companies_url_http check (url = '' or url ~* '^https?://')
);

create table if not exists public.standard_company_import_runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  file_name text not null,
  added_count int not null default 0,
  updated_count int not null default 0,
  unchanged_count int not null default 0,
  skipped_count int not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists standard_companies_updated_idx
  on public.standard_companies (updated_at desc);
create index if not exists standard_company_import_runs_created_idx
  on public.standard_company_import_runs (created_at desc);

alter table public.standard_companies enable row level security;
alter table public.standard_company_import_runs enable row level security;

drop policy if exists "standard_companies_select_public" on public.standard_companies;
create policy "standard_companies_select_public" on public.standard_companies
  for select to anon, authenticated using (true);

drop policy if exists "standard_company_import_runs_select_own" on public.standard_company_import_runs;
create policy "standard_company_import_runs_select_own" on public.standard_company_import_runs
  for select to authenticated using ((select auth.uid()) = user_id);

revoke all on public.standard_companies from anon, authenticated;
revoke all on public.standard_company_import_runs from anon, authenticated;
grant select on public.standard_companies to anon, authenticated;
grant select on public.standard_company_import_runs to authenticated;


-- ===================== migrations/20260822090000_standard_company_catalog_recruitment_fields.sql =====================
-- Preserve the recruitment fields needed by the Hot Companies page when
-- the shared standard company table already exists in production.
alter table if exists public.standard_companies
  add column if not exists company_type text not null default '',
  add column if not exists deadline_text text not null default '',
  add column if not exists notice_url text not null default '',
  add column if not exists apply_url text not null default '';

alter table if exists public.standard_companies
  drop constraint if exists standard_companies_notice_url_http,
  drop constraint if exists standard_companies_apply_url_http;

alter table if exists public.standard_companies
  add constraint standard_companies_notice_url_http
    check (notice_url = '' or notice_url ~* '^https?://'),
  add constraint standard_companies_apply_url_http
    check (apply_url = '' or apply_url ~* '^https?://');


-- ===================== migrations/20260822123000_standard_company_catalog_update_date.sql =====================
alter table public.standard_companies
  add column if not exists source_update_date date;


-- ===================== migrations/20261014101309_mail_interview_auto_sync.sql =====================
-- Additive mailbox sync. Credentials live in Vault; existing APIs remain compatible during rollout.
create schema if not exists mail_sync_private;
revoke all on schema mail_sync_private from public, anon, authenticated;
grant usage on schema mail_sync_private to service_role;
grant usage on schema vault to service_role;
grant select on vault.decrypted_secrets to service_role;

alter table public.interviews add column if not exists status text not null default 'scheduled' check (status in ('scheduled','cancelled'));
alter table public.interviews add column if not exists source text not null default 'manual';
alter table public.interviews add column if not exists version integer not null default 1;
alter table public.interviews add column if not exists timezone text;
alter table public.interviews add column if not exists meeting_url text;
alter table public.interviews add column if not exists location text;
alter table public.interviews add column if not exists contact text;
alter table public.interviews add column if not exists end_time timestamptz;

create table public.mail_sync_settings (
 account_id uuid primary key references public.mailbox_accounts(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 enabled boolean not null default true, provider text, model text,
 enabled_at timestamptz not null default now(), timezone text not null default 'Asia/Shanghai', folder text not null default 'INBOX',
 uidvalidity text, last_uid bigint, next_scan_at timestamptz not null default now(),
 lease_token uuid, lease_until timestamptz, config_version integer not null default 1,
 last_checked_at timestamptz, last_success_at timestamptz, error_code text,
 failures integer not null default 0, error_until timestamptz, backfill_since timestamptz,
 updated_at timestamptz not null default now()
);
create index mail_sync_settings_due on public.mail_sync_settings(next_scan_at) where enabled;
create table mail_sync_private.credentials (
 kind text not null check(kind in ('mailbox','ai')), owner_id uuid not null,
 provider text not null default '', user_id uuid not null references auth.users(id) on delete cascade,
 secret_id uuid not null references vault.secrets(id), version integer not null default 1,
 primary key(kind,owner_id,provider)
);
create table public.mail_sync_messages (
 id uuid primary key default gen_random_uuid(), account_id uuid not null references public.mailbox_accounts(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade, folder text not null, uidvalidity text not null, uid bigint not null,
 message_id text, references_ids text[] not null default '{}', received_at timestamptz not null,
 source_data jsonb not null, status text not null default 'pending' check(status in ('pending','review','done','ignored','suppressed','failed')),
 analysis jsonb, reason text, interview_id uuid references public.interviews(id) on delete set null,
 attempts integer not null default 0, next_attempt_at timestamptz not null default now(), lease_token uuid, lease_until timestamptz,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(account_id,folder,uidvalidity,uid)
);
create index mail_sync_messages_pending on public.mail_sync_messages(next_attempt_at) where status='pending';
create index mail_sync_messages_owner on public.mail_sync_messages(user_id,status);
create index mail_sync_messages_thread on public.mail_sync_messages(user_id,message_id);
create table public.interview_mail_sources (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 interview_id uuid references public.interviews(id) on delete set null, event_key text not null,
 snapshot jsonb, last_received_at timestamptz, sequence integer, suppressed boolean not null default false,
 unique(user_id,event_key)
);
create index interview_mail_sources_target on public.interview_mail_sources(interview_id);
create table public.interview_change_log (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 interview_id uuid references public.interviews(id) on delete set null,
 message_id uuid references public.mail_sync_messages(id) on delete set null,
 action text not null, before_data jsonb, after_data jsonb, created_at timestamptz not null default now()
);
create index interview_change_log_owner on public.interview_change_log(user_id,created_at desc);

alter table mail_sync_private.credentials enable row level security;
grant all on mail_sync_private.credentials to service_role;
alter table public.mail_sync_settings enable row level security;
alter table public.mail_sync_messages enable row level security;
alter table public.interview_mail_sources enable row level security;
alter table public.interview_change_log enable row level security;
create policy own_settings on public.mail_sync_settings for select to authenticated using ((select auth.uid())=user_id);
create policy own_messages on public.mail_sync_messages for select to authenticated using ((select auth.uid())=user_id);
create policy own_sources on public.interview_mail_sources for select to authenticated using ((select auth.uid())=user_id);
create policy own_changes on public.interview_change_log for select to authenticated using ((select auth.uid())=user_id);
revoke all on public.mail_sync_settings,public.mail_sync_messages,public.interview_mail_sources,public.interview_change_log from anon,authenticated;
grant select on public.mail_sync_settings,public.interview_mail_sources,public.interview_change_log to authenticated;
-- Bodies and suggestions are returned by the authenticated backend, not a broadly selectable table.
grant all on public.mail_sync_settings,public.mail_sync_messages,public.interview_mail_sources,public.interview_change_log to service_role;

create or replace function mail_sync_private.capture_credential() returns trigger
language plpgsql security definer set search_path='' as $$
declare k text; oid uuid; p text; sec text; sid uuid; own uuid;
begin
 k:=case when tg_table_name='mailbox_accounts' then 'mailbox' else 'ai' end;
 if tg_op='DELETE' then
  if k='mailbox' then oid:=old.id; p:=''; else oid:=old.user_id; p:=old.provider; end if;
  select secret_id into sid from mail_sync_private.credentials where kind=k and owner_id=oid and provider=p;
  delete from mail_sync_private.credentials where kind=k and owner_id=oid and provider=p;
  if sid is not null then delete from vault.secrets where id=sid; end if;
  if k='ai' then update public.mail_sync_settings set config_version=config_version+1,error_code='AI_NOT_CONFIGURED',error_until=null,lease_token=null,lease_until=null where user_id=old.user_id and provider=p; end if;
  return old;
 end if;
 if k='mailbox' then oid:=new.id; p:=''; sec:=new.auth_code; else oid:=new.user_id; p:=new.provider; sec:=new.api_key; end if;
 own:=new.user_id;
 if sec is not null and length(sec)>0 and sec<>'[已安全保存]' then
  select secret_id into sid from mail_sync_private.credentials where kind=k and owner_id=oid and provider=p;
  if sid is null then
   select vault.create_secret(sec,'mail-sync-'||k||'-'||oid::text||'-'||p) into sid;
   insert into mail_sync_private.credentials(kind,owner_id,provider,user_id,secret_id) values(k,oid,p,own,sid);
  else
   perform vault.update_secret(sid,sec);
   update mail_sync_private.credentials set version=version+1 where kind=k and owner_id=oid and provider=p;
  end if;
  if k='mailbox' then
   insert into public.mail_sync_settings(account_id,user_id) values(oid,own) on conflict do nothing;
   update public.mail_sync_settings set config_version=config_version+1,error_code=null,error_until=null,failures=0,next_scan_at=now(),lease_token=null,lease_until=null where account_id=oid;
  else
   update public.mail_sync_settings set config_version=config_version+1,error_code=null,error_until=null,next_scan_at=now(),lease_token=null,lease_until=null where user_id=own and provider=p;
  end if;
 end if;
 return new;
end $$;
revoke all on function mail_sync_private.capture_credential() from public,anon,authenticated;
create trigger mail_sync_mail_credential after insert or update of auth_code on public.mailbox_accounts for each row execute function mail_sync_private.capture_credential();
create trigger mail_sync_mail_delete before delete on public.mailbox_accounts for each row execute function mail_sync_private.capture_credential();
create trigger mail_sync_ai_credential after insert or update of api_key on public.user_api_keys for each row execute function mail_sync_private.capture_credential();
create trigger mail_sync_ai_delete before delete on public.user_api_keys for each row execute function mail_sync_private.capture_credential();
-- Copy existing credentials inside the database. No secrets are returned to the migration client.
update public.mailbox_accounts set auth_code=auth_code;
update public.user_api_keys set api_key=api_key;
-- Existing single-provider accounts can be connected without guessing a provider; multiple-provider users
-- retain their existing browser selection, persisted on the next authenticated page visit.
update public.mail_sync_settings s set provider=k.provider from
 (select user_id,min(provider) provider from public.user_api_keys group by user_id having count(*)=1) k where s.user_id=k.user_id;

create or replace function public.mail_sync_credential(p_kind text,p_owner uuid,p_provider text default '') returns text
language sql security invoker set search_path='' as $$
 select v.decrypted_secret from mail_sync_private.credentials c join vault.decrypted_secrets v on v.id=c.secret_id
 where c.kind=p_kind and c.owner_id=p_owner and c.provider=p_provider
$$;
create or replace function public.mail_sync_authorize_cron(p_token text) returns boolean
language sql security invoker set search_path='' as $$
 select exists(select 1 from vault.decrypted_secrets where name='mail_sync_runner_token' and decrypted_secret=p_token and length(p_token)>=32)
$$;

create or replace function public.mail_sync_claim_account(p_account uuid default null) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare s public.mail_sync_settings; a public.mailbox_accounts;
begin
 select * into s from public.mail_sync_settings where enabled and provider is not null
 and (p_account is null or account_id=p_account) and next_scan_at<=now()
 and (lease_until is null or lease_until<now()) and (error_code is distinct from 'MAIL_AUTH_INVALID' or error_until<now())
 and exists(select 1 from mail_sync_private.credentials c where c.kind='ai' and c.owner_id=mail_sync_settings.user_id and c.provider=mail_sync_settings.provider)
 order by next_scan_at for update skip locked limit 1;
 if s.account_id is null then return null; end if;
 update public.mail_sync_settings set lease_token=gen_random_uuid(),lease_until=now()+interval '150 seconds',last_checked_at=now() where account_id=s.account_id returning * into s;
 select * into a from public.mailbox_accounts where id=s.account_id and user_id=s.user_id;
 return jsonb_build_object('settings',to_jsonb(s),'account',to_jsonb(a)-'auth_code','password',public.mail_sync_credential('mailbox',a.id,''));
end $$;

create or replace function public.mail_sync_store_scan(p_account uuid,p_token uuid,p_validity text,p_last bigint,p_messages jsonb) returns integer
language plpgsql security invoker set search_path='' as $$
declare s public.mail_sync_settings; m jsonb; n integer:=0;
begin
 select * into s from public.mail_sync_settings where account_id=p_account for update;
 if not s.enabled or s.lease_token is distinct from p_token or s.lease_until<now() then raise exception 'SYNC_SUPERSEDED'; end if;
 for m in select value from jsonb_array_elements(p_messages) loop
  insert into public.mail_sync_messages(account_id,user_id,folder,uidvalidity,uid,message_id,references_ids,received_at,source_data)
  values(s.account_id,s.user_id,s.folder,p_validity,(m->>'uid')::bigint,m->>'messageId',array(select jsonb_array_elements_text(coalesce(m->'references','[]'))),(m->>'receivedAt')::timestamptz,m)
  on conflict(account_id,folder,uidvalidity,uid) do nothing;
  n:=n+1;
 end loop;
 update public.mail_sync_settings set uidvalidity=p_validity,last_uid=p_last,lease_token=null,lease_until=null,last_success_at=now(),next_scan_at=now()+interval '5 minutes',backfill_since=null,failures=0,error_code=case when error_code like 'MAIL_%' then null else error_code end,updated_at=now() where account_id=p_account;
 return n;
end $$;

create or replace function public.mail_sync_claim_message(p_account uuid default null) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare m public.mail_sync_messages; s public.mail_sync_settings;
begin
 select mm.* into m from public.mail_sync_messages mm join public.mail_sync_settings ss on ss.account_id=mm.account_id
 where mm.status='pending' and ss.enabled and ss.provider is not null and mm.next_attempt_at<=now()
 and (p_account is null or mm.account_id=p_account) and (mm.lease_until is null or mm.lease_until<now())
 and (ss.error_code not like 'AI_%' or ss.error_code is null or ss.error_until<now())
 order by mm.received_at,mm.uid for update of mm skip locked limit 1;
 if m.id is null then return null; end if;
 select * into s from public.mail_sync_settings where account_id=m.account_id;
 update public.mail_sync_messages set lease_token=gen_random_uuid(),lease_until=now()+interval '150 seconds',attempts=attempts+1 where id=m.id returning * into m;
 return jsonb_build_object('message',to_jsonb(m),'settings',to_jsonb(s),'apiKey',public.mail_sync_credential('ai',s.user_id,s.provider));
end $$;

create or replace function public.mail_sync_snapshot(p_data jsonb) returns jsonb language sql immutable security invoker set search_path='' as $$
 select jsonb_build_object('company_name',p_data->'company_name','position_name',p_data->'position_name','interview_time',p_data->'interview_time','round',p_data->'round','interview_type',p_data->'interview_type','status',p_data->'status','meeting_url',p_data->'meeting_url','location',p_data->'location')
$$;

create or replace function public.mail_sync_apply(p_id uuid,p_token uuid,p_version integer,p_analysis jsonb,p_manual boolean default false) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare m public.mail_sync_messages; s public.mail_sync_settings; ev public.interviews; src public.interview_mail_sources;
 key text; legacy text; op text; before_data jsonb; after_data jsonb; ids uuid[]; reason text; oldtime timestamptz; target_version integer;
begin
 select * into m from public.mail_sync_messages where id=p_id for update;
 if m.id is null then raise exception 'MESSAGE_NOT_FOUND'; end if;
 if not p_manual and (m.lease_token is distinct from p_token or m.lease_until<now()) then raise exception 'SYNC_SUPERSEDED'; end if;
 if p_manual and m.status<>'review' then raise exception 'SUGGESTION_ALREADY_RESOLVED'; end if;
 select * into s from public.mail_sync_settings where account_id=m.account_id for update;
 if not p_manual and (not s.enabled or s.config_version<>p_version or not exists(select 1 from mail_sync_private.credentials where kind='ai' and owner_id=s.user_id and provider=s.provider)) then raise exception 'SYNC_SUPERSEDED'; end if;
 op:=p_analysis->>'action';
 if op in ('review','ignore') then
  update public.mail_sync_messages set status=case when op='review' then 'review' else 'ignored' end,analysis=p_analysis,reason=p_analysis->>'reason',lease_token=null,lease_until=null,updated_at=now() where id=m.id;
  return jsonb_build_object('status',case when op='review' then 'review' else 'ignored' end);
 end if;
 if op not in ('create','reschedule','cancel') then raise exception 'INVALID_ACTION'; end if;
 if coalesce(length(btrim(p_analysis->>'company_name')),0)=0 or (op<>'cancel' and coalesce(p_analysis->>'interview_time','')='') then raise exception 'INVALID_INTERVIEW'; end if;
 key:=p_analysis->>'event_key'; legacy:=p_analysis->>'legacy_marker';
 if key is null or length(key)>1200 then raise exception 'INVALID_EVENT_KEY'; end if;
 select * into src from public.interview_mail_sources where user_id=m.user_id and event_key=key for update;
 if src.id is null and legacy is not null then select * into src from public.interview_mail_sources where user_id=m.user_id and event_key='legacy:'||legacy for update; end if;
 if src.suppressed then
  update public.mail_sync_messages set status='suppressed',reason='DELETED_BY_USER',lease_token=null,lease_until=null where id=m.id;
  return jsonb_build_object('status','suppressed');
 end if;
 if src.interview_id is not null then select * into ev from public.interviews where id=src.interview_id and user_id=m.user_id for update; end if;
 if ev.id is null then
  -- Exact provenance first, then a unique referenced message or explicit prior time.
  select array_agg(distinct i.id) into ids from public.interviews i where i.user_id=m.user_id and (
   (legacy is not null and position(legacy in coalesce(i.notes,''))>0)
   or i.id in (select interview_id from public.mail_sync_messages where user_id=m.user_id and message_id=any(m.references_ids) and interview_id is not null)
   or ((op in ('cancel','reschedule')) and p_analysis->>'prior_time' is not null and i.interview_time=(p_analysis->>'prior_time')::timestamptz and i.company_name=p_analysis->>'company_name'));
  if coalesce(array_length(ids,1),0)=1 then select * into ev from public.interviews where id=ids[1] and user_id=m.user_id for update;
  elsif coalesce(array_length(ids,1),0)>1 then reason:='MATCH_AMBIGUOUS'; end if;
 end if;
 if ev.id is not null and src.id is null then select * into src from public.interview_mail_sources where user_id=m.user_id and interview_id=ev.id order by last_received_at desc nulls last limit 1 for update; end if;
 if op in ('cancel','reschedule') and ev.id is null then reason:=coalesce(reason,'TARGET_NOT_IDENTIFIED'); end if;
 if ev.id is null and op='create' then
  select array_agg(i.id) into ids from public.interviews i where i.user_id=m.user_id and i.company_name=p_analysis->>'company_name'
  and coalesce(i.position_name,'')=coalesce(p_analysis->>'position_name','') and coalesce(i.round,'')=coalesce(p_analysis->>'round','') and i.interview_time=(p_analysis->>'interview_time')::timestamptz;
  if coalesce(array_length(ids,1),0)>0 then reason:='POSSIBLE_DUPLICATE'; end if;
 end if;
 if ev.id is not null then
  before_data:=to_jsonb(ev);
  if src.last_received_at>m.received_at and not p_manual then
   update public.mail_sync_messages set status='ignored',reason='OLDER_NOTIFICATION',analysis=p_analysis,interview_id=ev.id,lease_token=null,lease_until=null where id=m.id;
   return jsonb_build_object('status','ignored');
  end if;
  if src.sequence is not null and p_analysis->>'sequence' is not null and (p_analysis->>'sequence')::integer<src.sequence and not p_manual then
   update public.mail_sync_messages set status='ignored',reason='OLDER_NOTIFICATION',lease_token=null,lease_until=null where id=m.id;
   return jsonb_build_object('status','ignored');
  end if;
  if not p_manual and src.snapshot is not null and src.snapshot<>public.mail_sync_snapshot(before_data) then reason:='MANUAL_EDIT_CONFLICT'; end if;
  if op in ('reschedule','cancel') and src.id is null and not p_manual then reason:=coalesce(reason,'MANUAL_RECORD_REVIEW'); end if;
  target_version:=(m.analysis->>'target_version')::integer;
  if p_manual and target_version is not null and target_version<>ev.version then raise exception 'INTERVIEW_CHANGED'; end if;
 end if;
 if reason is not null and not p_manual then
  update public.mail_sync_messages set status='review',analysis=p_analysis||jsonb_build_object('target_id',ev.id,'target_version',ev.version,'current',before_data),reason=reason,interview_id=ev.id,lease_token=null,lease_until=null,updated_at=now() where id=m.id;
  return jsonb_build_object('status','review','reason',reason);
 end if;
 if ev.id is null then
  if op<>'create' then raise exception 'TARGET_NOT_IDENTIFIED'; end if;
  insert into public.interviews(id,user_id,company_name,position_name,interview_time,round,interview_type,notes,source,timezone,meeting_url,location,contact,end_time,application_id)
  values((p_analysis->>'stable_id')::uuid,m.user_id,p_analysis->>'company_name',nullif(p_analysis->>'position_name',''),(p_analysis->>'interview_time')::timestamptz,nullif(p_analysis->>'round',''),nullif(p_analysis->>'interview_type',''),coalesce(legacy,'')||E'\n来源邮件：'||(m.source_data->>'subject'),'email',s.timezone,p_analysis->>'meeting_url',p_analysis->>'location',p_analysis->>'contact',(p_analysis->>'end_time')::timestamptz,(p_analysis->>'application_id')::uuid)
  on conflict(id) do nothing returning * into ev;
  if ev.id is null then select * into ev from public.interviews where id=(p_analysis->>'stable_id')::uuid and user_id=m.user_id for update; if ev.id is null then raise exception 'ID_CONFLICT'; end if; end if;
 elsif op='cancel' then
  update public.interviews set status='cancelled' where id=ev.id and user_id=m.user_id returning * into ev;
 elsif op='reschedule' then
  update public.interviews set interview_time=(p_analysis->>'interview_time')::timestamptz,status='scheduled',meeting_url=coalesce(p_analysis->>'meeting_url',meeting_url),location=coalesce(p_analysis->>'location',location),end_time=(p_analysis->>'end_time')::timestamptz where id=ev.id and user_id=m.user_id returning * into ev;
 end if;
 after_data:=to_jsonb(ev);
 insert into public.interview_mail_sources(user_id,interview_id,event_key,snapshot,last_received_at,sequence)
 values(m.user_id,ev.id,key,public.mail_sync_snapshot(after_data),m.received_at,(p_analysis->>'sequence')::integer)
 on conflict(user_id,event_key) do update set interview_id=excluded.interview_id,snapshot=excluded.snapshot,last_received_at=excluded.last_received_at,sequence=excluded.sequence;
 -- Refresh all aliases of the same source so their snapshots cannot remain stale after a genuine reschedule.
 update public.interview_mail_sources set snapshot=public.mail_sync_snapshot(after_data),last_received_at=greatest(last_received_at,m.received_at) where user_id=m.user_id and interview_id=ev.id;
 update public.mail_sync_messages set status='done',analysis=p_analysis,interview_id=ev.id,reason=case when op='create' and before_data is not null then 'DUPLICATE' else null end,lease_token=null,lease_until=null,source_data=source_data-'body',updated_at=now() where id=m.id;
 insert into public.interview_change_log(user_id,interview_id,message_id,action,before_data,after_data) values(m.user_id,ev.id,m.id,op,before_data,after_data);
 return jsonb_build_object('status','done','interview_id',ev.id,'action',op);
end $$;

create or replace function mail_sync_private.interview_version_and_delete() returns trigger language plpgsql security definer set search_path='' as $$
declare marker text;
begin
 if tg_op='UPDATE' then new.version:=old.version+1; return new; end if;
 update public.interview_mail_sources set suppressed=true where interview_id=old.id and user_id=old.user_id;
 marker:=(regexp_match(coalesce(old.notes,''),'(\[Sugar邮件:[^]]+\])'))[1];
 if marker is not null then insert into public.interview_mail_sources(user_id,event_key,suppressed) values(old.user_id,'legacy:'||marker,true) on conflict(user_id,event_key) do update set suppressed=true; end if;
 insert into public.interview_change_log(user_id,action,before_data) values(old.user_id,'deleted_by_user',to_jsonb(old));
 return old;
end $$;
revoke all on function mail_sync_private.interview_version_and_delete() from public,anon,authenticated;
create trigger mail_sync_interview_version before update on public.interviews for each row execute function mail_sync_private.interview_version_and_delete();
create trigger mail_sync_interview_deleted before delete on public.interviews for each row execute function mail_sync_private.interview_version_and_delete();

-- RPCs are backend-only; service_role never goes to the browser.
revoke all on function public.mail_sync_credential(text,uuid,text),public.mail_sync_authorize_cron(text),public.mail_sync_claim_account(uuid),public.mail_sync_store_scan(uuid,uuid,text,bigint,jsonb),public.mail_sync_claim_message(uuid),public.mail_sync_snapshot(jsonb),public.mail_sync_apply(uuid,uuid,integer,jsonb,boolean) from public,anon,authenticated;
grant execute on function public.mail_sync_credential(text,uuid,text),public.mail_sync_authorize_cron(text),public.mail_sync_claim_account(uuid),public.mail_sync_store_scan(uuid,uuid,text,bigint,jsonb),public.mail_sync_claim_message(uuid),public.mail_sync_snapshot(jsonb),public.mail_sync_apply(uuid,uuid,integer,jsonb,boolean) to service_role;


-- ===================== migrations/20261014104330_mail_interview_sync_revision_and_scheduling.sql =====================
create or replace function public.mail_sync_user_revision() returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('updated_at',max(updated_at),'count',count(*),'version',coalesce(sum(version),0))
 from public.interviews where user_id=(select auth.uid())
$$;
revoke all on function public.mail_sync_user_revision() from public,anon;
grant execute on function public.mail_sync_user_revision() to authenticated,service_role;

-- This new automatic feature is initially active only for the account owner who requested rollout.
-- Other existing users can opt in using their own switch. Newly connected mailboxes use the documented default.
update public.mail_sync_settings s set enabled=false
where not exists(select 1 from auth.users u where u.id=s.user_id and u.email='twxyforl@gmail.com');

do $$ begin
 if not exists(select 1 from vault.secrets where name='mail_sync_runner_token') then
  perform vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),'mail_sync_runner_token','Mailbox automatic interview sync internal authorization');
 end if;
end $$;
create or replace function mail_sync_private.dispatch() returns bigint language plpgsql security invoker set search_path='' as $$
declare rid bigint;
begin
 if not exists(select 1 from public.mail_sync_settings where enabled and provider is not null and next_scan_at<=now() and (lease_until is null or lease_until<now()) and (error_code is distinct from 'MAIL_AUTH_INVALID' or error_until<now()))
 and not exists(select 1 from public.mail_sync_messages m join public.mail_sync_settings s on s.account_id=m.account_id where s.enabled and s.provider is not null and m.status='pending' and m.next_attempt_at<=now() and (m.lease_until is null or m.lease_until<now()) and (s.error_code not like 'AI_%' or s.error_code is null or s.error_until<now())) then return null; end if;
 select net.http_post(url:='https://www.sugarv.mom/api/mail-interview-sync?action=cron',headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='mail_sync_runner_token')),body:='{}'::jsonb,timeout_milliseconds:=110000) into rid;
 return rid;
end $$;
revoke all on function mail_sync_private.dispatch() from public,anon,authenticated;
grant execute on function mail_sync_private.dispatch() to service_role;
select cron.schedule('mail-interview-auto-sync','* * * * *','select mail_sync_private.dispatch();');
-- Enable after the production endpoint and database transactions have been verified.
select cron.alter_job(jobid,active:=false) from cron.job where jobname='mail-interview-auto-sync';

-- Keep only minimal evidence. Ordinary email bodies are never persisted by the scanner.
select cron.schedule('mail-interview-sync-cache-cleanup','15 3 * * *', $cleanup$
 update public.mail_sync_messages set source_data=source_data-'body' where created_at<now()-interval '7 days';
 delete from public.mail_sync_messages where status='ignored' and created_at<now()-interval '30 days';
 $cleanup$);


-- Updated transactional RPCs.
create or replace function public.mail_sync_store_scan(p_account uuid,p_token uuid,p_validity text,p_last bigint,p_messages jsonb) returns integer
language plpgsql security invoker set search_path='' as $$
declare s public.mail_sync_settings; m jsonb; n integer:=0;
begin
 select * into s from public.mail_sync_settings where account_id=p_account for update;
 if not s.enabled or s.lease_token is distinct from p_token or s.lease_until<now() then raise exception 'SYNC_SUPERSEDED'; end if;
 for m in select value from jsonb_array_elements(p_messages) loop
  insert into public.mail_sync_messages(account_id,user_id,folder,uidvalidity,uid,message_id,references_ids,received_at,source_data,status)
  values(s.account_id,s.user_id,s.folder,p_validity,(m->>'uid')::bigint,m->>'messageId',array(select jsonb_array_elements_text(coalesce(m->'references','[]'))),(m->>'receivedAt')::timestamptz,m,case when m->>'candidate'='false' then 'ignored' else 'pending' end)
  on conflict(account_id,folder,uidvalidity,uid) do nothing;
  n:=n+1;
 end loop;
 update public.mail_sync_settings set uidvalidity=p_validity,last_uid=p_last,lease_token=null,lease_until=null,last_success_at=now(),next_scan_at=now()+interval '5 minutes',backfill_since=null,failures=0,error_code=case when error_code like 'MAIL_%' then null else error_code end,updated_at=now() where account_id=p_account;
 return n;
end $$;

create or replace function public.mail_sync_apply(p_id uuid,p_token uuid,p_version integer,p_analysis jsonb,p_manual boolean default false) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare m public.mail_sync_messages; s public.mail_sync_settings; ev public.interviews; src public.interview_mail_sources;
 key text; legacy text; op text; before_data jsonb; after_data jsonb; ids uuid[]; reason text; oldtime timestamptz; target_version integer;
begin
 select * into m from public.mail_sync_messages where id=p_id for update;
 if m.id is null then raise exception 'MESSAGE_NOT_FOUND'; end if;
 if not p_manual and (m.lease_token is distinct from p_token or m.lease_until<now()) then raise exception 'SYNC_SUPERSEDED'; end if;
 if p_manual and m.status<>'review' then raise exception 'SUGGESTION_ALREADY_RESOLVED'; end if;
 select * into s from public.mail_sync_settings where account_id=m.account_id for update;
 if not p_manual and (not s.enabled or s.config_version<>p_version or not exists(select 1 from mail_sync_private.credentials where kind='ai' and owner_id=s.user_id and provider=s.provider)) then raise exception 'SYNC_SUPERSEDED'; end if;
 op:=p_analysis->>'action';
 if op in ('review','ignore') then
  update public.mail_sync_messages set status=case when op='review' then 'review' else 'ignored' end,analysis=p_analysis,reason=p_analysis->>'reason',lease_token=null,lease_until=null,updated_at=now() where id=m.id;
  return jsonb_build_object('status',case when op='review' then 'review' else 'ignored' end);
 end if;
 if op not in ('create','reschedule','cancel') then raise exception 'INVALID_ACTION'; end if;
 if coalesce(length(btrim(p_analysis->>'company_name')),0)=0 or (op<>'cancel' and coalesce(p_analysis->>'interview_time','')='') then raise exception 'INVALID_INTERVIEW'; end if;
 key:=p_analysis->>'event_key'; legacy:=p_analysis->>'legacy_marker';
 if key is null or length(key)>1200 then raise exception 'INVALID_EVENT_KEY'; end if;
 select * into src from public.interview_mail_sources where user_id=m.user_id and event_key=key for update;
 if src.id is null and legacy is not null then select * into src from public.interview_mail_sources where user_id=m.user_id and event_key='legacy:'||legacy for update; end if;
 if src.suppressed then
  update public.mail_sync_messages set status='suppressed',reason='DELETED_BY_USER',lease_token=null,lease_until=null where id=m.id;
  return jsonb_build_object('status','suppressed');
 end if;
 if src.interview_id is not null then select * into ev from public.interviews where id=src.interview_id and user_id=m.user_id for update; end if;
 if p_manual and p_analysis->>'target_id' is not null then
  select * into ev from public.interviews where id=(p_analysis->>'target_id')::uuid and user_id=m.user_id for update;
  if ev.id is null then raise exception 'TARGET_NOT_IDENTIFIED'; end if;
 end if;
 if ev.id is null then
  -- Exact provenance first, then a unique referenced message or explicit prior time.
  select array_agg(distinct i.id) into ids from public.interviews i where i.user_id=m.user_id and (
   (legacy is not null and position(legacy in coalesce(i.notes,''))>0)
   or i.id in (select interview_id from public.mail_sync_messages where user_id=m.user_id and message_id=any(m.references_ids) and interview_id is not null)
   or ((op in ('cancel','reschedule')) and p_analysis->>'prior_time' is not null and i.interview_time=(p_analysis->>'prior_time')::timestamptz and i.company_name=p_analysis->>'company_name'));
  if coalesce(array_length(ids,1),0)=1 then select * into ev from public.interviews where id=ids[1] and user_id=m.user_id for update;
  elsif coalesce(array_length(ids,1),0)>1 then reason:='MATCH_AMBIGUOUS'; end if;
 end if;
 if ev.id is not null and src.id is null then select * into src from public.interview_mail_sources where user_id=m.user_id and interview_id=ev.id order by last_received_at desc nulls last limit 1 for update; end if;
 if op in ('cancel','reschedule') and ev.id is null then reason:=coalesce(reason,'TARGET_NOT_IDENTIFIED'); end if;
 if ev.id is null and op='create' then
  select array_agg(i.id) into ids from public.interviews i where i.user_id=m.user_id and i.company_name=p_analysis->>'company_name'
  and coalesce(i.position_name,'')=coalesce(p_analysis->>'position_name','') and coalesce(i.round,'')=coalesce(p_analysis->>'round','') and i.interview_time=(p_analysis->>'interview_time')::timestamptz;
  if coalesce(array_length(ids,1),0)>0 then reason:='POSSIBLE_DUPLICATE'; end if;
 end if;
 if ev.id is not null then
  before_data:=to_jsonb(ev);
  if src.last_received_at>m.received_at and not p_manual then
   update public.mail_sync_messages set status='ignored',reason='OLDER_NOTIFICATION',analysis=p_analysis,interview_id=ev.id,lease_token=null,lease_until=null where id=m.id;
   return jsonb_build_object('status','ignored');
  end if;
  if src.sequence is not null and p_analysis->>'sequence' is not null and (p_analysis->>'sequence')::integer<src.sequence and not p_manual then
   update public.mail_sync_messages set status='ignored',reason='OLDER_NOTIFICATION',lease_token=null,lease_until=null where id=m.id;
   return jsonb_build_object('status','ignored');
  end if;
  if not p_manual and src.snapshot is not null and src.snapshot<>public.mail_sync_snapshot(before_data) then reason:='MANUAL_EDIT_CONFLICT'; end if;
  if op in ('reschedule','cancel') and src.id is null and not p_manual then reason:=coalesce(reason,'MANUAL_RECORD_REVIEW'); end if;
  target_version:=(m.analysis->>'target_version')::integer;
  if p_manual and target_version is not null and target_version<>ev.version then raise exception 'INTERVIEW_CHANGED'; end if;
 end if;
 if reason is not null and not p_manual then
  update public.mail_sync_messages set status='review',analysis=p_analysis||jsonb_build_object('target_id',ev.id,'target_version',ev.version,'current',before_data),reason=reason,interview_id=ev.id,lease_token=null,lease_until=null,updated_at=now() where id=m.id;
  return jsonb_build_object('status','review','reason',reason);
 end if;
 if ev.id is null then
  if op<>'create' then raise exception 'TARGET_NOT_IDENTIFIED'; end if;
  insert into public.interviews(id,user_id,company_name,position_name,interview_time,round,interview_type,notes,source,timezone,meeting_url,location,contact,end_time,application_id)
  values((p_analysis->>'stable_id')::uuid,m.user_id,p_analysis->>'company_name',nullif(p_analysis->>'position_name',''),(p_analysis->>'interview_time')::timestamptz,nullif(p_analysis->>'round',''),nullif(p_analysis->>'interview_type',''),coalesce(legacy,'')||E'\n来源邮件：'||(m.source_data->>'subject'),'email',s.timezone,p_analysis->>'meeting_url',p_analysis->>'location',p_analysis->>'contact',(p_analysis->>'end_time')::timestamptz,(p_analysis->>'application_id')::uuid)
  on conflict(id) do nothing returning * into ev;
  if ev.id is null then select * into ev from public.interviews where id=(p_analysis->>'stable_id')::uuid and user_id=m.user_id for update; if ev.id is null then raise exception 'ID_CONFLICT'; end if; end if;
 elsif op='cancel' then
  update public.interviews set status='cancelled' where id=ev.id and user_id=m.user_id returning * into ev;
 elsif op='reschedule' then
  update public.interviews set interview_time=(p_analysis->>'interview_time')::timestamptz,status='scheduled',meeting_url=coalesce(p_analysis->>'meeting_url',meeting_url),location=coalesce(p_analysis->>'location',location),end_time=(p_analysis->>'end_time')::timestamptz where id=ev.id and user_id=m.user_id returning * into ev;
 end if;
 after_data:=to_jsonb(ev);
 insert into public.interview_mail_sources(user_id,interview_id,event_key,snapshot,last_received_at,sequence)
 values(m.user_id,ev.id,key,public.mail_sync_snapshot(after_data),m.received_at,(p_analysis->>'sequence')::integer)
 on conflict(user_id,event_key) do update set interview_id=excluded.interview_id,snapshot=excluded.snapshot,last_received_at=excluded.last_received_at,sequence=excluded.sequence;
 -- Refresh all aliases of the same source so their snapshots cannot remain stale after a genuine reschedule.
 update public.interview_mail_sources set snapshot=public.mail_sync_snapshot(after_data),last_received_at=greatest(last_received_at,m.received_at) where user_id=m.user_id and interview_id=ev.id;
 update public.mail_sync_messages set status='done',analysis=p_analysis,interview_id=ev.id,reason=case when op='create' and before_data is not null then 'DUPLICATE' else null end,lease_token=null,lease_until=null,source_data=source_data-'body',updated_at=now() where id=m.id;
 insert into public.interview_change_log(user_id,interview_id,message_id,action,before_data,after_data) values(m.user_id,ev.id,m.id,op,before_data,after_data);
 return jsonb_build_object('status','done','interview_id',ev.id,'action',op);
end $$;


-- ===================== migrations/20261014105742_mail_interview_sync_transaction_fixes.sql =====================
-- Serialize event deduplication and protect manual records.
create or replace function public.mail_sync_apply(p_id uuid,p_token uuid,p_version integer,p_analysis jsonb,p_manual boolean default false) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare m public.mail_sync_messages; s public.mail_sync_settings; ev public.interviews; src public.interview_mail_sources;
 key text; legacy text; op text; before_data jsonb; after_data jsonb; ids uuid[]; review_reason text; oldtime timestamptz; target_version integer;
begin
 select * into m from public.mail_sync_messages where id=p_id for update;
 if m.id is null then raise exception 'MESSAGE_NOT_FOUND'; end if;
 if not p_manual and (m.lease_token is distinct from p_token or m.lease_until<now()) then raise exception 'SYNC_SUPERSEDED'; end if;
 if p_manual and m.status<>'review' then raise exception 'SUGGESTION_ALREADY_RESOLVED'; end if;
 select * into s from public.mail_sync_settings where account_id=m.account_id for update;
 if not p_manual and (not s.enabled or s.config_version<>p_version or not exists(select 1 from mail_sync_private.credentials where kind='ai' and owner_id=s.user_id and provider=s.provider)) then raise exception 'SYNC_SUPERSEDED'; end if;
 op:=p_analysis->>'action';
 if op in ('review','ignore') then
  update public.mail_sync_messages set status=case when op='review' then 'review' else 'ignored' end,analysis=p_analysis,reason=p_analysis->>'reason',lease_token=null,lease_until=null,updated_at=now() where id=m.id;
  return jsonb_build_object('status',case when op='review' then 'review' else 'ignored' end);
 end if;
 if op not in ('create','reschedule','cancel') then raise exception 'INVALID_ACTION'; end if;
 if coalesce(length(btrim(p_analysis->>'company_name')),0)=0 or (op<>'cancel' and coalesce(p_analysis->>'interview_time','')='') then raise exception 'INVALID_INTERVIEW'; end if;
 key:=p_analysis->>'event_key'; legacy:=p_analysis->>'legacy_marker';
 if key is null or length(key)>1200 then raise exception 'INVALID_EVENT_KEY'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(m.user_id::text||':'||key,0));
 select * into src from public.interview_mail_sources where user_id=m.user_id and event_key=key for update;
 if src.id is null and legacy is not null then select * into src from public.interview_mail_sources where user_id=m.user_id and event_key='legacy:'||legacy for update; end if;
 if src.suppressed then
  update public.mail_sync_messages set status='suppressed',reason='DELETED_BY_USER',lease_token=null,lease_until=null where id=m.id;
  return jsonb_build_object('status','suppressed');
 end if;
 if src.interview_id is not null then select * into ev from public.interviews where id=src.interview_id and user_id=m.user_id for update; end if;
 if p_manual and p_analysis->>'target_id' is not null then
  select * into ev from public.interviews where id=(p_analysis->>'target_id')::uuid and user_id=m.user_id for update;
  if ev.id is null then raise exception 'TARGET_NOT_IDENTIFIED'; end if;
 end if;
 if ev.id is null then
  -- Exact provenance first, then a unique referenced message or explicit prior time.
  select array_agg(distinct i.id) into ids from public.interviews i where i.user_id=m.user_id and (
   (legacy is not null and position(legacy in coalesce(i.notes,''))>0)
   or i.id in (select interview_id from public.mail_sync_messages where user_id=m.user_id and message_id=any(m.references_ids) and interview_id is not null)
   or ((op in ('cancel','reschedule')) and p_analysis->>'prior_time' is not null and i.interview_time=(p_analysis->>'prior_time')::timestamptz and i.company_name=p_analysis->>'company_name'));
  if coalesce(array_length(ids,1),0)=1 then select * into ev from public.interviews where id=ids[1] and user_id=m.user_id for update;
  elsif coalesce(array_length(ids,1),0)>1 then review_reason:='MATCH_AMBIGUOUS'; end if;
 end if;
 if ev.id is not null and src.id is null then select * into src from public.interview_mail_sources where user_id=m.user_id and interview_id=ev.id order by last_received_at desc nulls last limit 1 for update; end if;
 if op in ('cancel','reschedule') and ev.id is null then review_reason:=coalesce(review_reason,'TARGET_NOT_IDENTIFIED'); end if;
 if ev.id is null and op='create' then
  select array_agg(i.id) into ids from public.interviews i where i.user_id=m.user_id and i.company_name=p_analysis->>'company_name'
  and coalesce(i.position_name,'')=coalesce(p_analysis->>'position_name','') and coalesce(i.round,'')=coalesce(p_analysis->>'round','') and i.interview_time=(p_analysis->>'interview_time')::timestamptz;
  if coalesce(array_length(ids,1),0)>0 then review_reason:='POSSIBLE_DUPLICATE'; end if;
 end if;
 if ev.id is not null then
  before_data:=to_jsonb(ev);
  if src.last_received_at>m.received_at and not p_manual then
   update public.mail_sync_messages set status='ignored',reason='OLDER_NOTIFICATION',analysis=p_analysis,interview_id=ev.id,lease_token=null,lease_until=null where id=m.id;
   return jsonb_build_object('status','ignored');
  end if;
  if src.sequence is not null and p_analysis->>'sequence' is not null and (p_analysis->>'sequence')::integer<src.sequence and not p_manual then
   update public.mail_sync_messages set status='ignored',reason='OLDER_NOTIFICATION',lease_token=null,lease_until=null where id=m.id;
   return jsonb_build_object('status','ignored');
  end if;
  if not p_manual and src.snapshot is not null and src.snapshot<>public.mail_sync_snapshot(before_data) then review_reason:='MANUAL_EDIT_CONFLICT'; end if;
  if op in ('reschedule','cancel') and src.id is null and not p_manual then review_reason:=coalesce(review_reason,'MANUAL_RECORD_REVIEW'); end if;
  if op='create' and src.id is null and not p_manual and (ev.company_name is distinct from p_analysis->>'company_name' or ev.interview_time is distinct from (p_analysis->>'interview_time')::timestamptz) then review_reason:='MANUAL_EDIT_CONFLICT'; end if;
  target_version:=(m.analysis->>'target_version')::integer;
  if p_manual and target_version is not null and target_version<>ev.version then raise exception 'INTERVIEW_CHANGED'; end if;
 end if;
 if review_reason is not null and not p_manual then
  update public.mail_sync_messages set status='review',analysis=p_analysis||jsonb_build_object('target_id',ev.id,'target_version',ev.version,'current',before_data),reason=review_reason,interview_id=ev.id,lease_token=null,lease_until=null,updated_at=now() where id=m.id;
  return jsonb_build_object('status','review','reason',review_reason);
 end if;
 if ev.id is null then
  if op<>'create' then raise exception 'TARGET_NOT_IDENTIFIED'; end if;
  insert into public.interviews(id,user_id,company_name,position_name,interview_time,round,interview_type,notes,source,timezone,meeting_url,location,contact,end_time,application_id)
  values((p_analysis->>'stable_id')::uuid,m.user_id,p_analysis->>'company_name',nullif(p_analysis->>'position_name',''),(p_analysis->>'interview_time')::timestamptz,nullif(p_analysis->>'round',''),nullif(p_analysis->>'interview_type',''),coalesce(legacy,'')||E'\n来源邮件：'||(m.source_data->>'subject'),'email',s.timezone,p_analysis->>'meeting_url',p_analysis->>'location',p_analysis->>'contact',(p_analysis->>'end_time')::timestamptz,(p_analysis->>'application_id')::uuid)
  on conflict(id) do nothing returning * into ev;
  if ev.id is null then select * into ev from public.interviews where id=(p_analysis->>'stable_id')::uuid and user_id=m.user_id for update; if ev.id is null then raise exception 'ID_CONFLICT'; end if; end if;
 elsif op='cancel' then
  update public.interviews set status='cancelled' where id=ev.id and user_id=m.user_id returning * into ev;
 elsif op='reschedule' then
  update public.interviews set interview_time=(p_analysis->>'interview_time')::timestamptz,status='scheduled',meeting_url=coalesce(p_analysis->>'meeting_url',meeting_url),location=coalesce(p_analysis->>'location',location),end_time=(p_analysis->>'end_time')::timestamptz where id=ev.id and user_id=m.user_id returning * into ev;
 end if;
 after_data:=to_jsonb(ev);
 insert into public.interview_mail_sources(user_id,interview_id,event_key,snapshot,last_received_at,sequence)
 values(m.user_id,ev.id,key,public.mail_sync_snapshot(after_data),m.received_at,(p_analysis->>'sequence')::integer)
 on conflict(user_id,event_key) do update set interview_id=excluded.interview_id,snapshot=excluded.snapshot,last_received_at=excluded.last_received_at,sequence=excluded.sequence;
 -- Refresh all aliases of the same source so their snapshots cannot remain stale after a genuine reschedule.
 update public.interview_mail_sources set snapshot=public.mail_sync_snapshot(after_data),last_received_at=greatest(last_received_at,m.received_at) where user_id=m.user_id and interview_id=ev.id;
 update public.mail_sync_messages set status='done',analysis=p_analysis,interview_id=ev.id,reason=case when op='create' and before_data is not null then 'DUPLICATE' else null end,lease_token=null,lease_until=null,source_data=source_data-'body',updated_at=now() where id=m.id;
 insert into public.interview_change_log(user_id,interview_id,message_id,action,before_data,after_data) values(m.user_id,ev.id,m.id,op,before_data,after_data);
 return jsonb_build_object('status','done','interview_id',ev.id,'action',op);
end $$;


-- ===================== migrations/20261014111750_mail_interview_sync_thread_matching.sql =====================
-- A reply thread can contain different rounds; new invitations remain independent.
create or replace function public.mail_sync_apply(p_id uuid,p_token uuid,p_version integer,p_analysis jsonb,p_manual boolean default false) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare m public.mail_sync_messages; s public.mail_sync_settings; ev public.interviews; src public.interview_mail_sources;
 key text; legacy text; op text; before_data jsonb; after_data jsonb; ids uuid[]; review_reason text; oldtime timestamptz; target_version integer;
begin
 select * into m from public.mail_sync_messages where id=p_id for update;
 if m.id is null then raise exception 'MESSAGE_NOT_FOUND'; end if;
 if not p_manual and (m.lease_token is distinct from p_token or m.lease_until<now()) then raise exception 'SYNC_SUPERSEDED'; end if;
 if p_manual and m.status<>'review' then raise exception 'SUGGESTION_ALREADY_RESOLVED'; end if;
 select * into s from public.mail_sync_settings where account_id=m.account_id for update;
 if not p_manual and (not s.enabled or s.config_version<>p_version or not exists(select 1 from mail_sync_private.credentials where kind='ai' and owner_id=s.user_id and provider=s.provider)) then raise exception 'SYNC_SUPERSEDED'; end if;
 op:=p_analysis->>'action';
 if op in ('review','ignore') then
  update public.mail_sync_messages set status=case when op='review' then 'review' else 'ignored' end,analysis=p_analysis,reason=p_analysis->>'reason',lease_token=null,lease_until=null,updated_at=now() where id=m.id;
  return jsonb_build_object('status',case when op='review' then 'review' else 'ignored' end);
 end if;
 if op not in ('create','reschedule','cancel') then raise exception 'INVALID_ACTION'; end if;
 if coalesce(length(btrim(p_analysis->>'company_name')),0)=0 or (op<>'cancel' and coalesce(p_analysis->>'interview_time','')='') then raise exception 'INVALID_INTERVIEW'; end if;
 key:=p_analysis->>'event_key'; legacy:=p_analysis->>'legacy_marker';
 if key is null or length(key)>1200 then raise exception 'INVALID_EVENT_KEY'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(m.user_id::text||':'||key,0));
 select * into src from public.interview_mail_sources where user_id=m.user_id and event_key=key for update;
 if src.id is null and legacy is not null then select * into src from public.interview_mail_sources where user_id=m.user_id and event_key='legacy:'||legacy for update; end if;
 if exists(select 1 from public.mail_sync_messages old_message join public.interview_mail_sources old_source on old_source.user_id=old_message.user_id and old_source.event_key=old_message.analysis->>'event_key' where old_message.user_id=m.user_id and old_message.message_id=any(m.references_ids) and old_source.suppressed and (op in ('cancel','reschedule') or (old_source.snapshot->>'company_name'=p_analysis->>'company_name' and coalesce(old_source.snapshot->>'round','')=coalesce(p_analysis->>'round','')))) then
  update public.mail_sync_messages set status='suppressed',reason='DELETED_BY_USER',lease_token=null,lease_until=null where id=m.id;
  return jsonb_build_object('status','suppressed');
 end if;
 if src.suppressed then
  update public.mail_sync_messages set status='suppressed',reason='DELETED_BY_USER',lease_token=null,lease_until=null where id=m.id;
  return jsonb_build_object('status','suppressed');
 end if;
 if src.interview_id is not null then select * into ev from public.interviews where id=src.interview_id and user_id=m.user_id for update; end if;
 if p_manual and p_analysis->>'target_id' is not null then
  select * into ev from public.interviews where id=(p_analysis->>'target_id')::uuid and user_id=m.user_id for update;
  if ev.id is null then raise exception 'TARGET_NOT_IDENTIFIED'; end if;
 end if;
 if ev.id is null then
  -- Exact provenance first, then a unique referenced message or explicit prior time.
  select array_agg(distinct i.id) into ids from public.interviews i where i.user_id=m.user_id and (
   (legacy is not null and position(legacy in coalesce(i.notes,''))>0)
   or (op in ('reschedule','cancel') and i.company_name=p_analysis->>'company_name' and (p_analysis->>'position_name' is null or i.position_name=p_analysis->>'position_name') and (p_analysis->>'round' is null or i.round=p_analysis->>'round') and i.id in (select interview_id from public.mail_sync_messages where user_id=m.user_id and message_id=any(m.references_ids) and interview_id is not null))
   or ((op in ('cancel','reschedule')) and p_analysis->>'prior_time' is not null and i.interview_time=(p_analysis->>'prior_time')::timestamptz and i.company_name=p_analysis->>'company_name'));
  if coalesce(array_length(ids,1),0)=1 then select * into ev from public.interviews where id=ids[1] and user_id=m.user_id for update;
  elsif coalesce(array_length(ids,1),0)>1 then review_reason:='MATCH_AMBIGUOUS'; end if;
 end if;
 if ev.id is not null and src.id is null then select * into src from public.interview_mail_sources where user_id=m.user_id and interview_id=ev.id order by last_received_at desc nulls last limit 1 for update; end if;
 if op in ('cancel','reschedule') and ev.id is null then review_reason:=coalesce(review_reason,'TARGET_NOT_IDENTIFIED'); end if;
 if ev.id is null and op='create' then
  select array_agg(i.id) into ids from public.interviews i where i.user_id=m.user_id and i.company_name=p_analysis->>'company_name'
  and coalesce(i.position_name,'')=coalesce(p_analysis->>'position_name','') and coalesce(i.round,'')=coalesce(p_analysis->>'round','') and i.interview_time=(p_analysis->>'interview_time')::timestamptz;
  if coalesce(array_length(ids,1),0)>0 then review_reason:='POSSIBLE_DUPLICATE'; end if;
 end if;
 if ev.id is not null then
  before_data:=to_jsonb(ev);
  if src.last_received_at>m.received_at and not p_manual then
   update public.mail_sync_messages set status='ignored',reason='OLDER_NOTIFICATION',analysis=p_analysis,interview_id=ev.id,lease_token=null,lease_until=null where id=m.id;
   return jsonb_build_object('status','ignored');
  end if;
  if src.sequence is not null and p_analysis->>'sequence' is not null and (p_analysis->>'sequence')::integer<src.sequence and not p_manual then
   update public.mail_sync_messages set status='ignored',reason='OLDER_NOTIFICATION',lease_token=null,lease_until=null where id=m.id;
   return jsonb_build_object('status','ignored');
  end if;
  if not p_manual and src.snapshot is not null and src.snapshot<>public.mail_sync_snapshot(before_data) then review_reason:='MANUAL_EDIT_CONFLICT'; end if;
  if op in ('reschedule','cancel') and src.id is null and not p_manual then review_reason:=coalesce(review_reason,'MANUAL_RECORD_REVIEW'); end if;
  if op='create' and src.id is null and not p_manual and (ev.company_name is distinct from p_analysis->>'company_name' or ev.interview_time is distinct from (p_analysis->>'interview_time')::timestamptz) then review_reason:='MANUAL_EDIT_CONFLICT'; end if;
  target_version:=(p_analysis->>'target_version')::integer;
  if p_manual and target_version is not null and target_version<>ev.version then raise exception 'INTERVIEW_CHANGED'; end if;
 end if;
 if review_reason is not null and not p_manual then
  update public.mail_sync_messages set status='review',analysis=p_analysis||jsonb_build_object('target_id',ev.id,'target_version',ev.version,'current',before_data),reason=review_reason,interview_id=ev.id,lease_token=null,lease_until=null,updated_at=now() where id=m.id;
  return jsonb_build_object('status','review','reason',review_reason);
 end if;
 if ev.id is null then
  if op<>'create' then raise exception 'TARGET_NOT_IDENTIFIED'; end if;
  insert into public.interviews(id,user_id,company_name,position_name,interview_time,round,interview_type,notes,source,timezone,meeting_url,location,contact,end_time,application_id)
  values((p_analysis->>'stable_id')::uuid,m.user_id,p_analysis->>'company_name',nullif(p_analysis->>'position_name',''),(p_analysis->>'interview_time')::timestamptz,nullif(p_analysis->>'round',''),nullif(p_analysis->>'interview_type',''),coalesce(legacy,'')||E'\n来源邮件：'||(m.source_data->>'subject'),'email',s.timezone,p_analysis->>'meeting_url',p_analysis->>'location',p_analysis->>'contact',(p_analysis->>'end_time')::timestamptz,(p_analysis->>'application_id')::uuid)
  on conflict(id) do nothing returning * into ev;
  if ev.id is null then select * into ev from public.interviews where id=(p_analysis->>'stable_id')::uuid and user_id=m.user_id for update; if ev.id is null then raise exception 'ID_CONFLICT'; end if; end if;
 elsif op='cancel' then
  update public.interviews set status='cancelled' where id=ev.id and user_id=m.user_id returning * into ev;
 elsif op='reschedule' then
  update public.interviews set interview_time=(p_analysis->>'interview_time')::timestamptz,status='scheduled',meeting_url=coalesce(p_analysis->>'meeting_url',meeting_url),location=coalesce(p_analysis->>'location',location),end_time=(p_analysis->>'end_time')::timestamptz where id=ev.id and user_id=m.user_id returning * into ev;
 end if;
 after_data:=to_jsonb(ev);
 insert into public.interview_mail_sources(user_id,interview_id,event_key,snapshot,last_received_at,sequence)
 values(m.user_id,ev.id,key,public.mail_sync_snapshot(after_data),m.received_at,(p_analysis->>'sequence')::integer)
 on conflict(user_id,event_key) do update set interview_id=excluded.interview_id,snapshot=excluded.snapshot,last_received_at=excluded.last_received_at,sequence=excluded.sequence;
 -- Refresh all aliases of the same source so their snapshots cannot remain stale after a genuine reschedule.
 update public.interview_mail_sources set snapshot=public.mail_sync_snapshot(after_data),last_received_at=greatest(last_received_at,m.received_at) where user_id=m.user_id and interview_id=ev.id;
 update public.mail_sync_messages set status='done',analysis=p_analysis,interview_id=ev.id,reason=case when op='create' and before_data is not null then 'DUPLICATE' else null end,lease_token=null,lease_until=null,source_data=source_data-'body',updated_at=now() where id=m.id;
 insert into public.interview_change_log(user_id,interview_id,message_id,action,before_data,after_data) values(m.user_id,ev.id,m.id,op,before_data,after_data);
 return jsonb_build_object('status','done','interview_id',ev.id,'action',op);
end $$;


-- ===================== migrations/20261104083118_feishu_resource_sync.sql =====================
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
