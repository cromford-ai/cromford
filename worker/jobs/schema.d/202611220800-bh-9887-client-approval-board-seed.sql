-- ── BH-9887 slice C0: the client approval board switch and its knobs ───────
-- Readers: bin/lib/client-approval.sh (ca_enabled, ca_knob), from the conductor
-- fragment bin/merge-conductor.d/bh-9887-client-approval.sh and from
-- bin/client-approval-request.sh.
-- No table is created here, so no index, RLS or retention rule applies. The
-- marker files these rows govern are pruned by ca_prune (marker_keep_d).
-- client_approval_board.<owner>.<name> = on|off: only `on` asks the repo's
-- product board for the client approval of a head client mode withholds. No
-- row = off. project-3 is the one client-mode repo today (BH-9625), and the
-- ticket sets it on with this change.
-- INSERT OR IGNORE: a re-apply changes nothing and an operator's value stays.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('client_approval_board.example-org.project-3','on','BH-9887: on = ask the project-3 product board for the client approval of a withheld head and comment on the ticket; off or no row = today''s behaviour (bin/lib/client-approval.sh ca_enabled)','seed','2026-11-22T08:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('client_approval_board.retry_max','5','BH-9887: failed approval-request (and ticket comment) tries per PR head before one ALERTS line; code fallback CA_RETRY_MAX_DEFAULT','seed','2026-11-22T08:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('client_approval_board.timeout_s','15','BH-9887: seconds one approval-request POST may take; code fallback CA_TIMEOUT_S_DEFAULT','seed','2026-11-22T08:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('client_approval_board.absent_recheck_s','3600','BH-9887: seconds before a head whose board answered 404 (no route yet) is asked again; code fallback CA_ABSENT_RECHECK_S_DEFAULT','seed','2026-11-22T08:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('client_approval_board.marker_keep_d','90','BH-9887: days a state/client-approval marker file is kept before ca_prune deletes it; code fallback CA_MARKER_KEEP_D_DEFAULT','seed','2026-11-22T08:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('client_approval_board.prune_max','200','BH-9887: marker files ca_prune deletes at most in one run; code fallback CA_PRUNE_MAX_DEFAULT','seed','2026-11-22T08:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('client_approval_board.summary_max_chars','500','BH-9887: characters of the what.txt summary the approval request and the ticket comment carry at most; code fallback CA_SUMMARY_MAX_CHARS_DEFAULT','seed','2026-11-22T08:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('client_approval_board.approver_name_max','80','BH-9887: characters kept of each approver name the board returns; code fallback CA_APPROVER_NAME_MAX_DEFAULT','seed','2026-11-22T08:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('client_approval_board.approvers_max','10','BH-9887: approver names kept and named in the ticket comment at most; code fallback CA_APPROVERS_MAX_DEFAULT','seed','2026-11-22T08:00:00Z');
