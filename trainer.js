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
    black: 'SK Schwarz', affected: 'SK B · Betroffene'
  };
  const carSeatNames = {
    driver: 'Fahrer', front: 'Beifahrer', 'rear-left': 'hinten links',
    'rear-center': 'hinten Mitte', 'rear-right': 'hinten rechts'
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
  let lastOverviewUpdate = 0;
  const overviewTime = new Intl.DateTimeFormat('de-DE', {
    hour: '2-digit', minute: '2-digit', second: '2-digit', timeZone: 'Europe/Berlin'
  });
  let previewTime = 0;
  let previewTick = null;
  let arrivalClock = null;

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
    const model = exercise.patients.find((patient) => patient.id === id)?.model;
    const name = model?.name
      ?? window.TRAUMA_CASES.find((item) => item.id === exercise.case)
      ?.patients.find((patient) => patient.id === id)?.name ?? id;
    if (model?.car_number == null || (model.station_kind ?? 'car') !== 'car') return name;
    const seat = carSeatName(model);
    return seat ? 'Pkw ' + model.car_number + ' – ' + seat : name;
  }

  function carSeatName(model) {
    const legacySeat = model.name?.split(' · ').at(-1).replace(/platz$/i, '').trim().toLowerCase();
    return carSeatNames[model.car_seat] ?? Object.values(carSeatNames)
      .find((name) => name.toLowerCase() === legacySeat);
  }

  function options(select, items, label) {
    select.replaceChildren(new Option(label, ''), ...items.map((item) => new Option(item.title, item.id)));
  }

  function categoryForVitals(patient, vitals) {
    const red = (patient.id === 'fahrer' || patient.custom) && (vitals.s < 100 || vitals.g < 15 || vitals.h >= 120);
    return red ? 'red' : patient.model.walkable ? 'green' : 'yellow';
  }

  function fixedCategory(model) {
    if (model.black === true) return 'black';
    if (model.affected === true) return 'affected';
    return null;
  }

  function forecastLabel(patient) {
    const shortCategory = (category) => categoryLabels[category].split(' · ')[0];
    const fixed = fixedCategory(patient.model);
    if (fixed) return patient.status === 'ready' ? 'Start · ' + categoryLabels[fixed] : '';
    const progression = patient.model.progression;
    if (progression) {
      return 'Verlauf · ' + shortCategory(progression.from) + ' → ' + shortCategory(progression.to)
        + ' bei Minute ' + progression.at_seconds / 60;
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
    const progression = patient.model.progression;
    const at = progression?.at_seconds;
    let category = fixedCategory(patient.model)
      ?? (progression && (previewTime >= at ? progression.to : progression.from));
    const stories = patient.station_stories;
    const story = (progression && previewTime >= at ? stories?.after : null) ?? stories?.before;
    const note = el('secret');
    note.textContent = [story ? '' : patient.model.secret, progression ? 'Wechsel bei Minute ' + at / 60 : '']
      .filter(Boolean).join(' · ');
    note.hidden = !note.textContent;
    el('previewStory').hidden = !story?.story;
    const storyText = el('previewStoryText');
    if (storyText.textContent !== (story?.story ?? '')) storyText.textContent = story?.story ?? '';
    const additional = el('previewStoryAdditional');
    const additionalText = stories?.additional ? 'Zusatz zur Patientenstory: ' + stories.additional : '';
    if (additional.textContent !== additionalText) additional.textContent = additionalText;
    additional.hidden = !additionalText;
    el('clock').textContent = api.clock(previewTime);
    el('seek').value = Math.floor(minute);
    if (category === 'affected' || category === 'black') {
      el('triage').className = 'triage ' + category;
      el('triage').textContent = categoryLabels[category] + ' (Übungsmodell)';
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
    el('triage').textContent = categoryLabels[category] + ' (Übungsmodell)';
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

  function renderComposition(groups) {
    const kinds = groups.map(([, patients]) => stationKind(patients[0]));
    for (const [id, kind] of [['compositionCars', 'car'], ['compositionTrucks', 'truck'],
      ['compositionBuses', 'bus'], ['compositionObjects', 'object']]) {
      el(id).textContent = kinds.filter((groupKind) => groupKind === kind).length;
    }
    el('compositionPatients').textContent = exercise.patients.length;
  }

  function renderExercise(next) {
    const previous = selectedPatient()?.id;
    const changed = exercise?.id !== next?.id;
    const triageMode = next?.triage_mode ?? 'automatic';
    if (changed || (exercise?.triage_mode ?? 'automatic') !== triageMode) el('triageMode').value = triageMode;
    exercise = next;
    syncArrivalClock(next, changed);
    el('triageSettings').hidden = !next;
    const activeTitle = el('activeExerciseTitle');
    const title = next?.title ?? 'Keine Übung ausgewählt';
    if (activeTitle.textContent !== title) activeTitle.textContent = title;
    const option = el('exercise').selectedOptions[0];
    if (next && option?.value === next.id && option.textContent !== title) option.textContent = title;
    if (changed) setExerciseTitleEditing(false);
    lastOverviewUpdate = next ? Date.now() : 0;
    renderOverviewSync(navigator.onLine === false ? 'Verbindung unterbrochen' : '');
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
      renderActions();
      return;
    }
    const choose = el('choose');
    const rebuild = changed || choose.options.length !== next.patients.length
      || next.patients.some((patient, index) => choose.options[index].value !== patient.id
        || choose.options[index].textContent !== patientName(patient.id));
    if (rebuild) {
      choose.replaceChildren(...next.patients.map((patient) => new Option(patientName(patient.id), patient.id)));
      choose.value = next.patients.some((patient) => patient.id === previous) ? previous : next.patients[0].id;
      if (changed) resetPreview();
    }
    el('liveTitle').textContent = next.title;
    el('expiry').textContent = 'Zugang gültig bis ' + new Date(next.expires_at).toLocaleString('de-DE');
    renderOverview(rebuild, changed);
    renderPatient();
  }

  function syncArrivalClock(next, exerciseChanged) {
    const elapsed = Date.parse(next?.server_time) - Date.parse(next?.arrived_at);
    if (Number.isFinite(elapsed)) {
      const receivedAt = performance.now();
      const sameArrival = !exerciseChanged && arrivalClock?.arrivedAt === next.arrived_at;
      const previousElapsed = sameArrival ? arrivalClock.elapsed + receivedAt - arrivalClock.receivedAt : 0;
      arrivalClock = { arrivedAt: next.arrived_at, elapsed: Math.max(elapsed, previousElapsed), receivedAt };
    } else {
      arrivalClock = null;
    }
    renderArrivalClock();
  }

  function renderArrivalClock() {
    const field = el('arrivalClock');
    const text = arrivalClock
      ? api.clock(Math.max(0, arrivalClock.elapsed + performance.now() - arrivalClock.receivedAt) / 1000)
      : '–';
    if (field.textContent !== text) field.textContent = text;
  }

  function firstTriageLabel(patient) {
    return patient.first_triage_seconds == null
      ? '' : 'Erste Sichtung · ' + api.clock(patient.first_triage_seconds) + ' nach Eintreffen';
  }

  function renderOverviewSync(problem = '') {
    const notice = el('overviewSync');
    notice.hidden = !lastOverviewUpdate;
    if (!lastOverviewUpdate) return;
    notice.dataset.stale = String(Boolean(problem));
    const label = problem || 'Live verbunden';
    const status = el('overviewSyncStatus');
    if (status.textContent !== label) status.textContent = label;
    const time = el('overviewSyncTime');
    const timestamp = new Date(lastOverviewUpdate);
    time.dateTime = timestamp.toISOString();
    time.textContent = overviewTime.format(timestamp);
  }

  function renderJoin(code) {
    el('exerciseJoin').hidden = !code;
    const link = el('joinLink');
    const qr = el('joinQr');
    const print = el('printJoinQr');
    if (!code) {
      qr.replaceChildren();
      delete qr.dataset.url;
      link.value = '';
      link.hidden = true;
      print.disabled = true;
      return;
    }
    const url = new URL('join.html', location.href);
    url.hash = new URLSearchParams({ access: code });
    if (link.value !== url.href) {
      link.value = url.href;
      link.hidden = true;
    }
    drawQr(qr, url.href, 'QR-Code zum Übungsbeitritt');
    print.disabled = !qr.dataset.url;
  }

  el('resizeJoinQr').addEventListener('click', () => {
    const enlarged = el('joinQr').classList.toggle('is-enlarged');
    el('resizeJoinQr').textContent = enlarged ? 'QR verkleinern' : 'QR vergrößern';
  });

  el('printJoinQr').addEventListener('click', () => {
    const url = el('joinQr').dataset.url;
    if (!exercise || !url) return;
    const sheet = document.createElement('section');
    sheet.className = 'briefing-sheet';
    const heading = document.createElement('p');
    heading.textContent = 'Übungsbeitritt';
    const title = document.createElement('h2');
    title.textContent = exercise.title;
    const qr = document.createElement('div');
    qr.className = 'briefing-sheet-qr';
    drawQr(qr, url, 'QR-Code zum Übungsbeitritt');
    const instruction = document.createElement('p');
    instruction.textContent = 'Scanne diesen QR-Code beim Briefing. Öffne die Stations-QRs während der Übung im selben Browser.';
    const validity = document.createElement('p');
    validity.className = 'print-validity';
    validity.textContent = printValidity(exercise.expires_at);
    sheet.append(heading, title, qr, instruction, validity);
    printExercise([sheet]);
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

  function stationKind(patient) {
    const kind = patient.model?.station_kind;
    if (kind === 'truck' || kind === 'object') return kind;
    if (patient.model?.car_number != null) return 'car';
    if (busStationPattern.test(patient.id)) return 'bus';
    if (exercise.case === 'vu-baum' && ['fahrer', 'beifahrer'].includes(patient.id)) return 'car';
    return 'other';
  }

  function stationNumber(value) {
    return String(value).padStart(2, '0');
  }

  function stationGroup(patient) {
    const kind = stationKind(patient);
    const number = patient.model?.car_number;
    switch (kind) {
      case 'car': return number == null ? 'Beispiel-Pkw' : 'PKW ' + stationNumber(number);
      case 'truck': return 'Lkw ' + stationNumber(number);
      case 'bus': return 'Bus · ' + busStationPattern.exec(patient.id)[1] + ' Personen';
      case 'object': return 'Einklemmung ' + stationNumber(number);
      default: return 'Weitere Stationen';
    }
  }

  function compareStationGroups(a, b) {
    const prefixes = ['PKW ', 'Beispiel-Pkw', 'Lkw ', 'Bus ', 'Einklemmung ', 'Weitere Stationen'];
    const order = (name) => prefixes.findIndex((prefix) => name.startsWith(prefix));
    return order(a) - order(b) || a.localeCompare(b, 'de', { numeric: true });
  }

  function stationGroupName(group) {
    return group.replace(/^PKW 0*(\d+)$/, 'Pkw $1').replace(/^Bus · (\d+) Personen$/, 'Bus ($1 Plätze)');
  }

  function overviewGroups() {
    const groups = new Map();
    for (const patient of exercise.patients) {
      const group = stationGroup(patient);
      if (!groups.has(group)) groups.set(group, []);
      groups.get(group).push(patient);
    }
    return [...groups].sort(([a], [b]) => compareStationGroups(a, b));
  }

  function stationLabel(patient) {
    const name = patientName(patient.id);
    const model = patient.model;
    if (stationKind(patient) === 'object') {
      const detail = [objectTypeLabels[model.object_type], objectPositionLabels[model.object_position],
        objectEntrapmentLabels[model.car_entrapment]].filter(Boolean).join(' · ');
      return { label: 'Patient ' + stationNumber(model.car_patient_number), detail, place: model.car_vehicle };
    }
    if (model?.car_number != null) {
      const seat = carSeatName(model) ?? name.split(' · ').at(-1);
      const detail = model.car_vehicle_description ? 'Fahrzeug · ' + model.car_vehicle_description : '';
      return { label: stationNumber(model.car_patient_number) + ' ' + seat, detail,
        place: model.car_vehicle, placeLabel: 'Lage' };
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
        const label = stationLabel(patient).label;
        return { id: patient.id, title: group ? label : stationGroupName(stationGroup(patient)) + ' · ' + label };
      });
    options(select, stations, group ? 'Alle Patienten dieser Gruppe' : 'Alle Patienten');
    if (stations.some((station) => station.id === previous)) select.value = previous;
  }

  function updatePrintFilters(groups, reset) {
    const choices = groups.map(([group]) => ({ id: group, title: stationGroupName(group) }));
    const select = el('printVehicle');
    const previous = reset ? '' : select.value;
    options(select, choices, 'Alle Fahrzeuge und Stationen');
    if (choices.some((group) => group.id === previous)) select.value = previous;
    updatePrintStations(reset);
  }

  el('printVehicle').addEventListener('change', () => updatePrintStations());

  function printValidity(expiresAt) {
    const date = new Intl.DateTimeFormat('de-DE', {
      dateStyle: 'medium', timeStyle: 'short', timeZone: 'Europe/Berlin'
    }).format(new Date(expiresAt));
    return 'Gültig bis ' + date + ' Uhr (Berlin)';
  }

  function printExercise(pages, twoPerPage = false) {
    const print = el('exercisePrint');
    print.classList.toggle('two-per-page', twoPerPage);
    print.replaceChildren(...pages);
    document.body.classList.add('printing-exercise');
    window.print();
  }

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
      groups.get(group).push({ ...stationLabel(patient), qrUrl });
    }
    if (!groups.size) return;
    const validUntil = printValidity(exercise.expires_at);
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
          if (station.detail) {
            const detail = document.createElement('p');
            detail.className = 'station-card-place';
            detail.textContent = station.detail;
            card.append(detail);
          }
          if (station.place) {
            const place = document.createElement('p');
            place.className = 'station-card-place';
            place.textContent = (station.placeLabel ?? 'Auffindeort') + ' · ' + station.place;
            card.append(place);
          }
          const validity = document.createElement('p');
          validity.className = 'station-card-meta';
          validity.textContent = validUntil;
          card.append(validity);
          sheet.append(card);
        }
        pages.push(sheet);
      }
    }
    printExercise(pages, perPage === 2);
  });

  window.addEventListener('afterprint', () => {
    document.body.classList.remove('printing-exercise');
    el('exercisePrint').replaceChildren();
  });

  for (const id of ['overviewCategory', 'overviewStatus']) {
    el(id).addEventListener('change', () => renderOverview());
  }

  function createOverviewGroup(group, patients) {
    const section = document.createElement('li');
    section.className = 'patient-group';
    const heading = document.createElement('h3');
    const title = document.createElement('span');
    title.className = 'station-heading';
    const kind = stationKind(patients[0]);
    if (kind !== 'other') {
      const svgNamespace = 'http://www.w3.org/2000/svg';
      const icon = document.createElementNS(svgNamespace, 'svg');
      icon.classList.add('station-icon');
      icon.setAttribute('aria-hidden', 'true');
      icon.setAttribute('focusable', 'false');
      const use = document.createElementNS(svgNamespace, 'use');
      use.setAttribute('href', 'station-icons.svg#' + (kind === 'object' ? 'entrapment' : kind));
      icon.append(use);
      title.append(icon);
    }
    title.append(stationGroupName(group));
    const count = document.createElement('span');
    count.className = 'muted small';
    heading.append(title, count);
    const context = document.createElement('p');
    context.className = 'station-group-context small';
    context.hidden = true;
    const list = document.createElement('ul');
    list.className = 'patient-overview';
    for (const patient of patients) {
      const row = document.createElement('li');
      row.dataset.patient = patient.id;
      const button = document.createElement('button');
      button.type = 'button';
      const name = document.createElement('strong');
      name.textContent = patientName(patient.id);
      const category = document.createElement('span');
      const status = document.createElement('span');
      status.className = 'patient-runtime';
      const forecast = document.createElement('span');
      forecast.className = 'patient-forecast muted';
      const firstTriage = document.createElement('span');
      firstTriage.className = 'patient-first-triage';
      button.append(name, category, status, forecast, firstTriage);
      button.addEventListener('click', () => {
        el('choose').value = patient.id;
        el('choose').dispatchEvent(new Event('change'));
        el('choose').focus();
      });
      row.append(button);
      list.append(row);
    }
    section.append(heading, context, list);
    return section;
  }

  function renderOverview(rebuild = false, resetFilters = false) {
    const overview = el('patientOverview');
    const focusedId = document.activeElement?.closest('[data-patient]')?.dataset.patient;
    if (resetFilters) {
      el('overviewCategory').value = '';
      el('overviewStatus').value = '';
    }
    if (rebuild) {
      const groups = overviewGroups();
      renderComposition(groups);
      updatePrintFilters(groups, resetFilters);
      overview.replaceChildren(...groups.map(([group, patients]) => createOverviewGroup(group, patients)));
    }
    const selected = el('choose').value;
    const categoryFilter = el('overviewCategory').value;
    const statusFilter = el('overviewStatus').value;
    const patients = new Map(exercise.patients.map((patient) => [patient.id, patient]));
    let focusedRow = null;
    let visible = 0;
    for (const section of overview.children) {
      const rows = section.lastElementChild.children;
      let groupVisible = 0;
      for (const row of rows) {
        const patient = patients.get(row.dataset.patient);
        row.hidden = Boolean((categoryFilter && (patient.category ?? 'none') !== categoryFilter)
          || (statusFilter && patient.status !== statusFilter));
        if (!row.hidden) groupVisible++;
        if (patient.id === focusedId) focusedRow = row;
        const button = row.firstElementChild;
        const [, category, status, forecast, firstTriage] = button.children;
        const label = categoryLabels[patient.category];
        button.setAttribute('aria-pressed', String(patient.id === selected));
        category.className = label ? 'triage patient-category ' + patient.category : 'patient-category muted';
        category.textContent = label ?? '–';
        status.textContent = api.labels[patient.status] + ' · ' + api.clock(patient.elapsed);
        forecast.textContent = forecastLabel(patient);
        forecast.hidden = !forecast.textContent;
        firstTriage.textContent = firstTriageLabel(patient);
        firstTriage.hidden = !firstTriage.textContent;
      }
      const groupCount = section.firstElementChild.lastElementChild;
      const text = (groupVisible === rows.length ? groupVisible : groupVisible + ' von ' + rows.length)
        + (rows.length === 1 ? ' Patient' : ' Patienten');
      if (groupCount.textContent !== text) groupCount.textContent = text;
      const lead = patients.get(rows[0].dataset.patient);
      const context = section.querySelector('.station-group-context');
      const kind = stationKind(lead);
      const identification = kind === 'object' ? objectTypeLabels[lead.model.object_type]
        : lead.model?.car_vehicle_description;
      const contextText = ['car', 'truck', 'object'].includes(kind)
        ? [identification, lead.model?.car_vehicle].filter(Boolean).join(' · ') : '';
      if (context.textContent !== contextText) context.textContent = contextText;
      context.hidden = !contextText;
      section.hidden = groupVisible === 0;
      visible += groupVisible;
    }
    if (focusedId && (!focusedRow || focusedRow.hidden)) el('overviewCategory').focus();
    else if (rebuild && focusedRow) focusedRow.firstElementChild.focus();
    const count = el('overviewCount');
    const text = visible + ' von ' + exercise.patients.length + ' Patienten angezeigt.';
    if (count.textContent !== text) count.textContent = text;
  }

  function renderPatient() {
    const patient = selectedPatient();
    renderActions(patient);
    if (!patient) return;
    const station = stationUrl(patient).href;
    const link = patientLink(station, patient);
    const numberedStation = patient.model?.car_number != null;
    el('stationTitle').textContent = numberedStation ? patientName(patient.id) : 'Stations-QR für diesen Patienten';
    const { detail, place, placeLabel = 'Auffindeort' } = stationLabel(patient);
    const location = el('stationLocation');
    location.textContent = [detail, place ? placeLabel + ' · ' + place : ''].filter(Boolean).join(' · ');
    location.hidden = !location.textContent;
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
    el('patientTriageTime').textContent = firstTriageLabel(patient) || (exercise.arrived_at
      ? 'Erste Sichtung noch offen.' : 'Erfasse zuerst das Eintreffen in der Übungssteuerung.');
  }

  function isExerciseAction(action) {
    return ['reset_all', 'close', 'start_arrival', 'clear_arrival'].includes(action);
  }

  function renderActions(patient) {
    for (const button of actions) {
      const action = button.dataset.action;
      button.disabled = busy || !exercise || (!patient && !isExerciseAction(action))
        || (action === 'pause' && patient?.status !== 'running')
        || (action === 'resume' && patient?.status !== 'paused')
        || (action === 'start_arrival' && Boolean(exercise.arrived_at))
        || (action === 'clear_arrival' && !exercise.arrived_at)
        || (action === 'mark_triage' && (!exercise.arrived_at || patient?.first_triage_seconds != null));
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

  function trainerAccessLost(error) {
    return error.status === 401 || (error.code === '42501'
      && error.message === 'Konto nicht für die Ausbilderansicht freigegeben');
  }

  function handleError(error) {
    if (trainerAccessLost(error)) {
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
    const controls = document.querySelectorAll('form button, #logout, #exercise, #editExerciseTitle, #createCustom, #startBus, #attachBus, #editCar, #editTruck, #editObject, #triageMode');
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

  function setExerciseTitleEditing(editing) {
    el('renameExerciseForm').hidden = !editing;
    el('editExerciseTitle').hidden = !exercise || editing;
    const field = el('renameExerciseTitle');
    field.setCustomValidity('');
    field.value = editing ? exercise.title : '';
    if (editing) {
      field.focus();
      field.select();
    }
  }

  function cancelExerciseTitleEditing() {
    if (busy) return;
    setExerciseTitleEditing(false);
    el('editExerciseTitle').focus();
  }

  el('editExerciseTitle').addEventListener('click', () => {
    if (exercise && !busy) setExerciseTitleEditing(true);
  });
  el('cancelExerciseTitle').addEventListener('click', cancelExerciseTitleEditing);
  el('renameExerciseTitle').addEventListener('input', (event) => event.target.setCustomValidity(''));
  el('renameExerciseForm').addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    event.preventDefault();
    cancelExerciseTitleEditing();
  });
  el('renameExerciseForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!exercise || busy) return;
    const field = el('renameExerciseTitle');
    const title = field.value.trim();
    if (!title) {
      field.setCustomValidity('Gib einen Namen für die Übung ein.');
      field.reportValidity();
      return;
    }
    const session = exercise.id;
    await run(async () => {
      const next = await rpc({ p_action: 'rename_exercise', p_session: session, p_title: title });
      renderExercise(next);
      setExerciseTitleEditing(false);
      message('Übung umbenannt.');
    });
    if (exercise?.id === session && el('renameExerciseForm').hidden) el('editExerciseTitle').focus();
  });

  el('triageSettingsForm').addEventListener('submit', (event) => {
    event.preventDefault();
    if (!exercise) return;
    const mode = el('triageMode').value;
    void run(async () => {
      const next = await rpc({ p_action: 'set_triage_mode', p_session: exercise.id, p_title: mode });
      renderExercise(next);
      el('triageMode').value = next.triage_mode ?? 'automatic';
      message('Sichtungseinstellung gespeichert.');
    });
  });

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
  const objectTypeLabels = {
    beam: 'Betonträger', skip: 'Mulde', car: 'Pkw', 'car-bike': 'Pkw und Fahrrad',
    truck: 'Lkw', bus: 'Bus', machine: 'Maschine'
  };
  const objectPositionLabels = { under: 'Unter einem Gegenstand', between: 'Zwischen Gegenständen' };
  const objectEntrapmentLabels = {
    'left-arm': 'Linker Arm', 'right-arm': 'Rechter Arm', 'both-arms': 'Beide Arme',
    'left-leg': 'Linkes Bein', 'right-leg': 'Rechtes Bein', 'both-legs': 'Beide Beine'
  };
  const cabSeats = [['driver', 'Fahrerplatz'], ['front', 'Beifahrerplatz']];
  const stationForms = [
    setupStationForm('car', 'Car', 'Pkw', [
      ...cabSeats, ['rear-left', 'Hinten links'], ['rear-center', 'Hinten Mitte'], ['rear-right', 'Hinten rechts']
    ]),
    setupStationForm('truck', 'Truck', 'Lkw', cabSeats),
    setupStationForm('object', 'Object', 'Klemmstelle', [['patient', 'Person']])
  ];

  for (const [id, labels] of [['objectType', objectTypeLabels], ['objectPosition', objectPositionLabels]]) {
    el(id).replaceChildren(...Object.entries(labels).map(([value, label]) => new Option(label, value)));
  }

  function setupStationForm(kind, suffix, title, seats) {
    const prefix = suffix.toLowerCase();
    const form = {
      kind, title, loadedNumber: '', baseline: '', editVersion: 0,
      card: el(prefix + 'Booking'), fields: el(prefix + 'Form'),
      choiceLabel: el('edit' + suffix + 'Choice'), select: el('edit' + suffix),
      start: el('start' + suffix), attach: el('attach' + suffix), save: el('save' + suffix),
      location: el(prefix + 'Situation'), status: el(prefix + 'EditStatus'), unsaved: el(prefix + 'Unsaved')
    };
    if (kind === 'object') {
      form.objectType = el('objectType');
      form.objectPosition = el('objectPosition');
    } else {
      form.description = el(prefix + 'Description');
    }
    form.rows = seats.map(([seat, label]) => createSeatControl(form, el(prefix + 'Seats'), seat, label));
    return form;
  }

  function createSeatControl(form, container, seat, label) {
    const objectStation = form.kind === 'object';
    const group = document.createElement('fieldset');
    group.className = 'car-seat';
    group.innerHTML = `<legend>${label}</legend>
      <label>Besetzung und Verletzungsprofil
        <select class="seat-profile">
          <option value="">${objectStation ? 'Profil auswählen' : 'Leer'}</option><option value="affected">${categoryLabels.affected}</option>
          <option value="minor">Leicht verletzt · SK III</option><option value="urgent">Schwer verletzt · SK II</option>
          <option value="critical">Vital bedroht · SK I</option>
          <option value="black">${categoryLabels.black}</option>
          <option value="green-yellow">Verlauf · SK III → SK II</option>
          <option value="urgent-red">Verlauf · SK II → SK I</option>
          <option value="red-ex">Verlauf · SK I → ${categoryLabels.black}</option>
        </select>
      </label>
      <div class="seat-details" hidden>
        <label class="seat-transition-label" hidden>Kategorienwechsel ab Patientenstart
          <strong class="seat-transition-value" aria-hidden="true"></strong>
          <input class="seat-transition" type="range" min="1" max="44" step="1" disabled>
        </label>
        ${objectStation ? `<label>Eingeklemmte Körperregion
          <select class="seat-entrapment" required disabled>
            <option value="">Körperregion auswählen</option>
            ${Object.entries(objectEntrapmentLabels).map(([value, name]) => `<option value="${value}">${name}</option>`).join('')}
          </select>
        </label>` : `<label>Befreiungslage
          <select class="seat-access">
            <option value="none">Frei zugänglich</option>
            <option value="enclosed">Eingeschlossen</option>
            <option value="trapped">Eingeklemmt</option>
          </select>
        </label>
        <label class="seat-entrapment-label" hidden>Klemmstelle
          <select class="seat-entrapment" required disabled>
            <option value="">Klemmstelle auswählen</option>
            <option value="door">${form.kind === 'truck' ? 'Tür / Kabinenrahmen' : 'Tür / B-Säule'}</option>
            <option value="footwell">Fußraum / Bein</option>
            <option value="dashboard">${seat.startsWith('rear-') ? 'Sitzreihe / Vordersitz' : 'Sitz / Armaturenbrett'}</option>
            <option value="roof">Dach / Sitz</option>
          </select>
        </label>`}
        <label>Eigener Zusatz zur Patientenstory (optional)
          <input class="seat-injury" maxlength="400">
        </label>
        ${objectStation ? '' : `<div class="seat-move" hidden>
          <label>Sitzplatz wechseln
            <select class="seat-move-target"></select>
          </label>
          <button class="seat-move-button" type="button">Umsetzen oder tauschen</button>
        </div>`}
      </div>`;
    const legend = group.querySelector('legend');
    const profile = group.querySelector('.seat-profile');
    const details = group.querySelector('.seat-details');
    const transition = group.querySelector('.seat-transition');
    const transitionLabel = group.querySelector('.seat-transition-label');
    const transitionValue = group.querySelector('.seat-transition-value');
    const access = group.querySelector('.seat-access');
    const entrapment = group.querySelector('.seat-entrapment');
    const entrapmentLabel = group.querySelector('.seat-entrapment-label');
    const injury = group.querySelector('.seat-injury');
    const move = group.querySelector('.seat-move');
    const moveTarget = group.querySelector('.seat-move-target');
    const moveButton = group.querySelector('.seat-move-button');
    const row = { seat, label, profile, transition, access, entrapment, injury, move, moveTarget, moveButton, patientNumber: null };
    function showEntrapment() {
      entrapment.disabled = !profile.value || (access != null && access.value !== 'trapped');
      if (entrapmentLabel) entrapmentLabel.hidden = entrapment.disabled;
    }
    access?.addEventListener('change', showEntrapment);
    function showTransitionMinute() {
      const text = 'Minute ' + transition.value;
      transitionValue.textContent = text;
      transition.setAttribute('aria-valuetext', text);
    }
    transition.addEventListener('input', showTransitionMinute);
    profile.addEventListener('change', () => {
      if (!profile.value) {
        row.patientNumber = null;
        if (access) access.value = 'none';
        entrapment.value = '';
        injury.value = '';
      }
      legend.textContent = row.patientNumber == null
        ? label
        : label + ' · Patient ' + String(row.patientNumber).padStart(2, '0');
      details.hidden = !profile.value;
      showEntrapment();
      const defaultMinute = { 'green-yellow': 12, 'urgent-red': 6, 'red-ex': 8 }[profile.value];
      transition.disabled = transitionLabel.hidden = defaultMinute == null;
      if (defaultMinute != null) {
        transition.value = defaultMinute;
        showTransitionMinute();
      }
    });
    moveTarget?.addEventListener('change', updateCarActions);
    moveButton?.addEventListener('click', () => moveCarOccupant(form, row));
    container.append(group);
    return row;
  }

  function stationPatients(form) {
    return (exercise?.patients ?? []).filter(({model}) =>
      model?.car_number != null && (model.station_kind ?? 'car') === form.kind);
  }

  function carPatients(form, number = form.loadedNumber) {
    return number ? stationPatients(form).filter(({model}) => model.car_number === Number(number)) : [];
  }

  function updateCarChoices(changed) {
    for (const form of stationForms) {
      const previous = changed ? '' : form.select.value;
      const numbers = [...new Set(stationPatients(form).map(({model}) => model.car_number))].sort((a, b) => a - b);
      const firstOption = form.kind === 'object' ? 'Neue Klemmstelle konfigurieren' : 'Neuen ' + form.title + ' konfigurieren';
      form.select.replaceChildren(new Option(firstOption, ''),
        ...numbers.map((number) => new Option(form.title + ' ' + String(number).padStart(2, '0') + ' bearbeiten', number)));
      form.select.value = numbers.includes(Number(previous)) ? previous : '';
      form.choiceLabel.hidden = !numbers.length;
    }
    if (changed) loadCarForm();
  }

  function legacyCarConfig(form, model) {
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
      : fixedCategory(model) ?? (model.walkable ? 'minor' : model.nibpFastCycle ? 'critical' : 'urgent');
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
      seat: form.rows.find((row) => row.label.toLowerCase() === seat.toLowerCase())?.seat,
      vehicle: vehicle === 'Fahrzeuglage vor Ort erkunden' ? '' : vehicle,
      profile, entrapment, injury: model.story === defaults[profile] ? '' : model.story
    };
  }

  function loadCarForm(form) {
    if (!form) {
      for (const item of stationForms) loadCarForm(item);
      return;
    }
    form.loadedNumber = form.select.value;
    const patients = carPatients(form);
    form.fields.reset();
    if (form.description) {
      form.savedDescription = patients[0]?.model.car_vehicle_description ?? '';
      form.description.value = form.savedDescription;
    }
    for (const row of form.rows) fillCarSeat(row);
    form.editVersion = patients[0]?.model.car_edit_version ?? 0;
    for (const {model} of patients) {
      const config = model.car_seat ? {
        seat: model.car_seat, vehicle: model.car_vehicle, profile: model.car_profile,
        entrapment: model.car_entrapment, injury: model.car_injury
      } : legacyCarConfig(form, model);
      const row = form.rows.find((item) => item.seat === config.seat);
      if (!row) continue;
      form.location.value = config.vehicle ?? '';
      if (form.objectType) {
        form.objectType.value = model.object_type;
        form.objectPosition.value = model.object_position;
      }
      fillCarSeat(row, { ...config, patient_number: model.car_patient_number,
        transition_minute: model.progression ? model.progression.at_seconds / 60 : null });
    }
    updateCarMoveChoices(form);
    form.baseline = JSON.stringify(carFormConfig(form));
    showCarDirtyState();
  }

  function fillCarSeat(row, config) {
    row.patientNumber = config?.patient_number ?? null;
    row.profile.value = config?.profile ?? '';
    const entrapment = config?.entrapment ?? (row.access ? 'none' : '');
    if (row.access) {
      row.access.value = ['none', 'enclosed'].includes(entrapment) ? entrapment : 'trapped';
      row.entrapment.value = row.access.value === 'trapped' ? entrapment : '';
    } else {
      row.entrapment.value = entrapment;
    }
    row.injury.value = config?.injury ?? '';
    row.profile.dispatchEvent(new Event('change'));
    if (config?.transition_minute != null) {
      row.transition.value = config.transition_minute;
      row.transition.dispatchEvent(new Event('input'));
    }
  }

  function updateCarMoveChoices(form) {
    for (const row of form.rows) {
      if (!row.move) continue;
      row.move.hidden = !form.loadedNumber || !row.profile.value;
      const target = row.moveTarget.value;
      row.moveTarget.replaceChildren(new Option('Zielplatz wählen', ''),
        ...form.rows.filter((other) => other !== row).map((other) =>
          new Option(other.profile.value ? 'Tauschen mit ' + other.label : other.label, other.seat)));
      row.moveTarget.value = target;
    }
    updateCarActions();
  }

  function moveCarOccupant(form, row) {
    if (!form.loadedNumber || busy || !row.profile.value) return;
    const target = form.rows.find((other) => other.seat === row.moveTarget.value);
    if (!target || target === row) return;
    const occupant = carOccupantConfig(row);
    const otherOccupant = target.profile.value ? carOccupantConfig(target) : null;
    fillCarSeat(row, otherOccupant);
    fillCarSeat(target, occupant);
    row.moveTarget.value = '';
    target.moveTarget.value = '';
    updateCarMoveChoices(form);
    showCarDirtyState();
    target.profile.focus();
  }

  function updateCarActions() {
    for (const form of stationForms) {
      const patients = carPatients(form);
      const editing = patients.length > 0;
      const started = patients.some((patient) => patient.status !== 'ready');
      form.start.hidden = editing;
      form.attach.hidden = !exercise || editing;
      form.save.hidden = !editing;
      form.save.disabled = busy || started;
      for (const row of form.rows) {
        if (row.moveButton) row.moveButton.disabled = busy || !row.moveTarget.value;
      }
      form.status.hidden = !editing;
      const text = started ? 'Setze die bereits gestarteten Patienten vor dem Bearbeiten zurück.'
        : form.kind === 'object' ? 'Die Patientennummer und der QR-Code bleiben erhalten.'
          : 'Umgesetzte Insassen behalten ihre Patientennummer und ihren QR-Code. Entfernte Insassen verlieren ihren QR-Zugang. Neue Insassen erhalten einen eigenen Code.';
      if (form.status.textContent !== text) form.status.textContent = text;
    }
  }

  function carOccupantConfig(row) {
    return {
      seat: row.seat, profile: row.profile.value, injury: row.injury.value,
      ...(row.patientNumber == null ? {} : { patient_number: row.patientNumber }),
      entrapment: row.access && row.access.value !== 'trapped' ? row.access.value : row.entrapment.value,
      transition_minute: row.transition.disabled ? null : row.transition.valueAsNumber
    };
  }

  function carFormConfig(form) {
    const occupants = form.rows.filter((row) => row.profile.value).map(carOccupantConfig);
    const config = { vehicle: form.location.value, occupants };
    const description = form.description?.value.trim() ?? '';
    if (description || form.savedDescription) config.vehicle_description = description;
    if (form.kind !== 'car') config.kind = form.kind;
    if (form.objectType) {
      config.object_type = form.objectType.value;
      config.object_position = form.objectPosition.value;
    }
    return config;
  }

  function carFormIsDirty(form) {
    return form.baseline !== JSON.stringify(carFormConfig(form));
  }

  function showCarDirtyState() {
    for (const form of stationForms) form.unsaved.hidden = !carFormIsDirty(form);
    if (stationForms.some(carFormIsDirty)) window.addEventListener('beforeunload', warnBeforeLeaving);
    else window.removeEventListener('beforeunload', warnBeforeLeaving);
  }

  function warnBeforeLeaving(event) {
    event.preventDefault();
    event.returnValue = '';
  }

  async function confirmCarChanges(forms = stationForms, discardNow = false) {
    for (const form of forms) {
      if (!carFormIsDirty(form)) continue;
      const dialog = el('carChangesDialog');
      const started = carPatients(form).some((patient) => patient.status !== 'ready');
      dialog.querySelector('[data-car-choice="save"]').disabled = started;
      el('carChangesTitle').textContent = form.unsaved.textContent;
      el('carChangesMessage').textContent = started
        ? 'Ein Patient ist gestartet. Du kannst die Bearbeitung behalten oder die Änderungen verwerfen.'
        : 'Möchtest du die Änderungen vor dem Wechsel speichern?';
      dialog.returnValue = 'cancel';
      const choice = await new Promise((resolve) => {
        dialog.addEventListener('close', () => resolve(dialog.returnValue), { once: true });
        dialog.showModal();
      });
      if (choice === 'save') await saveCar(form, Boolean(exercise));
      else if (choice !== 'discard') return false;
      else if (discardNow) loadCarForm(form);
    }
    return true;
  }

  for (const button of el('carChangesDialog').querySelectorAll('[data-car-choice]')) {
    button.addEventListener('click', () => el('carChangesDialog').close(button.dataset.carChoice));
  }
  for (const form of stationForms) {
    form.card.querySelector('summary').addEventListener('click', (event) => {
      if (form.card.open) return;
      if (busy) {
        event.preventDefault();
        return;
      }
      const others = stationForms.filter((other) => other !== form);
      const closeOthers = () => {
        for (const other of others) other.card.open = false;
      };
      if (!others.some(carFormIsDirty)) {
        closeOthers();
        return;
      }
      event.preventDefault();
      void run(async () => {
        if (!await confirmCarChanges(others, true)) return;
        closeOthers();
        form.card.open = true;
      });
    });

    form.fields.addEventListener('input', showCarDirtyState);
    form.fields.addEventListener('change', (event) => {
      if (event.target.classList.contains('seat-profile')) updateCarMoveChoices(form);
      showCarDirtyState();
    });

    form.select.addEventListener('change', () => {
      const number = form.select.value;
      form.select.value = form.loadedNumber;
      void run(async () => {
        if (number === form.loadedNumber || !await confirmCarChanges([form])) return;
        form.select.value = number;
        loadCarForm(form);
      });
    });

    form.fields.addEventListener('submit', (event) => {
      event.preventDefault();
      const attach = event.submitter === form.attach;
      if (form.loadedNumber && form.save.disabled) return;
      void run(() => saveCar(form, attach));
    });
  }

  async function saveCar(form, attach) {
    const editNumber = Number(form.loadedNumber);
    const config = carFormConfig(form);
    if (!config.occupants.length) throw new Error(form.kind === 'object'
      ? 'Wähle ein Verletzungsprofil für die Person.' : 'Wähle mindestens einen besetzten Sitzplatz.');
    if (!form.fields.reportValidity()) throw new Error('Prüfe die Angaben im Formular.');
    if (editNumber) Object.assign(config, { car_number: editNumber, edit_version: form.editVersion });
    const next = await rpc({ p_config: config, p_session: attach || editNumber ? exercise.id : null }, api.bookCar);
    if (editNumber) {
      renderExercise(next);
      resetPreview();
      loadCarForm(form);
      message(form.kind === 'object' ? 'Änderungen an der Klemmstelle gespeichert.'
        : 'Änderungen am ' + form.title + ' gespeichert.');
      return;
    }
    if (attach) {
      renderExercise(next);
      const patients = stationPatients(form);
      const number = Math.max(...patients.map(({model}) => model.car_number));
      const first = patients.find(({model}) => model.car_number === number);
      el('choose').value = first.id;
      renderOverview();
      renderPatient();
      resetPreview();
      message(form.title + ' ' + String(number).padStart(2, '0') + ' hinzugefügt.');
    } else {
      openCreatedExercise(next);
    }
    loadCarForm(form);
  }
  el('choose').addEventListener('change', () => {
    renderOverview();
    renderPatient();
    resetPreview();
  });
  for (const button of actions) {
    button.addEventListener('click', () => {
      const action = button.dataset.action;
      const patient = isExerciseAction(action) ? null : selectedPatient();
      if (!exercise || busy || button.disabled) return;
      if (action.startsWith('reset') && !confirm(action === 'reset_all'
        ? 'Alle Patienten der Übung „' + exercise.title + '“ zurücksetzen?' : patientName(patient.id) + ' zurücksetzen?')) return;
      if (action === 'close' && !confirm('Übung „' + exercise.title + '“ beenden und alle Zugänge schließen?')) return;
      if (action === 'clear_arrival' && !confirm('Zeitmessung und alle erfassten Sichtungszeiten zurücksetzen? Die Patientenverläufe laufen weiter.')) return;
      void run(async () => {
        if (action === 'close' && !await confirmCarChanges()) return;
        const next = await rpc({ p_action: action, p_session: exercise.id, p_patient: patient?.id });
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
        if (action === 'start_arrival') message('Eintreffen erfasst.');
        if (action === 'clear_arrival') message('Zeitmessung und Sichtungszeiten zurückgesetzt.');
        if (action === 'mark_triage') message('Sichtung erfasst.');
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
    if (arrivalClock) renderArrivalClock();
    if (previewTick === null) return;
    const now = performance.now();
    previewTime = Math.min(previewDuration, previewTime + (now - previewTick) / 1000 * Number(el('speed').value));
    previewTick = previewTime < previewDuration ? now : null;
    drawPreview();
  }, 200);
  async function poll() {
    if (!auth || document.hidden) return;
    if (lastOverviewUpdate && Date.now() - lastOverviewUpdate > 12000
      && el('overviewSync').dataset.stale !== 'true') {
      renderOverviewSync('Aktualisierung verzögert');
    }
    if (busy || polling) return;
    if (Date.now() >= auth.until) {
      signedOut(true);
      message(needsLogin().message);
      return;
    }
    if (!exercise || navigator.onLine === false) return;
    polling = true;
    const version = actionVersion;
    try {
      const next = await rpc({ p_action: 'status', p_session: exercise.id });
      if (auth && version === actionVersion) renderExercise(next);
    } catch (error) {
      if (auth && version === actionVersion) {
        if (trainerAccessLost(error) || exerciseUnavailable(error)) handleError(error);
        else renderOverviewSync('Verbindung unterbrochen');
      }
    } finally {
      polling = false;
    }
  }

  setInterval(poll, 3000);
  window.addEventListener('offline', () => renderOverviewSync('Verbindung unterbrochen'));
  window.addEventListener('online', poll);
  document.addEventListener('visibilitychange', poll);
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
