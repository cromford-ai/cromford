// worker/jobs/src/lib/schema-sql.workerd.js — the composed jobs schema as text,
// for the deployed worker (BH-4987). package.json maps `#schema-sql` here under
// the `workerd` condition, which wrangler's bundler applies. wrangler.jsonc
// loads `*.sql` as a Text module. bin/harness-sync.sh composes ../../schema.sql
// from schema.d/ before `wrangler deploy` and skips the deploy if it cannot.
import SQL from "../../schema.sql";
export default SQL;
