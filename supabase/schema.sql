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
 add column if not exists triage_mode text not null default 'automatic' check (triage_mode in ('automatic', 'choose')),
 add column if not exists arrived_at timestamptz,
 add column if not exists inactive_at timestamptz;
alter table public.traumasim_patients
 add column if not exists revision integer not null default 0,
 add column if not exists scenario_model jsonb,
 add column if not exists first_triage_at timestamptz,
 add column if not exists identity_profile jsonb;
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
create table if not exists traumasim_private.exercise_shares (
 session_id uuid not null references public.traumasim_sessions(id) on delete cascade,
 recipient_id uuid not null references auth.users(id) on delete cascade,
 recipient_email text not null check (recipient_email = lower(btrim(recipient_email))),
 token_hash bytea not null unique check (octet_length(token_hash) = 32),
 created_at timestamptz not null default now(),
 primary key (session_id, recipient_email)
);
create index if not exists traumasim_exercise_shares_recipient on traumasim_private.exercise_shares (recipient_id);
alter table traumasim_private.exercise_templates enable row level security;
alter table traumasim_private.exercise_shares enable row level security;
alter table traumasim_private.bus_templates enable row level security;
alter table traumasim_private.trainers enable row level security;
alter table traumasim_private.models enable row level security;
revoke all on all tables in schema traumasim_private from public, anon, authenticated;

