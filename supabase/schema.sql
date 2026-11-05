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
 add column if not exists signing_key uuid not null default gen_random_uuid();
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

 return jsonb_build_object('case', exercise.case_key, 'title', exercise.title, 'expires_at', exercise.expires_at)
   || case when exists (
      select 1 from public.traumasim_patients p where p.session_id = exercise.id and p.scenario_model is not null
   ) then jsonb_build_object('patients', (
      select jsonb_agg(jsonb_build_object('id', p.patient_key, 'name', p.scenario_model->>'name') order by p.patient_key)
      from public.traumasim_patients p where p.session_id = exercise.id
   )) else '{}'::jsonb end;
end;
$$;

create or replace function traumasim_private.elapsed(
 p_started timestamptz, p_paused timestamptz, p_pause_seconds numeric, p_now timestamptz
) returns numeric language sql immutable set search_path = '' as $$
 select case when p_started is null then 0
   else greatest(0, least(1500, extract(epoch from (coalesce(p_paused, p_now) - p_started)) - p_pause_seconds)) end;
$$;

create or replace function traumasim_private.vitals(p_model jsonb, p_elapsed numeric)
returns jsonb language sql immutable strict set search_path = '' as $$
 with frame as (
   select least(4, floor(p_elapsed / 300)::integer) as i
 )
 select jsonb_object_agg(k, round(a + (b - a) * (p_elapsed / 300 - i)))
 from frame
 cross join unnest(array['s','d','h','r','o','g']) as fields(k)
 cross join lateral (
   select (p_model->'points'->i->>k)::numeric as a,
          (p_model->'points'->(i + 1)->>k)::numeric as b
 ) as points;
$$;

