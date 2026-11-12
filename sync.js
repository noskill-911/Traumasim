(function () {
  'use strict';

  const { url, publishableKey } = window.TRAUMASIM_SUPABASE;
  const surveyFields = {
    X: 'Kritische äußere Blutung', A: 'Atemweg und HWS', B: 'Atmung',
    C: 'Kreislauf', D: 'Neurologie', E: 'Weitere Befunde und Umgebung'
  };

  function renderPrimarySurvey(panel, survey) {
    panel.hidden = !survey;
    if (!survey) return;
    const findings = panel.querySelector('[data-survey-findings]');
    if (!findings.childElementCount) {
      for (const [key, label] of Object.entries(surveyFields)) {
        const row = document.createElement('div');
        const term = document.createElement('dt');
        const description = document.createElement('dd');
        term.textContent = key + ' · ' + label;
        row.append(term, description);
        findings.append(row);
      }
    }
    for (const [index, key] of Object.keys(surveyFields).entries()) {
      const row = findings.children[index];
      const text = survey.findings[key] || 'Im Fallprofil offen.';
      if (row.lastElementChild.textContent !== text) row.lastElementChild.textContent = text;
      row.classList.toggle('survey-focus', survey.focus.includes(key));
    }
    const risks = panel.querySelector('[data-survey-risks]');
    risks.hidden = !survey.risks.length;
    const list = risks.querySelector('ul');
    if (list.dataset.items !== JSON.stringify(survey.risks)) {
      list.dataset.items = JSON.stringify(survey.risks);
      list.replaceChildren(...survey.risks.map((risk) => {
        const item = document.createElement('li');
        item.textContent = risk;
        return item;
      }));
    }
    const note = panel.querySelector('[data-survey-note]');
    note.hidden = !survey.note;
    note.textContent = survey.note ? 'Zusatz aus dem Szenario · ' + survey.note : '';
  }

  async function request(path, body, accessToken) {
    const headers = { apikey: publishableKey, 'Content-Type': 'application/json' };
    if (accessToken) headers.Authorization = 'Bearer ' + accessToken;
    let response;
    try {
      response = await fetch(url + path, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(20000)
      });
    } catch {
      throw new Error('Supabase ist momentan nicht erreichbar.');
    }

    const data = await response.json().catch(() => null);
    if (!response.ok) {
      const message = data?.code === 'PGRST202' ? 'Die zentrale Übung ist noch nicht eingerichtet.'
        : data?.message || data?.msg || 'Die Anfrage ist fehlgeschlagen.';
      throw Object.assign(new Error(message), { status: response.status, code: data?.code });
    }
    return data;
  }

  window.TraumaSync = Object.freeze({
    join: (code) => request('/rest/v1/rpc/traumasim_join', { p_code: code }),
    exerciseCode: (caseId) => {
      try { return localStorage.getItem('traumasim:exercise:' + caseId); } catch { return null; }
    },
    saveExerciseCode: (caseId, code) => localStorage.setItem('traumasim:exercise:' + caseId, code),
    clearExerciseCode: (caseId, code) => {
      try {
        const key = 'traumasim:exercise:' + caseId;
        if (localStorage.getItem(key) === code) localStorage.removeItem(key);
      } catch {}
    },
    student: (params) => request('/rest/v1/rpc/traumasim_student', params),
    studentAssess: (params) => request('/rest/v1/rpc/traumasim_student_assess', params),
    studentMarkTriage: (params) => request('/rest/v1/rpc/traumasim_student_mark_triage', params),
    bookCar: (params, token) => request('/rest/v1/rpc/traumasim_book_car', params, token),
    bookBus: (params, token) => request('/rest/v1/rpc/traumasim_book_bus', params, token),
    createCustom: (scenario, token) => request('/rest/v1/rpc/traumasim_create_custom', { p_scenario: scenario }, token),
    trainer: (params, token) => request('/rest/v1/rpc/traumasim_trainer', params, token),
    signIn: (email, password) => request('/auth/v1/token?grant_type=password', { email, password }),
    signUp: (email, password, redirect) => request('/auth/v1/signup?redirect_to=' + encodeURIComponent(redirect), { email, password }),
    refresh: (refresh_token) => request('/auth/v1/token?grant_type=refresh_token', { refresh_token }),
    signOut: (token) => request('/auth/v1/logout?scope=local', {}, token),
    identityDetails: (identity) => identity ? [identity.name, identity.age + ' Jahre', identity.gender].join(' · ') : '',
    identitySource: (identity) => identity
      ? ['Namensbezug', identity.name_source, identity.name_locality, identity.name_background].filter(Boolean).join(' · ')
      : '',
    renderPrimarySurvey,
    clock: (seconds) => {
      const minutes = Math.floor(seconds / 60);
      const remainder = Math.floor(seconds % 60);
      return [minutes, remainder].map((value) => String(value).padStart(2, '0')).join(':');
    },
    labels: Object.freeze({ ready: 'Wartet auf Start', running: 'Läuft', paused: 'Pausiert', finished: 'Abgeschlossen' })
  });
})();
