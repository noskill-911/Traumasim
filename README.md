# TraumaSim

Patientensimulator für die Feuerwehr- und Rettungsdienstausbildung.

## Nutzung

- [Patientenbibliothek und QR-Codes](https://noskill-911.github.io/Traumasim/)
- [Ausbilderansicht](https://noskill-911.github.io/Traumasim/trainer.html)

Ausbilder legen eine Übung an und zeigen den Übungs-QR. Teilnehmende scannen ihn
einmal und öffnen danach im selben Browser die vorhandenen Patienten-QR-Codes.
Der erste gültige Patientenaufruf startet den Patienten geräteübergreifend. Beim erneuten Öffnen läuft derselbe Verlauf weiter. Sichtung und
Vitalwerte werden nach 60 bzw. 120 Sekunden freigegeben.

Die Ausbilderansicht erlaubt Pausieren, Fortsetzen und das Zurücksetzen eines
Patienten oder der ganzen Übung. Eine Übung ist 24 Stunden zugänglich. Der
Szenarioeditor bleibt lokal und erstellt JSON-Entwürfe.

Die Verläufe dienen der Ausbildung. Sie sind didaktische Beispiele und kein
validiertes medizinisches Verfahren. Keine personenbezogenen Daten verwenden.

Die [Dokumentation zur Synchronisierung](docs/synchronisierung.md) beschreibt
Einrichtung und Berechtigungen.

## Lizenz

Apache-2.0. Der lokal eingebundene [QR-Generator](vendor/qrcode-generator-LICENSE.txt) steht unter MIT.
