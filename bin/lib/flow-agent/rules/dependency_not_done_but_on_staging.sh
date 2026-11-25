#!/bin/bash
# bin/lib/flow-agent/rules/dependency_not_done_but_on_staging.sh — flow_rule_dependency_not_done_but_on_staging <record-file>:
# rc 0 match, 1 no match, 2 an input is unread. Placeholder: no match.
# owner: BH-9924.6 (#9957)
flow_rule_dependency_not_done_but_on_staging() { return 1; }
