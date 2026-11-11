(function () {
  'use strict';

  const MAX_PATIENTS = 30;
  const MAX_BYTES = 200000;
  const MINUTES = [0, 5, 10, 15, 20, 25];
  const MEASURES = [
    ['s', 'Systolischer Blutdruck', 0, 350],
    ['d', 'Diastolischer Blutdruck', 0, 350],
    ['h', 'Puls', 0, 350],
    ['r', 'Atemfrequenz', 0, 350],
    ['o', 'SpO₂', 0, 100],
    ['g', 'GCS', 3, 15]
  ];
  const TEXT_FIELDS = [
    ['intro', 'Lagebeschreibung'],
    ['story', 'Patientenaussage'],
    ['questions', 'Auf Nachfrage'],
    ['secret', 'Information nur für Ausbilder'],
    ['triageReason', 'Begründung der Sichtung']
  ];

  const isRecord = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
  const textLength = (value) => Array.from(value).length;
  const shortText = (value) => typeof value === 'string' && textLength(value) <= 2000;

  // PostgreSQL includes spaces after JSONB separators when checking the size.
  function jsonByteLength(value) {
    const json = JSON.stringify(value);
    let separators = 0;
    for (const [token] of json.matchAll(/"(?:[^"\\]|\\.)*"|[:,]/g)) {
      if (token.length === 1) separators++;
    }
    return new TextEncoder().encode(json).length + separators;
  }

  function validate(draft) {
    if (!isRecord(draft) || !Array.isArray(draft.patients)) {
      return { message: 'Der Szenarioentwurf benötigt eine Patientenliste.' };
    }
    if (draft.patients.length < 1 || draft.patients.length > MAX_PATIENTS) {
      return { message: 'Eine Übung benötigt 1 bis ' + MAX_PATIENTS + ' Patienten. Der Entwurf enthält ' + draft.patients.length + '.' };
    }
    if (typeof draft.title !== 'string' || !draft.title.trim() || textLength(draft.title.trim()) > 120) {
      return { field: 'title', message: 'Der Übungstitel muss 1 bis 120 Zeichen enthalten.' };
    }
    for (const [patientIndex, patient] of draft.patients.entries()) {
      const name = typeof patient?.name === 'string' ? patient.name.trim() : '';
      const label = 'Patient ' + (patientIndex + 1) + (name && textLength(name) <= 100 ? ' „' + name + '“' : '');
      if (!isRecord(patient) || !name || textLength(name) > 100) {
        return { patientIndex, field: 'name', message: label + ' benötigt einen Namen mit 1 bis 100 Zeichen.' };
      }
      for (const [field, title] of TEXT_FIELDS) {
        if (Object.hasOwn(patient, field) && !shortText(patient[field])) {
          return { patientIndex, field, message: label + ' benötigt im Feld „' + title + '“ einen Text mit höchstens 2000 Zeichen.' };
        }
      }
      if (Object.hasOwn(patient, 'condition') && (!Array.isArray(patient.condition) ||
        patient.condition.length !== 4 || !patient.condition.every(shortText))) {
        return { patientIndex, field: 'condition', message: label + ' benötigt vier Zustandsbeschreibungen mit je höchstens 2000 Zeichen.' };
      }
      for (const [index, minute] of MINUTES.entries()) {
        const point = Array.isArray(patient.points) ? patient.points[index] : null;
        const atMinute = label + ' · Minute ' + minute;
        if (point?.t !== minute) {
          return { patientIndex, minute, field: 't', message: atMinute + ' fehlt in der erwarteten Reihenfolge der Vitalwerte.' };
        }
        for (const [field, title, min, max] of MEASURES) {
          const value = point[field];
          if (!Number.isFinite(value) || value < min || value > max) {
            const problem = value == null ? 'fehlt.' : 'muss eine Zahl von ' + min + ' bis ' + max + ' sein.';
            return { patientIndex, minute, field, message: atMinute + ' · ' + title + ' ' + problem };
          }
        }
      }
      if (patient.points.length !== MINUTES.length) {
        return { patientIndex, field: 't', message: label + ' benötigt genau sechs Zeitpunkte für die Vitalwerte.' };
      }
    }
    if (jsonByteLength(draft) > MAX_BYTES) {
      return { message: 'Der Szenarioentwurf ist zu groß. Kürze die Patiententexte.' };
    }
    return null;
  }

  window.TraumaScenario = { MAX_PATIENTS, MAX_BYTES, MINUTES, MEASURES, validate };
})();
