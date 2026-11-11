# Zentrale Synchronisierung

## Betrieb

1. In der Ausbilderansicht mit einem freigegebenen, bestätigten Supabase-Auth-Konto
   anmelden. Für die Ersteinrichtung dort E-Mail und Passwort eingeben und
   „Ausbilderkonto einrichten“ wählen. Danach den Bestätigungslink in der E-Mail
   öffnen, zur Ausbilderansicht zurückkehren und anmelden. Die Anmeldung
   bleibt im selben Browserprofil bis zu 24 Stunden gültig. **Abmelden**
   beendet sie auch in weiteren Ausbilder-Tabs desselben Profils.
2. In **Konfiguration** eine Übung anlegen und Stationen zusammenstellen
   oder oben bei **Aktive Übung** eine vorhandene Übung auswählen.
   Über **Übung umbenennen** lässt sich der Name der aktiven Übung ändern.
   Direkt darunter steht der Übungs-QR fürs Briefing. Über **Übungs-QR als A4 drucken**
   lässt er sich als eigener Aushang mit Übungsname und Gültigkeit ausgeben.
   Teilnehmende scannen ihn einmal und
   können die Seite danach schließen. Während der Übung suchen sie die
   Patienten und öffnen die Stations-QRs im selben Browser. Der Beitritt
   speichert nur den Übungszugang.
   Ein separat kopierter Patientenlink gilt weiterhin nur für den jeweiligen
   Patienten dieser Übung und funktioniert auch ohne vorherigen Beitritt.
   Neu erzeugte Stations-QRs enthalten diesen eindeutigen Patientenzugang.
   Für ältere allgemeine Stations-QRs gilt der Übungsbeitritt im selben
   Browser. Wenn eine Station zu einer anderen Übung gehört, bleibt ein
   gültiger Übungszugang gespeichert. Bei einem abgelaufenen Stations-QR
   verweist die Patientenansicht auf den aktuellen QR vor Ort oder die Übungsleitung.
3. Beim ersten gültigen Aufruf setzt PostgreSQL die gemeinsame Startzeit. Geöffnete
   Patientenansichten fragen den Server im Vordergrund alle zwei Sekunden ab.
   Bei einer kurzen Unterbrechung bleibt der zuletzt empfangene Stand mit
   Uhrzeit sichtbar. Unter **Patient im Detail** können Ausbilder die
   **Schüler-Vorschau** öffnen und den angezeigten Stand lesen, ohne einen
   Patienten zu starten.
4. Beim Zurücksetzen bleibt der Zugangscode gültig. Bereits geöffnete Geräte
   zeigen „Wartet auf Start“. Ein erneuter Aufruf oder „Patient starten“ startet
   die neue Runde. Einzelreset und Übungsreset ändern den zentralen Zustand.
5. Unter **Übung** stehen die Besetzungszahlen direkt in der Patientenübersicht.
   Die Patienten sind nach Fahrzeug und Klemmstelle gruppiert. Bei einem Pkw
   zeigt der Name den Sitzplatz, zum Beispiel **Pkw 1 – Fahrer**.
   Unter den Gruppen stehen die Fahrzeugbezeichnung oder der Gegenstand
   sowie, falls eingetragen, Lage oder Auffindeort.
   Die Übersicht zeigt den Status, die Zeit seit Patientenstart
   und bei gestarteten Patienten die aktuelle Sichtungskategorie im
   Übungsmodell. Sie kann nach aktueller Sichtung und Startstatus gefiltert
   werden. Über der Liste steht die Uhrzeit des letzten
   erfolgreichen Abrufs. Bei einer Unterbrechung bleiben die zuletzt
   geladenen Daten sichtbar und sind als veraltet gekennzeichnet.
   Ein Klick auf den Patienten öffnet seine Auswahl für
   Steuerung, QR-Code und Vorschau. Die Steuerung für die ganze Übung
   steht oben neben dem Übungs-QR. **Übung beenden** schließt die Übung
   samt QR-Zugängen.
   **Eintreffen erfassen** startet die gemeinsame Stoppuhr. Die Übersicht
   zeigt je Patient die Zeit vom Eintreffen bis zur ersten erfassten
   Sichtung. In der Schüleransicht zählt die Auswahl der eigenen SK,
   unabhängig von der Wartezeit auf die Soll-SK. Ausbilder können eine
   Sichtung auch im Patientendetail erfassen. **Zeitmessung zurücksetzen**
   löscht die Referenz und die gemessenen Zeiten. Die Patientenverläufe
   laufen dabei weiter.
   Die **QR-Druckliste (A4)** kann alle Karten, ein Fahrzeug oder eine
   einzelne Station ausgeben. Auf jeder Karte stehen Übungsname und Gültigkeit.
