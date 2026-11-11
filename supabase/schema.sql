-- Apply as the project database owner. Safe to rerun over the preparation schema.
begin;

create schema if not exists traumasim_private;
revoke all on schema traumasim_private from public, anon, authenticated;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
-- Resolve pgcrypto whether it was installed by Supabase or the preparation script.
set local search_path = pg_catalog, extensions, public;

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
alter table public.traumasim_sessions
 add column if not exists trainer_id uuid references auth.users(id) on delete cascade,
 add column if not exists case_key text not null default 'vu-baum',
 add column if not exists signing_key uuid not null default gen_random_uuid(),
 add column if not exists triage_mode text not null default 'automatic' check (triage_mode in ('automatic', 'choose'));
alter table public.traumasim_patients
 add column if not exists revision integer not null default 0,
 add column if not exists scenario_model jsonb;
create index if not exists traumasim_sessions_trainer on public.traumasim_sessions (trainer_id, created_at desc);

alter table public.traumasim_sessions enable row level security;
alter table public.traumasim_patients enable row level security;
revoke all on public.traumasim_sessions, public.traumasim_patients from public, anon, authenticated;

create table if not exists traumasim_private.trainers (
 email text primary key check (email = lower(btrim(email)))
);
create table if not exists traumasim_private.models (
 case_key text not null,
 patient_key text not null,
 model jsonb not null,
 primary key (case_key, patient_key)
);
create table if not exists traumasim_private.bus_templates (
 capacity integer primary key check (capacity in (5, 10)),
 title text not null,
 briefing text not null,
 patients jsonb not null
);
create table if not exists traumasim_private.exercise_templates (
 id uuid primary key default gen_random_uuid(),
 trainer_id uuid not null references auth.users(id) on delete cascade,
 title text not null,
 case_key text not null,
 patients jsonb not null,
 created_at timestamptz not null default now(),
 unique (trainer_id, title)
);
alter table traumasim_private.exercise_templates
 add column if not exists triage_mode text not null default 'automatic' check (triage_mode in ('automatic', 'choose'));
alter table traumasim_private.exercise_templates enable row level security;
alter table traumasim_private.bus_templates enable row level security;
alter table traumasim_private.trainers enable row level security;
alter table traumasim_private.models enable row level security;
revoke all on all tables in schema traumasim_private from public, anon, authenticated;

insert into traumasim_private.models values ('vu-baum', 'fahrer', $model${"nibpFastCycle":true,"secret":"Verdacht auf Becken- und Oberschenkelverletzung mit innerer Blutung.","points":[{"t":0,"s":125,"d":80,"h":95,"r":20,"o":98,"g":15},{"t":5,"s":120,"d":75,"h":105,"r":23,"o":97,"g":15},{"t":10,"s":105,"d":65,"h":118,"r":26,"o":97,"g":15},{"t":15,"s":90,"d":55,"h":130,"r":29,"o":96,"g":14},{"t":20,"s":75,"d":45,"h":145,"r":32,"o":95,"g":12},{"t":25,"s":65,"d":40,"h":152,"r":34,"o":93,"g":9}],"condition":["Wach, orientiert, starke Schmerzen im Bein.","Blass, unruhig, Schwindel und Durst.","Kaltschweißig, schwacher Radialispuls, zunehmend verwirrt.","Bewusstseinsgetrübt, kaum adäquate Antworten."]}$model$)
on conflict (case_key, patient_key) do update set model = excluded.model;
insert into traumasim_private.models values ('vu-baum', 'beifahrer', $model${"secret":"Übungsannahme: Thoraxprellung ohne initiale vitale Bedrohung; weiterer Verlauf zunächst stabil.","points":[{"t":0,"s":130,"d":80,"h":90,"r":22,"o":97,"g":15},{"t":5,"s":130,"d":80,"h":92,"r":22,"o":97,"g":15},{"t":10,"s":128,"d":78,"h":94,"r":23,"o":97,"g":15},{"t":15,"s":128,"d":78,"h":96,"r":23,"o":97,"g":15},{"t":20,"s":125,"d":75,"h":98,"r":24,"o":96,"g":15},{"t":25,"s":125,"d":75,"h":98,"r":24,"o":96,"g":15}],"condition":["Wach, orientiert, Schmerzen beim tiefen Einatmen.","Weiterhin ansprechbar, atmet etwas schneller.","Weiterhin ansprechbar, Schmerzen im Brustkorb.","Weiterhin wach und orientiert."]}$model$)
on conflict (case_key, patient_key) do update set model = excluded.model;

-- Qualify pgcrypto with the actual extension schema and pin every function's search path.
do $install$
declare
 crypto_schema text;
begin
 select n.nspname into strict crypto_schema
 from pg_catalog.pg_extension e
 join pg_catalog.pg_namespace n on n.oid = e.extnamespace
 where e.extname = 'pgcrypto';

 execute format($fn$
  create or replace function traumasim_private.patient_code(p_session uuid, p_patient text, p_signing_key uuid)
  returns text language sql immutable strict set search_path = '' as $body$
    select p_session::text || '.' || encode(%I.hmac(p_patient, p_signing_key::text, 'sha256'), 'hex');
  $body$;
 $fn$, crypto_schema);
end
$install$;

-- Keep exercise credentials distinct from individual patient credentials.
create or replace function traumasim_private.exercise_code(p_session uuid, p_case text, p_signing_key uuid)
returns text language sql immutable strict set search_path = '' as $$
 select p_session::text || '.j' || split_part(
   traumasim_private.patient_code(p_session, 'exercise:' || p_case, p_signing_key), '.', 2
 );
$$;

create or replace function traumasim_private.preview_code(p_session uuid, p_patient text, p_signing_key uuid)
returns text language sql immutable strict set search_path = '' as $$
 select p_session::text || '.p' || split_part(
   traumasim_private.patient_code(p_session, 'preview:' || p_patient, p_signing_key), '.', 2
 );
$$;

