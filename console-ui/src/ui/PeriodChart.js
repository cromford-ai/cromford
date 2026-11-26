// The period bar chart (BH-9304, BH-9120.0): one bar per bucket of
// `series` [{bucket, value}], scaled to the largest value. A bucket with no
// value (null or undefined) is a gap labelled "no data", never a 0 bar. A
// real 0 is a zero-height bar labelled with format(0). Labels go through
// lib/format.js (fmtNum unless the screen hands its own format).

import { html } from '../router.js';
import { fmtNum } from '../lib/format.js';

const BAR = 40;       // viewBox units per bucket
const PLOT = 100;     // viewBox height of the bar area
const TOP = 14;       // room for the value label above a bar
const FOOT = 14;      // room for the bucket label under the bars

export function PeriodChart({ series, bucket, format = fmtNum }) {
  if (!Array.isArray(series) || series.length === 0) {
    return html`<div class="period-chart__empty">no data for this period</div>`;
  }
  const has = (v) => v !== null && v !== undefined && Number.isFinite(Number(v));
  const max = Math.max(0, ...series.filter((s) => has(s.value)).map((s) => Number(s.value)));
  const w = series.length * BAR;
  const h = TOP + PLOT + FOOT;
  return html`
    <svg class="period-chart" role="img" viewBox=${`0 0 ${w} ${h}`} style="width:100%;height:auto"
      aria-label=${`${series.length} ${bucket || 'bucket'} buckets`} preserveAspectRatio="none">
      ${series.map((s, i) => {
        const x = i * BAR;
        const key = String(s.bucket);
        if (!has(s.value)) {
          return html`<g key=${key}>
            <text class="period-chart__value period-chart__gap" data-bucket=${key} x=${x + BAR / 2} y=${TOP + PLOT - 2}
              text-anchor="middle">no data</text>
            <text class="period-chart__bucket" x=${x + BAR / 2} y=${h - 2} text-anchor="middle">${key}</text>
          </g>`;
        }
        const v = Number(s.value);
        const bh = max > 0 ? (v / max) * PLOT : 0;
        return html`<g key=${key}>
          <rect class="period-chart__bar" data-bucket=${key} x=${x + 4} y=${TOP + PLOT - bh} width=${BAR - 8} height=${bh}>
            <title>${`${key}: ${format(v)}`}</title></rect>
          <text class="period-chart__value" data-bucket=${key} x=${x + BAR / 2} y=${TOP + PLOT - bh - 2}
            text-anchor="middle">${format(v)}</text>
          <text class="period-chart__bucket" x=${x + BAR / 2} y=${h - 2} text-anchor="middle">${key}</text>
        </g>`;
      })}
    </svg>`;
}
