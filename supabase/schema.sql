-- TraumaSim: Schema für spätere zentrale Übungssitzungen
-- Im Supabase SQL Editor ausführen, nachdem die Zugriffsfunktionen implementiert wurden.
-- Bis dahin KEINE öffentlichen Lese-/Schreib-Policies anlegen.
create extension if not exists pgcrypto;
create table if not exists public.traumasim_sessions (
 id uuid primary key default gen_random_uuid(),
 title text not null,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default (now() + interval '24 hours')
);
create table if not exists public.traumasim_patients (
 id uuid primary key default gen_random_uuid(),
 session_id uuid not null references public.traumasim_sessions(id) on delete cascade,
 patient_key text not null,
 started_at timestamptz,
 paused_at timestamptz,
 accumulated_pause_seconds numeric not null default 0,
 state jsonb not null default '{}'::jsonb,
 updated_at timestamptz not null default now(),
 unique(session_id, patient_key)
);
alter table public.traumasim_sessions enable row level security;
alter table public.traumasim_patients enable row level security;
revoke all on public.traumasim_sessions from anon, authenticated;
revoke all on public.traumasim_patients from anon, authenticated;
-- WICHTIG: Ohne gesicherte RPC-/Edge-Funktionen ist dieses Schema bewusst
-- nicht aus dem Browser zugänglich. Keine service_role-Schlüssel im Frontend.
