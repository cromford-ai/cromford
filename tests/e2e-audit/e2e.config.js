import { web } from '@e2e-dev/web';
export default {
  tests: 'tests/**/*.e2e.js',
  workers: 1,
  retries: 0,
  timeout: 30000,
  targets: [{ name: 'local-audit', engine: web(), app: {
    url: 'http://127.0.0.1:0',
    command: { executable: process.execPath, args: ['server.mjs', '{port}'] }
  } }],
  output: process.env.E2E_AUDIT_OUTPUT || '.e2e'
};
