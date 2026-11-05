(function () {
  'use strict';

  const params = new URLSearchParams(location.search);
  const caseId = params.get('case') || 'vu-baum';
  const patientId = params.get('patient') || 'fahrer';
  const scenario = window.TRAUMA_CASES.find((item) => item.id === caseId);
  const patient = scenario?.patients.find((item) => item.id === patientId);
  const el = (id) => document.getElementById(id);
  const api = window.TraumaSync;

  if (!patient) {
    el('content').innerHTML = '<div class="panel"><h1>Patient nicht gefunden</h1><a href="index.html">Zur Übersicht</a></div>';
    return;
  }

  el('caseTitle').textContent = scenario.title;
  el('patientTitle').textContent = patient.name;
  const storageKey = 'traumasim-access:' + caseId + ':' + patientId;
  const linkCode = new URLSearchParams(location.hash.slice(1)).get('code');
  if (linkCode) history.replaceState(null, '', location.pathname + location.search);
  const exerciseCode = linkCode ? null : api.exerciseCode(caseId);
  let code = linkCode || exerciseCode;
  try { code ||= sessionStorage.getItem(storageKey); } catch {}
  let openPending = Boolean(code);
  const showJoinHint = () => { el('joinHint').hidden = false; };
  let snapshot = null;
  let busy = false;
  let animation = null;

function wavePath(kind,phase){let out='';const width=600;for(let x=0;x<=width;x+=2){let p=(x/width*6-phase)%1;if(p<0)p+=1;let y=45;if(kind==='ecg'){if(p<.58)y=45;else if(p<.64)y=43-4*Math.sin((p-.58)/.06*Math.PI);else if(p<.69)y=45+10*(p-.64)/.05;else if(p<.72)y=55-47*(p-.69)/.03;else if(p<.75)y=8+58*(p-.72)/.03;else if(p<.79)y=66-21*(p-.75)/.04;else if(p<.95)y=45-7*Math.sin((p-.79)/.16*Math.PI)}else if(kind==='pleth'){y=62-34*Math.pow(Math.max(0,Math.sin(Math.PI*p)),5)-8*Math.sin(Math.PI*p)}else{y=45-19*Math.sin(2*Math.PI*p)}out+=(x===0?'M':'L')+x+' '+y.toFixed(1)+' '}return out}
function animateWaves(){if(!document.getElementById('ecgTrace'))return;const v=snapshot?.vitals;if(!v||el('vitalsPanel').hidden){animation=null;return}const now=performance.now()/1000;document.getElementById('ecgTrace').setAttribute('d',wavePath('ecg',now*v.h/60*.16));document.getElementById('plethTrace').setAttribute('d',wavePath('pleth',now*v.h/60*.16));document.getElementById('respTrace').setAttribute('d',wavePath('resp',now*v.r/60*.16));animation=requestAnimationFrame(animateWaves)}

  function render() {
    el('intro').textContent = snapshot ? patient.intro : '';
    el('story').textContent = snapshot ? patient.story : '';
    el('questions').textContent = snapshot ? patient.questions : '';
    el('storyPanel').hidden = !snapshot;
    el('clockPanel').hidden = !snapshot;
    el('startPatient').hidden = snapshot?.status !== 'ready';
    el('triagePanel').hidden = !snapshot?.triage;
    el('vitalsPanel').hidden = !snapshot?.vitals;
    if (!snapshot) return;

    el('syncStatus').textContent = api.labels[snapshot.status];
    el('elapsed').textContent = api.clock(snapshot.elapsed);
    if (snapshot.triage) {
      const { red, reason, condition } = snapshot.triage;
      el('triageBox').className = 'triage ' + (red ? 'red' : 'yellow');
      el('triage').textContent = red ? 'SK I · ROT' : 'SK II · GELB';
      el('triageReason').textContent = reason;
      el('patientCondition').textContent = condition;
    }
    if (snapshot.vitals) {
      const { s, d, h, r, o, g } = snapshot.vitals;
      el('bp').textContent = s + '/' + d;
      el('hr').textContent = h;
      el('rr').textContent = r;
      el('spo').textContent = o;
      el('gcs').textContent = g;
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
  setInterval(() => { if (!document.hidden) void synchronize(); }, 2000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) void synchronize(); });
})();
