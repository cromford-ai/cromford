import { render } from 'preact';
import { html } from './router.js';
import { App } from './app.js';
import { api } from './api.js';
import { syncFleetDefault } from './theme/apply.js';
import { initSentry } from './lib/error-report.js';
import './styles.css';
import './phone-floor.css';
import './settings-shell.css';
import './ai-accounts.css';

// Off unless VITE_SENTRY_DSN was set at build time (BH-5619).
initSentry(import.meta.env);

render(html`<${App} />`, document.getElementById('app'));

// The boot script in <head> already painted the theme. This reads the fleet
// default row once, caches it for the next load, and repaints only when the
// viewer has no pick of their own and the row names a different theme. It
// never blocks the first render, and a failed read changes nothing.
syncFleetDefault(api).catch((err) => console.warn('theme: fleet default sync failed', err));
