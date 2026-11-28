#!/bin/bash
# bin/lib/mr-red-loop.sh — Mr Red loop-check seam (BH-9532 C0). bin/staff/mr-red.sh
# tick calls mrr_loop_check <fingerprint> <target> <lever> <approach> before a
# lever acts; any answer but `ok` skips that lever. The placeholder answers ok.
# owner: BH-9532.2
mrr_loop_check() { echo ok; }
