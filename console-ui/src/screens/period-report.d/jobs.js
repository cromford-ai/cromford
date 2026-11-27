// The JOBS period report (BH-9308, BH-9120.4). BH-9120.4 owns this file.
// totals = jobs created in the period by status, series = jobs per bucket,
// top rows = the newest
// mc.period.report_top_rows (fallback 20).
import { seriesBucket, logKnob } from '../../lib/log-period.js';

export const report = {
  title: 'JOBS',
  load: async (api, period, knobs) => {
    const res = await api.periodGet('/api/coord/jobs',
      { ...period, keep: { totals: 1, series: seriesBucket(period, Date.now()), limit: logKnob(knobs, 'report_top_rows') } });
    return {
      totals: res.totals, series: res.series || [], topRows: res.jobs || [],
      columns: ['id', 'project', 'kind', 'status', 'created_at'],
      rowHref: (r) => `/jobs/${encodeURIComponent(r.id)}`
    };
  }
};
