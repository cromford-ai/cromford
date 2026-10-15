#!/bin/bash
# bin/lib/ci-test-value/sources.sh — ctv_fetch_sources <out>: the reads the
# report adds beside the job logs. Owner: BH-6618.4. A no-op seam until then;
# bin/ci-test-value-report.sh calls it before the render.
ctv_fetch_sources() { return 0; }
