## Security audit (2026-10-21)

SECURITY AUDIT (2026-10-21). The whole-repo security audit (cloudflare/security-audit-skill) is a scheduled lane with a dollar cap, never a PR step. A PR gets the risky-file security lens only (auth, money, schema, webhooks, agents), and KIND: copy gets none. A reviewer never asks for a full audit on a PR. The lens receives the attack-class notes for the diff's surface; it does not widen its scope beyond the diff.
