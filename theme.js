(function () {
  'use strict';

  const key = 'traumasim:theme';
  const root = document.documentElement;
  const system = window.matchMedia('(prefers-color-scheme: dark)');
  let preference = storedPreference();
  let toggle;

  function storedPreference() {
    try {
      const value = localStorage.getItem(key);
      return value === 'dark' || value === 'light' ? value : null;
    } catch {
      return null;
    }
  }

  function applyTheme() {
    const dark = preference ? preference === 'dark' : system.matches;
    root.dataset.theme = dark ? 'dark' : 'light';
    if (!toggle) return;
    toggle.textContent = dark ? '☀ Hell' : '☾ Dunkel';
    toggle.setAttribute('aria-label', dark ? 'Helles Design einschalten' : 'Dunkelmodus einschalten');
  }

  applyTheme();
  system.addEventListener('change', applyTheme);
  window.addEventListener('storage', (event) => {
    if (event.key !== key && event.key !== null) return;
    preference = storedPreference();
    applyTheme();
  });
  document.addEventListener('DOMContentLoaded', () => {
    toggle = document.querySelector('[data-theme-toggle]');
    if (!toggle) return;
    applyTheme();
    toggle.hidden = false;
    toggle.addEventListener('click', () => {
      preference = root.dataset.theme === 'dark' ? 'light' : 'dark';
      try { localStorage.setItem(key, preference); } catch {}
      applyTheme();
    });
  });
})();
