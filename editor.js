(function () {
  'use strict';

  const el = (id) => document.getElementById(id);
  const key = 'traumasim-editor-v1';
  const fields = ['name', 'intro', 'story', 'questions', 'secret'];
  const { MAX_PATIENTS, MAX_BYTES, MEASURES: measures, MINUTES: minutes, triageMode, validate } = window.TraumaScenario;
  const initialPoints = () => minutes.map((t) => ({ t, s: 120, d: 80, h: 80, r: 16, o: 98, g: 15 }));
  let data;
  let current = 0;
  let inputs = [];

  function validDraft(draft) {
    return typeof draft?.title === 'string' && Array.isArray(draft.patients)
      && draft.patients.length >= 1 && draft.patients.length <= 100
      && draft.patients.every((patient) => patient && typeof patient.name === 'string');
  }

  function fillMissingPoints(draft) {
    for (const patient of draft.patients) {
      if (!Array.isArray(patient.points)) patient.points = initialPoints();
    }
    return draft;
  }

  try { data = JSON.parse(localStorage.getItem(key)); } catch {}
  if (!validDraft(data)) data = JSON.parse(JSON.stringify(window.TRAUMA_CASES[0]));
  fillMissingPoints(data);

  function message(text) {
    el('message').textContent = text;
  }

  function draftStatus(text) {
    const issue = validate(data);
    message(issue ? text + ' Vor dem Übungsstart prüfen. ' + issue.message : text + ' Der Entwurf ist startbereit.');
  }

  function commit() {
    const patient = data.patients[current];
    for (const field of fields) patient[field] = el(field).value;
    patient.walkable = el('walkable').checked;
    patient.points = inputs.map((row, i) => Object.fromEntries([
      ['t', minutes[i]], ...row.map((input, j) => [measures[j][0], input.value === '' ? null : input.valueAsNumber])
    ]));
    data.title = el('caseTitle').value;
  }

  function render() {
    const patient = data.patients[current];
    el('caseTitle').value = data.title;
    el('choose').replaceChildren(...data.patients.map((item, i) => new Option(item.name || 'Patient ' + (i + 1), i)));
    el('choose').value = current;
    for (const field of fields) el(field).value = patient[field] ?? '';
    const mode = triageMode(patient);
    el('triageMode').value = mode ?? '';
    el('walkable').disabled = mode !== 'automatic';
    el('walkable').checked = patient.walkable === true;

    const points = Array.isArray(patient.points) ? patient.points : initialPoints();
    inputs = [];
    const rows = minutes.map((minute) => {
      const row = document.createElement('tr');
      const label = document.createElement('th');
      label.scope = 'row';
      label.textContent = minute;
      row.append(label);
      const point = points.find((item) => item?.t === minute);
      inputs.push(measures.map(([field, name, min, max]) => {
        const cell = document.createElement('td');
        const input = document.createElement('input');
        input.type = 'number';
        input.required = true;
        input.min = min;
        input.max = max;
        input.step = '1';
        input.value = point?.[field] ?? '';
        input.setAttribute('aria-label', name + ', Minute ' + minute);
        cell.append(input);
        row.append(cell);
        return input;
      }));
      return row;
    });
    el('points').replaceChildren(...rows);
  }

  el('choose').addEventListener('change', () => {
    commit();
    current = Number(el('choose').value);
    render();
  });

  el('triageMode').addEventListener('change', () => {
    const patient = data.patients[current];
    const mode = el('triageMode').value;
    patient.affected = mode === 'affected';
    patient.black = mode === 'black';
    el('walkable').disabled = mode !== 'automatic';
  });

  el('add').addEventListener('click', () => {
    if (data.patients.length >= MAX_PATIENTS) return message('Eine Live-Übung unterstützt bis zu ' + MAX_PATIENTS + ' Patienten.');
    commit();
    data.patients.push({ name: 'Neuer Patient ' + (data.patients.length + 1), points: initialPoints() });
    current = data.patients.length - 1;
    render();
  });

  el('remove').addEventListener('click', () => {
    if (data.patients.length <= 1) return message('Mindestens ein Patient ist erforderlich.');
    commit();
    data.patients.splice(current, 1);
    current = Math.min(current, data.patients.length - 1);
    render();
  });

  el('save').addEventListener('click', () => {
    commit();
    try {
      localStorage.setItem(key, JSON.stringify(data));
      draftStatus('Entwurf gespeichert.');
    } catch {
      message('Der Entwurf konnte in diesem Browser nicht gespeichert werden.');
    }
  });

  el('export').addEventListener('click', () => {
    commit();
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = 'traumasim-szenario.json';
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    draftStatus('Entwurf exportiert.');
  });

  el('import').addEventListener('change', async (event) => {
    const file = event.target.files[0];
    if (!file) return;
    try {
      if (file.size > MAX_BYTES) throw new Error('Die Datei ist zu groß.');
      const incoming = JSON.parse(await file.text());
      if (Array.isArray(incoming?.patients) && incoming.patients.length > MAX_PATIENTS) {
        throw new Error('Die Datei enthält ' + incoming.patients.length + ' Patienten. Maximal ' + MAX_PATIENTS + ' sind möglich.');
      }
      if (!validDraft(incoming)) throw new Error('Ungültiger Szenarioentwurf.');
      data = fillMissingPoints(incoming);
      current = 0;
      render();
      draftStatus('Entwurf importiert. Speichere ihn für die Ausbilderansicht.');
    } catch (error) {
      message('Import fehlgeschlagen. ' + error.message);
    } finally {
      event.target.value = '';
    }
  });

  render();
})();
