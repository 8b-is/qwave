# Phoenix desktop audio routing

Phoenix must capture `phoenix_revelation_sink.monitor` and play into the selected physical output. Both streams explicitly set `node.dont-reconnect=true` and `node.dont-fallback=true`. Changing the desktop default output must not move the recorder to the hardware monitor: that creates a feedback path through Phoenix. Capture uses the distinct client name `PhoeniX_Input` so it does not share stream restore state with unrelated `parec` users.

If the selected hardware disappears, restart Phoenix after reconnecting or selecting a new device. These streams deliberately do not fall back to another device. Existing device selection controls restart the daemon.

Volume/mute synchronization and application routing run on one control worker. The audio loop submits a nonblocking tick every 16 blocks; at most one tick can wait. Slow system commands cannot stall PCM processing or spawn accumulating routing workers. Preset reload and telemetry still use local file I/O on the audio thread; this change does not promise hard real-time operation or measured end-to-end latency.

## Verification receipt — 2026-11-14

Task: fix severe delayed workstation audio. Agent: Codex. Shared family context: version 1. No MEM8 persistence interface was used; this file is the durable handoff.

Observed before repair: recorder process 3254 was connected to source 251 (USB hardware monitor), despite its command line requesting Phoenix monitor source 199. Playback also targeted hardware sink 251. The default sink was the USB device. This establishes an unintended feedback connection; perceptual delay was reported by the user, not measured by the agent.

Corrected the live route, built and installed the updated daemon, and restarted it. After restart, `PhoeniX_Input` captures source 199 and `PhoeniX_Hardware_Out` plays into sink 251. Changed the default sink to USB for one second and restored Phoenix: both stream connections remained unchanged. This verifies protection against default-output changes with the installed WirePlumber policy.

Validation: eight HUD unit tests and five Phoenix sound tests passed; release build, formatting and diff checks passed. Listening confirmation remains with the user. The existing automatic hardware rate selection chose 384000 Hz on restart.

Local rollback binary: `/home/hue/.local/state/qwave/backups/qwave-hypr-hud.before-audio-delay-fix-20261114`. Installed binary: `/home/hue/.local/bin/qwave-hypr-hud`. Stop Phoenix before replacing the executable, then start it again using `phoenix-toggle stop` and `phoenix-toggle start`.

## Bounded capture backlog — 2026-11-15

The capture pipe is now drained by a dedicated reader. A mutex/condition-variable
mailbox retains one complete 4096-byte stereo block (1024 frames, exactly 64/3 ms
at 48000 Hz). When DSP or playback falls behind, new capture replaces the pending
block. This prevents playback backpressure from stopping capture reads and
accumulating stale audio upstream. The reader, mailbox, and consumer each hold
at most one input block; no per-block thread or growing queue is created.
Interrupted and short reads are assembled into complete blocks; partial final
blocks are discarded, and EOF wakes the consumer. Normal loop termination kills
and reaps the audio children and joins the capture worker.

Overload can therefore produce skipped audio instead of an increasingly delayed
replay. This is not clock-drift resampling or a guarantee of total device latency:
external PipeWire buffers and blocking playback writes still exist, and a stalled
secondary device can still interrupt primary playback. The pending application
capture backlog remains bounded in that case.

Receipt: Codex, shared family context version 1, based on local routing fix
`847fea6` and upstream main `1fe6ba2`. `git pull --ff-only origin main` reported
already up to date. Preserved the existing routing fix for publication alongside
this change, as requested. Recalled the previous repair from this document;
no MEM8 recall/write interface was available, so this document is the handoff.

Validation: 11 HUD tests and 98 Rust library tests passed, including a synthetic
8 MiB capture with no consumer, short/interrupted reads, partial EOF, and consumer
wake-up. Release build, source formatting, and diff whitespace checks passed.
Installed the release binary at `/home/hue/.local/bin/qwave-hypr-hud`, retaining
rollback at `/home/hue/.local/state/qwave/backups/qwave-hypr-hud.before-buffer-fix-20261115`.
Restarted only Phoenix and its own children, preserving the separate monitor
recorder. The running executable's SHA-256 matches the release artifact.
Live smoke check: capture source 199 at s16le/48000 Hz and playback sink 251 at
s32le/384000 Hz. Four RSS samples over 30 seconds: daemon 3592–3600 KiB,
recorder 5672 KiB, playback 5712 KiB. This short check is not a long-run memory
or end-to-end audio-latency measurement; listening confirmation remains open.

### Follow-up: audible playback failed after deployment

The user reported no sound after the above deployment. Phoenix was alive, its
telemetry contained nonzero input, Spotify was routed to virtual sink 199, and
Phoenix output targeted USB sink 251. Both sinks were unmuted at 45%; the desktop
default had changed to HDMI. These observations did not establish audible output.

Stopped only Phoenix and its two child processes, set USB as the desktop default,
and moved Spotify directly to USB. The user confirmed: "Sound now". Leave Phoenix
bypassed for reliable listening. The bounded capture change remains on main and
installed, but its live audio result is NOT validated. The silence's precise cause
remains unresolved; investigate processing/output and the two successive volume
stages before re-enabling Phoenix. Do not treat the earlier short RSS/routing
smoke test as proof of working audio.