create or replace function traumasim_private.student(
 p_case text, p_patient text, p_code text, p_start_revision integer default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 exercise public.traumasim_sessions%rowtype;
 patient public.traumasim_patients%rowtype;
 model jsonb;
 snapshot_time timestamptz;
 seconds numeric;
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
 red boolean;
 category text;
 triage_delay integer;
 condition_index integer;
begin
 if p_code is null or p_code !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.j?[0-9a-f]{64}$' then
   raise exception using errcode = '42501', message = 'Patientenzugang ungültig oder abgelaufen';
 end if;

 select s.* into exercise
 from public.traumasim_sessions s
 where s.id = split_part(p_code, '.', 1)::uuid and s.case_key = p_case
   and s.trainer_id is not null
   and s.expires_at > clock_timestamp();
 if not found or p_patient is null
   or sha256(convert_to(case when strpos(p_code, '.j') = 37
        then traumasim_private.exercise_code(exercise.id, exercise.case_key, exercise.signing_key)
        else traumasim_private.patient_code(exercise.id, p_patient, exercise.signing_key) end, 'UTF8'))
        <> sha256(convert_to(p_code, 'UTF8')) then
   raise exception using errcode = '42501', message = 'Patientenzugang ungültig oder abgelaufen';
 end if;

 select coalesce(p.scenario_model, m.model) into model
 from public.traumasim_patients p
 left join traumasim_private.models m on m.case_key = p_case and m.patient_key = p.patient_key
 where p.session_id = exercise.id and p.patient_key = p_patient;
 if model is null then
   raise exception using errcode = '42501', message = 'Patientenzugang ungültig oder abgelaufen';
 end if;

 if p_start_revision is not null then
   -- Serialize starts with whole-exercise resets and instructor commands.
   perform 1 from public.traumasim_sessions s
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
   raise exception using errcode = '42501', message = 'Patientenzugang ungültig oder abgelaufen';
 end if;

 snapshot_time := clock_timestamp();
 seconds := traumasim_private.elapsed(patient.started_at, patient.paused_at, patient.accumulated_pause_seconds, snapshot_time);
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
 if patient.paused_at is null and next_bp_time <= 1500 then
   next_bp_wall_time := patient.started_at + make_interval(
     secs => (next_bp_time + patient.accumulated_pause_seconds)::double precision);
   if next_bp_wall_time >= exercise.expires_at then
     next_bp_wall_time := null;
   end if;
 end if;
 red := (p_patient = 'fahrer' or patient.scenario_model is not null) and ((vitals->>'s')::integer < 100 or (vitals->>'g')::integer < 15 or (vitals->>'h')::integer >= 120);
 category := case
   when red then 'red'
   when model->'walkable' = 'true'::jsonb then 'green'
   else 'yellow' end;
 -- Training timings follow the category available at the current patient time.
 triage_delay := case category when 'green' then 10 when 'yellow' then 20 else 35 end;
 condition_index := case
   when p_patient = 'beifahrer' then least(3, floor(seconds / 420)::integer)
   when (vitals->>'g')::integer <= 12 then 3
   when (vitals->>'s')::integer < 100 then 2
   when (vitals->>'h')::integer >= 110 then 1
   else 0 end;
 return jsonb_build_object(
   'revision', patient.revision,
   'status', case when patient.started_at is null then 'ready'
     when seconds >= 1500 then 'finished' when patient.paused_at is not null then 'paused' else 'running' end,
   'elapsed', floor(seconds),
   'server_time', snapshot_time,
   'triage', case when seconds >= triage_delay then jsonb_build_object(
     'category', category, 'red', red, 'condition', model->'condition'->>condition_index,
     'reason', case when red then coalesce(model->>'triageReason', 'Didaktische Einstufung: Zeichen eines kritischen Schocks')
       when category = 'green' then 'Gehfähig; Nachsichtung vorgesehen'
       when patient.scenario_model is not null then 'Schwer verletzt, ohne erkennbare vitale Bedrohung (Übungsmodell)'
       when p_patient = 'beifahrer' then 'Schwer verletzt, zunächst ohne erkennbare vitale Bedrohung'
       else 'Schwere Verletzung, Kreislauf zunächst kompensiert' end
   ) end,
   'monitor', case when seconds >= 25 then jsonb_strip_nulls(jsonb_build_object(
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
   'vitals', case when seconds >= 120 then vitals || jsonb_build_object('s', bp_values->'s', 'd', bp_values->'d') end
 ) || case when patient.scenario_model is not null then jsonb_build_object('brief', jsonb_build_object(
   'title', exercise.title, 'name', model->>'name', 'intro', model->>'intro',
   'story', model->>'story', 'questions', model->>'questions'
 )) else '{}'::jsonb end;
end;
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

 if p_action = 'create' then
   if p_title is null or length(btrim(p_title)) not between 1 and 120 then
     raise exception using errcode = '22023', message = 'Übungstitel muss 1 bis 120 Zeichen enthalten';
   end if;
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
         and traumasim_private.elapsed(started_at, paused_at, accumulated_pause_seconds, snapshot_time) < 1500;
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
   'model', coalesce(p.scenario_model, m.model),
   'custom', p.scenario_model is not null,
   'elapsed', floor(t.seconds),
   'status', case when p.started_at is null then 'ready'
     when t.seconds >= 1500 then 'finished' when p.paused_at is not null then 'paused' else 'running' end
 ) order by p.patient_key) into result
 from public.traumasim_patients p
 left join traumasim_private.models m on m.case_key = exercise.case_key and m.patient_key = p.patient_key
 cross join lateral (select traumasim_private.elapsed(p.started_at, p.paused_at, p.accumulated_pause_seconds, snapshot_time) as seconds) t
 where p.session_id = exercise.id;
 return jsonb_build_object('id', exercise.id, 'title', exercise.title, 'case', exercise.case_key,
   'expires_at', exercise.expires_at, 'patients', result,
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

revoke all on all functions in schema traumasim_private from public, anon, authenticated;
revoke all on function public.traumasim_book_bus(integer, uuid) from public, anon, authenticated;
revoke all on function public.traumasim_create_custom(jsonb) from public, anon, authenticated;
revoke all on function public.traumasim_join(text) from public, anon, authenticated;
revoke all on function public.traumasim_student(text, text, text, integer) from public, anon, authenticated;
revoke all on function public.traumasim_trainer(text, uuid, text, text) from public, anon, authenticated;
grant usage on schema traumasim_private to anon, authenticated;
grant execute on function traumasim_private.join_exercise(text) to anon, authenticated;
grant execute on function public.traumasim_join(text) to anon, authenticated;
grant execute on function traumasim_private.student(text, text, text, integer) to anon, authenticated;
grant execute on function traumasim_private.trainer(text, uuid, text, text) to authenticated;
grant execute on function public.traumasim_student(text, text, text, integer) to anon, authenticated;
grant execute on function traumasim_private.create_custom(jsonb) to authenticated;
grant execute on function traumasim_private.book_bus(integer, uuid), public.traumasim_book_bus(integer, uuid) to authenticated;
grant execute on function public.traumasim_create_custom(jsonb) to authenticated;
grant execute on function public.traumasim_trainer(text, uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
commit;
