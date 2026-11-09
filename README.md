# TraumaSim

Patientensimulator für die Feuerwehr- und Rettungsdienstausbildung.

## Nutzung

- [TraumaSim-Startseite](https://noskill-911.github.io/Traumasim/)
- [Ausbilderansicht](https://noskill-911.github.io/Traumasim/trainer.html)

Ausbilder legen eine Übung an und zeigen den Übungs-QR. Teilnehmende scannen ihn
einmal und wählen eine freigegebene Person oder öffnen im selben Browser
einen Patienten-QR vor Ort. Stations-QRs sind in der Live-Übersicht der
Ausbilder unter **Patient im Detail** zu finden.
Der erste gültige Patientenaufruf startet den Patienten geräteübergreifend. Beim erneuten Öffnen läuft derselbe Verlauf weiter.
Die simulierte Vorsichtung erscheint ab 10 Sekunden (SK III, grün),
20 Sekunden (SK II, gelb) oder 35 Sekunden (SK I, rot) gemeinsamer Patientenzeit.
Die simulierten Vitalwerte erscheinen gestaffelt ab Patientenstart:
Puls und SpO₂ nach 25 Sekunden, Atemfrequenz nach 40 Sekunden, GCS nach
45 Sekunden, Blutdruck nach 70 Sekunden und die EKG-Monitorkurve nach
90 Sekunden. Der Blutdruck bleibt bis zur nächsten abgeschlossenen Messung
stehen. Der Fahrer hat ein 3-Minuten-Intervall, der Beifahrer ein 5-Minuten-Intervall.
Der Monitor zeigt die Uhrzeit der letzten und der vorherigen Messung sowie
die geplante Uhrzeit des nächsten Messwerts in der Zeitzone Europe/Berlin.
Bei einer Pause ruht die Messplanung. Die Uhr am EKG zeigt die laufende
Berliner Ortszeit. Die zweite Uhr am Monitor zählt die gemeinsame
Patientenzeit ab dem ersten gültigen Patientenaufruf. Die Freigabezeiten
bilden einen Übungsablauf ab.

Die Ausbilderansicht erlaubt Pausieren, Fortsetzen und das Zurücksetzen eines
Patienten oder der ganzen Übung. Die Übersicht zeigt alle Patienten der
gewählten Übung. Die Ausbilder können eine Übung beenden und damit die
QR-Zugänge schließen. Übungen laufen spätestens nach 24 Stunden ab.

Eigene Szenarien im Szenarioeditor bearbeiten und als Entwurf speichern.
In der Ausbilderansicht **Eigenes Szenario als Übung starten** öffnen und
den gespeicherten Entwurf verwenden oder eine exportierte JSON-Datei
hochladen. Die Live-Übung erhält eine eigene Kopie des Entwurfs.

Die Verläufe dienen der Ausbildung. Sie sind didaktische Beispiele und kein
validiertes medizinisches Verfahren. Keine personenbezogenen Daten verwenden.

Die [Dokumentation zur Synchronisierung](docs/synchronisierung.md) beschreibt
Einrichtung und Berechtigungen.

## Lizenz

Apache-2.0. Der lokal eingebundene [QR-Generator](vendor/qrcode-generator-LICENSE.txt) steht unter MIT.
