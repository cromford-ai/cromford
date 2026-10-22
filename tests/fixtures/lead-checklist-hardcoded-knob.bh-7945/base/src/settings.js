// settingInt(key, fallback) — one integer row from the settings table.
// The fallback is the documented code default when the row is absent.
import { db } from './db.js';

export async function settingInt(key, fallback) {
  const row = await db.settings.findUnique({ where: { key } });
  const n = Number.parseInt(row?.value ?? '', 10);
  return Number.isFinite(n) ? n : fallback;
}
