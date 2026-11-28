#!/bin/bash
# bin/staff/mr-red-judge.sh — Mr Red outcome-judge seam (BH-9532 C0).
# bin/staff/mr-red.sh tick sources it and calls mrr_judge_tick once at the end
# of a tick, with MRR_INCOMPLETE set to the unread sources (- for none). The
# placeholder judges nothing.
# owner: BH-9532.4
mrr_judge_tick() { return 0; }
