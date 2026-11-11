(function () {
  'use strict';

  const params = new URLSearchParams(location.search);
  const caseId = params.get('case') || 'vu-baum';
  const patientId = params.get('patient') || 'fahrer';
  const scenario = window.TRAUMA_CASES.find((item) => item.id === caseId);
  const preset = scenario?.patients.find((item) => item.id === patientId);
  const el = (id) => document.getElementById(id);
  const api = window.TraumaSync;

  const busStation = scenario && /^bus-(5|10)-[0-9]{2}$/.test(patientId);
  const carStation = /^car-[0-9]{2}-[0-9]{2,}$/.test(patientId);
  if (!preset && !busStation && !carStation && !/^custom-[0-9a-f-]{36}$/.test(caseId)) {
    el('content').innerHTML = '<div class="panel"><h1>Patient nicht gefunden</h1><a href="index.html">Zur Übersicht</a></div>';
    return;
  }

  el('caseTitle').textContent = scenario?.title ?? 'TraumaSim';
  el('patientTitle').textContent = preset?.name ?? 'Übungspatient';
  const storageKey = 'traumasim-access:' + caseId + ':' + patientId;
  function readLinkFragment() {
    const fragment = new URLSearchParams(location.hash.slice(1));
    const linkCode = fragment.get('preview') || fragment.get('code');
    if (!linkCode) return false;
    history.replaceState({ traumasimPatientCode: linkCode, preview: fragment.has('preview') }, '', location.pathname + location.search);
    return true;
  }
  readLinkFragment();
  window.addEventListener('hashchange', () => {
    if (readLinkFragment()) location.reload();
  });
  // A direct link keeps its exercise on reload. A new station scan uses the joined exercise.
  const directCode = history.state?.traumasimPatientCode;
  const rejectedStationLink = history.state?.traumasimStationRejected === true;
  const preview = history.state?.preview === true;
  el('previewBanner').hidden = !preview;
  const exerciseCode = directCode || carStation || rejectedStationLink ? null : api.exerciseCode(caseId);
  let code = directCode || exerciseCode;
  if (!carStation && !rejectedStationLink) {
    try { code ||= sessionStorage.getItem(storageKey); } catch {}
  }
  let openPending = Boolean(code) && !preview;
  let pendingStartRevision;
  let connectionInterrupted = false;
  let lastReceived = null;
  const showJoinHint = () => {
    if (carStation) el('joinHint').textContent = 'Scanne den einzelnen QR-Code dieser Person am Pkw.';
    el('joinHint').hidden = false;
  };
  let snapshot = null;
  let busy = false;
  let choice = null;
  let choiceKey = null;
  let focusResolution = false;
  let animation = null;
  let waveFrameTime = null;
  let cardiacPhase = 0;
  let respPhase = 0;
  let monitor = null;
  let serverClockOffset = NaN;
  let snapshotReceivedAt = 0;
  const berlinClock = new Intl.DateTimeFormat('de-DE', {
    timeZone: 'Europe/Berlin', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23'
  });
  const triageLabels = {
    red: 'SK I · Rot', yellow: 'SK II · Gelb', green: 'SK III · Grün', affected: 'Unverletzt betroffen', black: 'EX · Schwarz'
  };

  function restoreChoice() {
    if (preview || !choiceKey) return;
    try {
      const saved = JSON.parse(localStorage.getItem(choiceKey));
      if (saved?.revision === snapshot.revision && Object.hasOwn(triageLabels, saved.selection)) {
        choice = saved.selection;
      } else if (saved?.revision < snapshot.revision) {
        localStorage.removeItem(choiceKey);
      }
    } catch {}
  }

  function saveChoice(selection) {
    choice = selection;
    if (preview || !choiceKey) return;
    try {
      const saved = JSON.parse(localStorage.getItem(choiceKey));
      if (!(saved?.revision > snapshot.revision)) {
        localStorage.setItem(choiceKey, JSON.stringify({ revision: snapshot.revision, selection }));
      }
    } catch {}
  }

function wavePath(kind,phase){let out='';const width=600;for(let x=0;x<=width;x+=2){let p=(x/width*6-phase)%1;if(p<0)p+=1;let y=45;if(kind==='ecg'){if(p<.58)y=45;else if(p<.64)y=43-4*Math.sin((p-.58)/.06*Math.PI);else if(p<.69)y=45+10*(p-.64)/.05;else if(p<.72)y=55-47*(p-.69)/.03;else if(p<.75)y=8+58*(p-.72)/.03;else if(p<.79)y=66-21*(p-.75)/.04;else if(p<.95)y=45-7*Math.sin((p-.79)/.16*Math.PI)}else if(kind==='pleth'){y=62-34*Math.pow(Math.max(0,Math.sin(Math.PI*p)),5)-8*Math.sin(Math.PI*p)}else{y=45-19*Math.sin(2*Math.PI*p)}out+=(x===0?'M':'L')+x+' '+y.toFixed(1)+' '}return out}
  function animateWaves(now) {
    if (!monitor) {
      animation = waveFrameTime = null;
      cardiacPhase = respPhase = 0;
      return;
    }
    const step = waveFrameTime == null ? 0 : Math.min((now - waveFrameTime) / 1000, .1);
    waveFrameTime = now;
    cardiacPhase = (cardiacPhase + step * (monitor.h ?? 0) / 60 * .16) % 1;
    respPhase = (respPhase + step * (monitor.r ?? 0) / 60 * .16) % 1;
    if (monitor.ecg) el('ecgTrace').setAttribute('d', wavePath('ecg', cardiacPhase));
    if (monitor.o != null) el('plethTrace').setAttribute('d', wavePath('pleth', cardiacPhase));
    if (monitor.r != null) el('respTrace').setAttribute('d', wavePath('resp', respPhase));
    animation = requestAnimationFrame(animateWaves);
  }

  function drawClocks() {
    const now = performance.now();
    if (snapshot) {
      // Advance one tick between server reads. The server owns pauses and resets.
      const tick = !connectionInterrupted && snapshot.status === 'running' && now - snapshotReceivedAt >= 1000 ? 1 : 0;
      const elapsed = api.clock(snapshot.elapsed + tick);
      el('elapsed').textContent = elapsed;
      const monitorElapsed = el('monitorElapsed');
      if (monitorElapsed) monitorElapsed.textContent = elapsed;
    }
    const clock = el('ecgClock');
    if (!clock) return;
    clock.hidden = !monitor?.ecg;
    if (clock.hidden) return;
    const wallTime = Number.isFinite(serverClockOffset) ? serverClockOffset + now : Date.now();
    clock.textContent = berlinClock.format(wallTime);
  }

  function receiveSnapshot(data) {
    const previousRevision = snapshot?.revision;
    const nextKey = data.exercise_id ? 'traumasim:triage:' + data.exercise_id + ':' + patientId : null;
    snapshot = data;
    if (choiceKey !== nextKey || previousRevision !== data.revision) {
      choiceKey = nextKey;
      choice = null;
      focusResolution = false;
      el('triageSelection').value = '';
      restoreChoice();
    }
    snapshotReceivedAt = performance.now();
    serverClockOffset = Date.parse(data.server_time) - snapshotReceivedAt;
    lastReceived = new Date();
  }

  function render() {
    const brief = snapshot && (snapshot.brief ?? preset);
    el('caseTitle').textContent = brief?.title ?? scenario?.title ?? 'TraumaSim';
    el('patientTitle').textContent = brief?.name ?? preset?.name ?? 'Übungspatient';
    el('intro').textContent = brief?.intro ?? '';
    el('story').textContent = brief?.story ?? '';
    el('questions').textContent = brief?.questions ?? '';
    el('storyPanel').hidden = !snapshot;
    el('startPatient').hidden = preview || snapshot?.status !== 'ready';
    const showChoice = snapshot?.triage_mode === 'choose' && snapshot.triage_selectable && !snapshot.triage;
    el('triageChoicePanel').hidden = !showChoice;
    el('triageObservation').hidden = !showChoice || !snapshot.observation;
    el('triageObservation').textContent = showChoice ? snapshot.observation ?? '' : '';
    el('triageChoiceForm').hidden = !showChoice || Boolean(choice);
    el('triageChoicePending').hidden = !showChoice || !choice;
    el('triagePanel').hidden = !snapshot?.triage;
    if (!snapshot?.triage) {
      el('triage').textContent = '';
      el('triageReason').textContent = '';
      el('patientCondition').textContent = '';
      el('triageBox').className = 'triage';
    }
    const showOwnChoice = snapshot?.triage_mode === 'choose' && snapshot.triage && choice;
    el('triageOwnChoice').hidden = !showOwnChoice;
    el('triageOwnChoice').textContent = showOwnChoice ? 'Deine Sichtung · ' + triageLabels[choice] : '';
    monitor = snapshot?.monitor ?? (snapshot?.vitals && { ...snapshot.vitals, ecg: true });
    el('vitalsPanel').hidden = !monitor;
    el('clockPanel').hidden = !snapshot || Boolean(monitor && el('monitorElapsed'));
    drawClocks();
    if (!snapshot) return;

    el('syncStatus').textContent = api.labels[snapshot.status];
    if (snapshot.triage) {
      const { red, reason, condition } = snapshot.triage;
      const category = snapshot.triage.category ?? (red ? 'red' : 'yellow');
      el('triageBox').className = 'triage ' + category;
      el('triage').textContent = triageLabels[category]?.toLocaleUpperCase('de') ?? '';
      el('triageReason').textContent = reason;
      el('patientCondition').textContent = condition;
      if (showOwnChoice && focusResolution) el('triage').focus({ preventScroll: true });
      focusResolution = false;
    }
    if (monitor) {
      const { s, d, h, r, o, g, ecg, bp_at, bp_wall_at, bp_next_wall_at, bp_previous } = monitor;
      el('bp').textContent = s != null && d != null ? s + '/' + d : '—';
      const bpTime = el('bpTime');
      const bpPrevious = el('bpPrevious');
      const bpNext = el('bpNext');
      if (bpTime) {
        bpTime.hidden = bp_at == null;
        bpTime.textContent = bp_wall_at ? 'Messzeit ' + berlinClock.format(Date.parse(bp_wall_at))
          : bp_at != null ? 'Messzeit +' + api.clock(bp_at) + ' (Übungszeit)' : '';
      }
      if (bpPrevious) {
        bpPrevious.hidden = !bp_previous;
        bpPrevious.textContent = bp_previous ? 'Vorher ' + bp_previous.s + '/' + bp_previous.d + ' · '
          + (bp_previous.wall_at ? berlinClock.format(Date.parse(bp_previous.wall_at))
            : '+' + api.clock(bp_previous.at) + ' (Übungszeit)') : '';
      }
      if (bpNext) {
        bpNext.hidden = !bp_next_wall_at && snapshot.status !== 'paused';
        bpNext.textContent = bp_next_wall_at ? 'Nächster Messwert ' + berlinClock.format(Date.parse(bp_next_wall_at))
          : snapshot.status === 'paused' ? 'Nächste Messung pausiert' : '';
      }
      const rateLabel = el('rateLabel');
      if (rateLabel) rateLabel.textContent = ecg ? 'HF' : 'Puls';
      el('hr').textContent = h ?? '—';
      el('rr').textContent = r ?? '—';
      el('spo').textContent = o ?? '—';
      el('gcs').textContent = g ?? '—';
      el('ecgTrace').toggleAttribute('hidden', !ecg);
      el('plethTrace').toggleAttribute('hidden', o == null);
      el('respTrace').toggleAttribute('hidden', r == null);
      if (animation === null) animation = requestAnimationFrame(animateWaves);
    }
  }

  async function synchronize({ revision } = {}) {
    if (!code || busy) return;
    busy = true;
    el('startPatient').disabled = true;
    el('retryConnection').disabled = true;
    const query = { p_case: caseId, p_patient: patientId, p_code: code };
    try {
      if (revision !== undefined && !preview) pendingStartRevision = revision;
      const canAssess = () => snapshot?.triage_mode === 'choose' && snapshot.triage_selectable && choice;
      const assess = () => api.studentAssess({ ...query, p_selection: choice, p_seen_revision: snapshot.revision });
      const useAssessment = pendingStartRevision === undefined && canAssess();
      const request = useAssessment ? assess() : api.student({ ...query, p_start_revision: pendingStartRevision });
      receiveSnapshot(await request);
      pendingStartRevision = undefined;
      const firstVisit = openPending;
      openPending = false;
      if (firstVisit && snapshot.status === 'ready') {
        pendingStartRevision = snapshot.revision;
        receiveSnapshot(await api.student({ ...query, p_start_revision: pendingStartRevision }));
        pendingStartRevision = undefined;
      }
      if (!useAssessment && canAssess() && !snapshot.triage) receiveSnapshot(await assess());
      if (!preview && !exerciseCode && !carStation) {
        try { sessionStorage.setItem(storageKey, code); } catch {}
      }
      connectionInterrupted = false;
      el('connectionNotice').hidden = true;
      el('retryConnection').hidden = true;
      render();
    } catch (error) {
      if (error.status == null || error.status === 429 || error.status >= 500) {
        connectionInterrupted = true;
        render();
        el('connectionNotice').textContent = lastReceived
          ? 'Verbindung unterbrochen. Letzter empfangener Stand um ' + berlinClock.format(lastReceived) + ' Uhr.'
          : 'Verbindung unterbrochen. Der Patient wird geladen, sobald die Verbindung wieder da ist.';
        el('connectionNotice').hidden = false;
        el('retryConnection').hidden = false;
        return;
      }
      pendingStartRevision = undefined;
      connectionInterrupted = false;
      el('connectionNotice').hidden = true;
      el('retryConnection').hidden = true;
      if (error.code === '42501') {
        if (exerciseCode) api.clearExerciseCode(caseId, exerciseCode);
        if (directCode) {
          // Keep a rejected station entry from falling through to a different exercise on reload.
          history.replaceState(preview ? null : { traumasimStationRejected: true }, '');
          el('stationRecovery').hidden = preview;
        }
        try {
          if (!directCode || sessionStorage.getItem(storageKey) === directCode) {
            sessionStorage.removeItem(storageKey);
          }
        } catch {}
        code = null;
        if (!preview && !directCode) showJoinHint();
      } else if (error.code === 'P0002') {
        code = null;
      }
      snapshot = null;
      render();
      el('syncStatus').textContent = error.message;
    } finally {
      el('startPatient').disabled = pendingStartRevision !== undefined;
      el('retryConnection').disabled = false;
      busy = false;
    }
  }

  el('startPatient').addEventListener('click', () => {
    if (snapshot?.status === 'ready') void synchronize({ revision: snapshot.revision });
  });
  el('triageChoiceForm').addEventListener('submit', (event) => {
    event.preventDefault();
    const selection = el('triageSelection').value;
    if (snapshot?.triage_mode !== 'choose' || !snapshot.triage_selectable || choice || !Object.hasOwn(triageLabels, selection)) return;
    saveChoice(selection);
    focusResolution = true;
    render();
    void synchronize();
  });
  window.addEventListener('storage', (event) => {
    if (event.key !== choiceKey || !snapshot || choice) return;
    restoreChoice();
    if (choice) void synchronize();
  });
  el('retryConnection').addEventListener('click', () => { void synchronize(); });
  if (code) {
    void synchronize();
  } else if (rejectedStationLink) {
    el('stationRecovery').hidden = false;
    el('syncStatus').textContent = 'Patientenzugang ungültig oder abgelaufen.';
  } else {
    showJoinHint();
    el('syncStatus').textContent = 'Übungszugang erforderlich.';
  }
  setInterval(drawClocks, 1000);
  setInterval(() => { if (!document.hidden) void synchronize(); }, 2000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) void synchronize(); });
})();
