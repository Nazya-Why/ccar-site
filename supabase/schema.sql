-- CCar — схема бази Supabase.
-- Запустіть цей файл цілком у Supabase → SQL Editor → New query → Run.
-- Повторний запуск безпечний.

-- ---------------------------------------------------------------
-- Заявки: запис на мийку, B2B-заявки, «передзвоніть мені»
-- ---------------------------------------------------------------
create table if not exists public.leads (
  id          bigint generated always as identity primary key,
  code        text unique,
  type        text not null check (type in ('booking', 'b2b', 'callback')),
  status      text not null default 'new' check (status in ('new', 'confirmed', 'done', 'cancelled')),
  name        text,
  phone       text not null,
  address     text,
  starts_at   timestamptz,
  ends_at     timestamptz,
  total       integer,
  duration    integer,
  data        jsonb not null default '{}'::jsonb,
  admin_note  text,
  created_at  timestamptz not null default now(),
  -- Один екіпаж: два активні записи не можуть перетинатися в часі
  constraint leads_no_overlap exclude using gist ((tstzrange(starts_at, ends_at)) with &&)
    where (type = 'booking' and status <> 'cancelled' and starts_at is not null)
);
create index if not exists leads_created_idx on public.leads (created_at desc);

-- Хто має доступ до адмінки
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

-- ---------------------------------------------------------------
-- Доступ: відвідувачі сайту НЕ читають і НЕ пишуть таблиці напряму,
-- лише через дві функції нижче. Адміни бачать і змінюють заявки.
-- ---------------------------------------------------------------
alter table public.leads  enable row level security;
alter table public.admins enable row level security;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

drop policy if exists "admins read leads"   on public.leads;
drop policy if exists "admins update leads" on public.leads;
drop policy if exists "admins see self"     on public.admins;
create policy "admins read leads"   on public.leads  for select to authenticated using (public.is_admin());
create policy "admins update leads" on public.leads  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins see self"     on public.admins for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------
-- Нова заявка з сайту. Повертає номер виду CC-00042.
-- Якщо час уже зайнятий — помилка 23P01 (API віддає HTTP 409).
-- ---------------------------------------------------------------
create or replace function public.create_lead(p jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_type   text := p ->> 'type';
  v_phone  text := left(trim(coalesce(p ->> 'phone', '')), 32);
  v_start  timestamptz;
  v_dur    integer;
  v_id     bigint;
  v_code   text;
begin
  if length(p::text) > 20000 then raise exception 'payload too large'; end if;
  if v_type not in ('booking', 'b2b', 'callback') then raise exception 'bad type'; end if;
  if length(regexp_replace(v_phone, '\D', '', 'g')) < 10 then raise exception 'bad phone'; end if;

  if v_type = 'booking' then
    v_start := ((p ->> 'date')::date + (p ->> 'time')::time) at time zone 'Europe/Kyiv';
    v_dur   := greatest(15, least(720, coalesce((p ->> 'duration')::integer, 60)));
    if v_start < now() or v_start > now() + interval '15 days' then raise exception 'bad date'; end if;
  end if;

  insert into public.leads (type, name, phone, address, starts_at, ends_at, total, duration, data)
  values (
    v_type,
    left(p ->> 'name', 120),
    v_phone,
    left(p ->> 'address', 300),
    v_start,
    v_start + make_interval(mins => v_dur),
    (p ->> 'total')::integer,
    v_dur,
    p - 'phone' - 'name' - 'address'
  )
  returning id into v_id;

  v_code := 'CC-' || lpad(v_id::text, 5, '0');
  update public.leads set code = v_code where id = v_id;
  return v_code;
end;
$$;

-- ---------------------------------------------------------------
-- Зайняті проміжки на день (хвилини від 00:00 за Києвом).
-- Жодних імен і телефонів — лише час.
-- ---------------------------------------------------------------
create or replace function public.busy_slots(d date)
returns table (start_min integer, end_min integer)
language sql stable security definer set search_path = public as $$
  select
    greatest(0,    (extract(epoch from (starts_at at time zone 'Europe/Kyiv') - d::timestamp) / 60)::integer),
    least(1440,    (extract(epoch from (ends_at   at time zone 'Europe/Kyiv') - d::timestamp) / 60)::integer)
  from public.leads
  where type = 'booking' and status <> 'cancelled' and starts_at is not null
    and tstzrange(starts_at, ends_at) && tstzrange((d::timestamp at time zone 'Europe/Kyiv'), ((d + 1)::timestamp at time zone 'Europe/Kyiv'));
$$;

revoke all on function public.create_lead(jsonb) from public;
revoke all on function public.busy_slots(date)   from public;
grant execute on function public.create_lead(jsonb) to anon, authenticated;
grant execute on function public.busy_slots(date)   to anon, authenticated;
grant execute on function public.is_admin()         to authenticated;
