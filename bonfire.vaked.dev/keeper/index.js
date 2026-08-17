/**
 * bonfire-keeper — the founder-absence cron (spec §3, M5)
 * ============================================================================
 * Cloudflare Pages Functions cannot self-schedule, so the keeper runs as a
 * tiny Workers cron: every hour it POSTs the bonfire keeper endpoint, which
 * applies the 30-day founder-absence rule. The endpoint is idempotent and
 * safe to call early — every transition it makes is already a fact in the
 * lattice — so this worker's only real job is *being regular*.
 *
 * Deploy: `npx wrangler deploy` (from this directory).
 * ========================================================================== */

export default {
  async scheduled(event, env, ctx) {
    const res = await fetch('https://bonfire.vaked.dev/api/keep', { method: 'POST' });
    if (!res.ok) {
      // Workers retries a failed scheduled run automatically; fail loudly so
      // the retry machinery knows this pass did not count.
      throw new Error(`keeper answered ${res.status}: ${(await res.text()).slice(0, 120)}`);
    }
  },
};
