export default [
  // BH-7934.3: the setup line screen's RETRY and CANCEL RUN, a POST to
  // `onboarding/runs/<id>/retry|cancel` exactly. Both forward the actor only.
  // The create (POST onboarding/runs) is not a row here, and the runner's
  // beat stays 405 from a browser.
  { method: 'POST', path: isActionPath('retry'), body: [] },
  { method: 'POST', path: isActionPath('cancel'), body: [] }
];

// onboarding/runs/<run id>/<verb>. The id is the worker's exact shape, ob_
// and 20 lowercase hex, so `.`, `..` and any other segment cannot match.
function isActionPath(verb) {
  const re = new RegExp(`^onboarding\\/runs\\/ob_[0-9a-f]{20}\\/${verb}$`);
  return (rest) => re.test(rest);
}
