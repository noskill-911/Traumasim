# TraumaSim – zentrale Synchronisierung (Vorbereitung)

## Stand
GitHub Pages stellt nur statische Dateien bereit. Der bisherige Startzeitpunkt wird
im lokalen Browser gespeichert und ist **nicht** geräteübergreifend.

## Zielarchitektur
1. Eine Übungssitzung erhält eine zufällige Sitzungs-ID.
2. Jeder Patient hat eine eigene öffentliche QR-URL mit einem zufälligen,
   auf diesen Patienten beschränkten Lesetoken.
3. Der erste gültige Patientenaufruf setzt serverseitig atomar `started_at`.
4. Spätere Aufrufe lesen dieselbe Startzeit. Der Zeitverlauf wird aus
   Serverzeit und Pausen berechnet.
5. Der Ausbilder erhält einen unabhängigen, hochentropischen Steuerungstoken.
6. Pausieren, Fortsetzen und Zurücksetzen erfolgen ausschließlich über
   serverseitig geprüfte Funktionen; Änderungen werden in Echtzeit verteilt.
7. Interne Diagnosen werden nicht an Schüler ausgeliefert.

## Sicherheit
Ein geheimer URL-Pfad allein genügt nicht, wenn der zugrunde liegende
Datensatz öffentlich lesbar ist. Token nur als Hash serverseitig speichern;
Lesetoken und Steuerungstoken strikt trennen. Token niemals im öffentlichen
GitHub-Repository speichern. Supabase `service_role` gehört ausschließlich
in sichere serverseitige Umgebungsvariablen.

Das SQL in `supabase/schema.sql` legt bewusst noch keine öffentlichen
Zugriffsrichtlinien an. Es ist ein Vorbereitungsschema, **keine fertige
Synchronisierungsimplementierung**.

## Noch erforderlich
- Supabase-Projekt-URL und öffentlicher Publishable-/anon-Key (kein Secret)
- Edge Functions/RPC mit Tokenprüfung und atomarem Start
- Sichere Erzeugung von Sitzungs- und Patiententokens
- Frontend-Anbindung und Geräte-/Rücksetztests
