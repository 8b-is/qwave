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

## Single-stage volume, PipeWire-Pulse recovery, and routing fixes — 2026-11-23

Root causes observed on `8bsov` (CachyOS, PipeWire `1.6.11`, WirePlumber `0.5.19`):

1. **PipeWire hijacked by `pulseaudio`**: `pulseaudio 17.0+r134+g77d25a1e6-2.1` had
   replaced `pipewire-pulse` on 2026-11-21 as a `pulse-native-provider` dependency of
   `gnome-settings-daemon`. `pulseaudio.service` claimed ALSA cards via `ReserveDevice1`
   on login, leaving PipeWire with zero sinks/sources (`hyprpwcenter` blank, `wpctl`
   volume keys ineffective, `pipewire-alsa` stranded) and locking the `TX-384Khz` USB
   DAC to `Altset 1` (`S16_LE`, `48000 Hz`) while downsampling Phoenix's `s32le 384000 Hz`
   stream via `speex-float-1` with ALSA `POLLOUT` warnings.
2. **Double volume attenuation (unresolved 2026-11-15 silence cause)**: `module-null-sink`
   in PipeWire defaults to `monitor.channel-volumes=true`. Because `phoenix-daemon`
   sets both `phoenix_revelation_sink` and the hardware DAC to the user's volume,
   audio passed through two cubic volume stages. Measured on a silent probe null sink
   (20,000 peak 440 Hz sine): default null sink delivered `19999` at 100%, `1822`
   (`-20.8 dB`) at 45%, and `540` (`-31.4 dB`) at 30% *before* Phoenix DSP and the
   second hardware attenuation stage (`-42.8 dB` net at 45%, `-62.7 dB` net at 30%).
   Passing `monitor.channel-volumes=false` in `sink_properties` delivered `19999`
   at 100%, 45%, and 30%, preserving full 16-bit dynamic range into Phoenix DSP while
   mirroring user volume/mute once onto the hardware DAC.
3. **Periodic `MOVE_SINK_INPUT` error spam and mute desync**: `move_all_sink_inputs_to`
   ignored `current_sink_id`, issuing `pactl move-sink-input` every ~5.4 s even on
   already-routed streams (logging `ERROR command:67 (MOVE_SINK_INPUT) error:3 (Invalid
   argument)` on `PhoeniX_Hardware_Out` because `node.dont-reconnect=true`) and
   unconditionally calling `set-sink-mute <hw> 0`, which unmuted hardware behind the
   user's mute toggle.
4. **Lifecycle hygiene**: `stop_phoenix_daemon` now unloads `phoenix_revelation_sink`'s
   null-sink module cleanly; `run_phoenix_daemon` reloads any legacy sink missing
   `monitor.channel-volumes=false`, waits 60 ms after module load so WirePlumber's
   async `stream-properties` restore settles before syncing volume/mute, and resets
   `PhoeniX_Hardware_Out` stream gain to 100% unmuted on startup.

### Verification receipt — 2026-11-23

Agent: Antigravity (Gemini). Shared family context: version 1. Branch:
`fix/phoenix-pipewire-volume-and-routing` (base `main` @ `8683ac0`).

- Replaced `pulseaudio` with `pipewire-pulse 1:1.6.11-2` (provides
  `pulse-native-provider`, preserving `gnome-settings-daemon`), restarted
  `pipewire`, `pipewire-pulse`, `wireplumber`, and `qwave-ear`.
- Validation: `cargo fmt --check`, 13/13 `qwave-hypr-hud` unit tests (including
  `phoenix_sink_module_parser_detects_unity_monitor_and_owner_module` and
  `phoenix_move_planner_skips_already_routed_streams_and_heals_drift`), 5/5
  `phoenix_sound` library tests, and release build passed.
- Rollback binary:
  `/home/hue/.local/state/qwave/backups/qwave-hypr-hud.before-pipewire-volume-fix-20261123`.
  Installed binary SHA-256:
  `31db79ac9b510ea1c2db11fcf54e0433ad5a4be907654bb64a27c60a76294794`.
- Live verification on PipeWire `1.6.11`:
  - `/proc/asound/card3/stream0`: `Status: Running`, `Altset = 2` (`S24_3LE`,
    24-bit), `Momentary freq = 384000 Hz`.
  - `phoenix_revelation_sink`: `monitor.channel-volumes = "false"`; `PhoeniX_Hardware_Out`:
    `100% / 0.00 dB`, unmuted, `s32le 2ch 384000Hz`.
  - Silent end-to-end probe at 45% volume (input peak `16000` into
    `phoenix_revelation_sink`, DAC muted during probe): `USB Audio Adapter.monitor`
    captured peak `25804` (`95265/96000` nonzero samples).
  - Mute mirror check: `phoenix_revelation_sink` mute `1 -> 0` mirrored to USB DAC
    as `Mute: yes -> Mute: no`.
  - `journalctl --user -u pipewire-pulse` over >6.5 s (past the 5.4 s routing tick):
    zero `ERROR` entries; `pw-top` showed `0` errors across all nodes.
  - Listening confirmation: user confirmed "Much better!!" on live desktop playback.