create or replace function traumasim_private.patient_name_catalog()
returns table(full_name text, gender text, street text, locality text, background text)
language sql immutable set search_path = '' as $$
 -- Hamburg's Landeszentrale für politische Bildung and the Lexikon der Feuerwehr Hamburg.
 values
   ('Abelke Bleken', 'weiblich', 'Abelke-Bleken-Ring', 'Ochsenwerder, Bezirk Bergedorf', 'Führte einen Hof in Ochsenwerder und wurde 1583 nach einem Hexenprozess hingerichtet.'), -- https://hamburg-strassennamen.de/item/23--abelke-bleken-ring
   ('Agathe Lasch', 'weiblich', 'Agathe-Lasch-Weg', 'Othmarschen, Bezirk Altona', 'Germanistin und erste Professorin an der Universität Hamburg.'), -- https://hamburg-strassennamen.de/item/16--agathe-lasch-weg
   ('Agnes Gierck', 'weiblich', 'Agnes-Gierck-Weg', 'Langenhorn, Bezirk Hamburg-Nord', 'Engagierte sich in Langenhorn im Widerstand gegen den Nationalsozialismus.'), -- https://hamburg-strassennamen.de/item/18--agnes-gierck-weg
   ('Agnes Wolffson', 'weiblich', 'Agnes-Wolffson-Straße', 'Neuallermöhe, Bezirk Bergedorf', 'Förderte als Stifterin die Ausbildung von Mädchen und gründete Haushaltungsschulen.'), -- https://hamburg-strassennamen.de/item/20--agnes-wolffson-strasse
   ('Albert Ballin', 'männlich', 'Am Ballinkai', 'Altenwerder, Bezirk Harburg', 'Hamburger Reeder und Generaldirektor der HAPAG.'), -- https://hamburg-strassennamen.de/item/58--am-ballinkai
   ('Albertine Assor', 'weiblich', 'Albertine-Assor-Straße', 'Schnelsen, Bezirk Eimsbüttel', 'Baute in Schnelsen eine evangelische Diakonisseneinrichtung auf und leitete sie als Oberin.'), -- https://hamburg-strassennamen.de/item/30--albertine-assor-strasse
   ('Alexander Conze', 'männlich', 'Conzestraße', 'Nienstedten, Bezirk Altona', 'Archäologe und Hochschullehrer.'), -- https://hamburg-strassennamen.de/item/479--conzestrasse
   ('Alma Ohlmann', 'weiblich', 'Alma-Ohlmann-Weg', 'Lokstedt, Bezirk Eimsbüttel', 'Leitete jahrzehntelang Gymnastikgruppen und betreute einen Seniorenkreis.'), -- https://hamburg-strassennamen.de/item/2542--alma-ohlmann-weg
   ('Alma Wartenberg', 'weiblich', 'Alma-Wartenberg-Platz', 'Ottensen, Bezirk Altona', 'Setzte sich in Ottensen als Sozialdemokratin für Frauenrechte ein.'), -- https://hamburg-strassennamen.de/item/51--alma-wartenberg-platz
   ('Alwin Lippert', 'männlich', 'Alwin-Lippert-Weg', 'Niendorf, Bezirk Eimsbüttel', 'Besaß den Hof, an dessen Gelände der Weg liegt.'), -- https://hamburg-strassennamen.de/item/56--alwin-lippert-weg
   ('Amalie Dietrich', 'weiblich', 'Amalie-Dietrich-Stieg', 'Barmbek-Nord, Bezirk Hamburg-Nord', 'Botanikerin und Forschungsreisende, später Kustodin eines Hamburger Museums.'), -- https://hamburg-strassennamen.de/item/77--amalie-dietrich-stieg
   ('Amalie Sieveking', 'weiblich', 'Amalie-Sieveking-Weg und Sievekingdamm', 'Volksdorf (Bezirk Wandsbek) und Hamm (Bezirk Hamburg-Mitte)', 'Gründete 1832 einen Frauenverein für Armen- und Krankenpflege.'), -- https://hamburg-strassennamen.de/item/2833--sievekingdamm
   ('Amália Rodrigues', 'weiblich', 'Amalia-Rodrigues-Weg', 'Bahrenfeld, Bezirk Altona', 'Portugiesische Sängerin, die den Fado international bekannt machte.'), -- https://hamburg-strassennamen.de/item/76--amalia-rodrigues-weg
   ('Annie Kienast', 'weiblich', 'Annie-Kienast-Straße', 'Langenhorn, Bezirk Hamburg-Nord', 'Verkäuferin und Gewerkschafterin, nach dem Krieg Mitglied der Hamburgischen Bürgerschaft.'), -- https://hamburg-strassennamen.de/item/111--annie-kienast-strasse
   ('Anny Ahlers', 'weiblich', 'Anny-Ahlers-Weg', 'St. Pauli, Bezirk Hamburg-Mitte', 'Trat als Tänzerin, Schauspielerin und Operettensängerin an der Hamburger Volksoper auf.'), -- https://hamburg-strassennamen.de/item/2620--anny-ahlers-weg
   ('Anny Tollens', 'weiblich', 'Anny-Tollens-Weg', 'Rahlstedt, Bezirk Wandsbek', 'Leitete die Kinderstube Rahlstedt und engagierte sich in der Kommunalpolitik.'), -- https://hamburg-strassennamen.de/item/112--anny-tollens-weg
   ('August Böhme', 'männlich', 'Böhmestraße', 'Wandsbek, Bezirk Wandsbek', 'Tischlermeister und letzter Wehrführer der Freiwilligen Feuerwehr Wandsbek.'), -- https://epub.sub.uni-hamburg.de/epub/volltexte/2013/25292/pdf/Lexikon_der_Hamburger_Feuerwehr.pdf
   ('Auguste Caecilie Baur', 'weiblich', 'Auguste-Baur-Straße', 'Blankenese, Bezirk Altona', 'Unterstützte als Stifterin wohltätige Zwecke.'), -- https://hamburg-strassennamen.de/item/159--auguste-baur-strasse
   ('Auguste Schmidt', 'weiblich', 'Auguste-Schmidt-Weg', 'Neuallermöhe, Bezirk Bergedorf', 'Mitbegründerin des Allgemeinen Deutschen Frauenvereins.'), -- https://hamburg-strassennamen.de/item/162--auguste-schmidt-weg
   ('Carl von Ossietzky', 'männlich', 'Ossietzkystraße', 'Jenfeld, Bezirk Wandsbek', 'Publizist und Friedensnobelpreisträger, der vom NS-Regime verfolgt wurde.'), -- https://www.hamburg.de/521446
   ('Catharina Fellendorf', 'weiblich', 'Catharina-Fellendorf-Straße', 'Neuallermöhe, Bezirk Bergedorf', 'Leistete Widerstand gegen die NS-Diktatur und wurde 1944 in Plötzensee hingerichtet.'), -- https://hamburg-strassennamen.de/item/446--catharina-fellendorf-strasse
   ('Charlotte Mügge', 'weiblich', 'Charlotte-Mügge-Weg', 'Jenfeld, Bezirk Wandsbek', 'Half Deserteuren während der NS-Diktatur und wurde dafür inhaftiert.'), -- https://hamburg-strassennamen.de/item/453--charlotte-muegge-weg
   ('Charlotte Niese', 'weiblich', 'Charlotte-Niese-Straße', 'Osdorf, Bezirk Altona', 'Schrieb Erzählungen über das Leben in Norddeutschland.'), -- https://hamburg-strassennamen.de/item/454--charlotte-niese-strasse
   ('Christoph Probst', 'männlich', 'Christoph-Probst-Weg', 'Eppendorf, Bezirk Hamburg-Nord', 'Student und Mitglied der Widerstandsgruppe Weiße Rose.'), -- https://hamburg-strassennamen.de/item/466--christoph-probst-weg
   ('Christopher Johann Hennig Harms', 'männlich', 'Christopher-Harms-Weg', 'Kirchwerder, Bezirk Bergedorf', 'Schuhmachermeister, dessen Testament eine Stiftung für benachteiligte Kinder vorsah.'), -- https://hamburg-strassennamen.de/item/465--christopher-harms-weg
   ('Clemens Schultz', 'männlich', 'Clemens-Schultz-Straße', 'St. Pauli, Bezirk Hamburg-Mitte', 'Wirkte als Pastor in St. Pauli.'), -- https://hamburg-strassennamen.de/item/475--clemens-schultz-strasse
   ('Cord Dreyer', 'männlich', 'Cord-Dreyer-Weg', 'Niendorf, Bezirk Eimsbüttel', 'Stellmachermeister und von 1881 bis 1899 Gemeindevorsteher in Niendorf.'), -- https://hamburg-strassennamen.de/item/480--cord-dreyer-weg
   ('Edvard Grieg', 'männlich', 'Griegstraße', 'Ottensen, Bezirk Altona', 'Norwegischer Komponist, bekannt unter anderem für die Musik zu „Peer Gynt“.'), -- https://hamburg-strassennamen.de/item/963--griegstrasse
   ('Elfriede Land', 'weiblich', 'Elfriede-Land-Weg', 'Altona-Nord, Bezirk Altona', 'Fuhr für die Hamburger Hochbahn Straßenbahn und gehörte zu den ersten Busfahrerinnen Deutschlands.'), -- https://hamburg-strassennamen.de/item/635--elfriede-land-weg
   ('Elfriede Lohse-Wächtler', 'weiblich', 'Elfriede-Lohse-Wächtler-Weg', 'Barmbek-Süd, Bezirk Hamburg-Nord', 'Malerin, die 1940 im Rahmen der NS-Krankenmorde getötet wurde.'), -- https://hamburg-strassennamen.de/item/636--elfriede-lohse-waechtler-weg
   ('Elisabeth Flügge', 'weiblich', 'Elisabeth-Flügge-Straße', 'Alsterdorf, Bezirk Hamburg-Nord', 'Hamburger Schulleiterin, die Verfolgten des NS-Regimes half.'), -- https://hamburg-strassennamen.de/item/640--elisabeth-fluegge-strasse
   ('Elisabeth Lange', 'weiblich', 'Elisabeth-Lange-Weg', 'Langenbek, Bezirk Harburg', 'Gegnerin der NS-Diktatur, die 1944 im KZ Fuhlsbüttel starb.'), -- https://hamburg-strassennamen.de/item/641--elisabeth-lange-weg
   ('Elisabeth Thomann', 'weiblich', 'Elisabeth-Thomann-Weg', 'Bergedorf, Bezirk Bergedorf', 'Verfasste literarische Texte über ihre Heimat Bergedorf.'), -- https://hamburg-strassennamen.de/item/643--elisabeth-thomann-weg
   ('Elisabeth Will', 'weiblich', 'Elisabeth-Will-Straße', 'Ottensen, Bezirk Altona', 'Engagierte sich in der Altonaer Bezirksversammlung für Bildung und Kultur.'), -- https://hamburg-strassennamen.de/item/3234--elisabeth-will-strasse
   ('Elise Averdieck', 'weiblich', 'Elise-Averdieck-Straße', 'Borgfelde, Bezirk Hamburg-Mitte', 'Leitete das Diakonissenhaus Bethesda und schrieb Kinderbücher.'), -- https://hamburg-strassennamen.de/item/645--elise-averdieck-strasse
   ('Elly Heuss-Knapp', 'weiblich', 'Elly-Heuss-Knapp-Ring', 'Neuallermöhe, Bezirk Bergedorf', 'Sozialpolitikerin und Gründerin des Müttergenesungswerks.'), -- https://hamburg-strassennamen.de/item/650--elly-heuss-knapp-ring
   ('Elly See', 'weiblich', 'Elly-See-Straße', 'Lurup, Bezirk Altona', 'Engagierte sich im SV Lurup und gründete den Zusammenschluss der Altonaer Sportvereine mit.'), -- https://hamburg-strassennamen.de/item/651--elly-see-strasse
   ('Elsa Bauer', 'weiblich', 'Elsa-Bauer-Weg', 'Alsterdorf, Bezirk Hamburg-Nord', 'Hamburger Lehrerin, die als Jüdin vom NS-Regime verfolgt wurde.'), -- https://hamburg-strassennamen.de/item/654--elsa-bauer-weg
   ('Ernst Cordua', 'männlich', 'Corduaweg', 'Heimfeld, Bezirk Harburg', 'Arbeitete als Arzt in Harburg.'), -- https://hamburg-strassennamen.de/item/482--corduaweg
   ('Eva Rühmkorf', 'weiblich', 'Eva-Rühmkorf-Straße', 'Altona-Nord, Bezirk Altona', 'Psychologin, die sich in der Hamburger Justizbehörde mit dem Strafvollzug befasste.'), -- https://hamburg-strassennamen.de/item/728--eva-ruehmkorf-strasse
   ('Fanny David', 'weiblich', 'Fanny-David-Weg', 'Lohbrügge, Bezirk Bergedorf', 'Leitete die Wohlfahrtsstelle Barmbek und arbeitete später in der jüdischen Fürsorge.'), -- https://hamburg-strassennamen.de/item/738--fanny-david-weg
   ('Fanny Hensel', 'weiblich', 'Fanny-Mendelssohn-Platz', 'Eimsbüttel, Bezirk Eimsbüttel', 'Komponistin und Pianistin, geboren in Hamburg als Fanny Zippora Mendelssohn.'), -- https://hamburg-strassennamen.de/item/741--fanny-mendelssohn-platz
   ('Fanny Lewald', 'weiblich', 'Fanny-Lewald-Ring', 'Neuallermöhe, Bezirk Bergedorf', 'Schriftstellerin, die in ihren Romanen unter anderem die Stellung von Frauen behandelte.'), -- https://hamburg-strassennamen.de/item/740--fanny-lewald-ring
   ('Felicitas Kukuck', 'weiblich', 'Felicitas-Kukuck-Straße', 'Altona-Nord, Bezirk Altona', 'Hamburger Komponistin, die nach 1945 in Blankenese ein umfangreiches Werk schuf.'), -- https://hamburg-strassennamen.de/item/751--felicitas-kukuck-strasse
   ('Ferdinand Laeisz', 'männlich', 'Laeiszstraße', 'St. Pauli, Bezirk Hamburg-Mitte', 'Hamburger Reeder und Gründer des Ferdinand-Laeisz-Stifts.'), -- https://hamburg-strassennamen.de/item/1649--laeiszstrasse
   ('Flora Neumann', 'weiblich', 'Flora-Neumann-Straße', 'St. Pauli, Bezirk Hamburg-Mitte', 'Jüdische Widerstandskämpferin, die später an Hamburger Schulen als Zeitzeugin berichtete.'), -- https://hamburg-strassennamen.de/item/775--flora-neumann-strasse
   ('Franz Carl Friedrich Chrysander', 'männlich', 'Chrysanderstraße', 'Bergedorf, Bezirk Bergedorf', 'Erforschte das Werk des Komponisten Georg Friedrich Händel.'), -- https://hamburg-strassennamen.de/item/467--chrysanderstrasse
   ('Frieda Hertha Martha Wieking', 'weiblich', 'Frieda-Wieking-Stieg', 'Uhlenhorst, Bezirk Hamburg-Nord', 'Krankenschwester und Gewerkschafterin, die sich als Betriebsrätin engagierte.'), -- https://hamburg-strassennamen.de/item/798--frieda-wieking-stieg
   ('Friedrich von Esmarch', 'männlich', 'Esmarchstraße', 'Altona-Altstadt, Bezirk Altona', 'Arzt, der das Lazarettwesen verbesserte und das zivile Samariterwesen aufbaute.'), -- https://hamburg-strassennamen.de/item/722--esmarchstrasse
   ('Gerhard Mercator', 'männlich', 'Merkatorweg', 'Billstedt, Bezirk Hamburg-Mitte', 'Kartograf, der die Mercatorprojektion entwickelte.'), -- https://hamburg-strassennamen.de/item/1903--merkatorweg
   ('Giacomo Meyerbeer', 'männlich', 'Meyerbeerstraße', 'Rahlstedt, Bezirk Wandsbek', 'Komponierte Opern.'), -- https://hamburg-strassennamen.de/item/1913--meyerbeerstrasse
   ('Hans Scholl', 'männlich', 'Geschwister-Scholl-Straße', 'Eppendorf, Bezirk Hamburg-Nord', 'Medizinstudent und Mitgründer der Widerstandsgruppe Weiße Rose.'), -- https://geschichtswerkstatt-eppendorf.de/denkmaeler/verhoerzelle/
   ('Helene Lange', 'weiblich', 'Helene-Lange-Straße', 'Harvestehude, Bezirk Eimsbüttel', 'Pädagogin und Frauenrechtlerin, die sich für bessere Bildungschancen von Mädchen einsetzte.'), -- https://hamburg-strassennamen.de/item/1195--helene-lange-strasse
   ('Helga Feddersen', 'weiblich', 'Helga-Feddersen-Twiete', 'Altona-Nord, Bezirk Altona', 'Hamburger Schauspielerin, Autorin und Gründerin des Theaters am Holstenwall.'), -- https://hamburg-strassennamen.de/item/1154--helga-feddersen-twiete
   ('Helma Steinbach', 'weiblich', 'Helma-Steinbach-Weg', 'Horn, Bezirk Hamburg-Mitte', 'Gründete die Hamburger Konsumgenossenschaft „Produktion“ mit.'), -- https://hamburg-strassennamen.de/item/1203--helma-steinbach-weg
   ('Henry Bengelsdorf', 'männlich', 'Bengelsdorfstieg', 'Bramfeld, Bezirk Wandsbek', 'Arbeitete in Hamburg als Inspektor bei der AOK.'), -- https://hamburg-strassennamen.de/item/258--bengelsdorfstieg
   ('Herbert Pardo', 'männlich', 'Herbert-Pardo-Weg', 'Neuallermöhe, Bezirk Bergedorf', 'Hamburger Rechtsanwalt, Bürgerschaftsmitglied und Vorsitzender der portugiesisch-jüdischen Gemeinde.'), -- https://hamburg-strassennamen.de/item/1219--herbert-pardo-weg
   ('Hermann Blohm', 'männlich', 'Hermann-Blohm-Straße', 'Steinwerder, Bezirk Hamburg-Mitte', 'Schiffbauingenieur und Mitgründer der Werft Blohm & Voss.'), -- https://hamburg-strassennamen.de/item/1231--hermann-blohm-strasse
   ('Hermann Krüger', 'männlich', 'Hermann-Krüger-Platz', 'Harburg, Bezirk Harburg', 'Lehrer und Schulleiter, der das Harburger Löwenhaus für Kinder gründete.'), -- https://hamburg-strassennamen.de/item/2982--hermann-krueger-platz
   ('Hugo Groothoff', 'männlich', 'Groothoffgasse', 'Winterhude, Bezirk Hamburg-Nord', 'Hamburger Architekt.'), -- https://hamburg-strassennamen.de/item/970--groothoffgasse
   ('Ida Ehre', 'weiblich', 'Ida-Ehre-Platz', 'Hamburg-Altstadt, Bezirk Hamburg-Mitte', 'Schauspielerin, Regisseurin und langjährige Leiterin der Hamburger Kammerspiele.'), -- https://filmmuseum-hamburg.de/personen/d-g/ida-ehre.html
   ('Jens Jacob Eschels', 'männlich', 'Eschelsweg', 'Altona-Altstadt, Bezirk Altona', 'Kapitän, der zur See nach Grönland fuhr.'), -- https://hamburg-strassennamen.de/item/721--eschelsweg
   ('Joachim Jungius', 'männlich', 'Jungiusstraße', 'Neustadt, Bezirk Hamburg-Mitte', 'Mathematiker und Physiker, der das Hamburger Akademische Gymnasium leitete.'), -- https://hamburg-strassennamen.de/item/1436--jungiusstrasse
   ('Johann Amos Comenius', 'männlich', 'Comeniusplatz', 'Hohenfelde, Bezirk Hamburg-Nord', 'Pädagoge, der sich für die Ausbildung von Lehrkräften einsetzte.'), -- https://hamburg-strassennamen.de/item/476--comeniusplatz
   ('Johann Ehlert Bieber', 'männlich', 'Bieberstraße', 'Rotherbaum, Bezirk Eimsbüttel', 'Oberspritzenmeister und Leiter der Löschmannschaften beim Großen Brand von 1842.'), -- https://epub.sub.uni-hamburg.de/epub/volltexte/2013/25292/pdf/Lexikon_der_Hamburger_Feuerwehr.pdf
   ('Johann Georg Repsold', 'männlich', 'Repsoldstraße', 'St. Georg und Hammerbrook, Bezirk Hamburg-Mitte', 'Oberspritzenmeister und Gründer der Hamburger Sternwarte.'), -- https://epub.sub.uni-hamburg.de/epub/volltexte/2013/25292/pdf/Lexikon_der_Hamburger_Feuerwehr.pdf
   ('Johannes Classen', 'männlich', 'Classenstieg', 'Wellingsbüttel, Bezirk Wandsbek', 'Leitete das Hamburger Johanneum von 1864 bis 1874.'), -- https://hamburg-strassennamen.de/item/470--classenstieg
   ('Julius Vosseler', 'männlich', 'Julius-Vosseler-Straße', 'Lokstedt, Bezirk Eimsbüttel', 'Leitete den Zoologischen Garten in Hamburg.'), -- https://hamburg-strassennamen.de/item/1429--julius-vosseler-strasse
   ('Justus Brinckmann', 'männlich', 'Justus-Brinckmann-Straße', 'Bergedorf, Bezirk Bergedorf', 'Gründete und leitete das Hamburger Museum für Kunst und Gewerbe.'), -- https://hamburg-strassennamen.de/item/1441--justus-brinckmann-strasse
   ('Jürgen Fehling', 'männlich', 'Fehlinghöhe', 'Steilshoop, Bezirk Wandsbek', 'Theaterregisseur und früherer Eigentümer des Geländes.'), -- https://hamburg-strassennamen.de/item/745--fehlinghoehe
   ('Jürgen Töpfer', 'männlich', 'Jürgen-Töpfer-Straße', 'Othmarschen, Bezirk Altona', 'Mitglied der Hamburgischen Bürgerschaft und CDU-Fraktionsvorsitzender in der Bezirksversammlung Altona.'), -- https://hamburg-strassennamen.de/item/1415--juergen-toepfer-strasse
   ('Katharina Jacob', 'weiblich', 'Katharina-Jacob-Weg', 'Groß Borstel, Bezirk Hamburg-Nord', 'Lehrerin und Mitglied der Widerstandsgruppe Bästlein-Jacob-Abshagen.'), -- https://hamburg-strassennamen.de/item/1495--katharina-jacob-weg
   ('Kurt Emmerich', 'männlich', 'Kurt-Emmerich-Platz', 'Wilhelmsburg, Bezirk Hamburg-Mitte', 'Berichtete als Sportreporter im NDR-Radio.'), -- https://hamburg-strassennamen.de/item/1638--kurt-emmerich-platz
   ('Kurt-Adolf Körber', 'männlich', 'Kurt-A.-Körber-Chaussee', 'Bergedorf, Bezirk Bergedorf', 'Gründete die Hauni-Werke und wurde Hamburger Ehrenbürger.'), -- https://hamburg-strassennamen.de/item/1635--kurt-a-koerber-chaussee
   ('Käte Latzke', 'weiblich', 'Käte-Latzke-Weg', 'Neuallermöhe, Bezirk Bergedorf', 'Stenotypistin und Widerstandskämpferin, die im KZ Ravensbrück starb.'), -- https://hamburg-strassennamen.de/item/1449--kaete-latzke-weg
   ('Lazarus Ludwig Zamenhof', 'männlich', 'Zamenhofweg', 'Farmsen-Berne, Bezirk Wandsbek', 'Entwickelte die Plansprache Esperanto.'), -- https://hamburg-strassennamen.de/item/2248--zamenhofweg
   ('Leo Fall', 'männlich', 'Fallstraße', 'Rahlstedt, Bezirk Wandsbek', 'Operettenkomponist, der auch als Kapellmeister in Hamburg arbeitete.'), -- https://hamburg-strassennamen.de/item/737--fallstrasse
   ('Leonhard Euler', 'männlich', 'Eulerweg', 'Rahlstedt, Bezirk Wandsbek', 'Schweizer Mathematiker, der unter anderem in Sankt Petersburg arbeitete.'), -- https://hamburg-strassennamen.de/item/724--eulerweg
   ('Lovis Corinth', 'männlich', 'Corinthstraße', 'Othmarschen, Bezirk Altona', 'Maler und Grafiker.'), -- https://hamburg-strassennamen.de/item/483--corinthstrasse
   ('Margaretha Rothe', 'weiblich', 'Margaretha-Rothe-Weg', 'Niendorf, Bezirk Eimsbüttel', 'Hamburger Medizinstudentin und Mitglied der Weißen Rose Hamburg.'), -- https://hamburg-strassennamen.de/item/1815--margaretha-rothe-weg
   ('Margaretha Treuge', 'weiblich', 'Margaretha-Treuge-Weg', 'Ohlsdorf, Bezirk Hamburg-Nord', 'Leitete die Soziale Frauenschule in Hamburg und gründete den Hamburger Frauenring mit.'), -- https://hamburg-strassennamen.de/item/1816--margaretha-treuge-weg
   ('Marianne Timm', 'weiblich', 'Marianne-Timm-Weg', 'Rothenburgsort, Bezirk Hamburg-Mitte', 'Theologin und erste Hamburger Pastorin, die von der Kanzel predigen durfte.'), -- https://hamburg-strassennamen.de/item/1823--marianne-timm-weg
   ('Marie Bautz', 'weiblich', 'Marie-Bautz-Weg', 'Farmsen-Berne, Bezirk Wandsbek', 'Arbeitete in einer Fabrik und vertrat später die SPD in der Hamburgischen Bürgerschaft.'), -- https://hamburg-strassennamen.de/item/2289--marie-bautz-weg
   ('Marie-Anna Jonas', 'weiblich', 'Marie-Jonas-Platz', 'Eppendorf, Bezirk Hamburg-Nord', 'Hamburger Ärztin, die als Jüdin deportiert und in Auschwitz ermordet wurde.'), -- https://hamburg-strassennamen.de/item/1827--marie-jonas-platz
   ('Matthias Claudius', 'männlich', 'Claudiusstraße', 'Marienthal, Bezirk Wandsbek', 'Dichter und Verfasser des Abendlieds „Der Mond ist aufgegangen“.'), -- https://hamburg-strassennamen.de/item/473--claudiusstrasse
   ('Maud Hester von Ossietzky', 'weiblich', 'Ossietzkystraße', 'Jenfeld, Bezirk Wandsbek', 'Frauenrechtlerin, die die Zeitschrift „Die Weltbühne“ nach dem Krieg wiederbegründete.'), -- https://www.hamburg.de/521446
   ('Nikolaus Falck', 'männlich', 'Falckweg', 'Othmarschen, Bezirk Altona', 'Jurist und Erforscher der schleswig-holsteinischen Rechtsgeschichte.'), -- https://hamburg-strassennamen.de/item/735--falckweg
   ('Ottmar Mergenthaler', 'männlich', 'Mergenthalerweg', 'Eidelstedt, Bezirk Eimsbüttel', 'Entwickelte die Linotype-Setzmaschine für den Druck.'), -- https://hamburg-strassennamen.de/item/1902--mergenthalerweg
   ('Otto Meyerhof', 'männlich', 'Meyerhofstraße', 'Osdorf, Bezirk Altona', 'Biochemiker und Träger des Nobelpreises für Medizin.'), -- https://hamburg-strassennamen.de/item/1915--meyerhofstrasse
   ('Peter Schulz', 'männlich', 'Peter-Schulz-Platz', 'Hamburg-Altstadt, Bezirk Hamburg-Mitte', 'Jurist, Hamburger Bürgermeister und Präsident der Bürgerschaft.'), -- https://hamburg-strassennamen.de/item/3366--peter-schulz-platz
   ('Philipp Otto Runge', 'männlich', 'Rungestieg', 'Barmbek-Nord, Bezirk Hamburg-Nord', 'Maler der Romantik.'), -- https://hamburg-strassennamen.de/item/2527--rungestieg
   ('Ralph Benatzky', 'männlich', 'Benatzkyweg', 'Rahlstedt, Bezirk Wandsbek', 'Komponierte Operetten, darunter „Im weißen Rössl“.'), -- https://hamburg-strassennamen.de/item/256--benatzkyweg
   ('Ricarda Huch', 'weiblich', 'Ricarda-Huch-Ring', 'Neuallermöhe, Bezirk Bergedorf', 'Schriftstellerin und Historikerin, die auch Gedichte und Erzählungen veröffentlichte.'), -- https://hamburg-strassennamen.de/item/2435--ricarda-huch-ring
   ('Salomon Heine', 'männlich', 'Salomon-Heine-Weg', 'Eppendorf, Bezirk Hamburg-Nord', 'Hamburger Bankier und Onkel des Dichters Heinrich Heine.'), -- https://hamburg-strassennamen.de/item/2691--salomon-heine-weg
   ('Siegfried Detlev Bendixen', 'männlich', 'Bendixensweg', 'Barmbek-Nord, Bezirk Hamburg-Nord', 'Maler, der unter anderem in Hamburg und London arbeitete.'), -- https://hamburg-strassennamen.de/item/257--bendixensweg
   ('Sophie Scholl', 'weiblich', 'Geschwister-Scholl-Straße', 'Eppendorf, Bezirk Hamburg-Nord', 'Studentin und Mitglied der Widerstandsgruppe Weiße Rose.'), -- https://geschichtswerkstatt-eppendorf.de/denkmaeler/verhoerzelle/
   ('Stefan Zweig', 'männlich', 'Stefan-Zweig-Straße', 'Bramfeld, Bezirk Wandsbek', 'Österreichischer Schriftsteller und Verfasser der „Schachnovelle“.'), -- https://hamburg-strassennamen.de/item/2905--stefan-zweig-strasse
   ('Thomas Herbst', 'männlich', 'Herbstsweg', 'Barmbek-Nord, Bezirk Hamburg-Nord', 'Hamburger Maler.'), -- https://hamburg-strassennamen.de/item/1225--herbstsweg
   ('Traute Lafrenz', 'weiblich', 'Traute-Lafrenz-Straße', 'Groß Borstel und Alsterdorf, Bezirk Hamburg-Nord', 'Ärztin und Mitglied der Widerstandsgruppe Weiße Rose.'), -- https://hamburg-strassennamen.de/item/3569--traute-lafrenz-strasse
   ('Walter Bärsch', 'männlich', 'Walter-Bärsch-Weg', 'Groß Borstel, Bezirk Hamburg-Nord', 'Leitete den Hamburger schulpsychologischen Dienst und war Präsident des Deutschen Kinderschutzbundes.') -- https://hamburg-strassennamen.de/item/2569--walter-baersch-weg
