// BH-7243.1 owns this file.
// The roadmap ideas calls, spread into `api` (src/api.js). The read and the
// add both go through the coord proxy; the proxy stamps the actor on the add.
export const ideasApi = ({ get, post, coordPath }) => ({
  roadmapIdeas: (project, lane) =>
    get(coordPath(`/api/roadmap/ideas?${new URLSearchParams({ project, ...(lane ? { lane } : {}) })}`)),
  roadmapAddIdea: (body) => post(coordPath('/api/roadmap/ideas'), body)
});
