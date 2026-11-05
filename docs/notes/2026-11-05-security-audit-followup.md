# Security audit follow-up

This PR follows the audit of the audit-remediation revision. It depends on PR #5;
merge that PR first. The request explicitly groups the audit's source fixes into
one secondary PR, including the necessary CI checks, so this change exceeds the
usual small-diff target. It does not merge or deploy either PR.

The audit confirmed one medium issue. Seven other candidates remained
unverified, and its hardening notes included quality observations and operator
policy questions. Defensive fixes below do not retrospectively turn those leads
into confirmed vulnerabilities. Unreviewed/deferred coverage is not a clean bill
of health.

## Findings and candidate dispositions

| Audit item | Source change |
| --- | --- |
| Fleet expansion of `risk_tier.low_globs` | New allowlist entries require the independent human token; narrowing remains available to fleet callers. High/sensitive denylist removals require human authority. Unknown/default risk-policy changes require human authority. Refusals leave signatures and values unchanged. |
| Held staff filing after policy changes | Every retry evaluates current autonomy, cap and NEVER rules. A newly refused recommendation cannot file; augmentation uses current ask mode. |
| Ambient dashboard cookies and origin | Shared Pages middleware requires the exact requesting origin for cookie-authenticated unsafe methods. MCP cookie clients supply that origin. Bearer-only callers retain their explicit credential path. |
| QA sibling private reads | Shared middleware admits only exact GET jobs/flags routes for any request carrying `dashqa`, including one with a forged `dash` alongside it. Existing Worker projections still apply. |
| Human-only native staff changes | Autonomy raises, delegation, promotion and suppression approvals require the separate human token at the Worker. Automatic demotions and ask-first remain available. Pages forwards the token only for a verified Access identity. |
| Fly seed environment in supervisors | Boot runs before tini; the final handoff execs tini after seed removal. The persistent tailscaled process gets an explicitly filtered environment. Early boot termination stops that daemon. |
| Warm clone token and lifecycle | Tracing is disabled before reading the clone token. Clone and package installation use separate image layers; repository lifecycle code does not run in the clone-secret mount. |
| Shared project overlay | The existing code lock is exclusive before a run is claimed and stays held through execution, checkpoint and eviction. Shared-root workers now execute one run at a time. |

## Hardening and quality dispositions

| Audit note | Result |
| --- | --- |
| Fresh-checkout jobs import | Test bootstrap composes context budgets as well as lanes and LLM sites; regression covers the third composer. |
| Floating supply-chain inputs | Public CI actions use verified commit SHAs; the Fly Ubuntu base uses a registry-verified image digest. Full machine bootstrap requires exact Bun, CodeGraph and Playwright pins before installation, using existing bake settings or explicit overrides. Other deploy tools and optional bootstrap add-ons remain owner-managed, as described below. |
| Classification/replay tool access | Staff classification and Archie replay launch with no tools. The Claude no-tools path forces empty strict MCP and setting sources independently of optional profiles. |
| Missing act-time guard | `IRON_LAW_ENFORCE=1` refuses a missing guard/shim or unwritable guard settings before calling a runner. Existing unarmed alert-only behavior is retained and must not be described as sandbox enforcement. |
| Egress capabilities | Enforcement requires the capability-drop tool. Missing mechanisms retain the explicitly documented unenforced fallback rather than claiming isolation. |
| Proxy resources/framing | Raw request body is capped at 1 MiB, headers/body reads have deadlines, active connections are capped, idle streams close, ambiguous lengths/hosts are refused, and HTTP Host is bound to the allowed destination. |
| Restore proof | Missing object metadata or failed proof lookup refuses by default. Manual legacy recovery can explicitly request `--allow-unverified`; mismatches always refuse and automatic standby cannot use that override. |
| Restore archives | Python staging extraction accepts regular files/directories only, uses no-follow directory descriptors and exclusive file creation, and rejects traversal, links, duplicate file entries and excessive extensions. Expanded-byte/member budgets apply to outer and decrypted archives. |
| Private API caching/probe delay | Every Pages API response has `Cache-Control: no-store`. Coordination writes bypass the read-session cache. Read probes retain their documented 60-second maximum cache window. |
| Expired lock renewal | Expiry is checked in the conditional UPDATE; an expired lease returns 404 without changing the row. |
| Closed MCP schemas | Own-property membership replaces inherited membership. Prototype-named unknown arguments are rejected before handlers run. |
| OTP parser work | Candidate lookup uses adjacent indexed keyword spans rather than all pairs; overlap/negation lookup is indexed, and token cleaning avoids an unbounded email-address regex. Existing selection/tie rules and punctuation handling are preserved. |
| Webhook buffering | Malformed signatures are refused before reading a body. All receivers cap actual streamed bytes at 1 MiB before HMAC/JSON processing. |
| Writeback acknowledgment | Copy, deletion, visited merge, log write and log-watermark failures propagate before acknowledgment. Successful earlier rows may still acknowledge their completed prefix. |
| Lane archive expansion | Header validation caps declared expanded content at 128 MiB, 32768 members and 1024-character paths, with bounded extension headers and no sparse entries before extraction. |
| Browser approval binding | URL, captured element and normalized form/control state are checked after approval, together with current payment-page policy. The click uses the captured element handle. A changed operation stops without executing it. |
| Outstanding human answer revocation | Poll rechecks current allowed domains before metadata writes, decryption or answer consumption. Removing a site revokes outstanding answers. |
| Browser cancellation | The agent tracks the separate decision process group and stops it on timeout, termination, finish and decision-process exit. |
| Standby identity | Reports use the canonical fleet name from standby configuration, while backup keys/watermarks retain their bucket ID. |
| Snapshot freshness | Automatic promotion requires both a recent report and a recent snapshot (45 minutes), and rejects future/invalid ages. |
| Alert delivery | Failed Telegram delivery does not suppress the next incident/recovery attempt. Damping changes only after delivery succeeds. |

