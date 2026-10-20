# BH-7667 replay fixtures

`0338_salesforce_connector.sql.txt` (project-6 #2016) and
`0322_otter_connector.sql.txt` (project-6 #1920) feed the replay case U2 of
`tests/migration-index-lint.bh-7667-test.sh`.

They are RECONSTRUCTIONS, not verbatim copies. The build that wrote them ran
with no GitHub egress, so it could not read `refs/pull/2016/head` or
`refs/pull/1920/head` of example-org/project-6. Each fixture keeps the facts the
ticket and the plan recorded: one plain `CREATE INDEX IF NOT EXISTS … ON event`
(line 61 in 0338, line 54 in 0322), a commented `CREATE INDEX CONCURRENTLY`
example earlier in the file, and ordinary indexes on small tables. A later
change can replace them with the verbatim files; the expected line numbers in
U2 stay the same.

The `.sql.txt` extension keeps every `*.sql` lint in this repo from reading them,
and `.txt` is a text type the share mirror can audit (`bin/share/mapping.py`).
