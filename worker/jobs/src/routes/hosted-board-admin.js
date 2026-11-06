// hosted-board-admin routes — BH-8918 (BH-7913.1): board setup, token issue
// and token revoke for the hosted Board API (./hosted-board.js). GATED: these
// sit in ROUTES behind the main bearer, so only HARNESS_SECRET reaches them and
// a hosted-board token never does. The caller is
// `bin/jobs-client.sh hosted-board-token` (bin/jobs-client.d/bh-8918-hosted-board-token.sh).
//
// The plaintext token never reaches this worker: the client sends its sha256
// hex, and token_id is the first 12 hex of that hash. Doc: docs/HOSTED-BOARD.md.
//
// POST /api/hosted-board-admin/setup
//   {project, keyPrefix, boardId?, boardName?, tokenHash, role?, actorName?}
//   role system (default): INSERT OR IGNORE the board, then INSERT the token.
//   role operator: project must be "*"; no board. 200 {project, boardId, tokenId}.
//   400 {error:<field>}; 409 when the hash is already a token.
// POST /api/hosted-board-admin/revoke {project, tokenId}
//   sets revoked_at once. 200 {tokenId, revokedAt}; 404 when absent.

import { json } from "../lib/http.js";
import { PROJECT_RE } from "../lib/hosted-board.js";

const KEY_PREFIX_RE = /^[A-Z][A-Z0-9]{0,9}$/;
const BOARD_ID_RE = /^[a-z0-9][a-z0-9-]{0,62}$/;
const HASH_RE = /^[0-9a-f]{64}$/;
const TOKEN_ID_RE = /^[0-9a-f]{12}$/;
const nameOk = (s) => typeof s === "string" && s.trim() !== "" && !/[\r\n\t]/.test(s);

export const routes = [
  [
    "POST", "/api/hosted-board-admin/setup",
    async ({ env, body, t }) => {
      const role = body.role ?? "system";
      if (role !== "system" && role !== "operator") return json(400, { error: "role" });
      const project = body.project;
      if (role === "operator" ? project !== "*" : !(typeof project === "string" && PROJECT_RE.test(project))) return json(400, { error: "project" });
      if (typeof body.tokenHash !== "string" || !HASH_RE.test(body.tokenHash)) return json(400, { error: "tokenHash" });
      const actorName = body.actorName ?? (role === "operator" ? "Operator" : "System Harness");
      if (!nameOk(actorName)) return json(400, { error: "actorName" });
      const tokenId = body.tokenHash.slice(0, 12);
      const stmts = [];
      let boardId = null;
      if (role === "system") {
        if (typeof body.keyPrefix !== "string" || !KEY_PREFIX_RE.test(body.keyPrefix)) return json(400, { error: "keyPrefix" });
        boardId = body.boardId ?? "product-board";
        if (typeof boardId !== "string" || !BOARD_ID_RE.test(boardId)) return json(400, { error: "boardId" });
        const boardName = body.boardName ?? "Product Board";
        if (!nameOk(boardName)) return json(400, { error: "boardName" });
        stmts.push(env.DB.prepare(`INSERT OR IGNORE INTO hosted_board_boards (project, id, name, key_prefix, created_at)
          VALUES (?1,?2,?3,?4,?5)`).bind(project, boardId, boardName, body.keyPrefix, t));
      }
      stmts.push(env.DB.prepare(`INSERT INTO hosted_board_tokens (token_hash, token_id, project, role, actor_name, created_at)
        VALUES (?1,?2,?3,?4,?5,?6)`).bind(body.tokenHash, tokenId, project, role, actorName, t));
      try {
        await env.DB.batch(stmts);
      } catch (e) {
        if (/UNIQUE constraint failed: hosted_board_tokens/.test(String(e && e.message))) return json(409, { error: "token exists" });
        throw e;
      }
      return json(200, { project, boardId, tokenId });
    },
  ],
  [
    "POST", "/api/hosted-board-admin/revoke",
    async ({ env, body, t }) => {
      const { project, tokenId } = body;
      if (!(project === "*" || (typeof project === "string" && PROJECT_RE.test(project)))) return json(400, { error: "project" });
      if (typeof tokenId !== "string" || tokenId === "") return json(400, { error: "tokenId" });
      if (TOKEN_ID_RE.test(tokenId)) {
        await env.DB.prepare("UPDATE hosted_board_tokens SET revoked_at=?1 WHERE project=?2 AND token_id=?3 AND revoked_at IS NULL")
          .bind(t, project, tokenId).run();
      }
      const row = await env.DB.prepare("SELECT revoked_at FROM hosted_board_tokens WHERE project=?1 AND token_id=?2")
        .bind(project, tokenId).first();
      if (!row) return json(404, { error: "no such token" });
      return json(200, { tokenId, revokedAt: row.revoked_at });
    },
  ],
];
