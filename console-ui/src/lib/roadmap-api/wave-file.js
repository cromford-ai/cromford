// BH-7243.4 owns this file.
// The roadmap wave file calls, spread into `api` (src/api.js). Approve and
// reject go through the coord proxy, which stamps the actor; the issues read
// is the wave's status plus the issues the filing lane opened for it.
export const waveFileApi = ({ get, post, coordPath }) => ({
  roadmapApproveWave: ({ id, project }) =>
    post(coordPath('/api/roadmap/waves/approve'), { id, project, expected_status: 'draft' }),
  roadmapRejectWave: ({ id, project, reason }) =>
    post(coordPath('/api/roadmap/waves/reject'), { id, project, reason }),
  roadmapWaveIssues: (id, project) =>
    get(coordPath(`/api/roadmap/waves/issues?${new URLSearchParams({ id, project })}`))
});
