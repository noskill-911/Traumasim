(function () {
  'use strict';

  const el = (id) => document.getElementById(id);
  const api = window.TraumaSync;
  const previewDuration = Number(el('seek').max) * 60;
  const actions = Array.from(document.querySelectorAll('[data-action]'));
  const categoryLabels = {
    red: 'SK I · Rot', yellow: 'SK II · Gelb', green: 'SK III · Grün',
    black: 'EX · Schwarz', affected: 'Unverletzt betroffen'
  };
  let auth = null;
  let exercise = null;
  let busy = false;
  let polling = false;
  let actionVersion = 0;
  let refreshing = null;
  let previewTime = 0;
  let previewTick = null;

  if (new URLSearchParams(location.hash.slice(1)).has('access_token')) {
    history.replaceState(null, '', location.pathname + location.search);
  }

  function message(text) {
    el('message').textContent = text;
  }

  function showView(live) {
    el('configurationView').hidden = live;
    el('exerciseView').hidden = !live;
    el('showConfiguration').setAttribute('aria-pressed', String(!live));
    el('showExercise').setAttribute('aria-pressed', String(live));
  }

  el('showConfiguration').addEventListener('click', () => showView(false));
  el('showExercise').addEventListener('click', () => showView(true));

  function selectedPatient() {
    return exercise?.patients.find((patient) => patient.id === el('choose').value);
  }

  function patientName(id) {
    return exercise.patients.find((patient) => patient.id === id)?.model?.name
      ?? window.TRAUMA_CASES.find((item) => item.id === exercise.case)
      ?.patients.find((patient) => patient.id === id)?.name ?? id;
  }

  function options(select, items, label) {
    select.replaceChildren(new Option(label, ''), ...items.map((item) => new Option(item.title, item.id)));
  }

  function categoryForVitals(patient, vitals) {
    if (patient.model.affected === true) return 'affected';
    const red = (patient.id === 'fahrer' || patient.custom) && (vitals.s < 100 || vitals.g < 15 || vitals.h >= 120);
    return red ? 'red' : patient.model.walkable ? 'green' : 'yellow';
  }

  function forecastLabel(patient) {
    const shortCategory = (category) => categoryLabels[category].split(' · ')[0];
    const progression = patient.model.progression;
    if (progression) {
      return 'Verlauf · ' + shortCategory(progression.from) + ' → ' + shortCategory(progression.to)
        + ' bei Minute ' + progression.at_seconds / 60;
    }
    if (patient.model.affected === true) {
      return patient.status === 'ready' ? 'Start · Unverletzt betroffen' : '';
    }
    const points = patient.model.points;
    const start = patient.category ?? categoryForVitals(patient, points[0]);
    const categories = [start];
    for (const point of points) {
      if (point.t * 60 <= patient.elapsed) continue;
      const next = categoryForVitals(patient, point);
      if (categories.at(-1) !== next) categories.push(next);
    }
    if (patient.status !== 'ready' && categories.length === 1) return '';
    const heading = patient.status === 'ready' ? 'Start' : 'Vorschau';
    return heading + ' · ' + categories.map(shortCategory).join(' → ');
  }

  function drawPreview() {
    const patient = selectedPatient();
    if (!patient) return;
    const minute = previewTime / 60;
    if (patient.model.affected === true) {
      el('secret').textContent = patient.model.secret;
      el('clock').textContent = api.clock(previewTime);
      el('seek').value = Math.floor(minute);
      el('triage').className = 'triage affected';
      el('triage').textContent = 'UNVERLETZT BETROFFEN · BETREUUNG';
      el('vitals').replaceChildren();
      return;
    }
    const progression = patient.model.progression;
    const at = progression?.at_seconds;
    let category = progression && (previewTime >= at ? progression.to : progression.from);
    el('secret').textContent = patient.model.secret + (progression ? ' · Wechsel bei Minute ' + at / 60 : '');
    el('clock').textContent = api.clock(previewTime);
    el('seek').value = Math.floor(minute);
    if (category === 'black') {
      el('triage').className = 'triage black';
      el('triage').textContent = 'EX · SCHWARZ (Übungsmodell)';
      el('vitals').replaceChildren();
      return;
    }

    // The second curve point marks the chosen transition, as in the live calculation.
    const curveMinute = progression
      ? (previewTime <= at ? previewTime * 5 / at : 5 + (previewTime - at) * 20 / (previewDuration - at))
      : Math.min(minute, 25);
    const index = Math.min(4, Math.floor(curveMinute / 5));
    const [a, b] = patient.model.points.slice(index, index + 2);
    const v = {};
    // Match the patient monitor's time-based fluctuations.
    const phase = patient.model.car_number == null ? null : previewTime
      + patient.model.car_number * 13 + patient.model.car_patient_number * 7;
    const pulseOffset = phase == null ? 0
      : 1.4 * Math.sin(2 * Math.PI * phase / 31) + 0.6 * Math.sin(2 * Math.PI * phase / 67);
    const breathsOffset = phase == null ? 0 : 1.15 * Math.sin(2 * Math.PI * phase / 33);
    for (const key of ['s', 'd', 'h', 'r', 'o', 'g']) {
      const offset = key === 'h' ? pulseOffset : key === 'r' ? breathsOffset : 0;
      v[key] = Math.round(a[key] + (b[key] - a[key]) * (curveMinute - a.t) / 5 + offset);
    }
    category ||= categoryForVitals(patient, v);
    el('triage').className = 'triage ' + category;
    el('triage').textContent = { red: 'SK I · ROT', yellow: 'SK II · GELB', green: 'SK III · GRÜN' }[category] + ' (Übungsmodell)';
    el('vitals').innerHTML = [
      ['Blutdruck', v.s + '/' + v.d + ' mmHg'], ['Puls', v.h + '/min'], ['Atemfrequenz', v.r + '/min'],
      ['SpO₂', v.o + ' %'], ['GCS', v.g + '/15']
    ].map(([name, value]) => '<div class="metric"><span class="muted">' + name + '</span><strong>' + value + '</strong></div>').join('');
  }

  function resetPreview() {
    previewTick = null;
    previewTime = 0;
    drawPreview();
  }

  function renderExercise(next) {
    const previous = selectedPatient()?.id;
    const changed = exercise?.id !== next?.id;
    exercise = next;
    el('noExercise').hidden = Boolean(next);
    el('live').hidden = !next;
    el('patientControls').hidden = !next;
    el('exerciseActions').hidden = !next;
    el('preview').hidden = !next;
    renderJoin(next?.join_code);
    el('attachBus').hidden = !next;
    el('attachCar').hidden = !next;
    const briefing = next?.patients.find((patient) => patient.model?.bus_briefing)?.model.bus_briefing;
    el('busBriefing').hidden = !briefing;
    el('busBriefing').textContent = briefing ?? '';
    if (!next) {
      el('choose').replaceChildren();
      el('patientOverview').replaceChildren();
      el('liveTitle').textContent = '';
      for (const id of ['secret', 'vitals', 'triage', 'patientStatus', 'expiry']) el(id).textContent = '';
      el('patientLink').value = '';
      el('patientLink').hidden = true;
      el('openPatientLink').removeAttribute('href');
      renderStation(null);
      resetPreview();
      return;
    }
    const rebuild = changed || el('choose').options.length !== next.patients.length;
    if (rebuild) {
      el('choose').replaceChildren(...next.patients.map((patient) => new Option(patientName(patient.id), patient.id)));
      el('choose').value = next.patients.some((patient) => patient.id === previous) ? previous : next.patients[0].id;
      if (changed) resetPreview();
    }
    el('liveTitle').textContent = next.title;
    el('expiry').textContent = 'Zugang gültig bis ' + new Date(next.expires_at).toLocaleString('de-DE');
    renderOverview(rebuild);
    renderPatient();
  }

  function renderJoin(code) {
    el('exerciseJoin').hidden = !code;
    if (!code) {
      el('joinQr').replaceChildren();
      delete el('joinQr').dataset.url;
      el('joinLink').value = '';
      return;
    }
    const url = new URL('join.html', location.href);
    url.hash = new URLSearchParams({ access: code });
    el('joinLink').value = url.href;
    drawQr(el('joinQr'), url.href, 'QR-Code zum Übungsbeitritt');
  }

  function drawQr(container, url, title) {
    if (container.dataset.url === url) return;
    if (typeof window.qrcode !== 'function') {
      container.textContent = 'QR-Code gerade nicht verfügbar. Lade die Seite neu oder kopiere den Link.';
      delete container.dataset.url;
      return;
    }
    const qr = window.qrcode(0, 'M');
    qr.addData(url);
    qr.make();
    container.innerHTML = qr.createSvgTag({ cellSize: 5, scalable: true, title });
    container.dataset.url = url;
  }

  function renderStation(url) {
    const target = el('stationQr');
    el('station').hidden = !url;
    if (!url) {
      target.replaceChildren();
      delete target.dataset.url;
    } else {
      drawQr(target, url, 'Stations-QR für diesen Patienten');
    }
  }

  function renderOverview(rebuild = false) {
    const overview = el('patientOverview');
    if (rebuild) {
      const rows = exercise.patients.map((patient) => {
        const row = document.createElement('li');
        const button = document.createElement('button');
        button.type = 'button';
        const name = document.createElement('strong');
        name.textContent = patientName(patient.id);
        const category = document.createElement('span');
        const status = document.createElement('span');
        status.className = 'patient-runtime';
        const forecast = document.createElement('span');
        forecast.className = 'patient-forecast muted';
        button.append(name, category, status, forecast);
        button.addEventListener('click', () => {
          el('choose').value = patient.id;
          el('choose').dispatchEvent(new Event('change'));
          el('choose').focus();
        });
        row.append(button);
        return row;
      });
      overview.replaceChildren(...rows);
    }
    const selected = el('choose').value;
    exercise.patients.forEach((patient, index) => {
      const button = overview.children[index].firstElementChild;
      const [, category, status, forecast] = button.children;
      const label = categoryLabels[patient.category];
      button.setAttribute('aria-pressed', String(patient.id === selected));
      category.className = label ? 'triage patient-category ' + patient.category : 'patient-category muted';
      category.textContent = label ?? '–';
      status.textContent = api.labels[patient.status] + ' · ' + api.clock(patient.elapsed);
      forecast.textContent = forecastLabel(patient);
      forecast.hidden = !forecast.textContent;
    });
  }

  function renderPatient() {
    const patient = selectedPatient();
    if (!patient) return;
    const url = new URL('patient.html', location.href);
    url.search = new URLSearchParams({ case: exercise.case, patient: patient.id });
    const station = url.href;
    url.hash = new URLSearchParams({ code: patient.code });
    const carPatient = patient.model?.car_number != null;
    el('stationTitle').textContent = carPatient ? patientName(patient.id) : 'Stations-QR für diesen Patienten';
    renderStation(patient.custom ? (carPatient ? url.href : station) : null);
    const linkField = el('patientLink');
    if (linkField.value !== url.href) {
      linkField.value = url.href;
      linkField.hidden = true;
      el('openPatientLink').href = url.href;
    }
    el('patientStatus').textContent = [categoryLabels[patient.category], api.labels[patient.status],
      api.clock(patient.elapsed)].filter(Boolean).join(' · ');
    for (const button of actions) {
      const action = button.dataset.action;
      button.disabled = busy || (action === 'pause' && patient.status !== 'running')
        || (action === 'resume' && patient.status !== 'paused');
    }
  }

  function session(data) {
    if (!data?.access_token || !data.refresh_token) throw new Error('Die Anmeldung lieferte keine gültige Sitzung.');
    auth = { ...data, deadline: Date.now() + data.expires_in * 1000 };
  }

  async function rpc(params, call = api.trainer) {
    if (Date.now() + 30000 >= auth.deadline) {
      if (!refreshing) {
        const current = auth;
        refreshing = api.refresh(current.refresh_token).then((data) => {
          if (auth === current) session(data);
        }).finally(() => { refreshing = null; });
      }
      await refreshing;
    }
    if (!auth) throw new Error('Bitte erneut anmelden.');
    return call(params, auth.access_token);
  }

  function signedOut() {
    const token = auth?.access_token;
    auth = null;
    renderExercise(null);
    el('exercise').replaceChildren();
    el('workspace').hidden = true;
    showView(false);
    el('logout').hidden = true;
    el('login').hidden = false;
    if (token) void api.signOut(token).catch(() => {});
  }

  async function run(work) {
    if (busy) return;
    busy = true;
    actionVersion++;
    for (const control of document.querySelectorAll('form button, #logout, #exercise, #createCustom, #startBus, #attachBus')) control.disabled = true;
    renderPatient();
    try {
      await work();
    } catch (error) {
      if (error.status === 401 || error.code === '42501' || el('workspace').hidden) signedOut();
      message(error.message);
    } finally {
      busy = false;
      for (const control of document.querySelectorAll('form button, #logout, #exercise, #createCustom, #startBus, #attachBus')) control.disabled = false;
      renderPatient();
    }
  }

  el('login').addEventListener('submit', (event) => {
    event.preventDefault();
    const email = el('email').value.trim();
    const password = el('password').value;
    if (event.submitter?.id === 'register') {
      if (password.length < 8) {
        message('Wähle ein Passwort mit mindestens acht Zeichen.');
        return;
      }
      void run(async () => {
        await api.signUp(email, password, new URL('trainer.html', location.href).href);
        el('password').value = '';
        message('Bestätige deine E-Mail-Adresse über den Link in der Nachricht. Öffne anschließend wieder diese Ausbilderansicht und melde dich an.');
      });
      return;
    }
    void run(async () => {
      session(await api.signIn(email, password));
      el('password').value = '';
      const list = await rpc({ p_action: 'list' });
      options(el('exercise'), list, 'Übung auswählen');
      el('login').hidden = true;
      el('logout').hidden = false;
      el('workspace').hidden = false;
      message('Als Ausbilder angemeldet.');
      if (list.length) {
        el('exercise').value = list[0].id;
        renderExercise(await rpc({ p_action: 'status', p_session: list[0].id }));
        showView(true);
      }
    });
  });

  el('logout').addEventListener('click', () => {
    if (busy) return;
    signedOut();
    message('Abgemeldet.');
  });
  el('exercise').addEventListener('change', () => {
    const id = el('exercise').value;
    void run(async () => {
      renderExercise(id ? await rpc({ p_action: 'status', p_session: id }) : null);
      showView(Boolean(id));
    });
  });
  el('create').addEventListener('submit', (event) => {
    event.preventDefault();
    void run(async () => {
      const created = await rpc({ p_action: 'create', p_title: el('exerciseTitle').value });
      openCreatedExercise(created);
      el('exerciseTitle').value = '';
    });
  });
  function openCreatedExercise(created) {
    el('exercise').add(new Option(created.title, created.id), 1);
    el('exercise').value = created.id;
    renderExercise(created);
    message('Übung angelegt. Ergänze weitere Stationen oder öffne die Übungsansicht.');
  }

  el('createCustom').addEventListener('click', () => {
    void run(async () => {
      const input = el('scenarioFile');
      const file = input.files[0];
      if (file?.size > 200000) throw new Error('Die JSON-Datei ist zu groß.');
      const source = file ? await file.text() : localStorage.getItem('traumasim-editor-v1');
      if (!source) throw new Error('Speichere zuerst einen Entwurf im Szenarioeditor oder wähle eine JSON-Datei.');
      let draft;
      try { draft = JSON.parse(source); } catch { throw new Error('Der Entwurf ist keine gültige JSON-Datei.'); }
      openCreatedExercise(await rpc(draft, api.createCustom));
      input.value = '';
    });
  });
  for (const [button, attach] of [['startBus', false], ['attachBus', true]]) {
    el(button).addEventListener('click', () => {
      void run(async () => {
        const capacity = Number(el('busCapacity').value);
        const params = { p_capacity: capacity, p_session: attach ? exercise.id : null };
        const next = await rpc(params, api.bookBus);
        if (attach) {
          renderExercise(next);
          message('Bus mit ' + capacity + ' Personen hinzugefügt.');
        } else {
          openCreatedExercise(next);
        }
      });
    });
  }
  const seatControls = [
    ['driver', 'Fahrerplatz'], ['front', 'Beifahrerplatz'], ['rear-left', 'Hinten links'],
    ['rear-center', 'Hinten Mitte'], ['rear-right', 'Hinten rechts']
  ].map(([seat, label]) => {
    const group = document.createElement('fieldset');
    group.className = 'car-seat';
    group.innerHTML = `<legend>${label}</legend>
      <label>Besetzung und Verletzungsprofil
        <select class="seat-profile">
          <option value="">Leer</option><option value="affected">Unverletzt betroffen</option>
          <option value="minor">Leicht verletzt · SK III</option><option value="urgent">Schwer verletzt · SK II</option>
          <option value="critical">Vital bedroht · SK I</option>
          <option value="green-yellow">Verlauf · SK III → SK II</option>
          <option value="urgent-red">Verlauf · SK II → SK I</option>
          <option value="red-ex">Verlauf · SK I → EX (schwarz)</option>
        </select>
      </label>
      <div class="seat-details" hidden>
        <label class="seat-transition-label" hidden>Kategorienwechsel ab Patientenstart
          <strong class="seat-transition-value" aria-hidden="true"></strong>
          <input class="seat-transition" type="range" min="1" max="44" step="1" disabled>
        </label>
        <label>Befreiungslage
          <select class="seat-access">
            <option value="none">Frei zugänglich</option>
            <option value="enclosed">Eingeschlossen</option>
            <option value="trapped">Eingeklemmt</option>
          </select>
        </label>
        <label class="seat-entrapment-label" hidden>Klemmstelle
          <select class="seat-entrapment" required disabled>
            <option value="">Klemmstelle auswählen</option>
            <option value="door">Tür / B-Säule</option>
            <option value="footwell">Fußraum / Bein</option><option value="dashboard">Sitz / Armaturenbrett</option>
            <option value="roof">Dach / Sitz</option>
          </select>
        </label>
        <label>Eigene Verletzungsbeschreibung (optional)
          <input class="seat-injury" maxlength="400">
        </label>
      </div>`;
    const profile = group.querySelector('.seat-profile');
    const details = group.querySelector('.seat-details');
    const transition = group.querySelector('.seat-transition');
    const transitionLabel = group.querySelector('.seat-transition-label');
    const transitionValue = group.querySelector('.seat-transition-value');
    const access = group.querySelector('.seat-access');
    const entrapment = group.querySelector('.seat-entrapment');
    const entrapmentLabel = group.querySelector('.seat-entrapment-label');
    function showEntrapment() {
      entrapment.disabled = entrapmentLabel.hidden = !profile.value || access.value !== 'trapped';
    }
    access.addEventListener('change', showEntrapment);
    function showTransitionMinute() {
      const text = 'Minute ' + transition.value;
      transitionValue.textContent = text;
      transition.setAttribute('aria-valuetext', text);
    }
    transition.addEventListener('input', showTransitionMinute);
    profile.addEventListener('change', () => {
      details.hidden = !profile.value;
      showEntrapment();
      const defaultMinute = { 'green-yellow': 12, 'urgent-red': 6, 'red-ex': 8 }[profile.value];
      transition.disabled = transitionLabel.hidden = defaultMinute == null;
      if (defaultMinute != null) {
        transition.value = defaultMinute;
        showTransitionMinute();
      }
    });
    el('carSeats').append(group);
    return { seat, profile, transition, access, entrapment, injury: group.querySelector('.seat-injury') };
  });

  el('carForm').addEventListener('submit', (event) => {
    event.preventDefault();
    const attach = event.submitter?.id === 'attachCar';
    void run(async () => {
      const occupants = seatControls.filter((row) => row.profile.value).map((row) => ({
        seat: row.seat, profile: row.profile.value, injury: row.injury.value,
        entrapment: row.access.value === 'trapped' ? row.entrapment.value : row.access.value,
        transition_minute: row.transition.disabled ? null : row.transition.valueAsNumber
      }));
      if (!occupants.length) throw new Error('Wähle mindestens einen besetzten Sitzplatz.');
      const next = await rpc({ p_config: { vehicle: el('carSituation').value, occupants },
        p_session: attach ? exercise.id : null }, api.bookCar);
      if (attach) {
        renderExercise(next);
        const number = Math.max(...next.patients.map((patient) => patient.model.car_number ?? 0));
        const first = next.patients.find((patient) => patient.model.car_number === number);
        el('choose').value = first.id;
        renderOverview();
        renderPatient();
        resetPreview();
        message('Pkw ' + String(number).padStart(2, '0') + ' hinzugefügt.');
      } else {
        openCreatedExercise(next);
      }
      el('carForm').reset();
      for (const row of seatControls) row.profile.dispatchEvent(new Event('change'));
    });
  });
  el('choose').addEventListener('change', () => {
    renderOverview();
    renderPatient();
    resetPreview();
  });
  for (const button of actions) {
    button.addEventListener('click', () => {
      const action = button.dataset.action;
      const patient = selectedPatient();
      if (!exercise || !patient || busy) return;
      if (action.startsWith('reset') && !confirm(action === 'reset_all'
        ? 'Alle Patienten dieser Übung zurücksetzen?' : patientName(patient.id) + ' zurücksetzen?')) return;
      if (action === 'close' && !confirm('Übung beenden und alle Zugänge schließen?')) return;
      void run(async () => {
        const next = await rpc({ p_action: action, p_session: exercise.id, p_patient: patient.id });
        if (next.closed) {
          const select = el('exercise');
          Array.from(select.options).find((option) => option.value === next.id)?.remove();
          select.value = '';
          renderExercise(null);
          message('Übung beendet. Die QR-Zugänge sind geschlossen.');
          return;
        }
        renderExercise(next);
        if (action.startsWith('reset')) message('Zurückgesetzt.');
      });
    });
  }

  for (const [button, field] of [['copyLink', 'patientLink'], ['copyJoin', 'joinLink']]) {
    el(button).addEventListener('click', async () => {
      const input = el(field);
      try {
        await navigator.clipboard.writeText(input.value);
        message('Kopiert.');
      } catch {
        input.hidden = false;
        input.focus();
        input.select();
        message('Der Text ist markiert und kann kopiert werden.');
      }
    });
  }

  el('play').addEventListener('click', () => {
    if (previewTime >= previewDuration) previewTime = 0;
    previewTick = performance.now();
  });
  el('pause').addEventListener('click', () => { previewTick = null; });
  el('reset').addEventListener('click', resetPreview);
  el('seek').addEventListener('input', () => {
    previewTime = Number(el('seek').value) * 60;
    if (previewTick !== null) previewTick = performance.now();
    drawPreview();
  });
  setInterval(() => {
    if (previewTick === null) return;
    const now = performance.now();
    previewTime = Math.min(previewDuration, previewTime + (now - previewTick) / 1000 * Number(el('speed').value));
    previewTick = previewTime < previewDuration ? now : null;
    drawPreview();
  }, 200);
  async function poll() {
    if (!auth || !exercise || busy || polling || document.hidden) return;
    polling = true;
    const version = actionVersion;
    try {
      const next = await rpc({ p_action: 'status', p_session: exercise.id });
      if (auth && version === actionVersion) renderExercise(next);
    } catch (error) {
      if (auth && version === actionVersion) {
        if (error.status === 401 || error.code === '42501') signedOut();
        message(error.message);
      }
    } finally {
      polling = false;
    }
  }

  setInterval(poll, 3000);
})();
