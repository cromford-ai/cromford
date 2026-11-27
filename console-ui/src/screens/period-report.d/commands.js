// The COMMAND LOG period report (BH-9308, BH-9120.4). BH-9120.4 owns this file.
// totals = commands created in the period by status, series = commands per
// bucket, top rows = the newest
// mc.period.report_top_rows (fallback 20).
import { seriesBucket, logKnob } from '../../lib/log-period.js';

export const report = {
  title: 'COMMAND LOG',
  load: async (api, period, knobs) => {
    const res = await api.periodGet('/api/cockpit/commands',
      { ...period, keep: { totals: 1, series: seriesBucket(period, Date.now()), limit: logKnob(knobs, 'report_top_rows') } });
    return {
      totals: res.totals, series: res.series || [], topRows: res.commands || [],
      columns: ['id', 'type', 'project', 'status', 'created_at'],
      rowHref: (r) => `/history/commands?id=${encodeURIComponent(r.id)}`
    };
  }
};
