#!/bin/bash
# bin/lib/ci-test-value/model.sh — ctv_model_pass <occurrences.tsv>: the model
# pass over the rows the rules left undecided. Owner: BH-6618.3. A no-op seam
# until then; ctv_classify_all calls it unless CTV_NO_MODEL=1 (--no-model).
ctv_model_pass() { return 0; }
