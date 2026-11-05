# TraumaSim

Kostenloser, quelloffener Patientensimulator für Feuerwehr- und Rettungsdienstausbildung.

## Nutzung

Die öffentliche Patientenbibliothek befindet sich unter GitHub Pages. Einzelne Patienten
haben eine eigene URL und starten beim Öffnen automatisch. Sichtungskategorie und Vitalwerte
werden zeitverzögert angezeigt. Die medizinischen Verläufe sind **didaktische Beispiele**,
keine validierte medizinische Prognose und kein geprüftes Hamburger mSTaRT-Verfahren.

## Aufbau

- `index.html`: öffentliche Patientenbibliothek
- `patient.html`: Schüleransicht
- `trainer.html`: Ausbildervorschau (derzeit **nicht zugriffsgeschützt**)
- `patients.js`: öffentliche Beispieldaten
- `editor.html`: lokaler Szenarioeditor

**Sicherheit:** Ein langer URL-Pfad allein schützt keine Daten auf GitHub Pages.
Öffentliche Dateien einschließlich `patients.js` sind von allen einsehbar.
Keine geheimen Diagnosen oder personenbezogenen Daten in das öffentliche Repository
hochladen. Eigene Szenarien werden zunächst nur lokal im Browser bearbeitet.
Für echte getrennte Berechtigungen und Live-Synchronisierung ist später ein Backend nötig.

## Lizenz

Apache-2.0. Beiträge und Weiterentwicklungen sind willkommen.
