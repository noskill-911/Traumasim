(function () {
  'use strict';

  const el = (id) => document.getElementById(id);
  const api = window.TraumaSync;
  const previewDuration = Number(el('seek').max) * 60;
  const actions = Array.from(document.querySelectorAll('[data-action]'));
  const sessionKey = 'traumasim:trainer-session';
  const sessionLifetime = 24 * 60 * 60 * 1000;
  const categoryLabels = {
    red: 'SK I · Rot', yellow: 'SK II · Gelb', green: 'SK III · Grün',
    black: 'EX · Schwarz', affected: 'Unverletzt betroffen'
  };
  const busStationPattern = /^bus-(5|10)-(\d{2})$/;
  const busLocations = [
    'Neben der Fahrertür', 'Vorn am Querplatz, am Boden', 'Im Mittelgang',
    'Seitlich in der hinteren Sitzreihe', 'Neben der mittleren Tür',
    'Zweite Sitzreihe, neben dem Sitz', 'An der Mitteltür, am Boden',
    'Im Türbereich, nahe dem Haltegriff', 'Hinten links am Fensterplatz',
    'An der Hintertür, zwischen Sitzreihe und Tür'
  ];
  let auth = null;
  let persistentSession = false;
  let exercise = null;
  let busy = false;
  let polling = false;
  let actionVersion = 0;
  let refreshing = null;
  let previewTime = 0;
  let previewTick = null;
  let carEditVersion = 0;
  let loadedCarNumber = '';
  let carFormBaseline = '';

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

  function renderComposition() {
    const panel = el('exerciseComposition');
    panel.hidden = !exercise;
    if (!exercise) return;

    const cars = new Map();
    const buses = new Map();
    let other = 0;
    for (const patient of exercise.patients) {
      const carNumber = patient.model?.car_number;
      const bus = busStationPattern.exec(patient.id);
      const exampleCar = exercise.case === 'vu-baum' && ['fahrer', 'beifahrer'].includes(patient.id);
      if (carNumber != null || exampleCar) {
        const label = exampleCar ? 'Beispiel-Pkw' : 'Pkw ' + String(carNumber).padStart(2, '0');
        cars.set(label, (cars.get(label) ?? 0) + 1);
      } else if (bus) {
        const label = 'Bus (' + bus[1] + ' Plätze)';
        buses.set(label, (buses.get(label) ?? 0) + 1);
      } else {
        other++;
      }
    }
    el('compositionCars').textContent = cars.size;
    el('compositionBuses').textContent = buses.size;
    el('compositionPatients').textContent = exercise.patients.length;
    const vehicles = (counts) => [...counts].sort(([a], [b]) => a.localeCompare(b, 'de', { numeric: true }));
    const details = [...vehicles(cars), ...vehicles(buses)]
      .map(([label, count]) => label + ' · ' + count + (count === 1 ? ' Person' : ' Personen'));
    if (other) details.push(other === 1 ? '1 weitere Person' : other + ' weitere Personen');
    el('compositionDetails').replaceChildren(...details.map((label) => {
      const item = document.createElement('li');
      item.textContent = label;
      return item;
    }));
  }

  function renderExercise(next) {
    const previous = selectedPatient()?.id;
    const changed = exercise?.id !== next?.id;
    exercise = next;
    el('noExercise').hidden = Boolean(next);
    el('live').hidden = !next;
    el('patientControls').hidden = !next;
    el('exerciseToolbar').hidden = !next;
    el('saveTemplateForm').hidden = !next;
    el('updateTemplate').hidden = !next;
    el('preview').hidden = !next;
    renderJoin(next?.join_code);
    el('attachBus').hidden = !next;
    if (changed || el('choose').options.length !== (next?.patients.length ?? 0)) updateCarChoices(changed);
    updateCarActions();
    const briefing = next?.patients.find((patient) => patient.model?.bus_briefing)?.model.bus_briefing;
    el('busBriefing').hidden = !briefing;
    el('busBriefing').textContent = briefing ?? '';
    if (!next) {
      renderComposition();
      el('choose').replaceChildren();
      el('patientOverview').replaceChildren();
      el('liveTitle').textContent = '';
      for (const id of ['secret', 'vitals', 'triage', 'patientStatus', 'expiry']) el(id).textContent = '';
      el('patientLink').value = '';
      el('patientLink').hidden = true;
      el('openPatientLink').removeAttribute('href');
      el('previewPatientLink').removeAttribute('href');
      el('previewPatientLink').hidden = true;
      renderStation(null);
      resetPreview();
      return;
    }
    const choose = el('choose');
    const rebuild = changed || choose.options.length !== next.patients.length
      || next.patients.some((patient, index) => choose.options[index].value !== patient.id
        || choose.options[index].textContent !== patientName(patient.id));
    if (rebuild) {
      renderComposition();
      choose.replaceChildren(...next.patients.map((patient) => new Option(patientName(patient.id), patient.id)));
      choose.value = next.patients.some((patient) => patient.id === previous) ? previous : next.patients[0].id;
      if (changed) resetPreview();
    }
    el('liveTitle').textContent = next.title;
    el('expiry').textContent = 'Zugang gültig bis ' + new Date(next.expires_at).toLocaleString('de-DE');
    renderOverview(rebuild, changed);
    renderPatient();
  }

  function renderJoin(code) {
    el('exerciseJoin').hidden = !code;
    const link = el('joinLink');
    if (!code) {
      el('joinQr').replaceChildren();
      delete el('joinQr').dataset.url;
      link.value = '';
      link.hidden = true;
      return;
    }
    const url = new URL('join.html', location.href);
    url.hash = new URLSearchParams({ access: code });
    if (link.value !== url.href) {
      link.value = url.href;
      link.hidden = true;
    }
    drawQr(el('joinQr'), url.href, 'QR-Code zum Übungsbeitritt');
  }

  el('resizeJoinQr').addEventListener('click', () => {
    const enlarged = el('joinQr').classList.toggle('is-enlarged');
    el('resizeJoinQr').textContent = enlarged ? 'QR verkleinern' : 'QR vergrößern';
  });

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
    el('stationDownload').hidden = !target.querySelector('svg');
  }

  el('stationDownload').addEventListener('click', () => {
    const svg = el('stationQr').querySelector('svg');
    const patient = selectedPatient();
    if (!svg || !patient) return;
    const url = URL.createObjectURL(new Blob([svg.outerHTML], { type: 'image/svg+xml' }));
    const download = document.createElement('a');
    download.href = url;
    download.download = patient.id + '-station.svg';
    download.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  });

  function stationUrl(patient) {
    const url = new URL('patient.html', location.href);
    url.search = new URLSearchParams({ case: exercise.case, patient: patient.id });
    return url;
  }

  function patientLink(url, patient) {
    const link = new URL(url);
    link.hash = new URLSearchParams({ code: patient.code });
    return link.href;
  }

  function stationGroup(patient) {
    if (patient.model?.car_number != null) {
      return 'PKW ' + String(patient.model.car_number).padStart(2, '0');
    }
    const bus = busStationPattern.exec(patient.id);
    if (bus) return 'Bus · ' + bus[1] + ' Personen';
    if (exercise.case === 'vu-baum' && ['fahrer', 'beifahrer'].includes(patient.id)) {
      return 'Beispiel-Pkw';
    }
    return 'Weitere Stationen';
  }

  function compareStationGroups(a, b) {
    const order = (name) => name.startsWith('PKW ') ? 0 : name.startsWith('Bus ') ? 1 : 2;
    return order(a) - order(b) || a.localeCompare(b, 'de', { numeric: true });
  }

  function printLabel(patient) {
    const number = (value) => String(value).padStart(2, '0');
    const name = patientName(patient.id);
    const model = patient.model;
    if (model?.car_number != null) {
      const seat = name.split(' · ').at(-1).replace(/^Fahrerplatz$/, 'Fahrer').replace(/^Beifahrerplatz$/, 'Beifahrer');
      return { label: number(model.car_patient_number) + ' ' + seat };
    }
    const bus = busStationPattern.exec(patient.id);
    if (bus) {
      const position = bus[2];
      return {
        label: position + (position === '01' ? ' Busfahrer' : ' Fahrgast'),
        place: busLocations[Number(position) - 1]
      };
    }
    return { label: name };
  }

  function updatePrintStations(reset = false) {
    const group = el('printVehicle').value;
    const select = el('printStation');
    const previous = reset ? '' : select.value;
    const stations = exercise.patients
      .filter((patient) => !group || stationGroup(patient) === group)
      .map((patient) => {
        const label = printLabel(patient).label;
        return { id: patient.id, title: group ? label : stationGroup(patient) + ' · ' + label };
      });
    options(select, stations, group ? 'Alle Stationen dieses Fahrzeugs' : 'Alle Stationen');
    if (stations.some((station) => station.id === previous)) select.value = previous;
  }

  function updateStationFilters(reset) {
    const groups = [...new Set(exercise.patients.map(stationGroup))]
      .sort(compareStationGroups)
      .map((group) => ({ id: group, title: group }));
    for (const id of ['overviewVehicle', 'printVehicle']) {
      const select = el(id);
      const previous = reset ? '' : select.value;
      options(select, groups, 'Alle Fahrzeuge und Stationen');
      if (groups.some((group) => group.id === previous)) select.value = previous;
    }
    if (reset) {
      el('overviewCategory').value = '';
      el('overviewStatus').value = '';
    }
    updatePrintStations(reset);
  }

  el('printVehicle').addEventListener('change', () => updatePrintStations());

  el('printStations').addEventListener('click', () => {
    if (!exercise?.patients.length) return;
    if (typeof window.qrcode !== 'function') {
      message('QR-Codes sind gerade nicht verfügbar. Lade die Seite neu.');
      return;
    }
    const perPage = Number(el('printPerPage').value);
    const selectedGroup = el('printVehicle').value;
    const selectedStation = el('printStation').value;
    const groups = new Map();
    for (const patient of exercise.patients) {
      const group = stationGroup(patient);
      if (selectedGroup && group !== selectedGroup) continue;
      if (selectedStation && patient.id !== selectedStation) continue;
      const qrUrl = patientLink(stationUrl(patient), patient);
      if (!groups.has(group)) groups.set(group, []);
      groups.get(group).push({ ...printLabel(patient), qrUrl });
    }
    if (!groups.size) return;
    const expiresAt = new Intl.DateTimeFormat('de-DE', {
      dateStyle: 'medium', timeStyle: 'short', timeZone: 'Europe/Berlin'
    }).format(new Date(exercise.expires_at));
    const pages = [];
    const sortedGroups = [...groups.entries()].sort(([a], [b]) => compareStationGroups(a, b));
    for (const [group, stations] of sortedGroups) {
      for (let offset = 0; offset < stations.length; offset += perPage) {
        const sheet = document.createElement('section');
        sheet.className = 'station-sheet';
        for (const station of stations.slice(offset, offset + perPage)) {
          const card = document.createElement('article');
          const run = document.createElement('p');
          run.className = 'station-card-meta';
          run.textContent = exercise.title;
          const vehicle = document.createElement('h2');
          vehicle.textContent = group;
          const patient = document.createElement('p');
          patient.className = 'station-card-label';
          patient.textContent = station.label;
          const code = document.createElement('div');
          code.className = 'station-card-qr';
          drawQr(code, station.qrUrl, 'Stations-QR');
          card.append(run, vehicle, patient, code);
          if (station.place) {
            const place = document.createElement('p');
            place.className = 'station-card-place';
            place.textContent = 'Auffindeort · ' + station.place;
            card.append(place);
          }
          const validity = document.createElement('p');
          validity.className = 'station-card-meta';
          validity.textContent = 'Gültig bis ' + expiresAt + ' Uhr (Berlin)';
          card.append(validity);
          sheet.append(card);
        }
        pages.push(sheet);
      }
    }
    const print = el('stationPrint');
    print.classList.toggle('two-per-page', perPage === 2);
    print.replaceChildren(...pages);
    document.body.classList.add('printing-stations');
    window.print();
  });

  window.addEventListener('afterprint', () => {
    document.body.classList.remove('printing-stations');
    el('stationPrint').replaceChildren();
  });

  for (const id of ['overviewVehicle', 'overviewCategory', 'overviewStatus']) {
    el(id).addEventListener('change', () => renderOverview());
  }

  function renderOverview(rebuild = false, resetFilters = false) {
    const overview = el('patientOverview');
    if (rebuild) {
      updateStationFilters(resetFilters);
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
    const groupFilter = el('overviewVehicle').value;
    const categoryFilter = el('overviewCategory').value;
    const statusFilter = el('overviewStatus').value;
    let visible = 0;
    exercise.patients.forEach((patient, index) => {
      const row = overview.children[index];
      row.hidden = Boolean((groupFilter && stationGroup(patient) !== groupFilter)
        || (categoryFilter && (patient.category ?? 'none') !== categoryFilter)
        || (statusFilter && patient.status !== statusFilter));
      if (!row.hidden) visible++;
      const button = row.firstElementChild;
      const [, category, status, forecast] = button.children;
      const label = categoryLabels[patient.category];
      button.setAttribute('aria-pressed', String(patient.id === selected));
      category.className = label ? 'triage patient-category ' + patient.category : 'patient-category muted';
      category.textContent = label ?? '–';
      status.textContent = api.labels[patient.status] + ' · ' + api.clock(patient.elapsed);
      forecast.textContent = forecastLabel(patient);
      forecast.hidden = !forecast.textContent;
    });
    const count = el('overviewCount');
    const text = visible + ' von ' + exercise.patients.length + ' Patienten angezeigt.';
    if (count.textContent !== text) count.textContent = text;
  }

  function renderPatient() {
    const patient = selectedPatient();
    if (!patient) return;
    const station = stationUrl(patient).href;
    const link = patientLink(station, patient);
    const carPatient = patient.model?.car_number != null;
    el('stationTitle').textContent = carPatient ? patientName(patient.id) : 'Stations-QR für diesen Patienten';
    renderStation(link);
    const previewLink = el('previewPatientLink');
    previewLink.hidden = !patient.preview_code;
    if (patient.preview_code) {
      const url = new URL(station);
      url.hash = new URLSearchParams({ preview: patient.preview_code });
      previewLink.href = url.href;
    } else {
      previewLink.removeAttribute('href');
    }
    const linkField = el('patientLink');
    if (linkField.value !== link) {
      linkField.value = link;
      linkField.hidden = true;
      el('openPatientLink').href = link;
    }
    el('patientStatus').textContent = [categoryLabels[patient.category], api.labels[patient.status],
      api.clock(patient.elapsed)].filter(Boolean).join(' · ');
    for (const button of actions) {
      const action = button.dataset.action;
      button.disabled = busy || (action === 'pause' && patient.status !== 'running')
        || (action === 'resume' && patient.status !== 'paused');
    }
  }

  function readSession() {
    try {
      const saved = JSON.parse(localStorage.getItem(sessionKey));
      return saved && typeof saved.id === 'string' && typeof saved.access_token === 'string'
        && typeof saved.refresh_token === 'string' && Number.isFinite(saved.deadline)
        && Number.isFinite(saved.until) ? saved : null;
    } catch {
      return null;
    }
  }

  function saveSession(data, id, until) {
    if (!data?.access_token || !data.refresh_token || !(data.expires_in > 0)) {
      throw new Error('Die Anmeldung lieferte keine gültige Sitzung.');
    }
    auth = { id, until, access_token: data.access_token, refresh_token: data.refresh_token,
      deadline: Date.now() + data.expires_in * 1000 };
    try {
      localStorage.setItem(sessionKey, JSON.stringify(auth));
      persistentSession = true;
    } catch {
      persistentSession = false;
    }
  }

  function currentSession() {
    if (persistentSession) {
      const saved = readSession();
      auth = saved?.id === auth?.id ? saved : null;
    }
    return auth;
  }

  function needsLogin() {
    return Object.assign(new Error('Die Ausbildersitzung ist abgelaufen. Bitte erneut anmelden.'), { status: 401 });
  }

  async function refreshSession() {
    const refresh = async () => {
      const current = currentSession();
      if (!current || Date.now() >= current.until) throw needsLogin();
      if (Date.now() + 30000 < current.deadline) return;
      let data;
      try {
        data = await api.refresh(current.refresh_token);
      } catch (error) {
        if ([400, 401, 403].includes(error.status)) throw needsLogin();
        throw error;
      }
      const latest = currentSession();
      if (!latest || latest.id !== current.id || Date.now() >= latest.until) throw needsLogin();
      if (latest.refresh_token === current.refresh_token) saveSession(data, current.id, current.until);
    };
    // Read the stored token inside the lock because another tab may have rotated it.
    if (navigator.locks) await navigator.locks.request(sessionKey, refresh);
    else await refresh();
  }

  async function rpc(params, call = api.trainer) {
    const current = currentSession();
    if (!current || Date.now() >= current.until) throw needsLogin();
    if (Date.now() + 30000 >= current.deadline) {
      if (!refreshing) {
        refreshing = refreshSession().finally(() => { refreshing = null; });
      }
      await refreshing;
    }
    const ready = currentSession();
    if (!ready || ready.id !== current.id || Date.now() >= ready.until) throw needsLogin();
    const result = await call(params, ready.access_token);
    if (currentSession()?.id !== ready.id) throw needsLogin();
    return result;
  }

  function signedOut(revoke = false) {
    const saved = readSession();
    const current = saved && saved.id === auth?.id ? saved : auth;
    if (current && saved?.id === current.id) {
      try { localStorage.removeItem(sessionKey); } catch {}
    }
    auth = null;
    persistentSession = false;
    actionVersion++;
    renderExercise(null);
    loadCarForm();
    el('exercise').replaceChildren();
    renderTemplateOptions([]);
    el('workspace').hidden = true;
    showView(false);
    el('logout').hidden = true;
    el('login').hidden = false;
    if (revoke && current) void api.signOut(current.access_token).catch(() => {});
  }

  function handleError(error) {
    if (error.status === 401 || (error.code === '42501'
      && error.message === 'Konto nicht für die Ausbilderansicht freigegeben')) {
      signedOut();
    } else if (exerciseUnavailable(error)) {
      el('exercise').selectedOptions[0]?.remove();
      el('exercise').value = '';
      renderExercise(null);
    }
    message(error.message);
  }

  function exerciseUnavailable(error) {
    return error.code === '42501' && error.message === 'Übung nicht verfügbar oder abgelaufen';
  }

  function renderTemplateOptions(templates) {
    options(el('exerciseTemplate'), templates, 'Vorlage auswählen');
    el('templateRunTitle').value = '';
    el('startTemplateForm').hidden = !templates.length;
    el('noTemplates').hidden = Boolean(templates.length);
  }

  async function openWorkspace(list) {
    options(el('exercise'), list, 'Übung auswählen');
    el('login').hidden = true;
    el('logout').hidden = false;
    el('workspace').hidden = false;
    message('Als Ausbilder angemeldet.');
    if (list.length) {
      await switchExercise(list[0].id);
    }
    renderTemplateOptions(await rpc({ p_action: 'list_templates' }));
  }

  async function run(work) {
    if (busy) return;
    busy = true;
    actionVersion++;
    const controls = document.querySelectorAll('form button, #logout, #exercise, #createCustom, #startBus, #attachBus, #editCar');
    for (const control of controls) control.disabled = true;
    renderPatient();
    try {
      await work();
    } catch (error) {
      if (el('workspace').hidden) el('login').hidden = false;
      handleError(error);
    } finally {
      busy = false;
      for (const control of controls) control.disabled = false;
      updateCarActions();
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
      const data = await api.signIn(email, password);
      el('password').value = '';
      const list = await api.trainer({ p_action: 'list' }, data.access_token);
      saveSession(data, crypto.randomUUID(), Date.now() + sessionLifetime);
      await openWorkspace(list);
    });
  });

  el('logout').addEventListener('click', () => {
    if (busy) return;
    void run(async () => {
      if (!await confirmCarChanges()) return;
      signedOut(true);
      message('Abgemeldet.');
    });
  });
  el('exercise').addEventListener('change', () => {
    const id = el('exercise').value;
    el('exercise').value = exercise?.id ?? '';
    void run(async () => {
      if (id === exercise?.id || !await confirmCarChanges()) return;
      await switchExercise(id);
    });
  });
  async function switchExercise(id) {
    const select = el('exercise');
    let next;
    try {
      next = id ? await rpc({ p_action: 'status', p_session: id }) : null;
    } catch (error) {
      if (!exerciseUnavailable(error)) throw error;
      Array.from(select.options).find((option) => option.value === id)?.remove();
      message(error.message);
      return;
    }
    select.value = next?.id ?? '';
    renderExercise(next);
    showView(Boolean(next));
  }

  el('saveTemplateForm').addEventListener('submit', (event) => {
    event.preventDefault();
    if (!exercise) return;
    void run(async () => {
      const template = await rpc({ p_action: 'save_template', p_session: exercise.id, p_title: el('templateTitle').value });
      const select = el('exerciseTemplate');
      select.add(new Option(template.title, template.id), 1);
      select.value = template.id;
      el('templateRunTitle').value = template.title;
      el('startTemplateForm').hidden = false;
      el('noTemplates').hidden = true;
      el('templateTitle').value = '';
      message('Übungsvorlage gespeichert.');
    });
  });

  el('exerciseTemplate').addEventListener('change', () => {
    const select = el('exerciseTemplate');
    el('templateRunTitle').value = select.value ? select.selectedOptions[0].textContent : '';
  });

  el('updateTemplate').addEventListener('click', () => {
    const select = el('exerciseTemplate');
    if (!exercise || !select.value) {
      message('Wähle zuerst eine Vorlage aus.');
      return;
    }
    if (!confirm('Vorlage „' + select.selectedOptions[0].textContent + '“ mit der Besetzung aus „' + exercise.title + '“ aktualisieren?')) return;
    void run(async () => {
      if (!await confirmCarChanges()) return;
      await rpc({ p_action: 'update_template', p_session: exercise.id, p_patient: select.value });
      message('Übungsvorlage aktualisiert.');
    });
  });

  el('startTemplateForm').addEventListener('submit', (event) => {
    event.preventDefault();
    const id = el('exerciseTemplate').value;
    if (!id) return;
    void run(async () => {
      if (!await confirmCarChanges()) return;
      openCreatedExercise(await rpc({ p_action: 'start_template', p_session: id, p_title: el('templateRunTitle').value }));
      showView(true);
    });
  });
  el('create').addEventListener('submit', (event) => {
    event.preventDefault();
    void run(async () => {
      if (!await confirmCarChanges()) return;
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
      const feedback = el('scenarioIssue');
      feedback.hidden = true;
      const input = el('scenarioFile');
      const file = input.files[0];
      const validator = window.TraumaScenario;
      if (file?.size > validator.MAX_BYTES) throw new Error('Die JSON-Datei ist zu groß.');
      const source = file ? await file.text() : localStorage.getItem('traumasim-editor-v1');
      if (!source) throw new Error('Speichere zuerst einen Entwurf im Szenarioeditor oder wähle eine JSON-Datei.');
      let draft;
      try { draft = JSON.parse(source); } catch { throw new Error('Der Entwurf ist keine gültige JSON-Datei.'); }
      const issue = validator.validate(draft);
      if (issue) {
        feedback.textContent = issue.message;
        feedback.hidden = false;
        return;
      }
      if (!await confirmCarChanges()) return;
      openCreatedExercise(await rpc(draft, api.createCustom));
      input.value = '';
    });
  });
  for (const [button, attach] of [['startBus', false], ['attachBus', true]]) {
    el(button).addEventListener('click', () => {
      void run(async () => {
        if (!attach && !await confirmCarChanges()) return;
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
    return { seat, label, group, profile, transition, access, entrapment, injury: group.querySelector('.seat-injury') };
  });

  function carPatients(number) {
    if (!number) return [];
    return (exercise?.patients ?? []).filter((patient) => patient.model?.car_number === Number(number));
  }

  function updateCarChoices(changed) {
    const select = el('editCar');
    const previous = changed ? '' : select.value;
    const numbers = [...new Set((exercise?.patients ?? []).map((p) => p.model?.car_number).filter((n) => n != null))];
    numbers.sort((a, b) => a - b);
    select.replaceChildren(new Option('Neuen Pkw konfigurieren', ''),
      ...numbers.map((number) => new Option('Pkw ' + String(number).padStart(2, '0') + ' bearbeiten', number)));
    select.value = numbers.includes(Number(previous)) ? previous : '';
    el('editCarChoice').hidden = !numbers.length;
    if (changed) loadCarForm();
  }

  function legacyCarConfig(model) {
    // Older bookings stored the generated description but not the form values.
    const seat = model.name.split(' · ').at(-1);
    const separator = '. Sitzplatz ' + seat + ', ';
    const at = model.intro.lastIndexOf(separator);
    const vehicle = at < 0 ? '' : model.intro.slice(0, at);
    const entrapment = {
      'eingeschlossen, Ausstieg versperrt': 'enclosed',
      'im Bereich von Tür und B-Säule eingeklemmt': 'door',
      'mit einem Bein im deformierten Fußraum eingeklemmt': 'footwell',
      'zwischen Sitz und Armaturenbrett eingeklemmt': 'dashboard',
      'im Bereich von Dach und Sitz eingeklemmt': 'roof'
    }[at < 0 ? '' : model.intro.slice(at + separator.length, -1)] ?? 'none';
    const profile = model.progression
      ? { yellow: 'green-yellow', red: 'urgent-red', black: 'red-ex' }[model.progression.to]
      : model.affected ? 'affected' : model.walkable ? 'minor' : model.nibpFastCycle ? 'critical' : 'urgent';
    const defaults = {
      affected: 'Keine Verletzung in dieser Übungsrolle. Die Person ist aufgewühlt.',
      minor: 'Die Person ist orientiert und klagt über eine schmerzhafte Prellung.',
      urgent: 'Die Person klagt über starke Schmerzen an einer Extremität. Verdacht auf eine Fraktur.',
      critical: 'Die Person ist blass, antwortet verzögert und wirkt zunehmend benommen.',
      'green-yellow': 'Beim Aufprall ist mein Unterschenkel gegen den Sitz vor mir gestoßen. Ein paar Schritte gingen noch, aber es tut weh.',
      'urgent-red': 'Die Person ist zunächst orientiert und klagt über Schmerzen nach einem Anprall.',
      'red-ex': 'Die Person ist blass, antwortet verzögert und wirkt zunehmend benommen.'
    };
    return {
      seat: seatControls.find((row) => row.label.toLowerCase() === seat.toLowerCase())?.seat,
      vehicle: vehicle === 'Fahrzeuglage vor Ort erkunden' ? '' : vehicle,
      profile, entrapment, injury: model.story === defaults[profile] ? '' : model.story
    };
  }

  function loadCarForm() {
    loadedCarNumber = el('editCar').value;
    const patients = carPatients(loadedCarNumber);
    el('carForm').reset();
    for (const row of seatControls) {
      row.group.hidden = Boolean(patients.length);
      row.profile.options[0].disabled = Boolean(patients.length);
      row.patientNumber = null;
      row.profile.dispatchEvent(new Event('change'));
    }
    carEditVersion = patients[0]?.model.car_edit_version ?? 0;
    for (const {model} of patients) {
      const config = model.car_seat ? {
        seat: model.car_seat, vehicle: model.car_vehicle, profile: model.car_profile,
        entrapment: model.car_entrapment, injury: model.car_injury
      } : legacyCarConfig(model);
      const row = seatControls.find((item) => item.seat === config.seat);
      if (!row) continue;
      row.group.hidden = false;
      row.patientNumber = model.car_patient_number;
      el('carSituation').value = config.vehicle ?? '';
      row.profile.value = config.profile;
      row.access.value = ['none', 'enclosed'].includes(config.entrapment) ? config.entrapment : 'trapped';
      row.entrapment.value = row.access.value === 'trapped' ? config.entrapment : '';
      row.injury.value = config.injury ?? '';
      row.profile.dispatchEvent(new Event('change'));
      if (model.progression) {
        row.transition.value = model.progression.at_seconds / 60;
        row.transition.dispatchEvent(new Event('input'));
      }
    }
    carFormBaseline = JSON.stringify(carFormConfig());
    showCarDirtyState();
    updateCarActions();
  }

  function updateCarActions() {
    const patients = carPatients(el('editCar').value);
    const editing = patients.length > 0;
    const started = patients.some((patient) => patient.status !== 'ready');
    el('startCar').hidden = editing;
    el('attachCar').hidden = !exercise || editing;
    el('saveCar').hidden = !editing;
    el('saveCar').disabled = busy || started;
    const status = el('carEditStatus');
    status.hidden = !editing;
    const text = started ? 'Setze die bereits gestarteten Patienten dieses Pkw vor dem Bearbeiten zurück.'
      : 'Änderungen gelten für die vorhandenen Insassen. Ihre Patienten-QRs bleiben gültig.';
    if (status.textContent !== text) status.textContent = text;
  }

  function carFormConfig() {
    const occupants = seatControls.filter((row) => row.profile.value).map((row) => ({
      seat: row.seat, profile: row.profile.value, injury: row.injury.value,
      patient_number: row.patientNumber,
      entrapment: row.access.value === 'trapped' ? row.entrapment.value : row.access.value,
      transition_minute: row.transition.disabled ? null : row.transition.valueAsNumber
    }));
    return { vehicle: el('carSituation').value, occupants };
  }

  function carFormIsDirty() {
    return carFormBaseline !== JSON.stringify(carFormConfig());
  }

  function showCarDirtyState() {
    const dirty = carFormIsDirty();
    el('carUnsaved').hidden = !dirty;
    if (dirty) window.addEventListener('beforeunload', warnBeforeLeaving);
    else window.removeEventListener('beforeunload', warnBeforeLeaving);
  }

  function warnBeforeLeaving(event) {
    event.preventDefault();
    event.returnValue = '';
  }

  async function confirmCarChanges() {
    if (!carFormIsDirty()) return true;
    const dialog = el('carChangesDialog');
    const started = carPatients(loadedCarNumber).some((patient) => patient.status !== 'ready');
    dialog.querySelector('[data-car-choice="save"]').disabled = started;
    el('carChangesMessage').textContent = started
      ? 'Ein Patient ist gestartet. Du kannst die Bearbeitung behalten oder die Änderungen verwerfen.'
      : 'Möchtest du die Änderungen vor dem Wechsel speichern?';
    dialog.returnValue = 'cancel';
    const choice = await new Promise((resolve) => {
      dialog.addEventListener('close', () => resolve(dialog.returnValue), { once: true });
      dialog.showModal();
    });
    if (choice === 'save') {
      await saveCar(Boolean(exercise));
      return true;
    }
    return choice === 'discard';
  }

  for (const button of el('carChangesDialog').querySelectorAll('[data-car-choice]')) {
    button.addEventListener('click', () => el('carChangesDialog').close(button.dataset.carChoice));
  }
  el('carForm').addEventListener('input', showCarDirtyState);
  el('carForm').addEventListener('change', showCarDirtyState);

  el('editCar').addEventListener('change', () => {
    const select = el('editCar');
    const number = select.value;
    select.value = loadedCarNumber;
    void run(async () => {
      if (number === loadedCarNumber || !await confirmCarChanges()) return;
      select.value = number;
      loadCarForm();
    });
  });

  el('carForm').addEventListener('submit', (event) => {
    event.preventDefault();
    const attach = event.submitter?.id === 'attachCar';
    if (loadedCarNumber && el('saveCar').disabled) return;
    void run(() => saveCar(attach));
  });

  async function saveCar(attach) {
    const editNumber = Number(loadedCarNumber);
    const config = carFormConfig();
    if (!config.occupants.length) throw new Error('Wähle mindestens einen besetzten Sitzplatz.');
    if (!el('carForm').reportValidity()) throw new Error('Prüfe die Angaben im Pkw-Formular.');
    if (editNumber) Object.assign(config, { car_number: editNumber, edit_version: carEditVersion });
    const next = await rpc({ p_config: config, p_session: attach || editNumber ? exercise.id : null }, api.bookCar);
    if (editNumber) {
      renderExercise(next);
      resetPreview();
      loadCarForm();
      message('Änderungen am Pkw gespeichert.');
      return;
    }
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
    loadCarForm();
  }
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
        ? 'Alle Patienten der Übung „' + exercise.title + '“ zurücksetzen?' : patientName(patient.id) + ' zurücksetzen?')) return;
      if (action === 'close' && !confirm('Übung „' + exercise.title + '“ beenden und alle Zugänge schließen?')) return;
      void run(async () => {
        if (action === 'close' && !await confirmCarChanges()) return;
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
    if (!auth || busy || polling || document.hidden) return;
    if (Date.now() >= auth.until) {
      signedOut(true);
      message(needsLogin().message);
      return;
    }
    if (!exercise) return;
    polling = true;
    const version = actionVersion;
    try {
      const next = await rpc({ p_action: 'status', p_session: exercise.id });
      if (auth && version === actionVersion) renderExercise(next);
    } catch (error) {
      if (auth && version === actionVersion) {
        handleError(error);
      }
    } finally {
      polling = false;
    }
  }

  setInterval(poll, 3000);
  window.addEventListener('storage', (event) => {
    if ((event.key !== sessionKey && event.key !== null) || !persistentSession || !auth) return;
    if (readSession()?.id === auth.id) return;
    signedOut();
    message('Bitte die Ausbilderansicht neu laden oder erneut anmelden.');
  });

  const saved = readSession();
  loadCarForm();
  if (saved) {
    auth = saved;
    persistentSession = true;
    if (Date.now() >= saved.until) {
      signedOut(true);
      message(needsLogin().message);
    } else {
      el('login').hidden = true;
      message('Ausbildersitzung wird geladen …');
      void run(async () => openWorkspace(await rpc({ p_action: 'list' })));
    }
  }
})();
