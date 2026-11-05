(function () {
  'use strict';

  const params = new URLSearchParams(location.search);
  const caseId = params.get('case') || 'vu-baum';
  const patientId = params.get('patient') || 'fahrer';
  const scenario = window.TRAUMA_CASES.find((item) => item.id === caseId);
  const preset = scenario?.patients.find((item) => item.id === patientId);
  const el = (id) => document.getElementById(id);
  const api = window.TraumaSync;

  if (!preset && !/^custom-[0-9a-f-]{36}$/.test(caseId)) {
    el('content').innerHTML = '<div class="panel"><h1>Patient nicht gefunden</h1><a href="index.html">Zur Übersicht</a></div>';
    return;
  }

  el('caseTitle').textContent = scenario?.title ?? 'TraumaSim';
  el('patientTitle').textContent = preset?.name ?? 'Übungspatient';
  const storageKey = 'traumasim-access:' + caseId + ':' + patientId;
  const linkCode = new URLSearchParams(location.hash.slice(1)).get('code');
  if (linkCode) {
    history.replaceState({ traumasimPatientCode: linkCode }, '', location.pathname + location.search);
  }
  // A direct link keeps its exercise on reload. A new station scan uses the joined exercise.
  const directCode = history.state?.traumasimPatientCode;
  const exerciseCode = directCode ? null : api.exerciseCode(caseId);
  let code = directCode || exerciseCode;
  try { code ||= sessionStorage.getItem(storageKey); } catch {}
  let openPending = Boolean(code);
  const showJoinHint = () => { el('joinHint').hidden = false; };
  let snapshot = null;
  let busy = false;
  let animation = null;
  let monitor = null;
  let serverClockOffset = NaN;
  const berlinClock = new Intl.DateTimeFormat('de-DE', {
    timeZone: 'Europe/Berlin', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23'
  });

function wavePath(kind,phase){let out='';const width=600;for(let x=0;x<=width;x+=2){let p=(x/width*6-phase)%1;if(p<0)p+=1;let y=45;if(kind==='ecg'){if(p<.58)y=45;else if(p<.64)y=43-4*Math.sin((p-.58)/.06*Math.PI);else if(p<.69)y=45+10*(p-.64)/.05;else if(p<.72)y=55-47*(p-.69)/.03;else if(p<.75)y=8+58*(p-.72)/.03;else if(p<.79)y=66-21*(p-.75)/.04;else if(p<.95)y=45-7*Math.sin((p-.79)/.16*Math.PI)}else if(kind==='pleth'){y=62-34*Math.pow(Math.max(0,Math.sin(Math.PI*p)),5)-8*Math.sin(Math.PI*p)}else{y=45-19*Math.sin(2*Math.PI*p)}out+=(x===0?'M':'L')+x+' '+y.toFixed(1)+' '}return out}
  function animateWaves() {
    if (!monitor) {
      animation = null;
      return;
    }
    const now = performance.now() / 1000;
    if (monitor.ecg) el('ecgTrace').setAttribute('d', wavePath('ecg', now * monitor.h / 60 * .16));
    if (monitor.o != null) el('plethTrace').setAttribute('d', wavePath('pleth', now * monitor.h / 60 * .16));
    if (monitor.r != null) el('respTrace').setAttribute('d', wavePath('resp', now * monitor.r / 60 * .16));
    animation = requestAnimationFrame(animateWaves);
  }

  function drawEcgClock() {
    const clock = el('ecgClock');
    if (!clock) return;
    clock.hidden = !monitor?.ecg;
    if (clock.hidden) return;
    const now = Number.isFinite(serverClockOffset) ? serverClockOffset + performance.now() : Date.now();
    clock.textContent = berlinClock.format(now);
  }

  function render() {
    const brief = snapshot && (snapshot.brief ?? preset);
    el('caseTitle').textContent = brief?.title ?? scenario?.title ?? 'TraumaSim';
    el('patientTitle').textContent = brief?.name ?? preset?.name ?? 'Übungspatient';
    el('intro').textContent = brief?.intro ?? '';
    el('story').textContent = brief?.story ?? '';
    el('questions').textContent = brief?.questions ?? '';
    el('storyPanel').hidden = !snapshot;
    el('clockPanel').hidden = !snapshot;
    el('startPatient').hidden = snapshot?.status !== 'ready';
    el('triagePanel').hidden = !snapshot?.triage;
    monitor = snapshot?.monitor ?? (snapshot?.vitals && { ...snapshot.vitals, ecg: true });
    el('vitalsPanel').hidden = !monitor;
    serverClockOffset = Date.parse(snapshot?.server_time) - performance.now();
    drawEcgClock();
    if (!snapshot) return;

    el('syncStatus').textContent = api.labels[snapshot.status];
    el('elapsed').textContent = api.clock(snapshot.elapsed);
    if (snapshot.triage) {
      const { red, reason, condition } = snapshot.triage;
      const category = snapshot.triage.category ?? (red ? 'red' : 'yellow');
      el('triageBox').className = 'triage ' + category;
      el('triage').textContent = { red: 'SK I · ROT', yellow: 'SK II · GELB', green: 'SK III · GRÜN' }[category];
      el('triageReason').textContent = reason;
      el('patientCondition').textContent = condition;
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
    const query = { p_case: caseId, p_patient: patientId, p_code: code };
    try {
      if (revision !== undefined) query.p_start_revision = revision;
      snapshot = await api.student(query);
      const firstVisit = openPending;
      openPending = false;
      if (firstVisit && snapshot.status === 'ready') {
        snapshot = await api.student({ ...query, p_start_revision: snapshot.revision });
      }
      if (!exerciseCode) {
        try { sessionStorage.setItem(storageKey, code); } catch {}
      }
      render();
    } catch (error) {
      if (error.code === '42501') {
        if (exerciseCode) api.clearExerciseCode(caseId, exerciseCode);
        if (directCode) history.replaceState(null, '');
        try { sessionStorage.removeItem(storageKey); } catch {}
        code = null;
        showJoinHint();
      }
      snapshot = null;
      render();
      el('syncStatus').textContent = error.message;
    } finally {
      el('startPatient').disabled = false;
      busy = false;
    }
  }

  el('startPatient').addEventListener('click', () => {
    if (snapshot?.status === 'ready') void synchronize({ revision: snapshot.revision });
  });
  if (code) {
    void synchronize();
  } else {
    showJoinHint();
    el('syncStatus').textContent = 'Übungszugang erforderlich.';
  }
  setInterval(drawEcgClock, 1000);
  setInterval(() => { if (!document.hidden) void synchronize(); }, 2000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) void synchronize(); });
})();
