/* The site is fully rendered at build time; JavaScript adds only preview controls. */
(() => {
  const selector = document.querySelector('#language');
  selector.addEventListener('change', () => {
    window.location.assign(selector.value + window.location.hash);
  });

  const preview = document.querySelector('#editor-preview');
  const buttons = [...document.querySelectorAll('[data-theme]')];
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  let chosen = false;
  function setTheme(dark) {
    preview.classList.toggle('is-dark', dark);
    buttons.forEach(button => button.setAttribute('aria-pressed', String((button.dataset.theme === 'dark') === dark)));
    const light = preview.querySelector('.preview-light');
    const night = preview.querySelector('.preview-dark');
    light.setAttribute('aria-hidden', String(dark));
    night.setAttribute('aria-hidden', String(!dark));
    night.alt = light.alt;
  }
  buttons.forEach(button => button.addEventListener('click', () => {
    chosen = true;
    setTheme(button.dataset.theme === 'dark');
  }));
  setTheme(media.matches);
  media.addEventListener('change', event => { if (!chosen) setTheme(event.matches); });
})();
