// worker/jobs/test/lib/schema-sql.node.js — the composed jobs schema as text,
// for Node (node --test and every shell suite, BH-4987). package.json maps
// `#schema-sql` here under the `default` condition. The text comes from the one
// Node composer, jobs-schema.js, so no schema.sql needs to exist in the tree.
import { jobsSchemaSql } from "./jobs-schema.js";
export default jobsSchemaSql();
