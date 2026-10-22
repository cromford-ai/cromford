# bin/jobs-client.d/ — one file per new jobs-client verb (BH-7456)

A new `bin/jobs-client.sh` verb goes in its own file here, never as a new arm in
`bin/jobs-client.sh` (`catalog/list-files.tsv` makes `bin/list-file-lint.sh`
refuse a PR that grows that file without adding a file here). Name the file
`<ticket-key>-<verb>.sh` in lower case, for example `bh-1234-foo-get.sh`. It holds
one or more `#: <verb> <args>` lines at column 0 (they join the usage line after
the in-file entries, in file-name order) and exactly one function,
`jc_verb_<verb>` with each `-` written as `_` (`jc_verb_foo_get`). The client
sources the `*.sh` files here only when it runs directly and no in-file arm takes
the verb, so an in-file verb always wins and library mode never loads them. The
function gets the verb's arguments, and its return code is the script's exit
code; print a trailing newline yourself if the verb needs one. The module
functions (`bin/lib/jobs/*.sh`) are already loaded when it runs.
