#!/bin/bash
# bin/lib/fleet-version-rules.d/10-role.sh — sourced by fvc_decide
# (bin/lib/fleet-version-decide.sh), never executed.
# owner BH-7191.1: gate-only / retired -> SKIP <box> role=<r>, return 2
# (first in name order, so its SKIP stops the later rules for that box).
FVC_RULES+=(fvc_rule_role)
fvc_rule_role() { return 0; }
