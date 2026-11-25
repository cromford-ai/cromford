// verdict-current routes — BH-9558: the CURRENT verdict of a set of PRs.
//
// POST /api/verdict/current {prs:[<https://github.com/o/r/pull/N>...]} answers
// the newest verdict_history round per PR url, across every job that carries
// that pr_url (the build job, a review-verdict job), with who decided it
// (`builder`, `lead`, `human`, `risk-tier`) and a state word for the kanban.
// Lead rounds reach verdict_history through routes/verdicts.js
// (lib/verdict-rounds.js recordLeadRound). A url with no round is absent from
// `verdicts`. The reader is the console's kanban Pages Function
// (console-ui/functions/_lib/verdict-overlay.js).
//
// Cap: settings row `verdict.current.max_prs`. Over it, the first `cap` urls
// are answered and `truncated` is true. The bearer check is the route table's.
import { json } from "../lib/http.js";
import { strictInt } from "../lib/core.js";
import { overloadGiveUp } from "./verdict.js";
import { currentVerdicts, VERDICT_CURRENT_MAX_PRS_DEFAULT } from "../lib/verdict-rounds.js";

const PR_URL_RE = /^https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/pull\/[1-9][0-9]*$/;

// The cap: the `verdict.current.max_prs` row when it is a positive integer,
// else VERDICT_CURRENT_MAX_PRS_DEFAULT (the row's documented fallback). An
// unreadable row is the fallback too: the read answers, it never 500s on a knob.
export async function maxPrs(env) {
  try {
    const n = strictInt(await env.DB.prepare("SELECT value FROM settings WHERE key='verdict.current.max_prs'").first("value"));
    return n !== null && n > 0 ? n : VERDICT_CURRENT_MAX_PRS_DEFAULT;
  } catch {
    return VERDICT_CURRENT_MAX_PRS_DEFAULT;
  }
}

export const routes = [
  [
    "POST", "/api/verdict/current",
    async ({ env, t, body }) => overloadGiveUp(env, "POST /api/verdict/current", t, async () => {
      const prs = body && body.prs;
      if (!Array.isArray(prs) || prs.some((p) => typeof p !== "string" || !PR_URL_RE.test(p))) {
        return json(400, { error: "prs must be an array of https://github.com/<owner>/<repo>/pull/<n> urls" });
      }
      const uniq = [...new Set(prs)];
      if (!uniq.length) return json(200, { verdicts: {}, truncated: false, cap: null, as_of: t });
      const cap = await maxPrs(env);
      const asked = uniq.slice(0, cap);
      const verdicts = await currentVerdicts(env, asked);
      return json(200, { verdicts, truncated: uniq.length > cap, cap, as_of: t });
    }),
  ],
];
