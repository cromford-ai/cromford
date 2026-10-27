// BH-7243.2 owns this file.
// The roadmap board calls, spread into `api` (src/api.js). The read is ONE
// request (one D1 batch of 4 statements on the worker). The four writes go
// through the coord proxy, which stamps the actor. A decide is a CAS on
// status: a 409 error carries the stored row in err.body.decision. The board's
// drag and MOVE use api.roadmapMoveIdea (lib/roadmap-api/ideas.js).
export const boardApi = ({ get, post, coordPath }) => ({
  roadmapBoard: (project) => get(coordPath(`/api/roadmap/board?${new URLSearchParams({ project })}`)),
  roadmapLink: (body) => post(coordPath('/api/roadmap/links'), body),
  roadmapUnlink: (body) => post(coordPath('/api/roadmap/links/remove'), body),
  roadmapAddDecision: (body) => post(coordPath('/api/roadmap/decisions'), body),
  roadmapDecide: (body) => post(coordPath('/api/roadmap/decisions/decide'), body)
});