create or replace function traumasim_private.join_exercise(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 exercise public.traumasim_sessions%rowtype;
begin
 if p_code is null or p_code !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.j[0-9a-f]{64}$' then
   raise exception using errcode = '42501', message = 'Übungszugang ungültig oder abgelaufen';
 end if;

 select s.* into exercise from public.traumasim_sessions s
 where s.id = split_part(p_code, '.', 1)::uuid and s.trainer_id is not null
   and s.expires_at > clock_timestamp();
 if not found or sha256(convert_to(traumasim_private.exercise_code(exercise.id, exercise.case_key, exercise.signing_key), 'UTF8'))
       <> sha256(convert_to(p_code, 'UTF8')) then
   raise exception using errcode = '42501', message = 'Übungszugang ungültig oder abgelaufen';
 end if;

 return jsonb_build_object('case', exercise.case_key, 'expires_at', exercise.expires_at);
end;
$$;

create or replace function traumasim_private.elapsed(
 p_started timestamptz, p_paused timestamptz, p_pause_seconds numeric, p_now timestamptz
) returns numeric language sql immutable set search_path = '' as $$
 select case when p_started is null then 0
   else greatest(0, extract(epoch from (coalesce(p_paused, p_now) - p_started)) - p_pause_seconds) end;
$$;

create or replace function traumasim_private.patient_duration(p_model jsonb)
returns integer language sql immutable set search_path = '' as $$
 select case when p_model->'progression'->>'to' = 'black'
   then (p_model->'progression'->>'at_seconds')::integer else 2700 end;
$$;

create or replace function traumasim_private.vitals(p_model jsonb, p_elapsed numeric)
returns jsonb language sql immutable strict set search_path = '' as $$
 -- The second curve point marks the selected transition for scripted profiles.
 with transition as (
   select (p_model->'progression'->>'at_seconds')::numeric as at_seconds
 ), curve as (
   select case when at_seconds is null then least(p_elapsed, 1500)
     when p_elapsed <= at_seconds then p_elapsed * 300 / at_seconds
     else least(1500, 300 + (p_elapsed - at_seconds) * 1200
       / (traumasim_private.patient_duration(null) - at_seconds)) end as seconds
   from transition
 ), frame as (
   select seconds, least(4, floor(seconds / 300)::integer) as i from curve
 )
 select jsonb_object_agg(k, round(a + (b - a) * (seconds / 300 - i) + case
   when phase is null then 0
   when k = 'h' then (1.4 * sin(2 * pi() * phase / 31) + 0.6 * sin(2 * pi() * phase / 67))::numeric
   when k = 'r' then (1.15 * sin(2 * pi() * phase / 33))::numeric
   else 0 end))
 from frame
 -- Use the shared exercise clock and a fixed offset per car occupant.
 cross join lateral (select p_elapsed
   + (p_model->>'car_number')::integer * 13
   + (p_model->>'car_patient_number')::integer * 7 as phase) movement
 cross join unnest(array['s','d','h','r','o','g']) as fields(k)
 cross join lateral (
   select (p_model->'points'->i->>k)::numeric as a,
          (p_model->'points'->(i + 1)->>k)::numeric as b
 ) as points;
$$;

create or replace function traumasim_private.patient_category(
 p_model jsonb, p_patient text, p_custom boolean, p_elapsed numeric, p_vitals jsonb
) returns text language sql immutable set search_path = '' as $$
 select case
   when p_model->'affected' = 'true'::jsonb then 'affected'
   when p_model->'progression'->>'from' is not null then case
     when p_elapsed >= (p_model->'progression'->>'at_seconds')::integer then p_model->'progression'->>'to'
     else p_model->'progression'->>'from' end
   when (p_patient = 'fahrer' or p_custom)
     and ((p_vitals->>'s')::integer < 100 or (p_vitals->>'g')::integer < 15 or (p_vitals->>'h')::integer >= 120)
     then 'red'
   when p_model->'walkable' = 'true'::jsonb then 'green'
   else 'yellow' end;
$$;

create or replace function traumasim_private.student_snapshot(
 p_case text, p_patient text, p_code text, p_start_revision integer, p_selection text, p_seen_revision integer
) returns jsonb language plpgsql set search_path = '' as $$
declare
 exercise public.traumasim_sessions%rowtype;
 patient public.traumasim_patients%rowtype;
 model jsonb;
 snapshot_time timestamptz;
 seconds numeric;
 duration integer;
 progression jsonb;
 vitals jsonb;
 bp_interval integer;
 bp_time integer;
 bp_values jsonb;
 previous_bp_values jsonb;
 bp_wall_time timestamptz;
 previous_bp_wall_time timestamptz;
 next_bp_wall_time timestamptz;
 next_bp_time integer;
 tracked_pause_seconds numeric;
 bp_pause_seconds numeric;
 previous_bp_pause_seconds numeric;
 affected boolean;
 category text;
 triage_delay integer;
 condition_index integer;
 observation text;
 can_select boolean;
 exercise_access boolean := split_part(p_code, '.', 2) like 'j%';
 preview_access boolean := split_part(p_code, '.', 2) like 'p%';
begin
 if p_code is null or p_code !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[jp]?[0-9a-f]{64}$' then
   raise exception using errcode = '42501', message = 'Patientenzugang ungültig oder abgelaufen';
 end if;

 select s.* into exercise
 from public.traumasim_sessions s
 where s.id = split_part(p_code, '.', 1)::uuid and s.case_key = p_case
   and s.trainer_id is not null
   and s.expires_at > clock_timestamp();
 if not found or p_patient is null
   or sha256(convert_to(case
        when exercise_access then traumasim_private.exercise_code(exercise.id, exercise.case_key, exercise.signing_key)
        when preview_access then traumasim_private.preview_code(exercise.id, p_patient, exercise.signing_key)
        else traumasim_private.patient_code(exercise.id, p_patient, exercise.signing_key) end, 'UTF8'))
        <> sha256(convert_to(p_code, 'UTF8')) then
   raise exception using errcode = '42501', message = 'Patientenzugang ungültig oder abgelaufen';
 end if;
 if exercise_access and p_patient like 'car-%' then
   raise exception using errcode = 'P0002', message = 'Für diesen Patienten ist der einzelne Stations-QR erforderlich.';
 end if;

 if p_start_revision is not null and not preview_access then
   -- Serialize starts with whole-exercise resets and instructor commands.
   select s.* into exercise from public.traumasim_sessions s
   where s.id = exercise.id and s.expires_at > clock_timestamp() for update;
   if not found then
     raise exception using errcode = '42501', message = 'Patientenzugang ungültig oder abgelaufen';
   end if;
   update public.traumasim_patients
   set started_at = clock_timestamp(), updated_at = clock_timestamp()
   where session_id = exercise.id and patient_key = p_patient
     and revision = p_start_revision and started_at is null;
 end if;

 select p.* into patient from public.traumasim_patients p
 where p.session_id = exercise.id and p.patient_key = p_patient;
 if not found then
   if exercise_access then
     raise exception using errcode = 'P0002', message = 'Diese Station gehört nicht zu deiner Übung.';
   end if;
   raise exception using errcode = '42501', message = 'Patientenzugang ungültig oder abgelaufen';
 end if;
 model := patient.scenario_model;
 if model is null then
   select m.model into model from traumasim_private.models m
   where m.case_key = p_case and m.patient_key = p_patient;
 end if;
 if model is null then
   raise exception using errcode = '42501', message = 'Patientenzugang ungültig oder abgelaufen';
 end if;

 snapshot_time := clock_timestamp();
 duration := traumasim_private.patient_duration(model);
 progression := model->'progression';
 seconds := least(duration, traumasim_private.elapsed(patient.started_at, patient.paused_at, patient.accumulated_pause_seconds, snapshot_time));
 vitals := traumasim_private.vitals(model, seconds);
 bp_interval := case when model->'nibpFastCycle' = 'true'::jsonb then 180 else 300 end;
 if seconds >= 70 then
   -- Hold the result from the last completed cuff cycle until the next one completes.
   bp_time := 70 + floor((seconds - 70) / bp_interval)::integer * bp_interval;
   bp_values := traumasim_private.vitals(model, bp_time);
   if bp_time > 70 then
     previous_bp_values := traumasim_private.vitals(model, bp_time - bp_interval);
   end if;
   -- Only pauses before a completed measurement shift its wall-clock timestamp.
   select coalesce(sum(p.duration), 0),
          coalesce(sum(p.duration) filter (where p.at < bp_time), 0),
          coalesce(sum(p.duration) filter (where p.at < bp_time - bp_interval), 0)
   into tracked_pause_seconds, bp_pause_seconds, previous_bp_pause_seconds
   from jsonb_to_recordset(coalesce(patient.state->'monitor_pauses', '[]'::jsonb)) as p(at numeric, duration numeric);
   -- Older exercises may contain pauses without a recorded position.
   if tracked_pause_seconds = patient.accumulated_pause_seconds then
     bp_wall_time := patient.started_at + make_interval(secs => (bp_time + bp_pause_seconds)::double precision);
     if previous_bp_values is not null then
       previous_bp_wall_time := patient.started_at + make_interval(
         secs => (bp_time - bp_interval + previous_bp_pause_seconds)::double precision);
     end if;
   end if;
 end if;
 next_bp_time := coalesce(bp_time + bp_interval, 70);
 if patient.paused_at is null and next_bp_time <= duration
    and (progression->>'to' is distinct from 'black' or next_bp_time < duration) then
   next_bp_wall_time := patient.started_at + make_interval(
     secs => (next_bp_time + patient.accumulated_pause_seconds)::double precision);
   if next_bp_wall_time >= exercise.expires_at then
     next_bp_wall_time := null;
   end if;
 end if;
 category := traumasim_private.patient_category(model, p_patient, patient.scenario_model is not null, seconds, vitals);
 affected := category = 'affected';
 -- Training timings follow the category available at the current patient time.
 triage_delay := case category when 'affected' then 10 when 'green' then 10 when 'yellow' then 20 else 35 end;
 condition_index := case
   when p_patient = 'beifahrer' then least(3, floor(seconds / 420)::integer)
   when (vitals->>'g')::integer <= 12 then 3
   when (vitals->>'s')::integer < 100 then 2
   when (vitals->>'h')::integer >= 110 then 1
   else 0 end;
 observation := case
   when category = 'black' then 'Die Person reagiert im Übungsmodell nicht mehr.'
   when progression->>'from' = 'green' then case category
     when 'green' then 'Wach und orientiert. Schmerzen am Unterschenkel, kann noch selbst gehen.'
     else 'Der Unterschenkel schwillt an. Die Schmerzen nehmen zu, Auftreten ist nicht mehr möglich.' end
   when progression->>'to' = 'red' and category = 'red' then 'Die Person wird blass und benommen. Der Kreislauf verschlechtert sich.'
   else model->'condition'->>condition_index end;
 -- The choice becomes available at the same time for every category.
 can_select := exercise.triage_mode = 'choose' and seconds >= 10;
 return jsonb_build_object(
   'exercise_id', exercise.id,
   'revision', patient.revision,
   'status', case when patient.started_at is null then 'ready'
     when seconds >= duration then 'finished' when patient.paused_at is not null then 'paused' else 'running' end,
   'elapsed', floor(seconds),
   'server_time', snapshot_time,
   'triage_mode', exercise.triage_mode,
   'triage_selectable', can_select,
   'observation', case when can_select then observation end,
   'triage', case when (exercise.triage_mode = 'automatic' and seconds >= triage_delay)
     or (can_select and p_seen_revision = patient.revision and p_selection in ('red', 'yellow', 'green', 'affected', 'black'))
     then jsonb_build_object(
     'category', category, 'red', category = 'red',
     'condition', observation,
     'reason', case when category = 'black' then 'Im Übungsmodell verstorben'
       when affected then 'Unverletzt, aufgewühlt und betreuungsbedürftig'
       when category = 'red' then coalesce(model->>'triageReason', 'Didaktische Einstufung: Zeichen eines kritischen Schocks')
       when category = 'green' then 'Gehfähig; Nachsichtung vorgesehen'
       when patient.scenario_model is not null then 'Schwer verletzt, ohne erkennbare vitale Bedrohung (Übungsmodell)'
       when p_patient = 'beifahrer' then 'Schwer verletzt, zunächst ohne erkennbare vitale Bedrohung'
       else 'Schwere Verletzung, Kreislauf zunächst kompensiert' end
   ) end,
   'monitor', case when not affected and category <> 'black' and seconds >= 25 then jsonb_strip_nulls(jsonb_build_object(
     'h', vitals->'h',
     'o', vitals->'o',
     'r', case when seconds >= 40 then vitals->'r' end,
     'g', case when seconds >= 45 then vitals->'g' end,
     's', bp_values->'s',
     'd', bp_values->'d',
     'bp_at', bp_time,
     'bp_wall_at', bp_wall_time,
     'bp_next_wall_at', next_bp_wall_time,
     'bp_previous', case when previous_bp_values is not null then jsonb_build_object(
       's', previous_bp_values->'s', 'd', previous_bp_values->'d', 'at', bp_time - bp_interval,
       'wall_at', previous_bp_wall_time
     ) end,
     'ecg', case when seconds >= 90 then true end
   )) end,
   -- Preserve the complete snapshot for previously loaded student pages.
   'vitals', case when not affected and category <> 'black' and seconds >= 120 then vitals || jsonb_build_object('s', bp_values->'s', 'd', bp_values->'d') end
 ) || case when patient.scenario_model is not null then jsonb_build_object('brief', jsonb_build_object(
   'title', exercise.title, 'name', model->>'name', 'intro', model->>'intro',
   'story', case when category = 'black' then 'Die Person gibt im Übungsmodell keine Antwort mehr.' else model->>'story' end,
   'questions', case when category <> 'black' then model->>'questions' end
 )) else '{}'::jsonb end;
end;
$$;

create or replace function traumasim_private.student(
 p_case text, p_patient text, p_code text, p_start_revision integer default null
) returns jsonb language sql security definer set search_path = '' as $$
 select traumasim_private.student_snapshot(p_case, p_patient, p_code, p_start_revision, null, null);
$$;

create or replace function traumasim_private.student_assess(
 p_case text, p_patient text, p_code text, p_selection text, p_seen_revision integer
) returns jsonb language sql security definer set search_path = '' as $$
 select traumasim_private.student_snapshot(p_case, p_patient, p_code, null, p_selection, p_seen_revision);
$$;

create or replace function traumasim_private.require_trainer()
returns uuid language plpgsql stable set search_path = '' as $$
declare
 trainer uuid := auth.uid();
begin
 if not exists (
   select 1 from auth.users u
   join traumasim_private.trainers t on t.email = lower(u.email)
   where u.id = trainer and u.email_confirmed_at is not null
 ) then
   raise exception using errcode = '42501', message = 'Konto nicht für die Ausbilderansicht freigegeben';
 end if;
 return trainer;
end;
$$;

create or replace function traumasim_private.trainer(
 p_action text default 'list', p_session uuid default null, p_patient text default null, p_title text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 trainer uuid := traumasim_private.require_trainer();
 exercise public.traumasim_sessions%rowtype;
 template traumasim_private.exercise_templates%rowtype;
 template_patients jsonb;
 new_session_id uuid;
 snapshot_time timestamptz;
 result jsonb;
begin


 if p_action = 'list' then
   select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'expires_at', s.expires_at)
     order by s.created_at desc), '[]'::jsonb) into result
   from public.traumasim_sessions s
   where s.trainer_id = trainer and s.expires_at > clock_timestamp();
   return result;
 end if;

 if p_action = 'list_templates' then
   select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title)
     order by t.created_at desc), '[]'::jsonb) into result
   from traumasim_private.exercise_templates t where t.trainer_id = trainer;
   return result;
 end if;

 if (p_action in ('create', 'save_template') or (p_action = 'start_template' and p_title is not null))
    and (p_title is null or length(btrim(p_title)) not between 1 and 120) then
   raise exception using errcode = '22023', message = 'Der Titel muss 1 bis 120 Zeichen enthalten.';
 end if;

 if p_action = 'start_template' then
   select t.* into template from traumasim_private.exercise_templates t
   where t.id = p_session and t.trainer_id = trainer;
   if not found then
     raise exception using errcode = '42501', message = 'Vorlage nicht verfügbar.';
   end if;
   new_session_id := gen_random_uuid();
   insert into public.traumasim_sessions (id, title, trainer_id, case_key, triage_mode)
   values (new_session_id, coalesce(btrim(p_title), template.title), trainer, case when template.case_key like 'custom-%'
     then 'custom-' || new_session_id::text else template.case_key end, template.triage_mode)
   returning * into exercise;
   insert into public.traumasim_patients (session_id, patient_key, scenario_model)
   select exercise.id, p.patient_key, p.scenario_model
   from jsonb_to_recordset(template.patients) as p(patient_key text, scenario_model jsonb);
 elsif p_action = 'create' then
   insert into public.traumasim_sessions (title, trainer_id)
   values (btrim(p_title), trainer) returning * into exercise;
   insert into public.traumasim_patients (session_id, patient_key)
   select exercise.id, m.patient_key from traumasim_private.models m where m.case_key = exercise.case_key;
 else
   select s.* into exercise
   from public.traumasim_sessions s
   where s.id = p_session and s.trainer_id = trainer and s.expires_at > clock_timestamp()
   for update;
   if not found or exercise.expires_at <= clock_timestamp() then
     raise exception using errcode = '42501', message = 'Übung nicht verfügbar oder abgelaufen';
   end if;

   if p_action in ('reset', 'pause', 'resume') and not exists (
     select 1 from public.traumasim_patients p where p.session_id = exercise.id and p.patient_key = p_patient
   ) then
     raise exception using errcode = '22023', message = 'Patient gehört nicht zu dieser Übung';
   end if;
   snapshot_time := clock_timestamp();
   case p_action
     when 'status' then null;
     when 'set_triage_mode' then
       if p_title is null or p_title not in ('automatic', 'choose') then
         raise exception using errcode = '22023', message = 'Ungültige Einstellung für die Sichtung.';
       end if;
       update public.traumasim_sessions s set triage_mode = p_title where s.id = exercise.id
       returning s.* into exercise;
     when 'save_template', 'update_template' then
       select jsonb_agg(jsonb_build_object('patient_key', p.patient_key, 'scenario_model', p.scenario_model)
         order by p.patient_key)
       into template_patients
       from public.traumasim_patients p where p.session_id = exercise.id;
       if template_patients is null then
         raise exception using errcode = '22023', message = 'Für die Vorlage wird mindestens ein Patient benötigt.';
       end if;
       if p_action = 'save_template' then
         insert into traumasim_private.exercise_templates (trainer_id, title, case_key, patients, triage_mode)
         values (trainer, btrim(p_title), exercise.case_key, template_patients, exercise.triage_mode)
         on conflict (trainer_id, title) do nothing
         returning * into template;
         if not found then
           raise exception using errcode = '22023', message = 'Eine Vorlage mit diesem Namen ist bereits vorhanden.';
         end if;
       else
         if p_patient is null or p_patient !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
           raise exception using errcode = '22023', message = 'Wähle eine gültige Vorlage aus.';
         end if;
         update traumasim_private.exercise_templates t
         set case_key = exercise.case_key, patients = template_patients, triage_mode = exercise.triage_mode
         where t.id = p_patient::uuid and t.trainer_id = trainer
         returning * into template;
         if not found then
           raise exception using errcode = '42501', message = 'Vorlage nicht verfügbar.';
         end if;
       end if;
       return jsonb_build_object('id', template.id, 'title', template.title);
     when 'close' then
       update public.traumasim_sessions set expires_at = snapshot_time where id = exercise.id;
       return jsonb_build_object('id', exercise.id, 'closed', true);
     when 'reset', 'reset_all' then
       update public.traumasim_patients
       set started_at = null, paused_at = null, accumulated_pause_seconds = 0,
           state = '{}'::jsonb, updated_at = snapshot_time, revision = revision + 1
       where session_id = exercise.id and (p_action = 'reset_all' or patient_key = p_patient);
     when 'pause' then
       update public.traumasim_patients
       set paused_at = snapshot_time, updated_at = snapshot_time
       where session_id = exercise.id and patient_key = p_patient
         and started_at is not null and paused_at is null
         and traumasim_private.elapsed(started_at, paused_at, accumulated_pause_seconds, snapshot_time)
           < traumasim_private.patient_duration(scenario_model);
     when 'resume' then
       update public.traumasim_patients
       set accumulated_pause_seconds = accumulated_pause_seconds + extract(epoch from (snapshot_time - paused_at)),
           state = jsonb_set(state, '{monitor_pauses}', coalesce(state->'monitor_pauses', '[]'::jsonb)
             || jsonb_build_array(jsonb_build_object(
               'at', extract(epoch from (paused_at - started_at)) - accumulated_pause_seconds,
               'duration', extract(epoch from (snapshot_time - paused_at))
             ))),
           paused_at = null, updated_at = snapshot_time
       where session_id = exercise.id and patient_key = p_patient and paused_at is not null;
     else raise exception using errcode = '22023', message = 'Unbekannte Übungsaktion';
   end case;
 end if;

 snapshot_time := clock_timestamp();
 select jsonb_agg(jsonb_build_object(
   'id', p.patient_key,
   'code', traumasim_private.patient_code(exercise.id, p.patient_key, exercise.signing_key),
   'preview_code', traumasim_private.preview_code(exercise.id, p.patient_key, exercise.signing_key),
   'model', patient_model.model,
   'custom', p.scenario_model is not null,
   'elapsed', floor(t.seconds),
   'category', case when p.started_at is not null then traumasim_private.patient_category(
     patient_model.model, p.patient_key, p.scenario_model is not null, t.seconds,
     traumasim_private.vitals(patient_model.model, t.seconds)) end,
   'status', case when p.started_at is null then 'ready'
     when t.seconds >= limit_time.duration then 'finished' when p.paused_at is not null then 'paused' else 'running' end
 ) order by p.patient_key) into result
 from public.traumasim_patients p
 left join traumasim_private.models m on m.case_key = exercise.case_key and m.patient_key = p.patient_key
 cross join lateral (select coalesce(p.scenario_model, m.model) as model) patient_model
 cross join lateral (select traumasim_private.patient_duration(p.scenario_model) as duration) limit_time
 cross join lateral (select least(limit_time.duration,
   traumasim_private.elapsed(p.started_at, p.paused_at, p.accumulated_pause_seconds, snapshot_time)) as seconds) t
 where p.session_id = exercise.id;
 return jsonb_build_object('id', exercise.id, 'title', exercise.title, 'case', exercise.case_key,
   'expires_at', exercise.expires_at, 'patients', result, 'triage_mode', exercise.triage_mode,
   'join_code', traumasim_private.exercise_code(exercise.id, exercise.case_key, exercise.signing_key));
