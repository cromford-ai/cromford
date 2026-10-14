# Console preview: nothing a build starts outlives it (BH-6073)

Doc: bin/console-preview-deploy.sh, bin/lib/console-preview.sh

## What changed

`cpv_run_unpriv` in `bin/lib/console-preview.sh` runs the two preview build
commands (`npm ci --ignore-scripts`, `npm run build`) of
`bin/console-preview-deploy.sh`. It now does three more things.

1. **Own PID namespace.** The command runs under
   `unshare --pid --fork --kill-child --mount-proc`, then `setpriv` to the
   build user, then `env -i`, then `timeout -k 5 <timeout>`. `timeout` is PID 1
   of the namespace. When PID 1 exits, the command ended or timed out, the
   kernel kills every process left in the namespace. A `setsid`, `nohup` or
   double-fork child of `vite.config.js` cannot leave the namespace. An outer
   `timeout -k 10 <timeout + 30>` is the backstop. For a real build user,
   `setpriv` changes the credentials of the child. The kernel then clears the
   PR_SET_PDEATHSIG that `--kill-child` set. If the outer timeout or
   `lane-reaper.sh` kills `unshare`, the namespace stays alive. The inner
   `timeout -k 5 <timeout>` ends it, at most `<timeout>` + 5 s later. The
   namespace still holds every process. The next run's preflight refuses while
   one of them is alive. In self mode with no `setpriv`, `--kill-child` does
   take PID 1, and the namespace goes with it.
2. **Preflight.** Before `chown -R` gives the build tree to the build user,
   `pgrep -u <uid>` and `pgrep -U <uid>` must find no process. A live process
   of that uid could write the build tree.
3. **Post-check.** After the namespace returns, the same read runs again. A
   live process means the output is not used, so root never copies `dist/`
   while the build user can still write it.

`deploy_one` now reads rc 125 of the `npm run build` step as a box fault, the
same as the `npm ci` step. Before, every non-zero rc of that step was
"vite build failed" and was charged to the head.

Only the function's own checks return 125. The PR head picks the rc of its
build (`"build": "exit 125"`), so a command rc of 125 is returned as 1. That
build is "vite build failed" and is charged to the head. A head cannot stop
the lane with it.

## The rc 125 reasons

`cpv_run_unpriv` returns 125 with one stderr line. The lane logs
`#<n> build not isolated: <that line> at <sha7> — not charged to the head; this
run stops` and raises one `console-preview-box` alert. No head is charged.

- `this box cannot start a PID namespace (unshare --pid refused), so the build cannot be isolated`
- `pgrep is not installed, so the build user cannot be checked`
- `build user '<who>' (uid <uid>) has <k> live process(es) (pid <first 5>) — no build starts while one is alive`
- `build user '<who>' (uid <uid>) still has <k> process(es) after the build (pid <first 5>) — the build output is not used`
- the BH-5909 reasons: not root, no `setpriv`, no such user, uid 0, a tree the user cannot write.

## Why no user-wide kill

The ticket also offered `pkill -KILL -u <user>` after each build. That kills
every process of the user, and other lanes also drop to `nobody` with
`setpriv`. The namespace kills only the build's own processes. Nothing outside
the namespace is ever signalled.

## Operator step

The default build user is `nobody`. Other hub lanes run as `nobody` too, so
the preflight refuses every build while one of them is alive.

1. On the hub, as root, run
   `unshare --pid --fork --kill-child --mount-proc -- true; echo $?`. It must
   print 0. If it does not, do not turn the lane on: every build is refused
   with a box alert.
2. Before you set `CONSOLE_PREVIEW_DEPLOY=1`, create a user that runs nothing
   else.
3. Set `CONSOLE_PREVIEW_BUILD_USER` to that user in `env/global.env`.
4. Turn the lane on for one tick. After the `#<n> preview deployed` line,
   `ps -u <user>` must be empty.

## Test mode

`CONSOLE_PREVIEW_BUILD_USER=self` (only with `HARNESS_TEST_SANDBOX=1`) tries
the PID namespace as root, then inside a user namespace
(`unshare --user --map-root-user`). If neither works, it runs with no
namespace and prints `self mode without a PID namespace (test sandbox)`. It
checks the uid in `CPV_TEST_UID`, and no uid when that is unset. A real build
user is always checked by its own uid.

A build agent sandbox can lack `CAP_SYS_ADMIN`. There the plain
`unshare --pid` fails and the user-namespace form runs. The suite
`tests/console-preview-build-iso.bh-6073-test.sh` prints
`SKIP: no PID namespace on <host>` for C1 and C2 on a host with neither, and
fails instead when `CPV_PIDNS_REQUIRED=1`.