6. Die Übung ist auf 45 Minuten ausgelegt. Die Zeit zählt ab dem jeweiligen
   Patientenstart. Bei älteren 25-Minuten-Profilen gelten danach die letzten
   Basiswerte weiter. Die letzten Werte und die Fallinformationen bleiben
   nach Ablauf der Patientenzeit abrufbar, solange die Übung offen ist.
   Die Ausbildervorschau hat eine eigene Uhr bis Minute 45. Sie verändert
   den Live-Verlauf nicht.

Unter **Konfiguration → Sichtung in der Schüleransicht** können Ausbilder
pro Übung **Eigene Sichtung vor Auflösung** aktivieren. Teilnehmende wählen
dann am Patienten per Schaltfläche **SK I**, **SK II**, **SK III**,
**SK B · Betroffene** oder **SK Schwarz**. Die eigene Wahl bleibt sichtbar.
Nach vier Sekunden erscheint daneben die **Soll-SK** aus dem Übungsmodell.
Über **Eigene SK ändern** lässt sich der Patient erneut sichten. Nach der
neuen Auswahl erscheint die Soll-SK erneut nach vier Sekunden.
Standardmäßig erscheint die hinterlegte Kategorie weiterhin automatisch.

## Eigene Szenarien

Unter **Konfiguration → Weitere Übungsstarts → Übungsvorlagen** kann
die aktive Zusammenstellung als benannte Vorlage gespeichert werden. Eine
Vorlage enthält die Besetzung, Patientenprofile und Sichtungseinstellung und bleibt für den
Ausbilder verfügbar. Ein Start aus der Vorlage legt einen eigenen
Durchlauf mit 24 Stunden Gültigkeit und frischen QR-Zugängen an.
Der Durchlauf kann einen eigenen Namen bekommen. Eine bestehende Vorlage
lässt sich mit der Besetzung der aktiven Übung aktualisieren.

Im Szenarioeditor Patienten, Texte, Gehfähigkeit und Vitalverläufe pflegen.
Für **SK B · Betroffene** und **SK Schwarz** kann die Kategorie fest
vorgegeben werden.
Danach den gespeicherten Entwurf oder eine exportierte JSON-Datei in der
Ausbilderansicht als Live-Übung starten. Unterstützt werden bis zu 30
Patienten. Unvollständige Entwürfe bleiben speicherbar. Die Prüfung vor dem
Start benennt fehlende oder ungültige Angaben. Ein Live-Durchlauf
verwendet eine eigene Kopie der Falldaten.

Teilnehmende scannen den Übungs-QR beim Briefing und nutzen später die
Stations-QRs vor Ort im selben Browser. Der Stations-QR
eines eigenen Falls gehört zu diesem Live-Durchlauf. Bei der Beispielübung
gelten weiterhin die vorhandenen Fahrer- und Beifahrer-QRs. Ausbildertexte
aus eigenen Szenarien sind nur in der Ausbilderansicht verfügbar.

## Busunfall buchen

In der Ausbilderansicht unter **Übungselement Busunfall** die Variante mit
5 oder 10 Personen einschließlich Fahrer auswählen. Den Bus als eigene
Übung starten oder zur aktiven Übung als zusätzliche Lage hinzufügen.
Jede Busvariante enthält eine unverletzte, betreuungsbedürftige Person.
Die Rolle erscheint als **SK B · Betroffene** und hat keine simulierte
Monitoranzeige. Die bestehenden Stationslinks einer laufenden Übung bleiben gültig.
Die Fallmodelle sind private Supabase-Vorlagen und werden bei der Buchung
in die Übung kopiert. Bei einer Neuinstallation werden die Vorlagen aus
dem Szenarioexport eingespielt. Die Ausbildervorschau zeigt die Lage und
die internen Hinweise des ausgewählten Patienten.

