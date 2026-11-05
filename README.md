# TraumaSim

Patientensimulator für die Feuerwehr- und Rettungsdienstausbildung.

## Nutzung

- [Patientenbibliothek und QR-Codes](https://noskill-911.github.io/Traumasim/)
- [Ausbilderansicht](https://noskill-911.github.io/Traumasim/trainer.html)

Ausbilder legen eine Übung an und geben je Patient einen Link oder den Zugangscode
für den vorhandenen QR-Code aus. Der erste gültige Aufruf startet diesen Patienten
geräteübergreifend. Beim erneuten Öffnen läuft derselbe Verlauf weiter. Sichtung und
Vitalwerte werden nach 60 bzw. 120 Sekunden freigegeben.

Die Ausbilderansicht erlaubt Pausieren, Fortsetzen und das Zurücksetzen eines
Patienten oder der ganzen Übung. Eine Übung ist 24 Stunden zugänglich. Der
Szenarioeditor bleibt lokal und erstellt JSON-Entwürfe.

Die Verläufe dienen der Ausbildung. Sie sind didaktische Beispiele und kein
validiertes medizinisches Verfahren. Keine personenbezogenen Daten verwenden.

Die [Dokumentation zur Synchronisierung](docs/synchronisierung.md) beschreibt
Einrichtung und Berechtigungen.

## Lizenz

Apache-2.0.