$$;

create or replace function traumasim_private.draw_patient_identity(p_session uuid)
returns jsonb language sql volatile set search_path = '' as $$
 select jsonb_build_object('name', candidate.full_name, 'gender', candidate.gender,
   'age', 16 + floor(random() * 57)::integer, 'name_source', candidate.street,
   'name_locality', candidate.locality, 'name_background', candidate.background)
 from traumasim_private.patient_name_catalog() candidate
 order by exists (
   select 1 from public.traumasim_patients p
   where p.session_id = p_session and p.identity_profile->>'name' = candidate.full_name
 ), random()
 limit 1;
$$;

create or replace function traumasim_private.assign_patient_identity()
returns trigger language plpgsql set search_path = '' as $$
begin
 -- Serialize draws for the same exercise, including multi-patient inserts.
 perform 1 from public.traumasim_sessions s where s.id = new.session_id for update;
 new.identity_profile := traumasim_private.draw_patient_identity(new.session_id);
 return new;
end;
$$;

create or replace trigger traumasim_assign_patient_identity
before insert on public.traumasim_patients
for each row execute function traumasim_private.assign_patient_identity();

do $backfill$
declare
 patient record;
begin
 for patient in select id, session_id from public.traumasim_patients
   where identity_profile is null order by session_id, patient_key loop
   update public.traumasim_patients
   set identity_profile = traumasim_private.draw_patient_identity(patient.session_id)
   where id = patient.id;
 end loop;
end;
$backfill$;
alter table public.traumasim_patients alter column identity_profile set not null;

-- Add street context to previously assigned profiles without drawing names or ages again.
update public.traumasim_patients p
set identity_profile = p.identity_profile || jsonb_build_object(
 'name_locality', n.locality, 'name_background', n.background)
