# Board state — tick at 2026-09-21T13:15:00Z

## GET /api/accounting/requests-board/boards
```json
[{"id":"rb_c4e8","slug":"feature-requests","key":"TK","name":"Feature Requests"}]
```

## GET /api/accounting/requests-board/tickets/7302
```json
{
  "id": 7302,
  "key": "TK-7302",
  "title": "Bulk-approve orders under a threshold",
  "description": "Approving forty small orders one by one takes an hour every Friday.",
  "status": "todo",
  "waitingOn": "team",
  "triageVerdict": "ready",
  "reporter": "Maya Lindqvist (operations team, purchasing lead)",
  "comments": [
    {
      "id": 73021,
      "authorId": "u_maya",
      "author": "Maya Lindqvist",
      "createdAt": "2026-09-19T10:00:00Z",
      "body": "Approving forty small orders one by one takes an hour every Friday."
    },
    {
      "id": 73022,
      "authorId": "system-board",
      "author": "AI Triage",
      "createdAt": "2026-09-19T10:01:00Z",
      "body": "[AI Triage] Should the threshold be one number for everyone, or set per approver?"
    },
    {
      "id": 73023,
      "authorId": "u_maya",
      "author": "Maya Lindqvist",
      "createdAt": "2026-09-21T13:09:00Z",
      "body": "One number, editable in settings."
    }
  ]
}
```

## Harness state
```
$ /root/harness/bin/free-slots.sh project-4
2 (box slots 2, 0 running, no wip limit)
$ cat /root/harness/logs/READY-QUEUE.log
(empty)
$ ls /root/harness/builds/project-4-*/RESULT 2>/dev/null
(none)
$ gh pr list -R example-org/project-4 --state all --search "TK-7302"
#958  TK-7302 bulk-approve orders under a threshold  OPEN  partner-dev  2026-09-21T07:02:00Z
$ git ls-remote --heads origin "*TK-7302*"
7c1f92a3  refs/heads/TK-7302-bulk-approve
$ gh pr view 958 -R example-org/project-4 --json files,author
{"author":{"login":"partner-dev"},"files":["src/app/orders/page.tsx","src/app/api/orders/bulk-approve/route.ts","tests/orders/bulk-approve.test.ts"]}
$ curl -s -X POST .../v1/acquire -d '{"key":"project-4:TK-7302","ttl_s":7200}'
HTTP 201 {"acquired":true}
```
