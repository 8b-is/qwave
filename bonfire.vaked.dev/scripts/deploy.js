/**
 * bonfire — deploy (CLI path)
 * ============================================================================
 * Stages the deployable set via scripts/stage.js (the same pipeline the
 * Pages git integration runs) and uploads dist/ with wrangler. Never deploys
 * the repo root: `wrangler pages deploy` ignores `.assetsignore`, so the
 * staged directory is the only thing that ships.
 * ========================================================================== */

import { spawnSync } from 'node:child_process';

const CWD = new URL('..', import.meta.url).pathname;

await import('./stage.js');

const result = spawnSync('npx', ['wrangler', 'pages', 'deploy', 'dist'], {
  cwd: CWD,
  stdio: 'inherit',
});
process.exit(result.status ?? 1);
