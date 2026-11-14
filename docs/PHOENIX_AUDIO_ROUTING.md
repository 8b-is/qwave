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
