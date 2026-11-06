// The top bar (BH-4990, wave 1 of BH-4947): brand, the snapshot age and
// refresh countdown, who this session writes as, the watchdog, and a theme
// switch. The section links are in the side menu (src/ui/SideMenu.js,
// BH-9118); on a phone the bar's hamburger opens that menu as a drawer.
//
// The switch is the same pick /settings/appearance makes (the viewer's own
// ui.theme, then a repaint), for the three built-ins only. Custom themes stay
// on /settings/appearance. Its pressed button follows the page: a pick made
// anywhere else (APPEARANCE, the fleet default arriving) re-reads data-theme
// on THEME_CHANGE_EVENT.
//
// `onMenu` toggles the drawer, `menuOpen` is whether it is open, and `menuRef`
// is where the drawer hands focus back when it closes.

import { useState, useEffect } from 'preact/hooks';
import { html, Link } from '../router.js';
import { snapshotLabel, healthFromAge } from '../lib/format.js';
import { identityPill } from '../lib/identity.js';
import { Logo, Dot } from './icons.js';
import { healthColor } from './primitives.js';
import { BUILTIN_THEMES, THEME_ORDER } from '../theme/themes.js';
import { applyTheme, currentThemeId, writeViewerPick, writeThemeCache, themeFor } from '../theme/apply.js';
import { onThemeChange } from '../theme/tokens.js';

const pageTheme = () => (typeof document !== 'undefined' && document.documentElement ? currentThemeId(document) : null);

export function ThemeSwitch() {
  const [active, setActive] = useState(pageTheme);
  useEffect(() => onThemeChange(() => setActive(pageTheme())), []);
  const pick = (id) => {
    const theme = themeFor(id);
    writeViewerPick(id);
    writeThemeCache(theme);
    applyTheme(document, theme);
    setActive(id);
  };
  return html`
    <div class="themeswitch" role="group" aria-label="Theme">
      ${THEME_ORDER.map((id) => html`
        <button key=${id} type="button" class=${active === id ? 'themeswitch__btn themeswitch__btn--on' : 'themeswitch__btn'}
          data-theme-switch=${id} aria-pressed=${active === id ? 'true' : 'false'}
          onClick=${() => pick(id)}>${BUILTIN_THEMES[id].name}</button>`)}
    </div>`;
}

export function TopBar({ snap, loading, secondsLeft, watchdogDown, identity, menuOpen = false, onMenu, menuRef }) {
  const health = healthFromAge(snap.snapshot_age_min);
  const who = identityPill(identity ? identity.data : null, identity ? identity.error : null);
  return html`
    <div class="topbar">
      <button type="button" class="topbar__menu" ref=${menuRef} aria-label="Open menu"
        aria-expanded=${menuOpen ? 'true' : 'false'} aria-controls="sidemenu" onClick=${onMenu}>
        <svg width="18" height="14" viewBox="0 0 18 14" aria-hidden="true">
          <path d="M1 1h16M1 7h16M1 13h16" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round"/>
        </svg>
      </button>
      <${Link} to="/" class="topbar__brand">
        <${Logo}/>
        <span class="topbar__title">MISSION CONTROL</span>
        <span class="topbar__sub hide-sm">cromford</span>
      <//>
      <div class="topbar__right">
        <span class="topbar__snap">
          ${loading && snap.snapshot_age_min === undefined
            ? 'loading…'
            : html`<span class=${`topbar__age topbar__age--${health === 'ok' ? 'ok' : health === 'warn' ? 'warn' : 'bad'}`}>${snapshotLabel(snap.snapshot_age_min)}</span>`}
        </span>
        <span class="topbar__refresh hide-sm" title="the fleet poll refreshes on this cadence">
          refresh ${secondsLeft}s
        </span>
        <span class=${who.tone === 'ok' ? 'pill' : who.tone === 'warn' ? 'pill pill--warn' : 'pill pill--muted'}
          style="display:inline-block;min-width:0;max-width:40vw;overflow:hidden;text-overflow:ellipsis"
          title=${who.title}>${who.text}</span>
        <span class=${watchdogDown ? 'pill pill--warn' : 'pill'}>
          <${Dot} color=${watchdogDown ? 'var(--amber)' : healthColor(health)} size=${8}/>
          ${watchdogDown ? 'WATCHDOG DOWN' : 'WATCHDOG OK'}
        </span>
        <${ThemeSwitch}/>
      </div>
    </div>`;
}
