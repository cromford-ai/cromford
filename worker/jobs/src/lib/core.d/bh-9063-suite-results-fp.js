// core.d/bh-9063-suite-results-fp.js — BH-9063 (C0): the index of the suite
// ledger's lookup under image trust (lib/suite-trust.js). That lookup matches
// (repo, suite, fingerprint) in every ctx and class, so idx_suite_results_key
// (repo, ctx, suite, fingerprint) only serves its repo prefix. This index
// serves the hit read, its NOT EXISTS fail probe and the reds read
// (routes/suite-results.js lookupSql/redsSql with trust "image"). It lives here,
// not in schema.d, because test/suite-results-schema.bh-5366.test.js pins the
// schema's index list for this table; the lookup route runs ensureColumns.
export const ADDED_INDEXES = {
  suite_results: ["CREATE INDEX IF NOT EXISTS idx_suite_results_fp ON suite_results(repo, suite, fingerprint)"],
};
