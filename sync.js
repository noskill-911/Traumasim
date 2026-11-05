(function () {
  'use strict';

  const { url, publishableKey } = window.TRAUMASIM_SUPABASE;

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
    student: (params) => request('/rest/v1/rpc/traumasim_student', params),
    trainer: (params, token) => request('/rest/v1/rpc/traumasim_trainer', params, token),
    signIn: (email, password) => request('/auth/v1/token?grant_type=password', { email, password }),
    signUp: (email, password, redirect) => request('/auth/v1/signup?redirect_to=' + encodeURIComponent(redirect), { email, password }),
    refresh: (refresh_token) => request('/auth/v1/token?grant_type=refresh_token', { refresh_token }),
    signOut: (token) => request('/auth/v1/logout?scope=local', {}, token),
    clock: (seconds) => {
      const minutes = Math.floor(seconds / 60);
      const remainder = Math.floor(seconds % 60);
      return [minutes, remainder].map((value) => String(value).padStart(2, '0')).join(':');
    },
    labels: Object.freeze({ ready: 'Wartet auf Start', running: 'Läuft', paused: 'Pausiert', finished: 'Abgeschlossen' })
  });
})();
