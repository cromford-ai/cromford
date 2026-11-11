# env-templates/ — what a box's `env/` should contain

`global.env.example` is **generated** (BH-1178). It is the concatenation, in
filename order, of the topic files in `lanes/`:

```sh
bin/render-env-example.sh --write   # rewrite global.env.example
bin/render-env-example.sh --check   # report drift, repair nothing
```

Documenting a new knob is a new `lanes/<NNN>-<slug>.env.example` and nothing
else. It used to be a paragraph appended to the end of one 541-line file, which
25 of the last 200 merges did — always in the same trailing lines, so two
branches adding two unrelated knobs conflicted over knobs neither had read.

The knob PROSE is not generated from `catalog/lanes.json`, deliberately. The
registry carries a knob's type, default, bounds and a one-line `note`; these
files carry the paragraph that says what the number means, what zero does and
which incident bought the default. Rendering the template from the registry's
notes would replace six paragraphs of operator guidance with six sentences, so
the topic files hold that text verbatim and the registry is not their source.

The directory is called `lanes/` because that is the one spelling
`bin/lib/render-fragments.sh`'s `rf_registry()` and
`guardrails/rendered-file-freshness` already declared for it; the files in it
are per TOPIC, and a topic is usually but not always one lane.

The model credential blocks (OAuth token or Anthropic API key, one of the two)
are in `lanes/030-llm-runners.env.example`. Run
`bin/render-env-example.sh --write`, then copy `global.env.example`.

The other files here are hand-maintained: `project.env.example` (per project),
`github-app.env.example`, `alerts.conf.example` and `accounts.d/`.
