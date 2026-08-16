-- ===========================================================================
-- bonfire — the lattice (D1)
-- Spec §5. Table and column names follow the spec exactly; indexes and the
-- two CHECK constraints are added because the rules they encode are the
-- product, and a rule that lives only in application code is a rule that
-- eventually stops being true.
-- ===========================================================================

PRAGMA foreign_keys = ON;

-- --- fires -----------------------------------------------------------------
-- A fire declares its ash at creation. No ash sentence → no fire (§2 pillar 1),
-- enforced here as well as in the API and the UI.
CREATE TABLE IF NOT EXISTS fires (
  id            TEXT PRIMARY KEY,
  slug          TEXT UNIQUE NOT NULL,
  name          TEXT NOT NULL,
  question      TEXT,
  ash_sentence  TEXT NOT NULL CHECK (length(trim(ash_sentence)) >= 12),
  founder_hash  TEXT,
  pulse         TEXT DEFAULT 'none' CHECK (pulse IN ('daily', 'weekly', 'none')),
  state         TEXT DEFAULT 'EMBER' CHECK (state IN ('EMBER', 'PARÁZS', 'HAMU')),
  created_at    INTEGER NOT NULL,
  ash_at        INTEGER
);

CREATE INDEX IF NOT EXISTS idx_fires_state   ON fires (state, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_fires_founder ON fires (founder_hash);

-- --- waves -----------------------------------------------------------------
-- One ember = one wave. `essence` is the text as written; `wave32` is the
-- 32-byte vector (see shared/wave.js for the byte layout).
--
-- NOTE: `phase_deg` is INTEGER per the spec. Full precision lives in the
-- centidegree field inside wave32; this column is the queryable rounding.
CREATE TABLE IF NOT EXISTS waves (
  id          TEXT PRIMARY KEY,
  fire_id     TEXT NOT NULL REFERENCES fires (id) ON DELETE CASCADE,
  essence     TEXT NOT NULL,
  author_hash TEXT NOT NULL,
  wave32      BLOB NOT NULL,
  vad_v       INTEGER NOT NULL,
  vad_a       INTEGER NOT NULL,
  vad_d       INTEGER NOT NULL,
  amplitude   REAL NOT NULL,
  frequency   REAL NOT NULL,
  phase_deg   INTEGER NOT NULL,
  decay_tau   INTEGER NOT NULL,
  decision    TEXT NOT NULL CHECK (decision IN ('STORE', 'REINFORCE', 'TEMPORARY', 'DROP')),
  ts          INTEGER NOT NULL,
  -- Denormalised hex of wave32[0..16]. Duplicate detection is the hottest
  -- path the Custodian walks (§7 rule 1); it should not have to decode blobs.
  fingerprint TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_waves_fire        ON waves (fire_id, ts DESC);
CREATE INDEX IF NOT EXISTS idx_waves_fingerprint ON waves (fire_id, fingerprint);
CREATE INDEX IF NOT EXISTS idx_waves_author      ON waves (fire_id, author_hash);
CREATE INDEX IF NOT EXISTS idx_waves_frequency   ON waves (frequency);

-- --- chairs ----------------------------------------------------------------
-- Anonymous seats. `name_hash` is one-way and salted per deployment: there is
-- no path from this table back to a person (§7 rule 4).
CREATE TABLE IF NOT EXISTS chairs (
  id        TEXT PRIMARY KEY,
  fire_id   TEXT NOT NULL REFERENCES fires (id) ON DELETE CASCADE,
  name_hash TEXT NOT NULL,
  joined_at INTEGER NOT NULL,
  last_seen INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_chairs_seat ON chairs (fire_id, name_hash);
CREATE INDEX IF NOT EXISTS idx_chairs_seen        ON chairs (fire_id, last_seen DESC);

-- --- custodian_log ---------------------------------------------------------
-- Every intervention is written down. The Custodian is auditable by design:
-- "guard, don't direct" is only checkable if the guarding leaves a trace.
CREATE TABLE IF NOT EXISTS custodian_log (
  id      TEXT PRIMARY KEY,
  wave_id TEXT,
  action  TEXT NOT NULL,
  reason  TEXT NOT NULL,
  ts      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_custodian_ts ON custodian_log (ts DESC);

-- --- capsules --------------------------------------------------------------
-- The artifact of a completed fire. `m8` is the exported ash capsule.
CREATE TABLE IF NOT EXISTS capsules (
  id          TEXT PRIMARY KEY,
  fire_id     TEXT NOT NULL REFERENCES fires (id) ON DELETE CASCADE,
  m8          BLOB NOT NULL,
  exported_at INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_capsules_fire ON capsules (fire_id);
