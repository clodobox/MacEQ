# MacEQ

A free, open-source, native macOS menu-bar system-wide equalizer built on Apple's
Core Audio process-tap API (macOS 14.4+). No virtual audio driver, no admin
password, volume keys keep working.

## Status: Milestone 0 — audio-path spike

Current build proves the core architecture with a straight passthrough (no EQ yet):

1. A **muted global process tap** captures the entire system mix and silences the
   original stream.
2. A **private aggregate device** wraps the tap plus the real default output device.
3. A single **IOProc** on the aggregate reads the tapped mix and writes it back to
   the output device unmodified.

### Build and run

Requires macOS 14.4+ and the Swift toolchain (Command Line Tools are enough).

```sh
scripts/build-app.sh
open build/MacEQ.app
```

Click **Start passthrough**, grant the system-audio permission when prompted, and
play music in any app.

### Milestone 0 exit criteria

- [ ] System audio plays through the passthrough unmodified.
- [ ] Original stream is silenced — audio is heard exactly once, not doubled.
- [ ] No glitches, dropouts, or pitch artifacts.
- [ ] Purple recording indicator appears in the menu bar (expected, unavoidable).
- [ ] Peak/RMS meters move with the audio (tap delivers real samples, not zeros).
- [ ] Per-callback latency logged (IO buffer frames / sample rate).

### Development notes

- Ad-hoc signing means macOS re-asks for the audio-capture permission after every
  rebuild. Reset a stuck grant with:
  `tccutil reset SystemAudioCaptureRequests com.jatingrewal.maceq`
- Known platform caveats being designed around: intermittent all-zero tap buffers
  after long uptime (needs teardown/rebuild recovery), level attenuation on
  multi-output interfaces, and sample-rate/Bluetooth renegotiation. See the PRD.

## Roadmap

- **M0 (done):** muted-tap + private-aggregate passthrough spike.
- **M1 (done):** menu-bar app, 10-band graphic EQ (vDSP biquads), preamp with
  auto mode, bypass, output-device follow.
- **M2 (done):** parametric EQ (12 APO filter types, draggable response curve,
  band table), Equalizer APO `config.txt` as the native preset format, AutoEQ
  import (paste + file), per-device profiles, app exclude list, safety limiter.
- **M3 (in progress):** spectrum analyzer overlay (done), latency/CPU display
  (done), buffer-size control (done), launch-at-login (done); remaining:
  convolution/FIR room correction, global hotkeys.
- **Hardening (planned):** zero-buffer tap watchdog, multi-output attenuation
  compensation, soak tests; Developer ID signing + notarization for distribution.
