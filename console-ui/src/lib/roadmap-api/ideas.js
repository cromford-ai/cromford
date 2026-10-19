// BH-7243.1 owns this file.
// The roadmap ideas calls, spread into `api` (src/api.js). The read and the
// add both go through the coord proxy; the proxy stamps the actor on the add.
// The move and the edit are a CAS on expected_version: a 409 error carries
// the stored idea in err.body.idea (src/api.js request()).
export const ideasApi = ({ get, post, coordPath }) => ({
  roadmapIdeas: (project, lane) =>
    get(coordPath(`/api/roadmap/ideas?${new URLSearchParams({ project, ...(lane ? { lane } : {}) })}`)),
  roadmapAddIdea: (body) => post(coordPath('/api/roadmap/ideas'), body),
  roadmapIdea: (project, id) =>
    get(coordPath(`/api/roadmap/ideas/${encodeURIComponent(id)}?${new URLSearchParams({ project })}`)),
  roadmapSummary: () => get(coordPath('/api/roadmap/summary')),
  roadmapMoveIdea: (body) => post(coordPath('/api/roadmap/ideas/move'), body),
  roadmapEditIdea: (body) => post(coordPath('/api/roadmap/ideas/edit'), body)
});
