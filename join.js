(function () {
  'use strict';

  const el = (id) => document.getElementById(id);
  const api = window.TraumaSync;
  const caseId = new URLSearchParams(location.search).get('case');
  const scanned = new URLSearchParams(location.hash.slice(1)).get('access');
  const code = scanned || (caseId && api.exerciseCode(caseId));

  async function join() {
    el('joinRetry').hidden = true;
    el('joinStatus').textContent = 'Übungszugang wird geprüft …';
    let exercise;
    try {
      exercise = await api.join(code);
    } catch (error) {
      el('joinStatus').textContent = error.message;
      if (error.code === '42501') {
        if (caseId) api.clearExerciseCode(caseId, code);
      } else {
        el('joinRetry').hidden = false;
      }
      return;
    }

    try {
      api.saveExerciseCode(exercise.case, code);
    } catch {
      el('joinStatus').textContent = 'Dieser Browser konnte den Übungszugang nicht speichern. Öffne den QR-Code in einem Browser mit aktiviertem Websitespeicher.';
      el('joinRetry').hidden = false;
      return;
    }

    history.replaceState(null, '', location.pathname + '?' + new URLSearchParams({ case: exercise.case }));
    el('joinTitle').textContent = exercise.title;
    const preset = window.TRAUMA_CASES.find((item) => item.id === exercise.case);
    const patients = exercise.patients ?? (exercise.hidden_stations ? [] : preset?.patients ?? []);
    const items = patients.map((patient) => {
      const item = document.createElement('li');
      const link = document.createElement('a');
      link.className = 'action';
      link.href = 'patient.html?' + new URLSearchParams({ case: exercise.case, patient: patient.id });
      link.textContent = patient.name ?? preset?.patients.find((item) => item.id === patient.id)?.name ?? patient.id;
      item.append(link);
      return item;
    });
    el('joinedPatients').replaceChildren(...items);
    el('joinedPatients').hidden = items.length === 0;
    el('joinStatus').textContent = items.length
      ? 'Du bist der Übung beigetreten. Wähle eine angezeigte Person oder scanne einen Stations-QR vor Ort im selben Browser.'
      : 'Du bist der Übung beigetreten. Scanne die einzelnen Patienten-QRs vor Ort.';
  }

  el('joinRetry').addEventListener('click', join);
  if (code) {
    void join();
  } else {
    el('joinStatus').textContent = 'Scanne den Übungs-QR, den dir die Ausbilder zeigen.';
  }
})();
