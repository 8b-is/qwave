/**
 * bonfire — the ash capsule (.m8)
 * ============================================================================
 * Spec §1: "Fires can burn to ash — and that is completion, not failure.
 * The ash is the artifact." §6: `GET /api/ash/:slug` returns the completed
 * fire and its `.m8` capsule.
 *
 * A capsule is a single self-describing file. It is deliberately simple: a
 * magic number, a JSON header you can read with `head -c`, and then the raw
 * 32-byte wave vectors back to back. Someone finding one of these in ten years
 * with no bonfire around should be able to parse it from the spec below.
 *
 *   offset  0   3   magic      "M8\0"
 *   offset  3   1   version    1
 *   offset  4   4   u32 BE     header length in bytes
 *   offset  8   N   header     UTF-8 JSON
 *   offset  8+N     payload    wave_count × 32 bytes, in chronological order
 *
 * The essences themselves live in the header, alongside the fire's own
 * metadata — the capsule is the memory, not a pointer to one.
 * ========================================================================== */

const MAGIC = [0x4d, 0x38, 0x00];   // "M8\0"
export const CAPSULE_VERSION = 1;

/**
 * @param {object} fire   the fires row
 * @param {Array}  waves  wave rows, chronological, each with a wave32 Uint8Array
 * @returns {Uint8Array}
 */
export function buildCapsule(fire, waves) {
  const header = {
    format: 'bonfire-ash-capsule',
    version: CAPSULE_VERSION,
    fire: {
      slug: fire.slug,
      name: fire.name,
      question: fire.question ?? null,
      ash_sentence: fire.ash_sentence,
      state: fire.state,
      created_at: fire.created_at,
      ash_at: fire.ash_at ?? null,
    },
    wave_count: waves.length,
    // The lattice's own reading of what happened here.
    waves: waves.map((w) => ({
      essence: w.essence,
      vad: [w.vad_v, w.vad_a, w.vad_d],
      amplitude: w.amplitude,
      frequency: w.frequency,
      phase_deg: w.phase_deg,
      decay_tau: w.decay_tau,
      decision: w.decision,
      ts: w.ts,
    })),
    note: 'A tűz kialudt. Ami maradt, az a hamu. / The fire went out. What remains is the ash.',
  };

  const headerBytes = new TextEncoder().encode(JSON.stringify(header));
  const payloadSize = waves.length * 32;
  const out = new Uint8Array(8 + headerBytes.length + payloadSize);
  const view = new DataView(out.buffer);

  out.set(MAGIC, 0);
  out[3] = CAPSULE_VERSION;
  view.setUint32(4, headerBytes.length, false);
  out.set(headerBytes, 8);

  let offset = 8 + headerBytes.length;
  for (const w of waves) {
    const bytes = w.wave32 instanceof Uint8Array ? w.wave32 : new Uint8Array(w.wave32 ?? 32);
    out.set(bytes.subarray(0, 32), offset);
    offset += 32;
  }

  return out;
}

/** Read a capsule back. The inverse of buildCapsule. */
export function readCapsule(bytes) {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  if (arr[0] !== MAGIC[0] || arr[1] !== MAGIC[1] || arr[2] !== MAGIC[2]) {
    throw new Error('Nem hamu-kapszula: hibás magic.');
  }
  const version = arr[3];
  const view = new DataView(arr.buffer, arr.byteOffset, arr.byteLength);
  const headerLength = view.getUint32(4, false);
  const header = JSON.parse(new TextDecoder().decode(arr.subarray(8, 8 + headerLength)));

  const vectors = [];
  let offset = 8 + headerLength;
  while (offset + 32 <= arr.length) {
    vectors.push(arr.subarray(offset, offset + 32));
    offset += 32;
  }

  return { version, header, vectors };
}