## Pkw mit Insassen

Unter **Übungselement Pkw mit Insassen** bis zu fünf Sitzplätze besetzen.
Verletzungsprofil und Befreiungslage werden je Person gewählt. Zur Auswahl
stehen **Frei zugänglich**, **Eingeschlossen** und **Eingeklemmt**.
Für eingeklemmte Personen wird zusätzlich die Klemmstelle gewählt.
Unter **Fahrzeug** kann z. B. „roter Volvo“ und unter **Lage** „Seitenlage“
eingetragen werden. **SK B · Betroffene**
und **SK Schwarz** sind auch als feste Profile wählbar. Die Profile
**SK III → SK II**, **SK II → SK I** und **SK I → SK Schwarz** wechseln
zur per Schieberegler gewählten Minute ab Patientenstart (Minute 1 bis 44). Voreingestellt
sind 12, 6 beziehungsweise 8 Minuten. Bei **SK III → SK II**
und **SK II → SK I** entwickelt sich der Verlauf bis Minute 45 weiter.
Die Standardstory berücksichtigt den Sitzplatz, die Befreiungslage und
den aktuellen Verletzungsverlauf. Bei einer Einklemmung oder einem
versperrten Ausstieg beschreibt sie die Behinderung vor Ort. Ein eigener
Text erscheint als Zusatz zur Patientenstory.
Die Simulationszeit hält bei einer Pause an. Beim Wechsel zu SK Schwarz endet
der Verlauf und der simulierte Monitor wird ausgeblendet. Puls und Atemfrequenz schwanken
leicht und für alle Geräte gleich über der Vitalwertkurve. Der Pkw kann als
eigene Übung starten oder zu einer laufenden Übung hinzugefügt werden.

Pkw werden innerhalb der Übung nummeriert. Personen erhalten je Pkw
fortlaufende Nummern. Beispiel **Pkw 02 · Patient 03 · hinten rechts**.
Den einzelnen QR-Code in der Ausbilderansicht am jeweiligen Platz auslegen.
Die Pkw-Personen erscheinen nicht in der Teilnehmerliste und lassen sich
nur mit ihrem eigenen Patienten-QR öffnen.

Unter **Konfiguration → Pkw mit Insassen → Pkw auswählen** lässt sich
ein gebuchter Pkw öffnen. Fahrzeuglage, Verletzungsprofile, Befreiungslage,
Wechselzeiten und eigene Verletzungstexte können dort geändert werden.
Personen können hinzugefügt, entfernt oder auf einen anderen Sitzplatz
gesetzt werden. Verbleibende Personen behalten Nummer und Stations-QR.
Bereits
gestartete Patienten dieses Pkw müssen vor dem Speichern zurückgesetzt werden.
Beim Wechsel des Pkw oder der Übung fragt TraumaSim nach, wenn Änderungen
noch gespeichert, verworfen oder weiter bearbeitet werden können.

## Lkw mit Insassen und Einklemmungsstellen

Unter **Fahrzeuge zusammenstellen → Lkw mit Insassen** lassen sich Fahrer-
und Beifahrerplatz einzeln besetzen. Verletzungsprofile und Befreiungslage
werden je Sitzplatz wie beim Pkw gewählt.

Unter **Einklemmung unter oder zwischen Gegenständen** wird je Stelle eine
Person angelegt. Zur Auswahl stehen Betonträger, Mulde, Pkw, Pkw und Fahrrad,
Lkw, Bus und Maschine. Dazu werden die Position **unter** oder **zwischen**
und die Klemmstelle gewählt. Möglich sind linker oder rechter Arm, linkes
oder rechtes Bein sowie beide Arme oder beide Beine. Ein Auffindeort kann
eingetragen werden.
Die Standardstory verwendet die gewählte Körperregion und Klemmlage.
In der Verlaufsvorschau lässt sich die Geschichte vor und nach einem
Kategorienwechsel prüfen.

Lkw und Einklemmungsstellen lassen sich zu einer vorhandenen Übung
hinzufügen oder als eigene Übung starten. Jede Person hat einen eigenen
Stations-QR. Die Übersicht zählt beide Typen getrennt und die A4-Druckliste
kann auf einen Lkw oder eine Einklemmungsstelle eingegrenzt werden.

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
