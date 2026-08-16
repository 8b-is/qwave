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
    });
  } catch (err) {
    return json({ lattice: 'error', error: err.message }, { status: 503 });
  }
}
