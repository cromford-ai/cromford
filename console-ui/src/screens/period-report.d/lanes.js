// The LANES period report (BH-9308, BH-9120.4). BH-9120.4 owns this file.
// totals = lane runs enqueued in the period by status (failed = done with a
// non-zero rc), series = runs per bucket, top rows = the newest
// mc.period.report_top_rows (fallback 20).
import { seriesBucket, logKnob } from '../../lib/log-period.js';

export const report = {
  title: 'LANES',
  load: async (api, period, knobs) => {
    const res = await api.periodGet('/api/coord/lane-runs',
      { ...period, keep: { totals: 1, series: seriesBucket(period, Date.now()), limit: logKnob(knobs, 'report_top_rows') } });
    return {
      totals: res.totals, series: res.series || [], topRows: res.runs || [],
      columns: ['id', 'lane', 'project', 'status', 'enqueued_at'],
      rowHref: (r) => `/lane-runs/run/${encodeURIComponent(r.id)}`
    };
  }
};
