import { useState, useEffect, useCallback } from 'preact/hooks';
import { h } from 'preact';
import htm from 'htm';

export const html = htm.bind(h);

// A history router small enough to read in one sitting. Cloudflare Pages serves
// index.html for every non-function path (see public/_redirects), so deep links
// and reloads land on the SPA rather than on a 404.

const listeners = new Set();

export function navigate(to, { replace = false } = {}) {
  if (to === currentPath() + currentSearch()) return;
  if (replace) window.history.replaceState({}, '', to);
  else window.history.pushState({}, '', to);
  window.scrollTo(0, 0);
  listeners.forEach((fn) => fn());
}

export const currentPath = () => window.location.pathname || '/';

if (typeof window !== 'undefined') {
  window.addEventListener('popstate', () => listeners.forEach((fn) => fn()));
}

// Query params ride the same subscription as the path, so a filter in the URL
// (e.g. /alerts?project=project-3) is shareable and survives a reload.
export const currentSearch = () => window.location.search || '';

export function useSearchParam(name) {
  const [value, setValue] = useState(() => new URLSearchParams(currentSearch()).get(name));
  useEffect(() => {
    const fn = () => setValue(new URLSearchParams(currentSearch()).get(name));
    listeners.add(fn);
    fn();
    return () => listeners.delete(fn);
  }, [name]);
  return value;
}

// The #fragment rides the same subscription (BH-5430: /merge-queue?risk=<repo>#<pr>
// opens one PR's break-risk reasons). pushState fires no hashchange, so a link
// that only moves the fragment is still heard through navigate's listeners.
export const currentHash = () => window.location.hash || '';

export function useHash() {
  const [value, setValue] = useState(() => currentHash());
  useEffect(() => {
    const fn = () => setValue(currentHash());
    listeners.add(fn);
    fn();
    return () => listeners.delete(fn);
  }, []);
  return value;
}

export function useRoute() {
  const [path, setPath] = useState(currentPath());
  useEffect(() => {
    const fn = () => setPath(currentPath());
    listeners.add(fn);
    return () => listeners.delete(fn);
  }, []);
  return path;
}

// `/pr/:project/:number` -> { project, number } or null when it does not match.
export function matchRoute(pattern, path) {
  const p = pattern.split('/').filter(Boolean);
  const s = path.split('/').filter(Boolean);
  if (p.length !== s.length) return null;
  const params = {};
  for (let i = 0; i < p.length; i++) {
    if (p[i].startsWith(':')) params[p[i].slice(1)] = decodeURIComponent(s[i]);
    else if (p[i] !== s[i]) return null;
  }
  return params;
}

// An in-app link: plain left clicks route, everything else (new tab, middle
// click, modifier) stays a real anchor so the browser does its normal thing.
// `onNavigate` runs after a routed click (the side menu's drawer closes on it).
export function Link({ to, class: cls, children, onNavigate, ...rest }) {
  const onClick = useCallback((e) => {
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return;
    e.preventDefault();
    navigate(to);
    if (onNavigate) onNavigate();
  }, [to, onNavigate]);
  return html`<a href=${to} class=${cls} onClick=${onClick} ...${rest}>${children}</a>`;
}
