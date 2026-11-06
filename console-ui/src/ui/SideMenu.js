// BH-9118: the side menu. Every NAV entry (src/app.js), by group, in a column
// left of the page that scrolls up and down and never sideways. The collapse
// button turns it into an icon rail; the Team group adds one link per staff
// agent from the roster read. Both choices, and which groups are closed, are
// the viewer's own (lib/sidemenu.js keeps them in localStorage).
//
// On a phone the menu is a drawer the top bar's hamburger opens (`open`). It
// closes on Escape, on a scrim tap and after a link tap (`onClose`; App also
// closes it on any path change). Focus moves to the first item on open, stays
// inside while it is open, and goes back to `returnFocusRef` on close. The
// open drawer is always the full menu, never the rail.

import { useState, useEffect, useRef } from 'preact/hooks';
import { html, Link } from '../router.js';
import { api } from '../api.js';
import { useApi } from '../lib/hooks.js';
import { Skeleton } from './primitives.js';
import { menuGroups, teamLinks, readMenuPrefs, writeMenuPrefs } from '../lib/sidemenu.js';

const storage = () => (typeof window !== 'undefined' ? window.localStorage : null);
// A display:none control (the collapse button in the drawer) is not a Tab stop.
const visible = (el) => typeof el.getClientRects !== 'function' || el.getClientRects().length > 0;

export function SideMenu({ nav, groups, path, openAlerts = 0, open = false, onClose, returnFocusRef }) {
  const [prefs, setPrefs] = useState(() => readMenuPrefs(storage()));
  const save = (next) => { setPrefs(next); writeMenuPrefs(storage(), next); };
  // One read per app mount, no poll: the roster changes when an agent is added.
  const roster = useApi(() => api.staffRoster(), []);
  const team = roster.data || roster.error ? teamLinks(roster.data, path) : null;
  const rail = prefs.collapsed && !open;

  const navRef = useRef(null);
  // App hands a fresh onClose on every render; the key handler reads it here
  // so it is bound once per open (the Modal.js pattern, D39).
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  const wasOpen = useRef(false);
  useEffect(() => {
    if (!open) {
      if (wasOpen.current && returnFocusRef && returnFocusRef.current) returnFocusRef.current.focus();
      wasOpen.current = false;
      return undefined;
    }
    wasOpen.current = true;
    const first = navRef.current && navRef.current.querySelector('a');
    if (first) first.focus();
    const onKey = (e) => {
      if (e.key === 'Escape') { e.preventDefault(); if (closeRef.current) closeRef.current(); return; }
      if (e.key !== 'Tab' || !navRef.current) return;
      const focusable = [...navRef.current.querySelectorAll('a, button')].filter(visible);
      if (!focusable.length) return;
      const firstEl = focusable[0];
      const lastEl = focusable[focusable.length - 1];
      if (e.shiftKey && document.activeElement === firstEl) { e.preventDefault(); lastEl.focus(); }
      else if (!e.shiftKey && document.activeElement === lastEl) { e.preventDefault(); firstEl.focus(); }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open]);

  const close = () => { if (onClose) onClose(); };
  const list = menuGroups(nav, groups, path, prefs.groups, team);
  const toggleGroup = (g) => save({ ...prefs, groups: { ...prefs.groups, [g.id]: !g.open } });
  const navCls = `sidemenu${rail ? ' sidemenu--rail' : ''}${open ? ' sidemenu--open' : ''}`;

  return html`
    ${open ? html`<div class="sidemenu__scrim" onClick=${close}></div>` : null}
    <nav id="sidemenu" class=${navCls} aria-label="primary" ref=${navRef}>
      <button type="button" class="sidemenu__collapse" aria-pressed=${prefs.collapsed ? 'true' : 'false'}
        aria-label=${prefs.collapsed ? 'Expand menu' : 'Collapse menu'} title=${prefs.collapsed ? 'Expand menu' : 'Collapse menu'}
        onClick=${() => save({ ...prefs, collapsed: !prefs.collapsed })}>
        <span aria-hidden="true">${prefs.collapsed ? '»' : '«'}</span>
      </button>
      ${list.map((g) => html`
        <div key=${g.id} class="sidemenu__group" data-group=${g.id}>
          <button type="button" class="sidemenu__grouphead" aria-expanded=${g.open ? 'true' : 'false'}
            onClick=${() => toggleGroup(g)}>
            <span class="sidemenu__chev" aria-hidden="true">${g.open ? '▾' : '▸'}</span>${g.label}
          </button>
          ${rail || g.open ? g.items.map((it) => html`
            <${Link} key=${it.to} to=${it.to} onNavigate=${close}
              class=${`navlink sidemenu__item${it.agent ? ' sidemenu__agent' : ''}${it.on ? ' navlink--on' : ''}`}
              aria-current=${it.on ? 'page' : undefined} title=${it.label} aria-label=${it.label}>
              ${it.icon ? html`<${it.icon} color="currentColor"/>` : html`<span class="sidemenu__dot" aria-hidden="true"></span>`}
              <span class="sidemenu__label">${it.label}</span>
              ${it.badge && openAlerts > 0 ? html`<span class="navlink__badge">${openAlerts}</span>` : null}
            <//>`) : null}
          ${g.id === 'team' && (rail || g.open) ? (
            team === null ? html`<div class="sidemenu__note"><${Skeleton} rows=${1} height=${12}/></div>`
            : team.error ? html`<div class="sidemenu__note">Roster did not load.</div>` : null
          ) : null}
        </div>`)}
    </nav>`;
}
