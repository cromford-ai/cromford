// The true D1 binding behind the proxies this worker puts on env.DB (BH-9657).
//
// index.js wraps env.DB in the retry proxy (lib/d1-retry.js), and a sampled
// request also gets the statement-stats proxy under it (lib/stmt-stats.js). A
// per-isolate cache keyed on env.DB itself would then keep one entry per
// wrapper, so a sampled request missed every cache that the unsampled requests
// had filled. Each wrapper registers itself here with markWrapper, and every
// such cache keys on rootDb(db).

const innerOf = new WeakMap(); // wrapper proxy -> the object it wraps

// Register `proxy` as a wrapper of `inner`.
export function markWrapper(proxy, inner) {
  innerOf.set(proxy, inner);
  return proxy;
}

// The first object in the chain proxy -> inner that is not a registered
// wrapper; db itself when db is not one. A wrapper is always registered over
// an object that already exists, so the chain has no cycle; the `seen` set
// only stops a bad registration from looping.
export function rootDb(db) {
  const seen = new Set();
  let cur = db;
  while (innerOf.has(cur) && !seen.has(cur)) {
    seen.add(cur);
    cur = innerOf.get(cur);
  }
  return cur;
}
