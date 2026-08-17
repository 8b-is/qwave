/**
 * bonfire — local dev launcher
 * ============================================================================
 * `wrangler pages dev` and `wrangler d1 execute --local` persist their local
 * D1 into *different* sqlite files in this wrangler generation, so a bare
 * `npm run dev` after `npm run db:local` would boot an empty lattice. This
 * launcher boots the dev server, waits for it, then applies schema.sql to
 * every local D1 file present — including the one the dev server just
 * created — so `npm run dev` alone is always enough.
 * ========================================================================== */

import { spawn } from 'node:child_process';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const CWD = new URL('..', import.meta.url).pathname;
const D1_DIR = join(CWD, '.wrangler', 'state', 'v3', 'd1', 'miniflare-D1DatabaseObject');
const SCHEMA = readFileSync(join(CWD, 'schema.sql'), 'utf8');

const args = process.argv.slice(2);
const portIdx = args.findIndex((a) => a === '--port' || a === '-p');
const port = portIdx >= 0 && args[portIdx + 1] ? args[portIdx + 1] : '8788';

const child = spawn('npx', [
  'wrangler', 'pages', 'dev', '.', '--d1', 'LATTICE=bonfire-lattice', ...args,
], { cwd: CWD, stdio: 'inherit' });

// Once the dev server answers, apply the schema to every local D1 file —
// the server's own included (its first /api/health probe creates it).
(async () => {
  for (let i = 0; i < 120; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (res.ok) break;
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 250));
  }
  try {
    const files = readdirSync(D1_DIR).filter((f) => f.endsWith('.sqlite'));
    for (const f of files) {
      const db = new DatabaseSync(join(D1_DIR, f));
      db.exec(SCHEMA);
      db.close();
    }
    if (files.length) console.log(`[bonfire] schema.sql applied to ${files.length} local D1 file(s)`);
  } catch { /* no local D1 yet — nothing to apply */ }
})();

process.on('SIGINT', () => child.kill('SIGINT'));
child.on('exit', (code) => process.exit(code ?? 0));