from traumasim_private.patient_name_catalog() n
where p.identity_profile->>'name' = n.full_name
 and (p.identity_profile->>'name_locality' is distinct from n.locality
   or p.identity_profile->>'name_background' is distinct from n.background);


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
 execute format($fn$
  create or replace function traumasim_private.new_share_token()
  returns text language sql volatile set search_path = '' as $body$
    select encode(%I.gen_random_bytes(32), 'hex');
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
   and s.inactive_at is null and s.expires_at > clock_timestamp();
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
   when p_model->'black' = 'true'::jsonb then 'black'
   when p_model->'progression'->>'from' is not null then case
     when p_elapsed >= (p_model->'progression'->>'at_seconds')::integer then p_model->'progression'->>'to'
     else p_model->'progression'->>'from' end
   when (p_patient = 'fahrer' or p_custom)
     and ((p_vitals->>'s')::integer < 100 or (p_vitals->>'g')::integer < 15 or (p_vitals->>'h')::integer >= 120)
     then 'red'
   when p_model->'walkable' = 'true'::jsonb then 'green'
   else 'yellow' end;
$$;

create or replace function traumasim_private.station_story(p_model jsonb, p_patient text, p_category text)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
 kind text := coalesce(p_model->>'station_kind', 'car');
 access_code text := p_model->>'car_entrapment';
 seat text := coalesce(p_model->>'car_seat', case (regexp_match(p_model->>'name', ' · ([^·]+)$'))[1]
   when 'Fahrerplatz' then 'driver' when 'Fahrer' then 'driver'
   when 'Beifahrerplatz' then 'front' when 'Beifahrer' then 'front'
   when 'hinten links' then 'rear-left' when 'hinten Mitte' then 'rear-center' when 'hinten rechts' then 'rear-right'
 end);
 profile text := coalesce(p_model->>'car_profile', case
   when p_model->'affected' = 'true'::jsonb then 'affected'
   when p_model->'black' = 'true'::jsonb then 'black'
   when p_model->'progression'->>'to' = 'yellow' then 'green-yellow'
   when p_model->'progression'->>'to' = 'red' then 'urgent-red'
   when p_model->'progression'->>'to' = 'black' then 'red-ex'
   when p_model->'walkable' = 'true'::jsonb then 'minor'
   when p_model->'nibpFastCycle' = 'true'::jsonb then 'critical'
   else 'urgent' end);
 legacy_story text := p_model->>'story';
 legacy_default text;
 additional text := nullif(p_model->>'car_injury', '');
 object_type text := p_model->>'object_type';
 object_name text;
 object_place text;
 limb text;
 seat_description text;
 access_description text;
 pain_site text;
 blocked boolean;
 findings text;
 condition text;
 reason text;
begin
 if p_model is null or not (p_patient like any (array['car-%', 'truck-%', 'object-%'])) then
   return null;
 end if;

 if kind = 'object' then
   object_name := case object_type
     when 'beam' then 'einem Betonträger' when 'skip' then 'einer Mulde'
     when 'car' then 'einem Pkw' when 'car-bike' then 'einem Pkw'
     when 'truck' then 'einem Lkw' when 'bus' then 'einem Bus' when 'machine' then 'einer Maschine'
   end;
   object_place := case p_model->>'object_position'
     when 'under' then 'unter ' || object_name
       || case when object_type = 'car-bike' then ' neben einem Fahrrad' else '' end
     when 'between' then 'zwischen ' || object_name
       || case when object_type = 'car-bike' then ' und einem Fahrrad' else ' und einem Hindernis' end
   end;
   limb := case access_code
     when 'left-arm' then 'dem linken Arm' when 'right-arm' then 'dem rechten Arm' when 'both-arms' then 'beiden Armen'
     when 'left-leg' then 'dem linken Bein' when 'right-leg' then 'dem rechten Bein' when 'both-legs' then 'beiden Beinen'
   end;
   access_description := case when limb is not null and object_place is not null
     then format('Die Person ist mit %s %s eingeklemmt.', limb, object_place)
     else p_model->>'intro' end;
   pain_site := case access_code
     when 'both-arms' then 'an beiden Armen' when 'both-legs' then 'an beiden Beinen'
     else 'am ' || substring(limb from 5) end;
 else
   if access_code is null then
     access_code := case
       when p_model->>'intro' like '%eingeschlossen, Ausstieg versperrt.' then 'enclosed'
       when p_model->>'intro' like '%Tür und B-Säule eingeklemmt.' then 'door'
       when p_model->>'intro' like '%im deformierten Fußraum eingeklemmt.' then 'footwell'
       when p_model->>'intro' like '%zwischen Sitz und Armaturenbrett eingeklemmt.' then 'dashboard'
       when p_model->>'intro' like '%von Dach und Sitz eingeklemmt.' then 'roof'
       else 'none' end;
   end if;
   seat_description := case seat
     when 'driver' then 'Die Person sitzt auf dem Fahrerplatz.'
     when 'front' then 'Die Person sitzt auf dem Beifahrerplatz.'
     when 'rear-left' then 'Die Person sitzt hinten links.'
     when 'rear-center' then 'Die Person sitzt hinten in der Mitte.'
     when 'rear-right' then 'Die Person sitzt hinten rechts.'
   end;
   access_description := case access_code
     when 'none' then 'Die Person ist frei zugänglich.'
     when 'enclosed' then 'Der Ausstieg ist versperrt. Die Person ist eingeschlossen.'
     when 'door' then case when kind = 'truck'
       then 'Die Person ist im Bereich von Tür und Kabinenrahmen eingeklemmt.'
       else 'Die Person ist im Bereich von Tür und B-Säule eingeklemmt.' end
     when 'footwell' then 'Ein Bein ist im deformierten Fußraum eingeklemmt.'
     when 'dashboard' then case when seat in ('driver', 'front')
       then 'Die Person ist zwischen Sitz und Armaturenbrett eingeklemmt.'
       else 'Die Person ist im Bereich der hinteren Sitzreihe am verformten Vordersitz eingeklemmt.' end
     when 'roof' then 'Die Person ist im Bereich von Dach und Sitz eingeklemmt.'
     else p_model->>'intro' end;
   pain_site := case access_code
     when 'footwell' then 'am betroffenen Bein'
     when 'dashboard' then 'im Bereich der Beine'
     when 'door' then 'an der Seite zur Tür'
     when 'roof' then 'im Schulterbereich'
     else case seat when 'driver' then 'am Unterarm' when 'front' then 'am Handgelenk' else 'am Unterschenkel' end
   end;
 end if;
 blocked := kind = 'object' or access_code is distinct from 'none';

 -- Original Pkw records did not distinguish built-in descriptions from authored text.
 if not (p_model ? 'car_injury') then
   legacy_default := case profile
     when 'affected' then 'Keine Verletzung in dieser Übungsrolle. Die Person ist aufgewühlt.'
     when 'black' then 'Die Person reagiert nicht auf Ansprache.'
     when 'minor' then 'Die Person ist orientiert und klagt über eine schmerzhafte Prellung.'
     when 'urgent' then 'Die Person klagt über starke Schmerzen an einer Extremität. Verdacht auf eine Fraktur.'
     when 'urgent-red' then 'Die Person ist zunächst orientiert und klagt über Schmerzen nach einem Anprall.'
     when 'green-yellow' then 'Beim Aufprall ist mein Unterschenkel gegen den Sitz vor mir gestoßen. Ein paar Schritte gingen noch, aber es tut weh.'
     else 'Die Person ist blass, antwortet verzögert und wirkt zunehmend benommen.' end;
   additional := nullif(nullif(legacy_story, legacy_default), '');
 end if;
 -- Leave the injury site open when the trainer supplied an explicit description.
 pain_site := case when additional is not null or pain_site is null then '' else ' ' || pain_site end;

 if p_category = 'black' then
   condition := case when profile = 'red-ex' then 'Keine Reaktion mehr auf Ansprache.' else 'Keine Reaktion auf Ansprache.' end;
   findings := case when profile = 'red-ex'
     then 'Die Person, die zuvor noch reagiert hat, zeigt auf Ansprache keine erkennbare Reaktion mehr.'
     else 'Die Person zeigt auf Ansprache keine erkennbare Reaktion.' end
     || ' Es sind keine Atembewegungen erkennbar.';
   reason := 'Im Übungsmodell verstorben';
 elsif profile = 'affected' then
   condition := 'Ansprechbar und aufgewühlt. Keine Verletzung in dieser Übungsrolle.';
   findings := case when blocked
     then 'Die Person ist aufgewühlt und bittet darum, aus der Lage befreit zu werden. Sie gibt keine Verletzung an.'
     else 'Die Person ist aufgewühlt, möchte wissen, was passiert ist, und gibt keine Verletzung an.' end;
   if kind = 'object' then
     findings := 'Das Objekt ist abgestützt. Der enge Spalt hält die Person trotzdem fest. ' || findings;
   end if;
   reason := 'Unverletzt, aufgewühlt und betreuungsbedürftig';
 elsif profile = 'minor' or (profile = 'green-yellow' and p_category = 'green') then
   condition := 'Wach und orientiert. Leichte Schmerzen.';
   findings := format('Die Person antwortet klar und berichtet über leichte Schmerzen%s.', pain_site);
   if profile = 'green-yellow' and not blocked then
     findings := findings || ' Anfangs kann sie den betroffenen Bereich noch vorsichtig bewegen.';
   end if;
   reason := case when blocked then 'Im Übungsmodell leicht verletzt. Bewegung durch die Lage behindert. Nachsichtung vorgesehen.'
     else 'Im Übungsmodell leicht verletzt. Nachsichtung vorgesehen.' end;
 elsif profile in ('urgent', 'green-yellow') or (profile = 'urgent-red' and p_category = 'yellow') then
   condition := case profile when 'green-yellow' then 'Wach. Schmerzen nehmen zu, Bewegung schmerzt deutlich.'
     else 'Wach und orientiert. Deutliche Schmerzen.' end;
   findings := case profile
     when 'green-yellow' then format('Die Schmerzen%s haben deutlich zugenommen. Die Person schont den betroffenen Bereich.', pain_site)
     when 'urgent-red' then format('Die Person antwortet klar und klagt über Schmerzen%s.', pain_site)
       || case when additional is null then ' Sie berichtet auch über Beschwerden am Rumpf.' else '' end
     else format('Die Person klagt über starke Schmerzen%s und vermeidet Bewegungen im betroffenen Bereich.', pain_site)
       || case when additional is null then ' Es zeigt sich eine Schwellung.' else '' end
   end;
   reason := 'Schwer verletzt, ohne erkennbare vitale Bedrohung (Übungsmodell)';
 else
   condition := case profile when 'urgent-red' then 'Zunehmend blass und benommen. Antwortet verzögert.'
     else 'Blass und benommen. Reagiert verzögert auf Ansprache.' end;
   findings := case profile
     when 'urgent-red' then 'Die Person wird blass und kaltschweißig. Sie antwortet langsamer als zu Beginn.'
       || case when additional is null then ' Die Beschwerden am Rumpf haben zugenommen.' else '' end
     else 'Die Person ist blass und reagiert verzögert auf Ansprache.'
       || case when additional is null then ' Am Rumpf sind zusätzlich Anprallspuren zu sehen.'
          else '' end
   end;
   reason := 'Didaktische Einstufung: Zeichen eines kritischen Schocks';
 end if;
 return jsonb_build_object('story', concat_ws(' ', seat_description, access_description, findings),
   'condition', condition, 'reason', reason, 'additional', additional);
end;
$$;

-- xABCDE summaries are part of the exercise model. Never interpret free text as a confirmed finding.
create or replace function traumasim_private.primary_survey(
 p_model jsonb, p_patient text, p_category text, p_vitals jsonb, p_bp jsonb
) returns jsonb language plpgsql immutable set search_path = '' as $$
declare
 bus_seat text := case when p_patient ~ '^bus-(5|10)-[0-9]{2}$' then split_part(p_patient, '-', 3) end;
 profile text := coalesce(p_model->>'car_profile', case p_model->'progression'->>'to'
   when 'yellow' then 'green-yellow' when 'red' then 'urgent-red' when 'black' then 'red-ex'
 end);
 station boolean := p_patient like any (array['car-%', 'truck-%', 'object-%']);
 gcs integer := (p_vitals->>'g')::integer;
 pulse integer := (p_vitals->>'h')::integer;
 systolic integer := (p_bp->>'s')::integer;
 x_finding text := 'Keine kritische äußere Blutung im Fallprofil beschrieben.';
 a_finding text := 'Atemweg und HWS-Befund sind im Fallprofil nicht gesondert beschrieben.';
 b_finding text;
 c_finding text;
 d_finding text;
 e_finding text;
 focus text[] := '{}';
 risks text[] := '{}';
begin
 if p_model is null then return null; end if;

 if p_category = 'black' then
   b_finding := 'Keine Atembewegungen erkennbar.';
   c_finding := 'Kein Kreislauf im Übungsmodell dargestellt.';
   d_finding := 'Keine Reaktion auf Ansprache.';
   focus := array['B', 'C', 'D'];
 elsif p_category = 'affected' then
   b_finding := 'Keine Atembeschwerden im Fallprofil beschrieben.';
   c_finding := 'Keine Kreislaufbeschwerden im Fallprofil beschrieben.';
   d_finding := 'Ansprechbar und orientiert. Wirkt aufgewühlt.';
   e_finding := 'Unverletzt betroffen. Betreuung steht im Vordergrund.';
   focus := array['E'];
 else
   b_finding := format('AF %s/min · SpO₂ %s %%', p_vitals->>'r', p_vitals->>'o');
   c_finding := concat_ws(' · ', format('Puls %s/min', pulse),
     case when systolic is not null then format('letzter Blutdruck %s/%s mmHg', systolic, p_bp->>'d') end);
   d_finding := format('GCS %s', gcs);
   if gcs < 15 then focus := array_append(focus, 'D'); end if;
   if gcs <= 12 then
     risks := array_append(risks, 'A · Bei weiterer Bewusstseinseintrübung kann der Atemweg gefährdet werden.');
   end if;
 end if;

 if p_patient = 'fahrer' then
   e_finding := 'Bein im Fußraum eingeklemmt. Verdacht auf Becken- und Oberschenkelverletzung.';
   c_finding := 'Verdacht auf innere Blutung. ' || c_finding;
   focus := focus || array['C', 'E'];
   risks := array_append(risks, 'C · Fortschreitender Blutverlust mit zunehmender Kreislaufverschlechterung.');
 elsif p_patient = 'beifahrer' then
   b_finding := 'Schmerzen beim tiefen Einatmen. ' || b_finding;
   e_finding := 'Thoraxprellung im Übungsprofil.';
   focus := array['B', 'E'];
   risks := array_append(risks, 'B · Schmerzen können die Atemtiefe einschränken.');
 elsif bus_seat is not null and p_category not in ('affected', 'black') then
   e_finding := case bus_seat
     when '01' then 'Schmerz an der linken Schulter, Person gehfähig.'
     when '02' then 'Platzwunde an der Stirn und Kopfschmerzen.'
     when '03' then 'Linker Unterarm schmerzhaft, geschwollen und sichtbar verformt.'
     when '04' then 'Anprall an einer Sitzlehne mit Bauchbeschwerden. Äußerlich kaum Verletzungen sichtbar.'
     when '06' then 'Rechtes Knie schmerzhaft, aber belastbar.'
     when '07' then 'Linkes Sprunggelenk geschwollen. Auftreten ist nicht möglich.'
     when '08' then 'Schmerzen an der rechten Schulter, Arm in Schonhaltung.'
     when '09' then 'Seitlicher Druckschmerz an der Hüfte. Person gehfähig.'
     when '10' then 'Schmerzhafter Finger nach Einklemmung am Sitz.'
   end;
   focus := focus || array['E'];
   if bus_seat = '02' then
     d_finding := case when gcs <= 12 then 'Zunehmend schläfrig, antwortet nur noch knapp. '
       else 'Antwortet verzögert und ist desorientiert. ' end || d_finding;
     focus := focus || array['D'];
     risks := array_append(risks, 'D · Die Bewusstseinslage kann sich nach dem Kopfaufprall verschlechtern.');
   elsif bus_seat = '04' then
     if p_category = 'red' then
       c_finding := 'Blässe und Kreislaufauffälligkeiten nach dem Bauchanprall. ' || c_finding;
     end if;
     focus := focus || array['C'];
     risks := array_append(risks, 'C · Nach stumpfem Bauchtrauma ist eine verzögerte Kreislaufverschlechterung durch innere Blutung möglich.');
   end if;
 elsif station and p_category not in ('affected', 'black') then
   e_finding := case
     when profile = 'green-yellow' and p_category = 'yellow' then 'Zunehmende Schmerzen und eingeschränkte Beweglichkeit.'
     when profile = 'urgent' then 'Starke Schmerzen und Schonhaltung im betroffenen Bereich.'
     when profile in ('urgent-red', 'red-ex', 'critical') then 'Schmerzen oder Anprall nach dem Unfallmechanismus.'
     when p_category = 'green' then 'Leichte Schmerzen im betroffenen Bereich.'
     else 'Beschwerden nach dem Unfall; siehe Patientenstory.' end;
   if p_model->>'car_entrapment' not in ('none', 'enclosed') then
     e_finding := e_finding || ' Die Einklemmung begrenzt die Untersuchung.';
   elsif p_model->>'car_entrapment' = 'enclosed' then
     e_finding := e_finding || ' Die Person ist eingeschlossen.';
   end if;
   focus := focus || array['E'];
   if profile in ('urgent-red', 'red-ex', 'critical') then
     if p_category = 'red' then
       c_finding := 'Blässe und Hinweise auf Kreislaufverschlechterung. ' || c_finding;
       d_finding := 'Verzögerte Reaktion auf Ansprache. ' || d_finding;
       focus := focus || array['C', 'D'];
     end if;
     risks := array_append(risks, 'C/D · Zunehmende Kreislaufstörung und Bewusstseinseintrübung im Verlauf möglich.');
   elsif profile = 'green-yellow' and p_category = 'green' then
     risks := array_append(risks, 'E · Schmerzen können zunehmen und die Beweglichkeit einschränken.');
   end if;
 end if;

 return jsonb_build_object(
   'findings', jsonb_build_object('X', x_finding, 'A', a_finding, 'B', b_finding, 'C', c_finding, 'D', d_finding,
     'E', coalesce(e_finding, 'Weitere Verletzungen und Temperatur sind im Fallprofil nicht gesondert beschrieben.')),
   'focus', focus, 'risks', risks,
   'note', case when station then nullif(btrim(p_model->>'car_injury'), '') end
 );
end;
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
 static_black boolean;
 category text;
 triage_delay integer;
 condition_index integer;
 observation text;
 generated_story jsonb;
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
   and s.inactive_at is null and s.expires_at > clock_timestamp();
 if not found or p_patient is null
   or sha256(convert_to(case
        when exercise_access then traumasim_private.exercise_code(exercise.id, exercise.case_key, exercise.signing_key)
        when preview_access then traumasim_private.preview_code(exercise.id, p_patient, exercise.signing_key)
        else traumasim_private.patient_code(exercise.id, p_patient, exercise.signing_key) end, 'UTF8'))
        <> sha256(convert_to(p_code, 'UTF8')) then
   raise exception using errcode = '42501', message = 'Patientenzugang ungültig oder abgelaufen';
 end if;
 if exercise_access and p_patient like any (array['car-%', 'truck-%', 'object-%']) then
   raise exception using errcode = 'P0002', message = 'Für diesen Patienten ist der einzelne Stations-QR erforderlich.';
 end if;

 if p_start_revision is not null and not preview_access then
   -- Serialize starts with whole-exercise resets and instructor commands.
   select s.* into exercise from public.traumasim_sessions s
   where s.id = exercise.id and s.inactive_at is null and s.expires_at > clock_timestamp() for update;
   if not found or exercise.expires_at <= clock_timestamp() then
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
 static_black := model->'black' = 'true'::jsonb;
 -- Training timings follow the category available at the current patient time.
 triage_delay := case category when 'affected' then 10 when 'green' then 10 when 'yellow' then 20 else 35 end;
 condition_index := case
   when p_patient = 'beifahrer' then least(3, floor(seconds / 420)::integer)
   when (vitals->>'g')::integer <= 12 then 3
   when (vitals->>'s')::integer < 100 then 2
   when (vitals->>'h')::integer >= 110 then 1
   else 0 end;
 observation := case
   when static_black then 'Die Person reagiert nicht.'
   when category = 'black' then 'Die Person reagiert im Übungsmodell nicht mehr.'
   when progression->>'from' = 'green' then case category
     when 'green' then 'Wach und orientiert. Schmerzen am Unterschenkel, kann noch selbst gehen.'
     else 'Der Unterschenkel schwillt an. Die Schmerzen nehmen zu, Auftreten ist nicht mehr möglich.' end
   when progression->>'to' = 'red' and category = 'red' then 'Die Person wird blass und benommen. Der Kreislauf verschlechtert sich.'
   else model->'condition'->>condition_index end;
 generated_story := traumasim_private.station_story(model, p_patient, category);
 observation := coalesce(generated_story->>'condition', observation);
 -- The choice becomes available at the same time for every category.
 can_select := exercise.triage_mode = 'choose' and seconds >= 10;
 return jsonb_build_object(
   'exercise_id', exercise.id,
   'identity', patient.identity_profile,
   'revision', patient.revision,
   'status', case when patient.started_at is null then 'ready'
     when seconds >= duration then 'finished' when patient.paused_at is not null then 'paused' else 'running' end,
   'elapsed', floor(seconds),
   'server_time', snapshot_time,
   'triage_mode', exercise.triage_mode,
   'triage_selectable', can_select,
   'observation', case when can_select then observation end,
   'primary_survey', case when seconds >= least(120, duration) then
     traumasim_private.primary_survey(model, p_patient, category, vitals, bp_values) end,
   'triage', case when (exercise.triage_mode = 'automatic' and seconds >= triage_delay)
     or (can_select and p_seen_revision = patient.revision and p_selection in ('red', 'yellow', 'green', 'affected', 'black'))
     then jsonb_build_object(
     'category', category, 'red', category = 'red',
     'condition', observation,
     'reason', coalesce(generated_story->>'reason', case when category = 'black' then 'Im Übungsmodell verstorben'
       when affected then 'Unverletzt, aufgewühlt und betreuungsbedürftig'
       when category = 'red' then coalesce(model->>'triageReason', 'Didaktische Einstufung: Zeichen eines kritischen Schocks')
       when category = 'green' then 'Gehfähig; Nachsichtung vorgesehen'
       when patient.scenario_model is not null then 'Schwer verletzt, ohne erkennbare vitale Bedrohung (Übungsmodell)'
       when p_patient = 'beifahrer' then 'Schwer verletzt, zunächst ohne erkennbare vitale Bedrohung'
       else 'Schwere Verletzung, Kreislauf zunächst kompensiert' end)
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
   'title', exercise.title,
   'name', coalesce(case when p_patient like 'car-%' then
     'Pkw ' || (model->>'car_number') || ' – ' || coalesce(case model->>'car_seat'
       when 'driver' then 'Fahrer' when 'front' then 'Beifahrer'
       when 'rear-left' then 'hinten links' when 'rear-center' then 'hinten Mitte'
       when 'rear-right' then 'hinten rechts' end,
       (regexp_match(model->>'name', ' · (Fahrer|Beifahrer|hinten links|hinten Mitte|hinten rechts)(platz)?$'))[1])
     end, model->>'name'),
   'intro', case when model->>'station_kind' = 'truck' and model->>'car_entrapment' = 'door'
     then regexp_replace(model->>'intro', 'Tür und B-Säule eingeklemmt[.]$', 'Tür und Kabinenrahmen eingeklemmt.')
     when generated_story is not null and (model->>'car_seat' like 'rear-%'
       or model->>'name' ~ ' · hinten (links|Mitte|rechts)$')
     then regexp_replace(model->>'intro', 'zwischen Sitz und Armaturenbrett eingeklemmt[.]$',
       'im Bereich der hinteren Sitzreihe am verformten Vordersitz eingeklemmt.')
     else model->>'intro' end,
   'story', case
     when generated_story is not null then concat_ws(E'\n\n', generated_story->>'story',
       'Ergänzende Fallinformation: ' || (generated_story->>'additional'))
     when static_black then coalesce(nullif(model->>'story', ''), observation)
     when category = 'black' then 'Die Person gibt im Übungsmodell keine Antwort mehr.'
     else model->>'story' end,
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

create or replace function traumasim_private.student_mark_triage(
 p_case text, p_patient text, p_code text, p_seen_revision integer
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 marked_at timestamptz := clock_timestamp();
 snapshot jsonb;
 exercise public.traumasim_sessions%rowtype;
begin
 snapshot := traumasim_private.student_snapshot(p_case, p_patient, p_code, null, null, null);
 if split_part(p_code, '.', 2) like 'p%'
    or snapshot->'triage_selectable' is distinct from 'true'::jsonb
    or (snapshot->>'revision')::integer is distinct from p_seen_revision then
   return jsonb_build_object('recorded', false);
 end if;

 -- Recheck the timing reference, mode and patient revision while serialized with trainer actions.
 select s.* into exercise from public.traumasim_sessions s
 where s.id = (snapshot->>'exercise_id')::uuid and s.inactive_at is null and s.expires_at > clock_timestamp() for update;
 if not found or exercise.triage_mode <> 'choose' or exercise.arrived_at is null
    or exercise.arrived_at > marked_at or exercise.expires_at <= clock_timestamp() then
   return jsonb_build_object('recorded', false);
 end if;
 update public.traumasim_patients p
 set first_triage_at = least(p.first_triage_at, marked_at)
 where p.session_id = exercise.id and p.patient_key = p_patient and p.revision = p_seen_revision;
 return jsonb_build_object('recorded', found);
end;
$$;

create table if not exists traumasim_private.trainer_access_requests (
 email text primary key,
 requested_at timestamptz not null default now(),
 invite_hash text unique,
 expires_at timestamptz,
 activation_id uuid,
 activation_until timestamptz,
 completed_at timestamptz,
 activated_user_id uuid references auth.users(id) on delete cascade
);
alter table traumasim_private.trainer_access_requests enable row level security;
revoke all on traumasim_private.trainer_access_requests from public, anon, authenticated;

create or replace function traumasim_private.require_trainer()
returns uuid language plpgsql stable set search_path = '' as $$
declare
 trainer uuid := auth.uid();
begin
 if not exists (
   select 1 from auth.users u
   join traumasim_private.trainers t on t.email = lower(u.email)
   left join traumasim_private.trainer_access_requests r on r.email = t.email and r.completed_at is not null
   where u.id = trainer and u.email_confirmed_at is not null
     and (r.email is null or (r.activated_user_id = u.id and exists (
       select 1 from auth.sessions s where s.user_id = u.id and s.id::text = auth.jwt()->>'session_id'
         and s.created_at >= r.completed_at
     )))
 ) then
   raise exception using errcode = '42501', message = 'Konto nicht für die Ausbilderansicht freigegeben';
 end if;
 return trainer;
end;
$$;

create or replace function traumasim_private.list_overview(p_trainer uuid, p_now timestamptz)
returns jsonb language sql stable set search_path = '' as $$
 with entries as (
   select s.id, s.title, s.case_key, s.expires_at, s.inactive_at,
     least(p_now, s.expires_at, s.inactive_at) as course_at,
     case when s.inactive_at is null and s.expires_at > p_now then 'active' else 'inactive' end as section,
     case when s.inactive_at is null and s.expires_at > p_now then s.created_at
       else coalesce(s.inactive_at, s.expires_at) end as sort_at,
     null::jsonb as saved_patients
   from public.traumasim_sessions s where s.trainer_id = p_trainer
   union all
   select t.id, t.title, t.case_key, null, null, p_now, 'templates', t.created_at, t.patients
   from traumasim_private.exercise_templates t where t.trainer_id = p_trainer
 ), roster as (
   select e.id, e.section, p.patient_key, p.scenario_model, p.started_at,
     p.paused_at, p.accumulated_pause_seconds
   from entries e join public.traumasim_patients p on p.session_id = e.id
   where e.section <> 'templates'
   union all
   select e.id, e.section, p.patient_key, p.scenario_model, null, null, 0
   from entries e
   cross join lateral jsonb_to_recordset(e.saved_patients) as p(patient_key text, scenario_model jsonb)
   where e.section = 'templates'
 ), summaries as (
   select e.id, e.section,
     jsonb_build_object(
       'car', count(distinct case when p.patient_key like 'car-%' then split_part(p.patient_key, '-', 2)
         when e.case_key = 'vu-baum' and p.patient_key in ('fahrer', 'beifahrer') then 'preset' end),
       'truck', count(distinct split_part(p.patient_key, '-', 2)) filter (where p.patient_key like 'truck-%'),
       'bus', count(distinct split_part(p.patient_key, '-', 2)) filter (where p.patient_key like 'bus-%'),
       'object', count(distinct split_part(p.patient_key, '-', 2)) filter (where p.patient_key like 'object-%'),
       'patients', count(p.patient_key)
     ) as counts,
     jsonb_build_object(
       'red', count(*) filter (where category.value = 'red'),
       'yellow', count(*) filter (where category.value = 'yellow'),
       'green', count(*) filter (where category.value = 'green'),
       'affected', count(*) filter (where category.value = 'affected'),
       'black', count(*) filter (where category.value = 'black')
     ) as categories
   from entries e
   left join roster p on p.id = e.id and p.section = e.section
   left join traumasim_private.models m on m.case_key = e.case_key and m.patient_key = p.patient_key
   cross join lateral (select coalesce(p.scenario_model, m.model) as model) patient_model
   cross join lateral (select least(traumasim_private.patient_duration(patient_model.model),
     traumasim_private.elapsed(p.started_at, least(p.paused_at, e.course_at), p.accumulated_pause_seconds, e.course_at)
   ) as seconds) t
   cross join lateral (select case when p.patient_key is not null then
     traumasim_private.patient_category(patient_model.model, p.patient_key, p.scenario_model is not null,
       t.seconds, traumasim_private.vitals(patient_model.model, t.seconds)) end as value) category
   group by e.id, e.section
 ), overview as (
   select e.section, e.sort_at, e.id,
     jsonb_build_object('id', e.id, 'title', e.title, 'counts', s.counts, 'categories', s.categories)
     || case when e.section = 'templates' then '{}'::jsonb
       else jsonb_build_object('expires_at', e.expires_at, 'inactive_at', e.inactive_at) end as item
   from entries e join summaries s on s.id = e.id and s.section = e.section
 )
 select jsonb_build_object(
   'active', coalesce(jsonb_agg(item order by sort_at desc, id) filter (where section = 'active'), '[]'::jsonb),
   'inactive', coalesce(jsonb_agg(item order by sort_at desc, id) filter (where section = 'inactive'), '[]'::jsonb),
   'templates', coalesce(jsonb_agg(item order by sort_at desc, id) filter (where section = 'templates'), '[]'::jsonb)
 )
 from overview;
$$;

create or replace function traumasim_private.exercise_report(p_exercise public.traumasim_sessions, p_now timestamptz)
returns jsonb language sql stable set search_path = '' as $$
 with timing as (
   select p_exercise.inactive_at is null and p_exercise.expires_at > p_now as active,
     least(p_now, p_exercise.expires_at, p_exercise.inactive_at) as course_at
 )
 select jsonb_build_object(
   'id', p_exercise.id,
   'title', p_exercise.title,
   'active', timing.active,
   'created_at', p_exercise.created_at,
   'ended_at', case when not timing.active then coalesce(p_exercise.inactive_at, p_exercise.expires_at) end,
   'arrived_at', p_exercise.arrived_at,
   'patients', coalesce((
     select jsonb_agg(jsonb_build_object(
       'id', p.patient_key,
       'identity', p.identity_profile,
       'name', coalesce(nullif(patient_model.model->>'name', ''), case
         when p_exercise.case_key = 'vu-baum' and p.patient_key = 'fahrer' then 'Fahrer'
         when p_exercise.case_key = 'vu-baum' and p.patient_key = 'beifahrer' then 'Beifahrer'
         else p.patient_key end),
       'status', case when p.started_at is null then 'ready'
         when t.seconds >= patient_model.duration then 'finished'
         when p.paused_at is not null or not timing.active then 'paused' else 'running' end,
       'category', traumasim_private.patient_category(patient_model.model, p.patient_key, p.scenario_model is not null,
         t.seconds, traumasim_private.vitals(patient_model.model, t.seconds)),
       'elapsed', floor(t.seconds),
       'first_triage_seconds', floor(extract(epoch from (p.first_triage_at - p_exercise.arrived_at)))
     ) order by p.patient_key)
     from public.traumasim_patients p
     left join traumasim_private.models m on m.case_key = p_exercise.case_key and m.patient_key = p.patient_key
     cross join lateral (select coalesce(p.scenario_model, m.model) as model,
       traumasim_private.patient_duration(coalesce(p.scenario_model, m.model)) as duration) patient_model
     cross join lateral (select least(patient_model.duration,
       traumasim_private.elapsed(p.started_at, least(p.paused_at, timing.course_at),
         p.accumulated_pause_seconds, timing.course_at)) as seconds) t
     where p.session_id = p_exercise.id
   ), '[]'::jsonb)
 )
 from timing;
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
 renamed_title text;
 snapshot_time timestamptz;
 archive_time timestamptz;
 exercise_active boolean;
 selected_email text;
 recipient_account uuid;
 share_token text;
 result jsonb;
begin

 if p_action = 'shared_report' then
   if p_title is null or p_title !~ '^[0-9a-f]{64}$' then
     raise exception using errcode = '42501', message = 'Freigabe nicht verfügbar.';
   end if;
   select traumasim_private.exercise_report(s, clock_timestamp()) into result
   from traumasim_private.exercise_shares sh
   join public.traumasim_sessions s on s.id = sh.session_id
   join auth.users u on u.id = sh.recipient_id and lower(u.email) = sh.recipient_email
   where sh.token_hash = sha256(decode(p_title, 'hex')) and u.id = trainer and u.email_confirmed_at is not null;
   if not found then
     raise exception using errcode = '42501', message = 'Freigabe nicht verfügbar.';
   end if;
   return result;
 end if;

 if p_action = 'list_overview' then
   return traumasim_private.list_overview(trainer, clock_timestamp());
 end if;

 if p_action = 'list' then
   select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'expires_at', s.expires_at)
     order by s.created_at desc), '[]'::jsonb) into result
   from public.traumasim_sessions s
   where s.trainer_id = trainer and s.inactive_at is null and s.expires_at > clock_timestamp();
   return result;
 end if;

 if p_action = 'list_templates' then
   select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title)
     order by t.created_at desc), '[]'::jsonb) into result
   from traumasim_private.exercise_templates t where t.trainer_id = trainer;
   return result;
 end if;

 if (p_action in ('create', 'create_empty', 'save_template') or (p_action = 'start_template' and p_title is not null))
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
 elsif p_action = 'create_empty' then
   new_session_id := gen_random_uuid();
   insert into public.traumasim_sessions (id, title, trainer_id, case_key)
   values (new_session_id, btrim(p_title), trainer, 'custom-' || new_session_id::text)
   returning * into exercise;
 elsif p_action = 'create' then
   insert into public.traumasim_sessions (title, trainer_id)
   values (btrim(p_title), trainer) returning * into exercise;
   insert into public.traumasim_patients (session_id, patient_key)
   select exercise.id, m.patient_key from traumasim_private.models m where m.case_key = exercise.case_key;
 else
   select s.* into exercise
   from public.traumasim_sessions s
   where s.id = p_session and s.trainer_id = trainer
   for update;
   if not found then
     raise exception using errcode = '42501', message = 'Übung nicht verfügbar oder abgelaufen';
   end if;

   snapshot_time := clock_timestamp();
   exercise_active := exercise.inactive_at is null and exercise.expires_at > snapshot_time;
   if p_action = 'archive_report' then
     if exercise_active then
       raise exception using errcode = '22023', message = 'Der Archivbericht ist nur bei inaktiven Übungen verfügbar.';
     end if;
     return traumasim_private.exercise_report(exercise, snapshot_time);
   end if;

   if p_action = 'share_list' then
     select coalesce(jsonb_agg(jsonb_build_object('email', sh.recipient_email, 'created_at', sh.created_at)
       order by sh.created_at desc, sh.recipient_email), '[]'::jsonb) into result
     from traumasim_private.exercise_shares sh where sh.session_id = exercise.id;
     return result;
   end if;

   if p_action in ('share_create', 'share_revoke') then
     selected_email := lower(regexp_replace(p_title, '^[[:space:]]+|[[:space:]]+$', '', 'g'));
     if selected_email is null or length(selected_email) not between 3 and 254
       or position('@' in selected_email) < 2 then
       raise exception using errcode = '22023', message = 'Gib eine gültige E-Mail-Adresse an.';
     end if;
     if p_action = 'share_revoke' then
       delete from traumasim_private.exercise_shares sh
       where sh.session_id = exercise.id and sh.recipient_email = selected_email;
       return jsonb_build_object('email', selected_email, 'revoked', true);
     end if;
     select (array_agg(u.id))[1] into recipient_account
     from auth.users u
     join traumasim_private.trainers t on t.email = lower(u.email)
     where t.email = selected_email and u.email_confirmed_at is not null
     having count(*) = 1;
     if not found then
       raise exception using errcode = '22023', message = 'Für diese Adresse ist kein bestätigtes Ausbilderkonto verfügbar.';
     end if;
     share_token := traumasim_private.new_share_token();
     insert into traumasim_private.exercise_shares (session_id, recipient_id, recipient_email, token_hash, created_at)
     values (exercise.id, recipient_account, selected_email, sha256(decode(share_token, 'hex')), snapshot_time)
     on conflict (session_id, recipient_email) do update
     set recipient_id = excluded.recipient_id, token_hash = excluded.token_hash, created_at = excluded.created_at;
     return jsonb_build_object('token', share_token, 'email', selected_email);
   end if;

   if p_action in ('reactivate', 'delete_exercise') then
     if exercise_active then
       raise exception using errcode = '22023', message = 'Diese Aktion ist nur bei inaktiven Übungen möglich.';
     end if;
   elsif not exercise_active then
     raise exception using errcode = '42501', message = 'Übung nicht verfügbar oder abgelaufen';
   end if;

   if p_action in ('reset', 'pause', 'resume', 'mark_triage') and not exists (
     select 1 from public.traumasim_patients p where p.session_id = exercise.id and p.patient_key = p_patient
   ) then
     raise exception using errcode = '22023', message = 'Patient gehört nicht zu dieser Übung';
   end if;
   case p_action
     when 'status' then null;
     when 'rename_exercise' then
       renamed_title := regexp_replace(p_title, '^[[:space:]]+|[[:space:]]+$', '', 'g');
       if renamed_title is null or length(renamed_title) not between 1 and 120 then
         raise exception using errcode = '22023', message = 'Der Titel muss 1 bis 120 Zeichen enthalten.';
       end if;
       update public.traumasim_sessions s set title = renamed_title where s.id = exercise.id
       returning s.* into exercise;
     when 'start_arrival' then
       if exercise.arrived_at is null then
         update public.traumasim_sessions s set arrived_at = snapshot_time where s.id = exercise.id
         returning s.* into exercise;
       end if;
     when 'clear_arrival' then
       update public.traumasim_sessions s set arrived_at = null where s.id = exercise.id
       returning s.* into exercise;
       update public.traumasim_patients p set first_triage_at = null
       where p.session_id = exercise.id and p.first_triage_at is not null;
     when 'mark_triage' then
       if exercise.arrived_at is null then
         raise exception using errcode = '22023', message = 'Erfasse zuerst die Ankunft am Einsatzort.';
       end if;
       update public.traumasim_patients p set first_triage_at = snapshot_time
       where p.session_id = exercise.id and p.patient_key = p_patient and p.first_triage_at is null;
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
     when 'close', 'reactivate' then
       archive_time := case when p_action = 'close' then snapshot_time
         else coalesce(exercise.inactive_at, exercise.expires_at) end;
       update public.traumasim_patients p
       set paused_at = greatest(p.started_at, archive_time), updated_at = snapshot_time
       where p.session_id = exercise.id and p.started_at is not null and p.paused_at is null
         and traumasim_private.elapsed(p.started_at, null, p.accumulated_pause_seconds, archive_time)
           < traumasim_private.patient_duration(p.scenario_model);
       if p_action = 'close' then
         update public.traumasim_sessions s set inactive_at = archive_time where s.id = exercise.id;
         return jsonb_build_object('id', exercise.id, 'closed', true);
       end if;
       update public.traumasim_sessions s set inactive_at = null, expires_at = snapshot_time + interval '24 hours'
       where s.id = exercise.id returning s.* into exercise;
     when 'delete_exercise' then
       delete from public.traumasim_sessions s where s.id = exercise.id;
       return jsonb_build_object('id', exercise.id, 'deleted', true);
     when 'reset', 'reset_all' then
       update public.traumasim_patients
       set started_at = null, paused_at = null, accumulated_pause_seconds = 0,
           state = '{}'::jsonb, updated_at = snapshot_time, revision = revision + 1, first_triage_at = null
       where session_id = exercise.id and (p_action = 'reset_all' or patient_key = p_patient);
       if p_action = 'reset_all' then
         update public.traumasim_sessions s set arrived_at = null where s.id = exercise.id
         returning s.* into exercise;
       end if;
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
   'identity', p.identity_profile,
   'code', traumasim_private.patient_code(exercise.id, p.patient_key, exercise.signing_key),
   'preview_code', traumasim_private.preview_code(exercise.id, p.patient_key, exercise.signing_key),
   'model', patient_model.model,
   'primary_survey', traumasim_private.primary_survey(patient_model.model, p.patient_key,
     live_survey.category, live_vitals.sample, live_survey.bp),
   'station_stories', case when initial_story.payload is not null then jsonb_build_object(
     'before', initial_story.payload - 'additional',
     'after', case when patient_model.model->'progression'->>'to' is not null
       then traumasim_private.station_story(patient_model.model, p.patient_key,
         patient_model.model->'progression'->>'to') - 'additional' end,
     'additional', initial_story.payload->'additional'
   ) end,
   'custom', p.scenario_model is not null,
   'elapsed', floor(t.seconds),
   'first_triage_seconds', floor(extract(epoch from (p.first_triage_at - exercise.arrived_at))),
   'category', case when p.started_at is not null then live_survey.category end,
   'status', case when p.started_at is null then 'ready'
     when t.seconds >= limit_time.duration then 'finished' when p.paused_at is not null then 'paused' else 'running' end
 ) order by p.patient_key) into result
 from public.traumasim_patients p
 left join traumasim_private.models m on m.case_key = exercise.case_key and m.patient_key = p.patient_key
 cross join lateral (select coalesce(p.scenario_model, m.model) as model) patient_model
 cross join lateral (select case when p.patient_key like any (array['car-%', 'truck-%', 'object-%'])
   then traumasim_private.station_story(patient_model.model, p.patient_key,
     coalesce(patient_model.model->'progression'->>'from',
       traumasim_private.patient_category(patient_model.model, p.patient_key, true, 0,
         traumasim_private.vitals(patient_model.model, 0))))
   end as payload) initial_story
 cross join lateral (select traumasim_private.patient_duration(p.scenario_model) as duration) limit_time
 cross join lateral (select least(limit_time.duration,
   traumasim_private.elapsed(p.started_at, p.paused_at, p.accumulated_pause_seconds, snapshot_time)) as seconds) t
 cross join lateral (select traumasim_private.vitals(patient_model.model, t.seconds) as sample,
   case when patient_model.model->'nibpFastCycle' = 'true'::jsonb then 180 else 300 end as bp_interval) live_vitals
 cross join lateral (select
   traumasim_private.patient_category(patient_model.model, p.patient_key, p.scenario_model is not null,
     t.seconds, live_vitals.sample) as category,
   case when t.seconds >= 70 then traumasim_private.vitals(patient_model.model,
     70 + floor((t.seconds - 70) / live_vitals.bp_interval) * live_vitals.bp_interval) end as bp
 ) live_survey
 where p.session_id = exercise.id;
 return jsonb_build_object('id', exercise.id, 'title', exercise.title, 'case', exercise.case_key,
   'expires_at', exercise.expires_at, 'patients', coalesce(result, '[]'::jsonb), 'triage_mode', exercise.triage_mode,
   'arrived_at', exercise.arrived_at, 'server_time', snapshot_time,
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
   foreach field in array array['affected', 'black'] loop
     if model ? field and jsonb_typeof(model->field) <> 'boolean' then
       raise exception using errcode = '22023', message = 'Die Kennzeichen für unverletzt betroffene und verstorbene Personen sind ungültig.';
     end if;
   end loop;
   if model->'affected' = 'true'::jsonb and model->'black' = 'true'::jsonb then
     raise exception using errcode = '22023', message = 'Wähle für eine Person entweder unverletzt betroffen oder SK Schwarz.';
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
     'black', coalesce(model->'black' = 'true'::jsonb, false),
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
   where s.id = p_session and s.trainer_id = trainer and s.inactive_at is null
     and s.expires_at > clock_timestamp() for update;
   if not found or exercise.expires_at <= clock_timestamp() then
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
 station_kind text := case when p_config ? 'kind' then p_config->>'kind' else 'car' end;
 station_prefix text := station_kind || '-';
 station_name text;
 seats text[];
 seat_names text[] := array['Fahrerplatz','Beifahrerplatz','hinten links','hinten Mitte','hinten rechts'];
 occupants jsonb := p_config->'occupants';
 vehicle text := nullif(btrim(p_config->>'vehicle'), '');
 vehicle_description text := case when station_kind in ('car', 'truck')
   then nullif(btrim(p_config->>'vehicle_description'), '') end;
 existing_vehicle_description text;
 object_type text := p_config->>'object_type';
 object_position text := p_config->>'object_position';
 object_name text;
 object_location text;
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
 location_description text;
 station_patient_key text;
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
   raise exception using errcode = '22023', message = 'Die Stationskonfiguration ist ungültig.';
 end if;
 case station_kind
   when 'car' then
     station_name := 'Pkw';
     seats := array['driver','front','rear-left','rear-center','rear-right'];
   when 'truck' then
     station_name := 'Lkw';
     seats := array['driver','front'];
   when 'object' then
     station_name := 'Einklemmung';
     seats := array['patient'];
     seat_names := array['Einklemmung'];
     object_name := case object_type
       when 'beam' then 'einem Betonträger'
       when 'skip' then 'einer Mulde'
       when 'car' then 'einem Pkw'
       when 'car-bike' then 'einem Pkw'
       when 'truck' then 'einem Lkw'
       when 'bus' then 'einem Bus'
       when 'machine' then 'einer Maschine'
     end;
     object_location := case object_position
       when 'under' then 'unter ' || object_name
         || case when object_type = 'car-bike' then ' neben einem Fahrrad' else '' end
       when 'between' then 'zwischen ' || object_name
         || case when object_type = 'car-bike' then ' und einem Fahrrad' else ' und einem Hindernis' end
     end;
     if object_location is null then
       raise exception using errcode = '22023', message = 'Wähle ein Objekt und die Lage der Einklemmung.';
     end if;
   else
     raise exception using errcode = '22023', message = 'Die Stationsart ist ungültig.';
 end case;
 if station_kind in ('car', 'truck') and (jsonb_typeof(p_config->'vehicle_description') not in ('string', 'null')
    or length(vehicle_description) > 120) then
   raise exception using errcode = '22023', message = 'Die Fahrzeugbeschreibung darf bis zu 120 Zeichen enthalten.';
 end if;
 if jsonb_array_length(occupants) not between 1 and cardinality(seats) then
   raise exception using errcode = '22023', message = case station_kind
     when 'car' then 'Wähle mindestens einen und höchstens fünf besetzte Sitzplätze.'
     when 'truck' then 'Wähle mindestens einen und höchstens zwei besetzte Sitzplätze.'
     else 'Eine Einklemmung an einem Objekt benötigt genau einen Patienten.'
   end;
 end if;
 if (select count(distinct item->>'seat') from jsonb_array_elements(occupants) item) <> jsonb_array_length(occupants) then
   raise exception using errcode = '22023', message = 'Jeder Sitzplatz darf nur einmal besetzt sein.';
 end if;
 if edit_car and (p_session is null or coalesce(p_config->>'car_number', '') !~ '^[1-9][0-9]?$'
    or coalesce(p_config->>'edit_version', '') !~ '^[0-9]{1,9}$') then
   raise exception using errcode = '22023', message = 'Die Stationsauswahl ist ungültig.';
 end if;

 if p_session is null then
   exercise.id := gen_random_uuid();
   insert into public.traumasim_sessions (id, title, case_key, trainer_id)
   values (exercise.id, case when station_kind = 'object' then 'Einklemmung an einem Objekt'
     else station_name || '-Lage' end, 'custom-' || exercise.id::text, trainer);
 else
   select s.* into exercise from public.traumasim_sessions s
   where s.id = p_session and s.trainer_id = trainer and s.inactive_at is null
     and s.expires_at > clock_timestamp() for update;
   if not found or exercise.expires_at <= clock_timestamp() then
     raise exception using errcode = '42501', message = 'Übung nicht verfügbar oder abgelaufen';
   end if;
 end if;

 if edit_car then
   car_no := (p_config->>'car_number')::integer;
   select count(*), bool_or(p.started_at is not null),
          max(coalesce((p.scenario_model->>'car_edit_version')::integer, 0)),
          max(greatest((p.scenario_model->>'car_patient_number')::bigint,
                       (p.scenario_model->>'car_patient_sequence')::bigint)),
          max(p.scenario_model->>'car_vehicle_description')
   into existing_count, has_started, edit_version, last_person_no, existing_vehicle_description
   from public.traumasim_patients p
   where p.session_id = exercise.id and p.patient_key like station_prefix || '%'
     and (p.scenario_model->>'car_number')::integer = car_no;
   if existing_count = 0 then
     raise exception using errcode = '22023', message = 'Die Station wurde in dieser Übung nicht gefunden.';
   end if;
   if has_started then
     raise exception using errcode = '22023', message = 'Setze die gestarteten Patienten dieser Station zuerst zurück.';
   end if;
   if edit_version <> (p_config->>'edit_version')::integer then
     raise exception using errcode = '40001', message = 'Die Station wurde zwischenzeitlich bearbeitet. Öffne die Bearbeitung erneut.';
   end if;
   -- Older clients only submit the Lage field when editing.
   if station_kind in ('car', 'truck') and not (p_config ? 'vehicle_description') then
     vehicle_description := existing_vehicle_description;
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
   from public.traumasim_patients p where p.session_id = exercise.id and p.patient_key like station_prefix || '%';
 end if;
 if (select count(*) from public.traumasim_patients p where p.session_id = exercise.id)
    - existing_count + jsonb_array_length(occupants) > 30 then
   raise exception using errcode = '22023', message = 'Eine Übung unterstützt insgesamt bis zu 30 Patienten.';
 end if;
 car_label := lpad(car_no::text, 2, '0');

 if edit_car then
   delete from public.traumasim_patients p
   where p.session_id = exercise.id and p.patient_key like station_prefix || '%'
     and (p.scenario_model->>'car_number')::integer = car_no
     and not exists (select 1 from jsonb_array_elements(occupants) item
                     where item->>'patient_number' = p.scenario_model->>'car_patient_number');
 end if;

 for person in select value from jsonb_array_elements(occupants)
   order by array_position(seats, value->>'seat') loop
   seat_name := seat_names[array_position(seats, person->>'seat')];
   profile := person->>'profile';
   if station_kind = 'object' then
     entrapment := case person->>'entrapment'
       when 'left-arm' then 'mit dem linken Arm'
       when 'right-arm' then 'mit dem rechten Arm'
       when 'both-arms' then 'mit beiden Armen'
       when 'left-leg' then 'mit dem linken Bein'
       when 'right-leg' then 'mit dem rechten Bein'
       when 'both-legs' then 'mit beiden Beinen'
     end;
     location_description := format('Die Person ist %s %s eingeklemmt.', entrapment, object_location);
   else
     entrapment := case person->>'entrapment'
       when 'none' then 'frei zugänglich, keine Einklemmung'
       when 'enclosed' then 'eingeschlossen, Ausstieg versperrt'
       when 'door' then 'im Bereich von Tür und B-Säule eingeklemmt'
       when 'footwell' then 'mit einem Bein im deformierten Fußraum eingeklemmt'
       when 'dashboard' then 'zwischen Sitz und Armaturenbrett eingeklemmt'
       when 'roof' then 'im Bereich von Dach und Sitz eingeklemmt'
     end;
     location_description := format('Sitzplatz %s, %s.', seat_name, entrapment);
   end if;
   if seat_name is null or profile is null or profile not in ('affected','black','minor','urgent','critical','green-yellow','urgent-red','red-ex')
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
     when 'black' then 'Die Person reagiert nicht auf Ansprache.'
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
   elsif profile = 'black' then
     select jsonb_agg(jsonb_build_object('t', minute, 's', 0, 'd', 0, 'h', 0, 'r', 0, 'o', 0, 'g', 3)
       order by minute)
     into points from generate_series(0, 25, 5) minute;
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
   station_patient_key := station_prefix || car_label || '-' || person_label;
   patient_model := jsonb_build_object(
     'name', format('%s %s · Patient %s', station_name, car_label, person_label)
       || case when station_kind = 'object' then '' else ' · ' || seat_name end,
     'intro', concat_ws(' ', case when vehicle_description is not null then
       format('Fahrzeug: %s. Lage: %s.', rtrim(vehicle_description, '.'), coalesce(rtrim(vehicle, '.'), 'Vor Ort erkunden'))
       when vehicle is not null then rtrim(vehicle, '.') || '.'
       when station_kind <> 'object' then 'Fahrzeuglage vor Ort erkunden.' end, location_description),
     'story', injury,
     'questions', '',
     'secret', case when station_kind = 'object' then format('%s %s · %s %s', station_name, car_label, location_description, injury)
       else format('%s %s · %s · %s. %s', station_name, car_label, seat_name, entrapment, injury) end,
     'car_number', car_no, 'car_patient_number', person_no, 'car_patient_sequence', last_booked_person_no,
     'car_vehicle', vehicle,
     'car_seat', person->>'seat', 'car_profile', profile, 'car_entrapment', person->>'entrapment',
     'car_injury', nullif(btrim(person->>'injury'), ''), 'car_edit_version', edit_version,
     'affected', profile = 'affected', 'black', profile = 'black', 'walkable', profile in ('affected','minor'),
     'nibpFastCycle', profile in ('critical','urgent-red','red-ex'),
     'progression', progression, 'points', points
   );
   if station_kind <> 'car' then
     patient_model := patient_model || jsonb_build_object('station_kind', station_kind);
   end if;
   if station_kind = 'object' then
     patient_model := patient_model || jsonb_build_object('object_type', object_type, 'object_position', object_position);
   elsif vehicle_description is not null then
     patient_model := patient_model || jsonb_build_object('car_vehicle_description', vehicle_description);
   end if;
   if retain_person then
     update public.traumasim_patients p
     set scenario_model = patient_model, updated_at = clock_timestamp()
     where p.session_id = exercise.id and p.patient_key = station_patient_key
       and (p.scenario_model->>'car_number')::integer = car_no;
     if not found then
       raise exception using errcode = '22023', message = 'Eine Person wurde an dieser Station nicht gefunden.';
     end if;
   else
     insert into public.traumasim_patients (session_id, patient_key, scenario_model)
     values (exercise.id, station_patient_key, patient_model);
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

create or replace function public.traumasim_student_mark_triage(
 p_case text, p_patient text, p_code text, p_seen_revision integer
) returns jsonb language sql security invoker set search_path = '' as $$
 select traumasim_private.student_mark_triage(p_case, p_patient, p_code, p_seen_revision);
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
revoke all on function public.traumasim_student_mark_triage(text, text, text, integer) from public, anon, authenticated;
revoke all on function public.traumasim_trainer(text, uuid, text, text) from public, anon, authenticated;
grant usage on schema traumasim_private to anon, authenticated;
grant execute on function traumasim_private.join_exercise(text) to anon, authenticated;
grant execute on function public.traumasim_join(text) to anon, authenticated;
grant execute on function traumasim_private.student(text, text, text, integer) to anon, authenticated;
grant execute on function traumasim_private.trainer(text, uuid, text, text) to authenticated;
grant execute on function public.traumasim_student(text, text, text, integer) to anon, authenticated;
grant execute on function traumasim_private.student_assess(text, text, text, text, integer),
 public.traumasim_student_assess(text, text, text, text, integer) to anon, authenticated;
grant execute on function traumasim_private.student_mark_triage(text, text, text, integer),
 public.traumasim_student_mark_triage(text, text, text, integer) to anon, authenticated;
grant execute on function traumasim_private.create_custom(jsonb) to authenticated;
grant execute on function traumasim_private.book_bus(integer, uuid), public.traumasim_book_bus(integer, uuid) to authenticated;
grant execute on function traumasim_private.book_car(jsonb, uuid), public.traumasim_book_car(jsonb, uuid) to authenticated;
grant execute on function public.traumasim_create_custom(jsonb) to authenticated;
grant execute on function public.traumasim_trainer(text, uuid, text, text) to authenticated;

create or replace function traumasim_private.request_trainer_access(p_email text)
returns void language plpgsql security definer set search_path = '' as $$
declare
 address text := lower(btrim(p_email));
begin
 if address is null or length(address) > 254 or address !~ '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9-]+([.][a-z0-9-]+)+$' then
   raise exception using errcode = '22023', message = 'Gib eine gültige E-Mail-Adresse ein.';
 end if;
 if not exists (
   select 1 from auth.users u join traumasim_private.trainers t on t.email = lower(u.email)
   where t.email = address and u.email_confirmed_at is not null
 ) then
   insert into traumasim_private.trainer_access_requests (email) values (address)
   on conflict (email) do update set requested_at = now()
   where trainer_access_requests.completed_at is null
     and trainer_access_requests.requested_at < now() - interval '30 days';
 end if;
end;
$$;

create or replace function traumasim_private.manage_trainer_access(p_action text, p_email text, p_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 owner_id uuid := traumasim_private.require_trainer();
begin
 if not exists (select 1 from auth.users where id = owner_id and lower(email) = 'phillip.ritter@gmail.com') then
   raise exception using errcode = '42501', message = 'Die Kontofreigabe ist dem Projektinhaber vorbehalten.';
 end if;
 if p_action = 'list' then
   return coalesce((select jsonb_agg(jsonb_build_object('email', r.email,
     'expires_at', r.expires_at) order by r.requested_at desc)
     from (select email, expires_at, requested_at from traumasim_private.trainer_access_requests
       where completed_at is null and requested_at >= now() - interval '30 days'
       order by requested_at desc limit 100) r), '[]'::jsonb);
 end if;
 if p_action = 'approve' then
   if p_hash is null or p_hash !~ '^[a-f0-9]{64}$' then
     raise exception using errcode = '22023', message = 'Die Einladung konnte nicht erstellt werden.';
   end if;
   update traumasim_private.trainer_access_requests
   set invite_hash = p_hash, expires_at = now() + interval '72 hours', activation_id = null, activation_until = null
   where email = p_email and completed_at is null and (activation_until is null or activation_until < now())
     and not exists (
       select 1 from auth.users u join traumasim_private.trainers t on t.email = lower(u.email)
       where t.email = p_email and u.email_confirmed_at is not null
     );
 elsif p_action = 'dismiss' then
   delete from traumasim_private.trainer_access_requests where email = p_email
     and completed_at is null and (activation_until is null or activation_until < now());
 else
   raise exception using errcode = '22023', message = 'Unbekannte Aktion.';
 end if;
 if not found then
   raise exception using errcode = '22023', message = 'Diese Anfrage ist gerade in Bearbeitung oder bereits erledigt.';
 end if;
 return 'true'::jsonb;
end;
$$;

-- Only the activation function's server credential can claim and complete an invitation.
create or replace function traumasim_private.activate_trainer_access(
 p_action text, p_hash text, p_activation uuid, p_user uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 address text;
 existing_user uuid;
begin
 if p_activation is null then return null; end if;
 if p_action = 'claim' then
   update traumasim_private.trainer_access_requests r
   set activation_id = p_activation, activation_until = now() + interval '2 minutes'
   where r.invite_hash = p_hash and r.expires_at > now() and r.completed_at is null
     and (r.activation_until is null or r.activation_until < now())
     and not exists (
       select 1 from auth.users u join traumasim_private.trainers t on t.email = lower(u.email)
       where t.email = r.email and u.email_confirmed_at is not null
     )
   returning r.email into address;
   if not found then return null; end if;
   select id into existing_user from auth.users where lower(email) = address and not is_sso_user;
   return jsonb_build_object('email', address, 'user_id', existing_user);
 elsif p_action = 'finish' then
   update traumasim_private.trainer_access_requests r
   set completed_at = clock_timestamp(), activated_user_id = p_user,
       invite_hash = null, expires_at = null, activation_id = null, activation_until = null
   where r.invite_hash = p_hash and r.activation_id = p_activation and r.activation_until > now()
     and exists (select 1 from auth.users u where u.id = p_user
       and lower(u.email) = r.email and u.email_confirmed_at is not null)
   returning r.email into address;
   if not found then return null; end if;
   insert into traumasim_private.trainers (email) values (address) on conflict do nothing;
   return jsonb_build_object('email', address);
 elsif p_action = 'release' then
   update traumasim_private.trainer_access_requests
   set activation_id = null, activation_until = null
   where invite_hash = p_hash and activation_id = p_activation;
 end if;
 return null;
end;
$$;

create or replace function public.traumasim_request_trainer_access(p_email text)
returns void language sql security invoker set search_path = '' as $$
 select traumasim_private.request_trainer_access(p_email);
$$;
create or replace function public.traumasim_manage_trainer_access(p_action text, p_email text default null, p_hash text default null)
returns jsonb language sql security invoker set search_path = '' as $$
 select traumasim_private.manage_trainer_access(p_action, p_email, p_hash);
$$;
create or replace function public.traumasim_activate_trainer_access(p_action text, p_hash text, p_activation uuid, p_user uuid default null)
returns jsonb language sql security invoker set search_path = '' as $$
 select traumasim_private.activate_trainer_access(p_action, p_hash, p_activation, p_user);
$$;

revoke all on function public.traumasim_request_trainer_access(text),
 traumasim_private.request_trainer_access(text), public.traumasim_manage_trainer_access(text, text, text),
 traumasim_private.manage_trainer_access(text, text, text),
 public.traumasim_activate_trainer_access(text, text, uuid, uuid),
 traumasim_private.activate_trainer_access(text, text, uuid, uuid) from public, anon, authenticated;
grant usage on schema traumasim_private to service_role;
grant execute on function public.traumasim_request_trainer_access(text), traumasim_private.request_trainer_access(text) to anon, authenticated;
grant execute on function public.traumasim_manage_trainer_access(text, text, text),
 traumasim_private.manage_trainer_access(text, text, text) to authenticated;
grant execute on function public.traumasim_activate_trainer_access(text, text, uuid, uuid),
 traumasim_private.activate_trainer_access(text, text, uuid, uuid) to service_role;

notify pgrst, 'reload schema';
commit;
