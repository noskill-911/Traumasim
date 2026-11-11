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
  const stationKind = /^(car|truck|object)-[0-9]{2}-[0-9]{2,}$/.exec(patientId)?.[1];
  if (!preset && !busStation && !stationKind && !/^custom-[0-9a-f-]{36}$/.test(caseId)) {
    el('content').innerHTML = '<div class="panel"><h1>Patient nicht gefunden</h1><a href="index.html">Zur Übersicht</a></div>';
    return;
  }

  const defaultTitle = preset ? scenario.title : 'TraumaSim';
  el('caseTitle').textContent = defaultTitle;
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
  const exerciseCode = directCode || stationKind || rejectedStationLink ? null : api.exerciseCode(caseId);
  let code = directCode || exerciseCode;
  if (!stationKind && !rejectedStationLink) {
    try { code ||= sessionStorage.getItem(storageKey); } catch {}
  }
  let openPending = Boolean(code) && !preview;
  let pendingStartRevision;
  let connectionInterrupted = false;
  let lastReceived = null;
  const showJoinHint = () => {
    if (stationKind) el('joinHint').textContent = 'Scanne den einzelnen Stations-QR dieser Person vor Ort.';
    el('joinHint').hidden = false;
  };
  let snapshot = null;
  let busy = false;
  let choice = null;
  let choiceKey = null;
  let changingChoice = false;
  let revealTimer;
  const revealDelay = 4000;
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
    red: 'SK I · Rot', yellow: 'SK II · Gelb', green: 'SK III · Grün', affected: 'SK B · Betroffene', black: 'SK Schwarz'
  };

  function restoreChoice() {
    if (preview || !choiceKey) return;
    try {
      const saved = JSON.parse(localStorage.getItem(choiceKey));
      if (saved?.revision === snapshot.revision && Object.hasOwn(triageLabels, saved.selection)) {
        const revealAt = Number.isFinite(saved.revealAt) ? Math.min(saved.revealAt, Date.now() + revealDelay) : 0;
        if (choice?.selection !== saved.selection || choice.revealAt !== revealAt) {
          applyChoice({ selection: saved.selection, revealAt });
        }
      } else if (saved?.revision < snapshot.revision) {
        localStorage.removeItem(choiceKey);
      }
    } catch {}
  }

  function applyChoice(nextChoice) {
    choice = nextChoice;
    if (snapshot.triage_mode === 'choose') snapshot.triage = null;
  }

  function saveChoice(selection) {
    applyChoice({ selection, revealAt: Date.now() + revealDelay });
    if (preview || !choiceKey) return;
    try {
      const saved = JSON.parse(localStorage.getItem(choiceKey));
      if (!(saved?.revision > snapshot.revision)) {
        localStorage.setItem(choiceKey, JSON.stringify({ revision: snapshot.revision, ...choice }));
      }
    } catch {}
  }

  function scheduleReveal() {
    clearTimeout(revealTimer);
    if (choice && choice.revealAt > Date.now()) {
      revealTimer = setTimeout(() => { if (!document.hidden) void synchronize(); }, choice.revealAt - Date.now());
    }
  }

  const ecgTrace = el('ecgTrace');
  const ecgBeatWidth = 100;
  const ecgBeat = 'h58 c1.25 0 1.75 -6 3 -6 s1.75 6 3 6 l5 10 3 -47 3 58 4 -21 c3 0 5 -7 8 -7 s5 7 8 7 h5 ';
  // A full extra beat on the left keeps the clipped trace continuous at each phase wrap.
  ecgTrace.setAttribute('d', 'M-100 45 ' + ecgBeat.repeat(7));

  function wavePath(kind, phase) {
    let path = '';
    const width = 600;
    for (let x = 0; x <= width; x += 2) {
      let position = (x / width * 6 - phase) % 1;
      if (position < 0) position += 1;
      let y;
      if (kind === 'pleth') {
        const pulse = Math.sin(Math.PI * position);
        y = 62 - 34 * Math.pow(Math.max(0, pulse), 5) - 8 * pulse;
      } else {
        y = 45 - 19 * Math.sin(2 * Math.PI * position);
      }
      path += (x === 0 ? 'M' : 'L') + x + ' ' + y.toFixed(1) + ' ';
    }
    return path;
  }
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
    if (monitor.ecg) ecgTrace.setAttribute('transform', 'translate(' + cardiacPhase * ecgBeatWidth + ' 0)');
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
    if (data.triage_mode !== 'choose' || !data.triage_selectable) changingChoice = false;
    if (choiceKey !== nextKey || previousRevision !== data.revision) {
      choiceKey = nextKey;
      choice = null;
      changingChoice = false;
      restoreChoice();
      scheduleReveal();
    }
    snapshotReceivedAt = performance.now();
    serverClockOffset = Date.parse(data.server_time) - snapshotReceivedAt;
    lastReceived = new Date();
  }

  function renderTriage() {
    const choosing = snapshot?.triage_mode === 'choose';
    const comparing = Boolean(choosing && snapshot.triage_selectable && choice);
    const showButtons = choosing && snapshot.triage_selectable && (!choice || changingChoice);
    const result = choosing && (!comparing || changingChoice || Date.now() < choice.revealAt) ? null : snapshot?.triage;
    const category = result && (result.category ?? (result.red ? 'red' : 'yellow'));
    const reason = result?.reason ?? '';
    const condition = result?.condition ?? (comparing ? snapshot.observation : '') ?? '';
    el('triageChoicePanel').hidden = !showButtons;
    el('cancelTriageChange').hidden = !changingChoice;
    el('triageObservation').hidden = !showButtons || !snapshot.observation;
    el('triageObservation').textContent = showButtons ? snapshot.observation ?? '' : '';
    el('triagePanel').hidden = !comparing && !result;
    el('triageAutoLabel').hidden = comparing;
    el('triageComparison').classList.toggle('is-comparison', comparing);
    el('triageOwnBox').hidden = !comparing;
    el('triageOwnBox').className = comparing ? 'triage ' + choice.selection : 'triage';
    el('triageOwnChoice').textContent = comparing ? triageLabels[choice.selection] : '';
    el('triageTargetLabel').hidden = !comparing;
    const pending = el('triageChoicePending');
    pending.hidden = !comparing || Boolean(result);
    const pendingText = changingChoice ? 'Wartet auf deine neue Auswahl' : 'Wird gleich aufgedeckt …';
    if (pending.textContent !== pendingText) pending.textContent = pendingText;
    el('changeTriageChoice').hidden = !comparing || changingChoice;
    el('triageBox').className = 'triage' + (category ? ' ' + category : comparing ? ' pending' : '');
    const label = triageLabels[category] ?? '';
    if (el('triage').textContent !== label) el('triage').textContent = label;
    el('triageExplanation').hidden = !reason && !condition;
    el('triageReason').hidden = !reason;
    el('triageReason').textContent = reason;
    el('patientCondition').hidden = !condition;
    el('patientCondition').textContent = condition;
  }

  function render() {
    const brief = snapshot && (snapshot.brief ?? preset);
    const identity = snapshot?.identity;
    el('caseTitle').textContent = brief?.title ?? defaultTitle;
    const stationName = brief?.name ?? preset?.name;
    el('patientTitle').textContent = identity?.name ?? stationName ?? 'Übungspatient';
    const details = el('patientIdentityDetails');
    details.textContent = [api.identityDetails(identity), identity ? stationName : ''].filter(Boolean).join(' · ');
    details.hidden = !details.textContent;
    const source = el('patientIdentitySource');
    source.textContent = api.identitySource(identity);
    source.hidden = !identity;
    el('intro').textContent = brief?.intro ?? '';
    const story = brief?.story ?? '';
    const questions = brief?.questions ?? '';
    if (el('story').textContent !== story) el('story').textContent = story;
    if (el('questions').textContent !== questions) el('questions').textContent = questions;
    el('patientQuestions').hidden = !questions.trim();
    el('storyPanel').hidden = !snapshot;
    el('startPatient').hidden = preview || snapshot?.status !== 'ready';
    renderTriage();
    monitor = snapshot?.monitor ?? (snapshot?.vitals && { ...snapshot.vitals, ecg: true });
    el('vitalsPanel').hidden = !monitor;
    el('clockPanel').hidden = !snapshot || Boolean(monitor && el('monitorElapsed'));
    drawClocks();
    if (!snapshot) return;

    el('syncStatus').textContent = api.labels[snapshot.status];
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
      ecgTrace.toggleAttribute('hidden', !ecg);
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
      const canAssess = () => snapshot?.triage_mode === 'choose' && snapshot.triage_selectable && choice && Date.now() >= choice.revealAt;
      const assess = async () => {
        const requestedChoice = choice;
        const data = await api.studentAssess({ ...query, p_selection: requestedChoice.selection, p_seen_revision: snapshot.revision });
        if (choice !== requestedChoice && data.triage_mode === 'choose') data.triage = null;
        return data;
      };
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
      if (!preview && !exerciseCode && !stationKind) {
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
  el('changeTriageChoice').addEventListener('click', () => {
    changingChoice = true;
    render();
    el('triageChoiceButtons').querySelector('button[data-category="' + choice.selection + '"]').focus();
  });
  el('cancelTriageChange').addEventListener('click', () => {
    changingChoice = false;
    render();
    el('changeTriageChoice').focus();
  });
  el('triageChoiceButtons').addEventListener('click', (event) => {
    const selection = event.target.closest('button[data-category]')?.dataset.category;
    if (snapshot?.triage_mode !== 'choose' || !snapshot.triage_selectable
      || (choice && !changingChoice) || !Object.hasOwn(triageLabels, selection)) return;
    restoreChoice();
    if (!choice || changingChoice) {
      if (!preview && code) {
        // Mark the learner's click independently of the delayed comparison.
        void api.studentMarkTriage({
          p_case: caseId, p_patient: patientId, p_code: code, p_seen_revision: snapshot.revision
        }).catch(() => {});
      }
      saveChoice(selection);
    }
    changingChoice = false;
    render();
    el('triageOwnChoice').focus({ preventScroll: true });
    scheduleReveal();
  });
  window.addEventListener('storage', (event) => {
    if (event.key !== choiceKey || !snapshot) return;
    const previousChoice = choice;
    restoreChoice();
    if (choice !== previousChoice) {
      render();
      scheduleReveal();
      void synchronize();
    }
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
