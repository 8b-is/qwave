/** Is the lattice bound? The client probes this once to decide whether the
 *  fire it shows is real or local. */
import { json, db, usingDevSalt } from './_lib/db.js';

export async function onRequestGet({ env }) {
  const lattice = db(env);
  if (!lattice) return json({ lattice: 'unbound' }, { status: 503 });

  try {
    await lattice.prepare('SELECT 1').first();
    return json({
      lattice: 'bound',
      // Surfaced so a deployment cannot quietly run on the dev salt.
      identity_salt: usingDevSalt(env) ? 'development' : 'configured',
      // Surfaced so an operator can see which of the Custodian's rules are
      // actually in force — rule 3 ships with no vocabulary by default.
      harm_terms: String(env?.HARM_TERMS ?? '').trim() ? 'configured' : 'none',
    });
  } catch (err) {
    return json({ lattice: 'error', error: err.message }, { status: 503 });
  }
}
