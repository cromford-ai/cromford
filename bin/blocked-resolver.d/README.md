# bin/blocked-resolver.d/ — optional resolver code, one file each (BH-7450)

New optional code for `bin/blocked-resolver.sh` goes here as its own file,
`<ticket-key>-<name>.sh` in lower case (for example `bh-7612-foo-rung.sh`;
the name matches `^[a-z]+-[0-9]+(\.[0-9]+)?-[a-z0-9][a-z0-9-]*\.sh$`). Do not
add one more word to `BR_OPT_MODULES` or one more
`[ -r "$H/bin/lib/<x>.sh" ] && . ...` line to the driver:
`bin/list-file-lint.sh` refuses a PR that grows the driver and adds no file
here (`catalog/list-files.tsv`).

A fragment is a sourced bash file. It defines functions only. It must not
define a name that the driver, a `bin/lib/br/*.sh` module, a
`bin/lib/br/opt/*.sh` module or a lib the driver sources defines, and two
fragments must not define the same name. It must never `exit`.

The driver sources every regular `*.sh` file in this directory once, in
`LC_ALL=C` name order, in the `# blocked-resolver.d (BH-7450)` block. That
block is directly after the optional-module loop (`BR_OPT_MODULES`) and before
`# THE DISPATCHER STOPS HERE`, so `say`, `LOG` and every module are already
loaded. Other files (this README, `*.sh.bak`, subdirectories) are not sourced.

The rules are the optional loop's rules (fail-open). A fragment that does not
parse (`bash -n`) is skipped with one `say` line. A fragment whose source
returns non-zero gets one `say` line with its rc, and the tick goes on.
`BR_OPT_OFF` skips a fragment by its file name without `.sh` (a whole comma
item, for example `BR_OPT_OFF=bh-7612-foo-rung`).

A fragment only defines things. The driver still needs a call site, one line:
`command -v br_x >/dev/null 2>&1 && br_x ...`.
`tests/blocked-resolver-frags.bh-7450-test.sh` checks the name format,
`bash -n` and the name rules over every fragment in this directory.
