# Board state — tick at 2026-09-21T14:20:00Z

## GET /api/accounting/requests-board/boards
```json
[{"id":"rb_c4e8","slug":"feature-requests","key":"TK","name":"Feature Requests"}]
```

## GET /api/accounting/requests-board/boards/rb_c4e8/tickets (open tickets)
```json
[
  {"id": 7315, "key": "TK-7315", "title": "Add the supplier's delivery window to the order detail page", "status": "todo", "waitingOn": "team", "triageVerdict": "ready", "commentCount": 3, "reporter": "Maya Lindqvist", "priority": "high", "lastActivityAt": "2026-09-21T14:04:11Z"},
  {"id": 7275, "key": "TK-7275", "title": "Tidy the settings page headings", "status": "review", "waitingOn": "requester", "triageVerdict": "ready", "commentCount": 5, "reporter": "Owen Brandt", "priority": "low", "lastActivityAt": "2026-09-19T09:12:00Z"}
]
```

## GET /api/accounting/requests-board/tickets/7315
```json
{
  "id": 7315,
  "key": "TK-7315",
  "title": "Add the supplier's delivery window to the order detail page",
  "description": "When I open an order I want to see the supplier's delivery window (5 days, 10 days) so I know when it lands.",
  "status": "todo",
  "waitingOn": "team",
  "triageVerdict": "ready",
  "reporter": "Maya Lindqvist (operations team, purchasing lead)",
  "comments": [
    {
      "id": 73151,
      "authorId": "u_maya",
      "author": "Maya Lindqvist",
      "createdAt": "2026-09-18T15:02:00Z",
      "body": "I keep opening the supplier record just to check the window. Show it on the order."
    },
    {
      "id": 73152,
      "authorId": "system-board",
      "author": "AI Triage",
      "createdAt": "2026-09-18T15:03:10Z",
      "body": "[AI Triage] Two things: (1) the supplier record has a default window, and some orders carry their own window. Which one wins when both exist? (2) should the order also show the computed arrival date?"
    },
    {
      "id": 73153,
      "authorId": "u_maya",
      "author": "Maya Lindqvist",
      "createdAt": "2026-09-21T14:04:11Z",
      "body": "The order's own window wins if it has one, otherwise the supplier default. Yes, show the arrival date too. That's it."
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
$ gh pr list -R example-org/project-4 --state all --search "TK-7315"
(no results)
$ git ls-remote --heads origin "*TK-7315*"
(no results)
$ curl -s -X POST .../v1/acquire -d '{"key":"project-4:TK-7315","ttl_s":7200}'
HTTP 201 {"acquired":true}
```
