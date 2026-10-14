# A reused review APPROVE carries its provenance (BH-4134)

Doc: CALL-GUARD

## What changed

Follow-up to BH-3940. A verdict reused from another lane (`review_bought`) used
to merge as if Claude had served it. It is now held for provenance exactly as a
rehydrated record is, and a paid read with no verdict no longer leaves the head
refused for the conductor all day.

- `bin/lib/review-bought.sh`: a hit also sets `RB_SERVED`, the lane that served
  it. That is the `rrverdict` line's 4th field, or a history round's
  `detail.served_by` (else `detail.provenance`). `/api/verdicts` rows carry
  none. Stdout is still `<source>\t<WORD>`. `review_bought_prov` sorts the hit
  into `cleared` (lead or human, the BH-1525 rule), `unknown` (no served word),
  `claude` (`rp_prov_is_claude`) or `fallback`.
- `mc_rereview` writes `rrverdict` as `<head> <WORD> <epoch> <served>`.
- `bin/review-prs.sh` `# >>> review-prs bought`: a `claude` reuse is written
  `served:<word>`. Every other reuse is `served:"reused-unknown"`, and an
  APPROVE beats the `provenance:<project>:<n>:<sha>` akey once, the same as a
  rehydrate. A `fallback` APPROVE is not reused, and the head buys one read
  under `~prov`.

## Trade-offs

- A box `/api/verdicts` row never names a served lane, so every box APPROVE
  review-prs reuses is now held with "Merge yourself when ready". In the
  conductor and the resolver the same case buys a Claude read under `~prov` and
  needs nobody. review-prs does not, as the ticket asked, so the head waits on
  a person if the conductor never visits it.
- Cost: every reused APPROVE with unknown provenance buys one extra `~prov`
  Claude read in the conductor and the resolver, a box row or a legacy
  3-field `rrverdict` line included. It is capped at one per (PR, head, day),
  and the free `review_bought` check runs first. `merge_retry` reads a row with `reused_from` and no `served`
  (written by BH-3940 before this) as `reused-unknown`.
- `# >>> conductor bound-verdict consume`: an `unknown` or `fallback` APPROVE is
  not consumed. It records `rbprov <key> <head>` once, and the spawn passes
  `MC_RR_REASON=prov`. `rrprovdefer` makes a refused `~prov` read say so once.
- `br_rereview`: an `unknown` or `fallback` APPROVE is not reused, and the
  rung buys its read under its own reason.
- `mc_rereview_run`, the call-guard deferral on the plain key
  `review:<slug>#<n>@<head>`: the guard counts a read from its claim, so a
  refusal cannot tell a finished read from one still running. The first such
  refusal records `rrguardfirst <slug>#<n> <head> <epoch>` and does nothing
  else. Only a refusal still standing `MC_RR_GUARD_SETTLE_S` later (default
  3000 s, past review-prs's 2400 s review timeout; a `merge-conductor` lane
  knob) asks `review_bought`. On a clean miss (rc 2) it records
  `rrguardspent <slug>#<n> <head>`, and the next spawn buys the one
  `~noverdict` read. If the read is unreadable (rc 1), nothing is recorded.

A reused BLOCK never merges anything, so it stays reused whatever served it.

## What reads as a fault and is not

- `served:"reused-unknown"` in a review-prs state row is a hold, not an error.
- `rrguardfirst` is the first refusal's clock, nothing more.
- `rrguardspent` in the conductor's attempts means another lane paid for a read
  of this head and got no verdict. The conductor did not fail.
- `rbprov` means a reused APPROVE was refused, and a Claude read is coming
  under `~prov`.

## Trade-offs

- A box `/api/verdicts` row never names a served lane, so every box APPROVE
  review-prs reuses is now held with "Merge yourself when ready". In the
  conductor and the resolver the same case buys a Claude read under `~prov` and
  needs nobody. review-prs does not, as the ticket asked, so the head waits on
  a person if the conductor never visits it.
- Cost: every reused APPROVE with unknown provenance buys one extra `~prov`
  Claude read in the conductor and the resolver, a box row or a legacy
  3-field `rrverdict` line included. It is capped at one per (PR, head, day),
  and the free `review_bought` check runs first.