## Operating requirements and limits

- Configure a dedicated `HUMAN_VERDICT_TOKEN` on both the Jobs Worker and its
  trusted Pages project with the same secret value for that pair; it must differ
  from both fleet and lead tokens. Never distribute the human token to agents.
  Native human approval calls now require `x-human-verdict-token` explicitly.
  A normal dashboard session without verified Access cannot grant human authority.
- Full bootstrap needs exact `bake.bun.version`, `bake.codegraph.version` and
  `bake.playwright.version`, or corresponding `BOOTSTRAP_<TOOL>_VERSION` overrides.
  `--repos-only` remains independent of these installation pins. The pinned
  Playwright CLI installs its matching browser; Bun downloads use release checksums.
- Restore now requires Python 3 and the shipped `bin/restore-archive.py` helper.
  Its defaults are 8 GiB expanded bytes and 100000 members per archive, adjustable
  with `RESTORE_MAX_BYTES` / `RESTORE_MAX_MEMBERS`. Symlink-containing historical
  backups are refused; operators must inspect and migrate them deliberately.
- Proxy/webhook 1 MiB body limits intentionally reject larger requests. HTTP
  duplicate framing is rejected even when duplicate values agree.
- Shared-root worker throughput is serialized for correctness. Separate harness
  roots are required before restoring parallel project execution safely.
- Prompts, sensitivity matching, replay scores and hooks are guidance or scoped
  guards. They do not authenticate a human or provide an OS security boundary.
- Fleet enqueue deliberately authorizes installed bin commands and arbitrary
  argument vectors under shared-fleet trust. This PR does not introduce separate
  executor identities or change the capability-based human-answer nonce design.
- Mutable Wrangler/other deployment installers and optional Semgrep/Vercel bootstrap add-ons
  still need owner-selected, compatibility-tested release pins. Fly's other tools
  already resolve exact bake versions; system package security updates retain
  their existing update policy. Pins need regular reviewed security updates.
- Deployment ingress/Access settings, process visibility/ACLs, production secret
  placement, directory ownership and real machine supervisor behavior were not
  inspected or changed. Image boot behavior still needs a disposable deployment
  check before rollout. Restore live-tree merge races and revocation/tombstone
  semantics remain operator policy, rather than claims of fixed vulnerabilities.

## Validation

All local target execution uses an offline Docker sandbox with an empty
allowlisted environment, read-only source/toolchain/dependencies, scratch-only
writes and explicit CPU, memory, PID, descriptor, file, disk and wall limits.
Only dummy identities and credentials are used; no model/provider, cloud control
plane, production data or production endpoint is involved. New regressions were
checked against pre-fix source (or the narrowly reverted control) before passing
with the fix. Generated target files are discarded.

The follow-up Node regression files are included in public CI. The Tester Army
suite exercises the shared Pages middleware and the real local Worker handlers.
Local browser checks use the already available Chromium over isolated loopback;
the existing built UI is reused because this PR changes no UI source. CI rebuilds
that UI and uses the package's matching Chromium. Local tests do not certify live
Cloudflare/Fly policy or provide a guarantee that the repository has no remaining
security issues.

Observed checks (overlapping suites are listed separately, not summed):

- Tester Army: 12/12 browser and HTTP tests.
- Follow-up/root bootstrap/lock regressions: 62/62, including the 8 proxy and
  9 restore Python regressions invoked by their Node wrappers.
- Policy/staff suites: 140/140. MCP/OTP/review/roadmap batch: 254/254.
- All 276 Pages test files were exercised in batches; two pre-existing skips.
  A roadmap reload race was made deterministic and its entire file passed again.
- Watchdog: 100/100; restore/standby/heartbeat: 276/276; egress: 53 passed,
  seven skipped (nested namespace privileges and unavailable baseline input).
- Runtime/bootstrap Node batch: 28/28; staff heartbeat: 168/168; lane
  manifests/rows/worker: 185/185; Fly seed: 142/142; package-manager bootstrap:
  16/16; no-tools/profile: 59/59; image bake contract: 134/134.
- Targeted real-browser off-list write, redirect and typing checks: 18/18.
- Full-tree gitleaks scanned approximately 101.75 MB and found no leaks.
- Syntax and the identifier guard passed. The only new identifier exemption is
  the exact public Ubuntu manifest digest, with registry provenance.

A monolithic Jobs sweep and browser-write suite exceeded the local resource/wall
budgets and are not reported as passed. Every observed Jobs failure was rerun in
isolation: archive/index volume checks passed 44/44; the Sentry give-up checks
passed 14/14 with the existing dependency mounted; flags/lead/policy regressions
passed 35/35 after fixing a real-clock fixture race. No production archive,
lead-review or Sentry behavior was changed to obtain these results. The complete
repository shell corpus, image build, real age/zstd integration and live
Cloudflare/Fly rollout were not executed. CI retains the full package matrix.
