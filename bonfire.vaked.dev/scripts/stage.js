/**
 * bonfire — stage
 * ============================================================================
 * Assembles the deployable set into `dist/` and content-hashes every
 * browser-facing JS/CSS filename, rewriting all references. Used by BOTH
 * deploy paths so they can never disagree:
 *
 *   - the CLI (`scripts/deploy.js`) stages, then runs wrangler on dist/;
 *   - the Pages git integration builds this script and uploads dist/.
 *
 * `wrangler pages deploy` ignores `.assetsignore`, so nothing internal ships
 * from either path: only the entries below reach the edge.
 *
 * ORDER MATTERS: a file is hashed *after* its imports have been rewritten —
 * a source file whose unchanged text now points at a newly-hashed dependency
 * must itself get a new name, or the CDN serves yesterday's bytes under
 * today's URL.
 * ========================================================================== */

import { cpSync, mkdirSync, rmSync, readdirSync, readFileSync, writeFileSync, renameSync } from 'node:fs';
import { createHash } from 'node:crypto';

const CWD = new URL('..', import.meta.url).pathname;
const DIST = `${CWD}dist`;

const DEPLOYABLE = [
  'index.html', 'fire.html', 'ash.html', '404.html',
  'assets', 'shared', 'functions',
  '_headers', '_redirects', 'robots.txt', 'sitemap.xml', 'site.webmanifest', 'favicon.svg',
  'llms.txt', 'AGENTS.md', '.well-known',
];

const PAGES = ['index.html', 'fire.html', 'ash.html', '404.html'];

function hash8(content) {
  return createHash('sha256').update(content).digest('hex').slice(0, 8);
}

function rewriteImports(src, sharedMap, assetMap) {
  for (const [base, h] of Object.entries(sharedMap)) {
    src = src.replaceAll(`from '../../shared/${base}.js'`, `from '../../shared/${h}'`);
  }
  for (const [base, h] of Object.entries(assetMap)) {
    src = src.replaceAll(`from './${base}.js'`, `from './${h}'`);
  }
  return src;
}

/** Content-hash browser-facing assets and point every reference at them. */
function hashAssets() {
  const jsDir = `${DIST}/assets/js`;
  const cssDir = `${DIST}/assets/css`;
  const sharedDir = `${DIST}/shared`;
  const sharedMap = {};
  const assetMap = {};

  // 1. Shared contract code first — the Functions bundler resolves the
  //    original names, so they stay in place; the hashed twins are what the
  //    browser fetches.
  for (const f of readdirSync(sharedDir)) {
    if (!f.endsWith('.js')) continue;
    const base = f.replace(/\.js$/, '');
    const content = readFileSync(`${sharedDir}/${f}`);
    const hashed = `${base}.${hash8(content)}.js`;
    writeFileSync(`${sharedDir}/${hashed}`, content);
    sharedMap[base] = hashed;
  }

  // 2. Page scripts, in dependency order: a file is named only once every
  //    import it references has a final name, so its own hash covers the
  //    rewrite. The page-script graph is acyclic (site/fire-room/ash →
  //    api/fire-canvas → shared), so the fixpoint loop terminates.
  const pending = readdirSync(jsDir).filter((f) => f.endsWith('.js'));
  let guard = pending.length * 2;
  while (pending.length && guard-- > 0) {
    let progress = false;
    for (let i = 0; i < pending.length; i++) {
      const f = pending[i];
      const base = f.replace(/\.js$/, '');
      const original = readFileSync(`${jsDir}/${f}`, 'utf8');
      const rewritten = rewriteImports(original, sharedMap, assetMap);

      // Blocked on an asset whose final name is not known yet.
      const stillWaiting = [...rewritten.matchAll(/from '\.\/([\w-]+)\.js'/g)]
        .some((m) => !assetMap[m[1]]);
      if (stillWaiting) continue;

      const hashed = `${base}.${hash8(rewritten)}.js`;
      writeFileSync(`${jsDir}/${f}`, rewritten);
      renameSync(`${jsDir}/${f}`, `${jsDir}/${hashed}`);
      assetMap[base] = hashed;
      pending.splice(i, 1);
      progress = true;
      break;
    }
    if (!progress) {
      // Cycle or oddball import — ship the file under its original name
      // rather than fail the deploy; the rewrite is idempotent.
      for (const f of pending) {
        const base = f.replace(/\.js$/, '');
        const rewritten = rewriteImports(readFileSync(`${jsDir}/${f}`, 'utf8'), sharedMap, assetMap);
        writeFileSync(`${jsDir}/${f}`, rewritten);
        assetMap[base] = `${base}.js`;
      }
      pending.length = 0;
    }
  }

  // 3. HTML references point at the final names.
  for (const page of PAGES) {
    let src = readFileSync(`${DIST}/${page}`, 'utf8');
    for (const [base, h] of Object.entries(assetMap)) {
      src = src.replaceAll(`/assets/js/${base}.js`, `/assets/js/${h}`);
    }
    writeFileSync(`${DIST}/${page}`, src);
  }

  // 4. The stylesheet (no cross-file rewrites; hash of its shipped bytes).
  for (const f of readdirSync(cssDir)) {
    if (!f.endsWith('.css')) continue;
    const base = f.replace(/\.css$/, '');
    const content = readFileSync(`${cssDir}/${f}`);
    const hashed = `${base}.${hash8(content)}.css`;
    renameSync(`${cssDir}/${f}`, `${cssDir}/${hashed}`);
    for (const page of PAGES) {
      let src = readFileSync(`${DIST}/${page}`, 'utf8');
      src = src.replaceAll(`/assets/css/${base}.css`, `/assets/css/${hashed}`);
      writeFileSync(`${DIST}/${page}`, src);
    }
  }
}

rmSync(DIST, { recursive: true, force: true });
mkdirSync(DIST, { recursive: true });

for (const entry of DEPLOYABLE) {
  cpSync(`${CWD}${entry}`, `${DIST}/${entry}`, { recursive: true });
}

hashAssets();

console.log(`[bonfire] staged ${DEPLOYABLE.length} entries into dist/ (content-hashed)`);
