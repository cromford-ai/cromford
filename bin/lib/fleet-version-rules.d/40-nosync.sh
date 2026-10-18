#!/bin/bash
# bin/lib/fleet-version-rules.d/40-nosync.sh — sourced by fvc_decide
# (bin/lib/fleet-version-decide.sh), never executed.
# owner BH-7191.2: no sync timer reported -> ALERT <box> nosync <detail>.
FVC_RULES+=(fvc_rule_nosync)
fvc_rule_nosync() { return 0; }
