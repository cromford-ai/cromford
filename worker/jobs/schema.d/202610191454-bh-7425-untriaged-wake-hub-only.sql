-- BH-7425 (part of #7397): untriaged-wake stays on the hub. bin/untriaged-wake.sh
-- is one fleet-wide run with no pl_dispatch, so a lane_placement row cannot move
-- it, and its bin/unblocked-children.sh call runs decompose-parent-close.sh
-- --cooled, which shares state/parent-close-<p>.* with the hub wake-loop.sh.
-- docs/notes/2026-10-19-BH-7425-untriaged-wake-hub-only.md has the evidence.
-- No table is created here, so no index and no retention rule apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.untriaged-wake.hub_only','one fleet-wide run, not pl_dispatch per project; its unblocked-children call runs decompose-parent-close --cooled, which shares state/parent-close-<p>.* and reads builds/<p>-* with the hub wake-loop (BH-7425)','BH-7425: why untriaged-wake stays on the hub; delete this row only with a ticket that splits the lane per project and moves the parent-close state off files','seed','2026-10-19T14:54:00Z');
