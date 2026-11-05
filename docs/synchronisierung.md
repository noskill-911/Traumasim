# Zentrale Synchronisierung

## Betrieb

1. In der Ausbilderansicht mit einem freigegebenen, bestätigten Supabase-Auth-Konto
   anmelden. Für die Ersteinrichtung dort E-Mail und Passwort eingeben und
   „Ausbilderkonto einrichten“ wählen. Danach den Bestätigungslink in der E-Mail
   öffnen, zur Ausbilderansicht zurückkehren und anmelden.
2. Eine Übung anlegen oder auswählen und den Übungs-QR zeigen. Teilnehmende
   scannen ihn einmal. Danach funktionieren im selben Browser die vorhandenen
   Patienten-QR-Codes. Der Beitritt startet noch keinen Patienten.
   Ein separat kopierter Patientenlink gilt weiterhin nur für den jeweiligen
   Patienten dieser Übung und funktioniert auch ohne vorherigen Beitritt.
3. Beim ersten gültigen Aufruf setzt PostgreSQL die gemeinsame Startzeit. Geöffnete
   Patientenansichten fragen den Server im Vordergrund alle zwei Sekunden ab.
4. Beim Zurücksetzen bleibt der Zugangscode gültig. Bereits geöffnete Geräte
   zeigen „Wartet auf Start“. Ein erneuter Aufruf oder „Patient starten“ startet
   die neue Runde. Einzelreset und Übungsreset ändern den zentralen Zustand.
5. **Übung beenden** schließt die Übung samt QR-Zugängen. Die Patientenübersicht
   zeigt den Status und die Übungszeit aller Patienten.
6. Die Ausbildervorschau hat eine eigene Uhr. Änderungen an der Vorschau
   wirken sich auf die Live-Übung erst über die gesonderten Steuerknöpfe aus.

## Eigene Szenarien

Im Szenarioeditor Patienten, Texte, Gehfähigkeit und Vitalverläufe pflegen.
Danach den gespeicherten Entwurf oder eine exportierte JSON-Datei in der
Ausbilderansicht als Live-Übung starten. Unterstützt werden bis zu 30
Patienten. Ein Live-Durchlauf verwendet eine eigene Kopie der Falldaten.

Teilnehmende scannen den Übungs-QR und wählen auf der Beitrittsseite einen
Patienten oder nutzen den Stations-QR im selben Browser. Der Stations-QR
eines eigenen Falls gehört zu diesem Live-Durchlauf. Bei der Beispielübung
gelten weiterhin die vorhandenen Fahrer- und Beifahrer-QRs. Ausbildertexte
aus eigenen Szenarien sind nur in der Ausbilderansicht verfügbar.

## Busunfall buchen

In der Ausbilderansicht unter **Übungselement Busunfall** die Variante mit
5 oder 10 Personen einschließlich Fahrer auswählen. Den Bus als eigene
Übung starten oder zur aktiven Übung als zusätzliche Lage hinzufügen.
Jede Busvariante enthält eine unverletzte, betreuungsbedürftige Person.
Die Rolle erscheint als **Unverletzt betroffen** und hat keine simulierte
Monitoranzeige. Die bestehenden Stationslinks einer laufenden Übung bleiben gültig.
Die Fallmodelle sind private Supabase-Vorlagen und werden bei der Buchung
in die Übung kopiert. Bei einer Neuinstallation werden die Vorlagen aus
dem Szenarioexport eingespielt. Die Ausbildervorschau zeigt die Lage und
die internen Hinweise des ausgewählten Patienten.

## Pkw mit Insassen

Unter **Übungselement Pkw mit Insassen** bis zu fünf Sitzplätze besetzen.
Verletzungsprofil und Einklemmung werden je Person gewählt. Eine eigene
Beschreibung und die Fahrzeuglage können ergänzt werden. Die Profile
**SK II → SK I** und **SK I → EX (schwarz)** wechseln zur gewählten Minute
ab Patientenstart. Voreingestellt sind Minute 6 beziehungsweise 8.
Die Simulationszeit hält bei einer Pause an. Bei EX endet der Verlauf
und der simulierte Monitor wird ausgeblendet. Puls und Atemfrequenz schwanken
leicht und für alle Geräte gleich über der Vitalwertkurve. Der Pkw kann als
eigene Übung starten oder zu einer laufenden Übung hinzugefügt werden.

Pkw werden innerhalb der Übung nummeriert, Personen innerhalb des Pkw in
Sitzplatzreihenfolge. Beispiel **Pkw 02 · Patient 03 · hinten rechts**.
Den einzelnen QR-Code in der Ausbilderansicht am jeweiligen Platz auslegen.
Die Pkw-Personen erscheinen nicht in der Teilnehmerliste und lassen sich
nur mit ihrem eigenen Patienten-QR öffnen.

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
  Das Übungstoken gibt Schülerzugang zu den Patienten dieser Übung, ein
  direkt geteilter Patientenlink nur zu dem jeweiligen Patienten. Beide Token
  sind serverseitig signiert und laufen mit der Übung ab. Die Links verwenden
  URL-Fragmente. Der Übungsbeitritt speichert den Zugang im Browserspeicher.
  Der Übungs-QR wird lokal in der Ausbilderansicht erzeugt. Die gedruckten
  QR-Ziele bleiben gleich und die QR-Bilder kommen direkt von GitHub Pages.
- Im öffentlichen Repository stehen die mitgelieferten Beispielmodelle.
  Im laufenden Schülerbetrieb liefert die API nur die aktuell freigegebenen
  Werte. Ausbilderdaten, Zugangscodes und Übungszustand gehören nicht in Git.

## Abnahme

In zwei getrennten Browserprofilen einmal den Übungs-QR und anschließend
denselben gedruckten Patienten-QR öffnen. Der zweite
Aufruf muss die bereits laufende Zeit übernehmen. Im Ausbilderfenster erst
einen Patienten zurücksetzen, dann die ganze Übung. In den Schülerprofilen
prüfen, welche Uhren stehen bleiben. Den Fahrer-Code am Beifahrer-Link
und einen Ausbilderaufruf ohne Sitzung testen. Beides muss abgelehnt werden.