end;
$$;

create or replace function traumasim_private.create_custom(p_scenario jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 trainer uuid := traumasim_private.require_trainer();
 exercise_id uuid := gen_random_uuid();
 title text := btrim(p_scenario->>'title');
 models jsonb := p_scenario->'patients';
 model jsonb;
 points jsonb;
 point jsonb;
 field text;
 point_index integer;
 patient_index integer := 0;
begin
 if jsonb_typeof(p_scenario) is distinct from 'object' or octet_length(p_scenario::text) > 200000
    or jsonb_typeof(p_scenario->'title') is distinct from 'string'
    or length(title) not between 1 and 120 or jsonb_typeof(models) is distinct from 'array' then
   raise exception using errcode = '22023', message = 'Der Szenarioentwurf ist ungültig.';
 end if;
 if jsonb_array_length(models) not between 1 and 30 then
   raise exception using errcode = '22023', message = 'Eine Übung benötigt 1 bis 30 Patienten.';
 end if;

 insert into public.traumasim_sessions (id, title, case_key, trainer_id)
 values (exercise_id, title, 'custom-' || exercise_id::text, trainer);
 for model in select value from jsonb_array_elements(models) loop
   patient_index := patient_index + 1;
   points := model->'points';
   if jsonb_typeof(model->'name') is distinct from 'string' or length(btrim(model->>'name')) not between 1 and 100
      or jsonb_typeof(points) is distinct from 'array' then
     raise exception using errcode = '22023', message = 'Jeder Patient benötigt einen Namen und Vitalwerte.';
   end if;
   if jsonb_array_length(points) <> 6 then
     raise exception using errcode = '22023', message = 'Die Vitalwerte benötigen sechs Zeitpunkte von Minute 0 bis 25.';
   end if;
   foreach field in array array['intro', 'story', 'questions', 'secret', 'triageReason'] loop
     if model ? field and (jsonb_typeof(model->field) <> 'string' or length(model->>field) > 2000) then
       raise exception using errcode = '22023', message = 'Patiententexte dürfen bis zu 2000 Zeichen enthalten.';
     end if;
   end loop;
   if model ? 'condition' then
     if jsonb_typeof(model->'condition') <> 'array' then
       raise exception using errcode = '22023', message = 'Der Zustand benötigt vier kurze Verlaufstexte.';
     end if;
     if jsonb_array_length(model->'condition') <> 4 or exists (
       select 1 from jsonb_array_elements(model->'condition') as stage(value)
       where jsonb_typeof(stage.value) <> 'string' or length(stage.value #>> '{}') > 2000
     ) then
       raise exception using errcode = '22023', message = 'Der Zustand benötigt vier kurze Verlaufstexte.';
     end if;
   end if;
   for point_index in 0..5 loop
     point := points->point_index;
     if point->'t' is distinct from to_jsonb(point_index * 5) then
       raise exception using errcode = '22023', message = 'Vitalwerte bitte für die Minuten 0, 5, 10, 15, 20 und 25 angeben.';
     end if;
     foreach field in array array['s','d','h','r','o','g'] loop
       if jsonb_typeof(point->field) is distinct from 'number'
          or (point->>field)::numeric not between 0 and 350 then
         raise exception using errcode = '22023', message = 'Ein Vitalwert fehlt oder liegt außerhalb des Eingabebereichs.';
       end if;
     end loop;
     if (point->>'o')::numeric > 100 or (point->>'g')::numeric not between 3 and 15 then
       raise exception using errcode = '22023', message = 'SpO₂ muss zwischen 0 und 100, GCS zwischen 3 und 15 liegen.';
     end if;
   end loop;
   insert into public.traumasim_patients (session_id, patient_key, scenario_model)
   values (exercise_id, 'patient-' || lpad(patient_index::text, 2, '0'), jsonb_build_object(
     'name', btrim(model->>'name'), 'intro', coalesce(model->>'intro', ''),
     'story', coalesce(model->>'story', ''), 'questions', coalesce(model->>'questions', ''),
     'secret', coalesce(model->>'secret', ''), 'walkable', model->'walkable' = 'true'::jsonb,
     'points', points, 'condition', model->'condition', 'triageReason', model->>'triageReason',
     'affected', coalesce(model->'affected' = 'true'::jsonb, false),
     'nibpFastCycle', coalesce(model->'nibpFastCycle' = 'true'::jsonb, false)
   ));
 end loop;
 return traumasim_private.trainer('status', exercise_id);
end;
$$;

create or replace function traumasim_private.book_bus(p_capacity integer, p_session uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 trainer uuid := traumasim_private.require_trainer();
 template traumasim_private.bus_templates%rowtype;
 exercise public.traumasim_sessions%rowtype;
 patient_prefix text := 'bus-' || p_capacity::text || '-';
begin
 select * into template from traumasim_private.bus_templates where capacity = p_capacity;
 if not found then
   raise exception using errcode = '22023', message = 'Wähle einen Bus mit 5 oder 10 Personen.';
 end if;

 if p_session is null then
   exercise.id := gen_random_uuid();
   insert into public.traumasim_sessions (id, title, case_key, trainer_id)
   values (exercise.id, template.title, 'custom-' || exercise.id::text, trainer);
 else
   select s.* into exercise from public.traumasim_sessions s
   where s.id = p_session and s.trainer_id = trainer and s.expires_at > clock_timestamp() for update;
   if not found then
     raise exception using errcode = '42501', message = 'Übung nicht verfügbar oder abgelaufen';
   end if;
   if exists (select 1 from public.traumasim_patients p
     where p.session_id = exercise.id and p.patient_key like patient_prefix || '%') then
     raise exception using errcode = '22023', message = 'Diese Busvariante ist bereits gebucht.';
   end if;
   if (select count(*) from public.traumasim_patients p where p.session_id = exercise.id) + p_capacity > 30 then
     raise exception using errcode = '22023', message = 'Eine Übung unterstützt insgesamt bis zu 30 Patienten.';
   end if;
 end if;

 insert into public.traumasim_patients (session_id, patient_key, scenario_model)
 select exercise.id, patient_prefix || lpad(passenger.position::text, 2, '0'),
   passenger.model || jsonb_build_object(
     'name', 'Bus ' || p_capacity::text || ' · ' || (passenger.model->>'name'),
     'bus_briefing', template.briefing)
 from jsonb_array_elements(template.patients) with ordinality as passenger(model, position);
 return traumasim_private.trainer('status', exercise.id);
end;
$$;

create or replace function traumasim_private.book_car(p_config jsonb, p_session uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 trainer uuid := traumasim_private.require_trainer();
 exercise public.traumasim_sessions%rowtype;
 seats text[] := array['driver','front','rear-left','rear-center','rear-right'];
 seat_names text[] := array['Fahrerplatz','Beifahrerplatz','hinten links','hinten Mitte','hinten rechts'];
 occupants jsonb := p_config->'occupants';
 vehicle text := coalesce(nullif(btrim(p_config->>'vehicle'), ''), 'Fahrzeuglage vor Ort erkunden.');
 person jsonb;
 car_no integer;
 person_no bigint;
 last_person_no bigint := 0;
 last_booked_person_no bigint;
 car_label text;
 person_label text;
 seat_name text;
 profile text;
 transition_minute integer;
 progression jsonb;
 entrapment text;
 injury text;
 points jsonb;
 edit_car boolean := coalesce(p_config ? 'car_number', false);
 edit_version integer;
 existing_count integer := 0;
 has_started boolean;
 retain_person boolean;
 patient_model jsonb;
begin
 if jsonb_typeof(p_config) is distinct from 'object'
    or octet_length(p_config::text) > 12000
    or length(vehicle) > 200
    or jsonb_typeof(occupants) is distinct from 'array' then
   raise exception using errcode = '22023', message = 'Die Pkw-Konfiguration ist ungültig.';
 end if;
 if jsonb_array_length(occupants) not between 1 and 5 then
   raise exception using errcode = '22023', message = 'Wähle mindestens einen und höchstens fünf besetzte Sitzplätze.';
 end if;
 if (select count(distinct item->>'seat') from jsonb_array_elements(occupants) item) <> jsonb_array_length(occupants) then
   raise exception using errcode = '22023', message = 'Jeder Sitzplatz darf nur einmal besetzt sein.';
 end if;
 if edit_car and (p_session is null or coalesce(p_config->>'car_number', '') !~ '^[1-9][0-9]?$'
    or coalesce(p_config->>'edit_version', '') !~ '^[0-9]{1,9}$') then
   raise exception using errcode = '22023', message = 'Die Pkw-Auswahl ist ungültig.';
 end if;

 if p_session is null then
   exercise.id := gen_random_uuid();
   insert into public.traumasim_sessions (id, title, case_key, trainer_id)
   values (exercise.id, 'Pkw-Lage', 'custom-' || exercise.id::text, trainer);
 else
   select s.* into exercise from public.traumasim_sessions s
   where s.id = p_session and s.trainer_id = trainer and s.expires_at > clock_timestamp() for update;
   if not found then
     raise exception using errcode = '42501', message = 'Übung nicht verfügbar oder abgelaufen';
   end if;
 end if;

 if edit_car then
   car_no := (p_config->>'car_number')::integer;
   select count(*), bool_or(p.started_at is not null),
          max(coalesce((p.scenario_model->>'car_edit_version')::integer, 0)),
          max(greatest((p.scenario_model->>'car_patient_number')::bigint,
                       (p.scenario_model->>'car_patient_sequence')::bigint))
   into existing_count, has_started, edit_version, last_person_no
   from public.traumasim_patients p
   where p.session_id = exercise.id and p.patient_key like 'car-%'
     and (p.scenario_model->>'car_number')::integer = car_no;
   if existing_count = 0 then
     raise exception using errcode = '22023', message = 'Der Pkw wurde in dieser Übung nicht gefunden.';
   end if;
   if has_started then
     raise exception using errcode = '22023', message = 'Setze die gestarteten Patienten dieses Pkw zuerst zurück.';
   end if;
   if edit_version <> (p_config->>'edit_version')::integer then
     raise exception using errcode = '40001', message = 'Der Pkw wurde zwischenzeitlich bearbeitet. Öffne die Bearbeitung erneut.';
   end if;
   if (select count(item->>'patient_number') <> count(distinct item->>'patient_number')
       from jsonb_array_elements(occupants) item) then
     raise exception using errcode = '22023', message = 'Jeder vorhandene Insasse darf nur einmal ausgewählt werden.';
   end if;
   -- Keep the highest assigned number on every remaining occupant so deleted QR links stay invalid.
   select last_person_no + count(*) into last_booked_person_no
   from jsonb_array_elements(occupants) item where item->>'patient_number' is null;
   edit_version := edit_version + 1;
 else
   edit_version := 0;
   last_booked_person_no := jsonb_array_length(occupants);
   select coalesce(max((p.scenario_model->>'car_number')::integer), 0) + 1 into car_no
   from public.traumasim_patients p where p.session_id = exercise.id and p.patient_key like 'car-%';
 end if;
 if (select count(*) from public.traumasim_patients p where p.session_id = exercise.id)
    - existing_count + jsonb_array_length(occupants) > 30 then
   raise exception using errcode = '22023', message = 'Eine Übung unterstützt insgesamt bis zu 30 Patienten.';
 end if;
 car_label := lpad(car_no::text, 2, '0');

 if edit_car then
   delete from public.traumasim_patients p
   where p.session_id = exercise.id and p.patient_key like 'car-%'
     and (p.scenario_model->>'car_number')::integer = car_no
     and not exists (select 1 from jsonb_array_elements(occupants) item
                     where item->>'patient_number' = p.scenario_model->>'car_patient_number');
 end if;

 for person in select value from jsonb_array_elements(occupants)
   order by array_position(seats, value->>'seat') loop
   seat_name := seat_names[array_position(seats, person->>'seat')];
   profile := person->>'profile';
   entrapment := case person->>'entrapment'
     when 'none' then 'frei zugänglich, keine Einklemmung'
     when 'enclosed' then 'eingeschlossen, Ausstieg versperrt'
     when 'door' then 'im Bereich von Tür und B-Säule eingeklemmt'
     when 'footwell' then 'mit einem Bein im deformierten Fußraum eingeklemmt'
     when 'dashboard' then 'zwischen Sitz und Armaturenbrett eingeklemmt'
     when 'roof' then 'im Bereich von Dach und Sitz eingeklemmt'
   end;
   if seat_name is null or profile is null or profile not in ('affected','minor','urgent','critical','green-yellow','urgent-red','red-ex')
      or entrapment is null or length(coalesce(person->>'injury', '')) > 400 then
     raise exception using errcode = '22023', message = 'Sitzplatz, Verletzungsprofil oder Befreiungslage sind ungültig.';
   end if;
   progression := null;
   if profile in ('green-yellow','urgent-red','red-ex') then
     if coalesce(person->>'transition_minute', '') !~ '^([1-9]|[1-3][0-9]|4[0-4])$' then
       raise exception using errcode = '22023', message = 'Der Wechsel muss zwischen Minute 1 und 44 liegen.';
     end if;
     transition_minute := (person->>'transition_minute')::integer;
     progression := jsonb_build_object('at_seconds', transition_minute * 60,
       'from', case profile when 'green-yellow' then 'green' when 'urgent-red' then 'yellow' else 'red' end,
       'to', case profile when 'green-yellow' then 'yellow' when 'urgent-red' then 'red' else 'black' end);
   end if;
   injury := coalesce(nullif(btrim(person->>'injury'), ''), case profile
     when 'affected' then 'Keine Verletzung in dieser Übungsrolle. Die Person ist aufgewühlt.'
     when 'minor' then 'Die Person ist orientiert und klagt über eine schmerzhafte Prellung.'
     when 'urgent' then 'Die Person klagt über starke Schmerzen an einer Extremität. Verdacht auf eine Fraktur.'
     when 'urgent-red' then 'Die Person ist zunächst orientiert und klagt über Schmerzen nach einem Anprall.'
     when 'green-yellow' then 'Beim Aufprall ist mein Unterschenkel gegen den Sitz vor mir gestoßen. Ein paar Schritte gingen noch, aber es tut weh.'
     else 'Die Person ist blass, antwortet verzögert und wirkt zunehmend benommen.'
   end);

   if progression is not null then
     select jsonb_agg(jsonb_build_object('t', minute, 's', systolic, 'd', diastolic,
       'h', pulse, 'r', breaths, 'o', saturation, 'g', gcs) order by minute)
     into points from (values
       ('green-yellow', 0, 123, 78, 84, 17, 99, 15),
       ('green-yellow', 5, 127, 80, 100, 21, 99, 15),
       ('green-yellow', 10, 128, 80, 104, 22, 99, 15),
       ('green-yellow', 15, 130, 82, 107, 23, 98, 15),
       ('green-yellow', 20, 130, 82, 109, 23, 98, 15),
       ('green-yellow', 25, 130, 82, 110, 24, 98, 15),
       ('urgent-red', 0, 128, 78, 88, 18, 99, 15),
       ('urgent-red', 5, 100, 65, 120, 26, 97, 15),
       ('urgent-red', 10, 89, 55, 128, 30, 95, 14),
       ('urgent-red', 15, 81, 51, 136, 32, 94, 13),
       ('urgent-red', 20, 75, 46, 141, 33, 93, 12),
       ('urgent-red', 25, 68, 42, 146, 34, 92, 11),
       ('red-ex', 0, 92, 59, 126, 28, 95, 13),
       ('red-ex', 5, 55, 34, 142, 10, 84, 5),
       ('red-ex', 10, 55, 34, 142, 10, 84, 5),
       ('red-ex', 15, 55, 34, 142, 10, 84, 5),
       ('red-ex', 20, 55, 34, 142, 10, 84, 5),
       ('red-ex', 25, 55, 34, 142, 10, 84, 5)
     ) as sample(template, minute, systolic, diastolic, pulse, breaths, saturation, gcs)
     where template = profile;
   elsif profile = 'critical' then
     select jsonb_agg(point || jsonb_build_object('g', least((point->>'g')::integer, 13)) order by ordinal)
     into points
     from traumasim_private.models m
     cross join lateral jsonb_array_elements(m.model->'points') with ordinality as sample(point, ordinal)
     where m.case_key = 'vu-baum' and m.patient_key = 'fahrer';
   else
     select jsonb_agg(jsonb_build_object('t', minute, 's', 125, 'd', 80,
       'h', case when profile = 'urgent' then 103 else 86 end,
       'r', case when profile = 'urgent' then 22 else 17 end,
       'o', 98, 'g', 15) order by minute)
     into points from generate_series(0, 25, 5) minute;
   end if;

   retain_person := edit_car and person->>'patient_number' is not null;
   if retain_person then
     if person->>'patient_number' !~ '^[1-9][0-9]{0,9}$' then
       raise exception using errcode = '22023', message = 'Die Patientennummer ist ungültig.';
     end if;
     person_no := (person->>'patient_number')::bigint;
   else
     last_person_no := last_person_no + 1;
     person_no := last_person_no;
   end if;
   person_label := lpad(person_no::text, greatest(2, length(person_no::text)), '0');
   patient_model := jsonb_build_object(
     'name', format('Pkw %s · Patient %s · %s', car_label, person_label, seat_name),
     'intro', format('%s. Sitzplatz %s, %s.', rtrim(vehicle, '.'), seat_name, entrapment),
     'story', injury,
     'questions', '',
     'secret', format('Pkw %s · %s · %s. %s', car_label, seat_name, entrapment, injury),
     'car_number', car_no, 'car_patient_number', person_no, 'car_patient_sequence', last_booked_person_no,
     'car_vehicle', nullif(btrim(p_config->>'vehicle'), ''),
     'car_seat', person->>'seat', 'car_profile', profile, 'car_entrapment', person->>'entrapment',
     'car_injury', nullif(btrim(person->>'injury'), ''), 'car_edit_version', edit_version,
     'affected', profile = 'affected', 'walkable', profile in ('affected','minor'),
     'nibpFastCycle', profile in ('critical','urgent-red','red-ex'),
     'progression', progression, 'points', points
   );
   if retain_person then
     update public.traumasim_patients p
     set scenario_model = patient_model, updated_at = clock_timestamp()
     where p.session_id = exercise.id and p.patient_key = 'car-' || car_label || '-' || person_label
       and (p.scenario_model->>'car_number')::integer = car_no;
     if not found then
       raise exception using errcode = '22023', message = 'Ein Insasse wurde in diesem Pkw nicht gefunden.';
     end if;
   else
     insert into public.traumasim_patients (session_id, patient_key, scenario_model)
     values (exercise.id, 'car-' || car_label || '-' || person_label, patient_model);
   end if;
 end loop;
 return traumasim_private.trainer('status', exercise.id);
end;
$$;

-- Keep the privileged implementations out of PostgREST's exposed schema.
create or replace function public.traumasim_join(p_code text)
returns jsonb language sql security invoker set search_path = '' as $$
 select traumasim_private.join_exercise(p_code);
$$;

create or replace function public.traumasim_student(
 p_case text, p_patient text, p_code text, p_start_revision integer default null
) returns jsonb language sql security invoker set search_path = '' as $$
 select traumasim_private.student(p_case, p_patient, p_code, p_start_revision);
$$;

create or replace function public.traumasim_student_assess(
 p_case text, p_patient text, p_code text, p_selection text, p_seen_revision integer
) returns jsonb language sql security invoker set search_path = '' as $$
 select traumasim_private.student_assess(p_case, p_patient, p_code, p_selection, p_seen_revision);
$$;

create or replace function public.traumasim_trainer(
 p_action text default 'list', p_session uuid default null, p_patient text default null, p_title text default null
) returns jsonb language sql security invoker set search_path = '' as $$
 select traumasim_private.trainer(p_action, p_session, p_patient, p_title);
$$;

create or replace function public.traumasim_create_custom(p_scenario jsonb)
returns jsonb language sql security invoker set search_path = '' as $$
 select traumasim_private.create_custom(p_scenario);
$$;

create or replace function public.traumasim_book_bus(p_capacity integer, p_session uuid default null)
returns jsonb language sql security invoker set search_path = '' as $$
 select traumasim_private.book_bus(p_capacity, p_session);
$$;

create or replace function public.traumasim_book_car(p_config jsonb, p_session uuid default null)
returns jsonb language sql security invoker set search_path = '' as $$
 select traumasim_private.book_car(p_config, p_session);
$$;

revoke all on all functions in schema traumasim_private from public, anon, authenticated;
revoke all on function public.traumasim_book_car(jsonb, uuid) from public, anon, authenticated;
revoke all on function public.traumasim_book_bus(integer, uuid) from public, anon, authenticated;
revoke all on function public.traumasim_create_custom(jsonb) from public, anon, authenticated;
revoke all on function public.traumasim_join(text) from public, anon, authenticated;
revoke all on function public.traumasim_student(text, text, text, integer) from public, anon, authenticated;
revoke all on function public.traumasim_student_assess(text, text, text, text, integer) from public, anon, authenticated;
revoke all on function public.traumasim_trainer(text, uuid, text, text) from public, anon, authenticated;
grant usage on schema traumasim_private to anon, authenticated;
grant execute on function traumasim_private.join_exercise(text) to anon, authenticated;
grant execute on function public.traumasim_join(text) to anon, authenticated;
grant execute on function traumasim_private.student(text, text, text, integer) to anon, authenticated;
grant execute on function traumasim_private.trainer(text, uuid, text, text) to authenticated;
grant execute on function public.traumasim_student(text, text, text, integer) to anon, authenticated;
grant execute on function traumasim_private.student_assess(text, text, text, text, integer),
 public.traumasim_student_assess(text, text, text, text, integer) to anon, authenticated;
grant execute on function traumasim_private.create_custom(jsonb) to authenticated;
grant execute on function traumasim_private.book_bus(integer, uuid), public.traumasim_book_bus(integer, uuid) to authenticated;
grant execute on function traumasim_private.book_car(jsonb, uuid), public.traumasim_book_car(jsonb, uuid) to authenticated;
grant execute on function public.traumasim_create_custom(jsonb) to authenticated;
grant execute on function public.traumasim_trainer(text, uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
commit;
