## Scalable tests (BH-7563)

SCALABLE TESTS (iron law, BH-7563, 2026-10-19). If a test does not test an external service, the test must not call it. External services are auth (Clerk), mail, payments, LLMs, Composio, and any shared, rate-limited or metered service. The PR and merge-queue path must scale to any number of parallel runs and never stop because of a vendor.
1. One seam (adapter file) per vendor.
2. In test mode, the seam returns a local fake: seeded data, 0 network calls, and a throw on an unimplemented method.
3. Tests sign in through a test-only session route: test flag AND non-production AND a secret. A unit test proves 404 in production.
4. A small real-vendor contract suite (about 5 tests per vendor), 1 worker, runs on main and nightly. A PR runs it only when it changes that vendor's adapter or auth files.
5. Each test seeds its own data with unique ids. No order dependence. Parallel runs on one commit must pass.
6. A budget test asserts 0 vendor calls in the PR suite.
7. A vendor error in the contract suite is a vendor failure (skip with a reason plus an alert), never a code failure.
- PLAN must list, per vendor the code touches: the seam, the fake and the contract test.
- REVIEW tags each of these, when this diff adds it, `[BLOCK scalable-tests]`: a new PR-path test that calls a real vendor; a vendor client imported outside its seam; a test sign-in through the real provider outside the contract suite; a test-only route without the production-404 test; tests that share data or depend on order.
