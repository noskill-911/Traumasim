# Zentrale Synchronisierung

## Betrieb

1. In der Ausbilderansicht mit einem freigegebenen, bestätigten Supabase-Auth-Konto
   anmelden. Für die Ersteinrichtung dort E-Mail und Passwort eingeben und
   „Ausbilderkonto einrichten“ wählen. Danach den Bestätigungslink in der E-Mail
   öffnen, zur Ausbilderansicht zurückkehren und anmelden.
2. Eine Übung anlegen und einen Patienten auswählen. Entweder den Patientenlink
   direkt weitergeben oder den Code zum bereits vorhandenen QR-Code mitteilen.
   Beide Zugänge gelten nur für den jeweiligen Patienten dieser Übung.
3. Beim ersten gültigen Aufruf setzt PostgreSQL die gemeinsame Startzeit. Geöffnete
   Patientenansichten fragen den Server im Vordergrund alle zwei Sekunden ab.
4. Beim Zurücksetzen bleibt der Zugangscode gültig. Bereits geöffnete Geräte
   zeigen „Wartet auf Start“. Ein erneuter Aufruf oder „Patient starten“ startet
   die neue Runde. Einzelreset und Übungsreset ändern den zentralen Zustand.
5. Die Ausbildervorschau hat eine eigene Uhr. Änderungen an der Vorschau
   wirken sich auf die Live-Übung erst über die gesonderten Steuerknöpfe aus.

## Einrichtung und Rechte

- `supabase/schema.sql` als Datenbankadministrator anwenden. Es aktualisiert
  auch das vorbereitete Schema.
- Zugelassene E-Mail-Adressen kleingeschrieben in
  `traumasim_private.trainers(email)` eintragen. Die RPC prüft die serverseitig
  bestätigte Adresse aus Supabase Auth und bei jeder Übungsaktion den Eigentümer
  der Übung. Die Liste bleibt in der Datenbank.
- E-Mail-Bestätigung und Passwortanmeldung in Supabase Auth aktivieren.
  Für die Rückleitung nach der Bestätigung kann die Pages-Ausbilderadresse in
  Supabase als Redirect URL hinterlegt werden. Bei eingeschränktem E-Mail-Versand
  kann der Projektadministrator das Konto über **Authentication → Users** anlegen.
- `supabase-config.js` enthält nur Projekt-URL und Publishable Key.
  Die Rollen `anon` und `authenticated` erhalten keine direkten
  Tabellenrechte. Öffentliche RPCs delegieren an Funktionen im privaten Schema.
  Der Schülercode besteht aus Übungs-ID und patientenspezifischer HMAC-Signatur.
  Der Signaturschlüssel bleibt in der Datenbank. Direkte Schülerlinks tragen den
  Code im URL-Fragment und die Seite entfernt ihn nach dem Lesen aus der URL.
- Im öffentlichen Repository stehen die mitgelieferten Beispielmodelle.
  Im laufenden Schülerbetrieb liefert die API nur die aktuell freigegebenen
  Werte. Ausbilderdaten, Zugangscodes und Übungszustand gehören nicht in Git.

## Abnahme

Mit zwei getrennten Browserprofilen denselben Patienten öffnen. Der zweite
Aufruf muss die bereits laufende Zeit übernehmen. Im Ausbilderfenster erst
einen Patienten zurücksetzen, dann die ganze Übung. In den Schülerprofilen
prüfen, welche Uhren stehen bleiben. Den Fahrer-Code am Beifahrer-Link
und einen Ausbilderaufruf ohne Sitzung testen. Beides muss abgelehnt werden.
