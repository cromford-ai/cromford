# Provenance of prompts/security-classes/

These files are the attack-class notes of the security lens (BH-7911).
`bin/lib/security-lens-classes.sh` picks at most two of them for a diff and
`bin/lib/rb/review.sh` appends them to the security lens prompt.

- Upstream repo: https://github.com/cloudflare/security-audit-skill
- Upstream sha: `c1c8a8c1471069fb0e188eeaff69b8e8db6564a8` (commit of 2026-09-14, "Clarify guidance and full audit modes")
- Copied on: 2026-10-21
- Licence: MIT (the full text is below)

The files are verbatim copies (`cp`, byte for byte). Never edit them by hand.
To update them, pin a new sha here, copy the files again, and update the table.
The blob sha is `git hash-object <file>`. It equals the upstream blob that
`git ls-tree <upstream sha> skills/security-audit/` lists.
Only the class files are vendored. The audit workflow (`SKILL.md`, `HUNTING.md`,
`RECONNAISSANCE.md`, `VALIDATION-AND-REPORTING.md`, `ATTACK-CLASSES.md`), the
validators and the report schema are not.

| local file | upstream path | bytes | git blob sha |
|---|---|---|---|
| `data-isolation.md` | `skills/security-audit/DATA-ISOLATION-AND-LIFECYCLE.md` | 7798 | `0cba1fa463b62c9b0caba710a201e29c1eecd0ec` |
| `web-auth.md` | `skills/security-audit/WEB-PROTOCOL-AND-AUTH.md` | 12300 | `1a099fa575cf52a61e9a627f91b61015120fa517` |
| `ai-llm.md` | `skills/security-audit/AI-AND-LLM.md` | 10617 | `02ba9039eca4cec811fefc77bce0d7349b379aae` |
| `cloud-deploy.md` | `skills/security-audit/CLOUD-AND-DEPLOYMENT.md` | 8291 | `5569f76c7740744aa3f60aaa89eaefe275f2e6c9` |
| `supply-chain.md` | `skills/security-audit/SUPPLY-CHAIN-AND-RELEASE.md` | 7258 | `bf96aed0803bc07471483ab129dea86759c3e305` |
| `client-side.md` | `skills/security-audit/CLIENT-SIDE.md` | 8594 | `8ba673e9e7e3d02f5518aa0219bcbeec7957531b` |
| `resource-exhaustion.md` | `skills/security-audit/RESOURCE-EXHAUSTION-AND-AVAILABILITY.md` | 7476 | `6cbbd1e2cfa482068c8279c2f7da9db43d3f54b8` |

## Upstream licence (MIT)

```
MIT License

Copyright (c) 2025-2026 Cloudflare, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
