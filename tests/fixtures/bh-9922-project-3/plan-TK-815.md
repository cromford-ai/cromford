# Plan — TK-815: recordings list shows the duration

## Files to touch

- `prisma/schema.prisma` — add `durationSec Int?` to model Recording.
- `src/app/backstage/recordings/page.tsx` — show the duration column.

## Tasks

Add the field to the Recording model and a column to the list.
