/** Is the lattice bound? The client probes this once to decide whether the
 *  fire it shows is real or local. It also carries the DoD's live counters —
 *  the platform eats its own medicine, and the landing page shows the
 *  numbers the ash sentence talks about. */
import { json, db, usingDevSalt } from './_lib/db.js';

export async function onRequestGet({ env }) {
  const lattice = db(env);
  if (!lattice) return json({ lattice: 'unbound' }, { status: 503 });

  try {
    const stats = await lattice.prepare(`
      SELECT
        (SELECT COUNT(*) FROM fires)    AS fires,
        (SELECT COUNT(*) FROM waves)    AS waves,
        (SELECT COUNT(*) FROM chairs)   AS chairs,
        (SELECT COUNT(*) FROM capsules) AS capsules
    `).first();

    return json({
      lattice: 'bound',
      // Surfaced so a deployment cannot quietly run on the dev salt.
      identity_salt: usingDevSalt(env) ? 'development' : 'configured',
      // Surfaced so an operator can see which of the Custodian's rules are
      // actually in force — rule 3 ships with no vocabulary by default.
      harm_terms: String(env?.HARM_TERMS ?? '').trim() ? 'configured' : 'none',
      stats,
    });
  } catch (err) {
    return json({ lattice: 'error', error: err.message }, { status: 503 });
  }
}
