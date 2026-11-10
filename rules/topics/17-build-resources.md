## Build resources (BH-9288)

BUILD RESOURCES (BH-9288, 2026-11-09). An execute session shares one machine with its own checks. TK-3659 ran two vitest suites in the background beside the typecheck, and the typecheck was killed (exit 137).
1. In execute, never background a test suite, a typecheck, a build or an e2e run (`&`, `nohup`, `run_in_background`).
2. Run one heavy check at a time, and wait for it to finish.
3. Before you start the next heavy check, make sure the last one has exited.
4. If a check ends out of memory (exit 137, heap out of memory), stop. Read the cause in `oom-procs.txt` and the stop reason. Do not raise the heap or the machine size first.
- The harness records the processes alive at an out-of-memory exit in `<build-dir>/oom-procs.txt`. It kills the process groups an execute session leaves alive.
