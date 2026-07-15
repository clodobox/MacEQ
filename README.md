# MacEQ

A free, open-source, native macOS menu-bar system-wide equalizer built on Apple's
Core Audio process-tap API (macOS 14.4+). No virtual audio driver, no admin
password, volume keys keep working.

## Status: Milestone 3 complete

Feature set:

- 10-band graphic EQ and full parametric EQ (12 Equalizer APO filter types,
  draggable response curve with live spectrum overlay)
- Equalizer APO `config.txt` as the native preset format — AutoEQ profiles
  import directly (paste, file, or text editor)
- Per-output-device profiles that switch automatically
- App exclude list (browser helper processes attributed to their apps)
- Convolution/FIR room correction (partitioned overlap-save; WAV/AIFF impulse
  responses, auto-resampled to the device rate)
- Safety limiter, auto preamp, buffer-size control, launch at login
- Global hotkey: Option+Command+E toggles the EQ from anywhere
- Self-healing: follows default-device and sample-rate changes, zero-buffer
  tap watchdog

Architecture: a **muted global process tap** captures and silences the system
mix, a **private aggregate device** pairs the tap with the real output device,
and one **IOProc** runs convolution -> biquad cascade -> preamp -> limiter and
writes to the output. No virtual driver, no admin password, volume keys work.

### Build and run

Requires macOS 14.4+ and the Swift toolchain (Command Line Tools are enough).

```sh
scripts/build-app.sh
open build/MacEQ.app
```

Grant the system-audio permission when prompted and play music in any app.
Run the tests with `swift run maceq-tests`.

### Development notes

- Ad-hoc signing means macOS re-asks for the audio-capture permission after every
  rebuild. Reset a stuck grant with:
  `tccutil reset SystemAudioCaptureRequests com.jatingrewal.maceq`
- Known platform caveats and their mitigations: intermittent all-zero tap buffers
  after long uptime (zero-buffer watchdog rebuilds the path), level attenuation on
  multi-output devices (compensated in the IOProc), and sample-rate/Bluetooth
  renegotiation (rate listener rebuilds the path).

## Roadmap

- **M0 (done):** muted-tap + private-aggregate passthrough spike.
- **M1 (done):** menu-bar app, 10-band graphic EQ (vDSP biquads), preamp with
  auto mode, bypass, output-device follow.
- **M2 (done):** parametric EQ (12 APO filter types, draggable response curve,
  band table), Equalizer APO `config.txt` as the native preset format, AutoEQ
  import (paste + file), per-device profiles, app exclude list, safety limiter.
- **M3 (done):** spectrum analyzer overlay, latency/CPU display, buffer-size
  control, launch-at-login, convolution/FIR room correction, global bypass
  hotkey; plus hardening: sample-rate follow and zero-buffer tap watchdog.
- **Remaining (planned):** debug-instrumentation cleanup, multi-output
  attenuation compensation, soak tests; Developer ID signing + notarization
  for distribution.
