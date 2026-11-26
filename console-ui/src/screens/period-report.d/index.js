// The period report seams (BH-9304, BH-9120.0). One file per screen, so the
// four sibling tickets never edit the same file: a sibling fills ONLY its own
// seam file and never edits this index.
//
// A seam file exports `report`: null until its owner fills it, then
//   {
//     title: 'COSTS',                       // the report's name on the page
//     load: (api, period) => Promise<{
//       totals,    // {<label>: number} for the whole period
//       series,    // [{bucket, value}] for PeriodChart; value null = no data
//       topRows,   // [{...}] the rows the report lists
//       columns    // [name] the columns of topRows, in order (also the CSV header)
//     }>
//   }
// `period` is {from, to, bucket, compare} (src/lib/period.js). `load` reads
// through api.periodGet(path, period).
//
// Owners: costs BH-9120.1; outcomes, dora BH-9120.2; ci, utilization
// BH-9120.3; jobs, lanes, history, commands BH-9120.4. Nothing reads REPORTS
// yet; BH-9120.1 adds the page.

import { report as costs } from './costs.js';
import { report as outcomes } from './outcomes.js';
import { report as dora } from './dora.js';
import { report as ci } from './ci.js';
import { report as utilization } from './utilization.js';
import { report as jobs } from './jobs.js';
import { report as lanes } from './lanes.js';
import { report as history } from './history.js';
import { report as commands } from './commands.js';

export const REPORTS = { costs, outcomes, dora, ci, utilization, jobs, lanes, history, commands };
