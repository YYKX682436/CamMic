# USB no-code handshake feasibility probe

Status for 2026-10-26: XR / iOS 14.3 physical USB loopback access, no-code TLS-PSK + HELLO / READY + real PCM, Wi-Fi isolation, key rotation/rejection, and unplug silence passed. This remains a Debug-only feasibility probe with no strict application-level Mac identity. See the [physical record](validation/USB-XR-iOS14.3-2026-10-26.md).

## Host and device evidence

- `NWParameters.requiredLocalEndpoint` selects a specific local IP address and port for listeners. [Apple's API reference](https://developer.apple.com/documentation/network/nwparameters/requiredlocalendpoint) lists it as available since iOS 12, so it is in the iOS 14.3 API surface. This is an API availability check, not proof of the iOS 14.3 runtime behavior.
- If this listener does not behave correctly on the XR, keep the boundary at IPv4 loopback and evaluate a BSD socket listener explicitly bound to `INADDR_LOOPBACK`, paired with a separately reviewed TLS-PSK adapter that preserves the current framing. Do not broaden the listener to all interfaces as a workaround.
- The attached device was read through USBMux as an iPhone XR (`iPhone11,8`) on iOS 14.3. Its UDID is intentionally not recorded in this repository.
- On the first XR attempt, CamMic failed before capture startup. A USB-attached `idevicesyslog` trace recorded `Local endpoint has port set, cannot override to 50890: 127.0.0.1:50890` from `nw_listener_create_with_port`. The TLS listener parameters already pinned the local loopback address and port, while the code also passed that port to `NWListener(using:on:)`; iOS 14.3 rejected this duplicate port selection. The probe now uses `NWListener(using:)` for both pinned endpoints, leaving the endpoint as the single source of the bind address and port. The corrected IPA subsequently passed the XR checks below.
- The updated `scripts/run-iproxy-usb.sh` was started for that paired device. `lsof` showed `iproxy` listening on `127.0.0.1:50888`, `127.0.0.1:50889`, and `127.0.0.1:50890`; the process was then stopped. This verifies the Mac-side proxy bind and USBMux device selection only.
- The user installed the corrected Debug IPA through TrollStore. Mac app metrics, the standalone protocol validator, QuickTime with CamMic explicitly selected, a CoreAudio input reader, and actual USB unplug were used together. Physical evidence is recorded separately from simulator and CI results.

## Test-only implementation boundary

The Debug-only probe has two device-side listeners: a plaintext init channel on `50889` and the existing TLS-PSK/CamMic protocol on `50890`. Both require local endpoint `127.0.0.1`. The init listener starts only after the user explicitly starts microphone capture and `AVAudioEngine.start()` succeeds. It handles at most eight one-shot requests per capture run. The Mac test button connects only to `127.0.0.1`; it does not accept a network address or retry over Wi-Fi.

Each capture run creates a 32-byte session key with `SecRandomCopyBytes`. Stop cancels both listeners and their active init connections, clears the key reference, and tears down the audio connection. A new run generates a different key. TLS-PSK uses the existing TLS 1.2 and CamMic HELLO / READY / PCM / ACK implementation. Release builds omit the USB listener, client, and UI entry points. The USB Mac client treats `.waiting` as terminal, since real TLS rejections can arrive in that state; it cancels, clears audio, and does not retry or fall back to Wi-Fi.

USBMux's paired-device trust is a system-level gate for the forwarded connection. The iOS app sees only its loopback peer and cannot distinguish the trusted Mac's CamMic process from another local process. The init response exposes the current key in plaintext to any client that can reach the loopback channel. This proves a no-pairing-code USB path under the trusted-host assumption; it does **not** establish strict application-level Mac identity. A production design needs first-use confirmation and a pinned Mac public key, then challenge-response and encryption of each session key to that key.

For a controlled personal setup where the trusted USB host is the security boundary, the public-key approval flow is not required to demonstrate this transport. For a production USB feature, it is needed if CamMic must distinguish its Mac app from another process on a paired Mac. The work is moderate rather than a transport rewrite: persistent Mac key material in Keychain, phone-side pinned-key storage and revocation, a first-use approval/fingerprint screen, signed nonce exchange, encryption of the per-run key, and lifecycle tests for reset/reinstall and stale requests. The public-key trust decision should happen before a Release USB entry point is added.

## Repeatable XR acceptance

1. Download `CamMic-USBProbe-Debug-iOS14-unsigned.ipa` and `CamMic-USBProbe-Debug-macOS-arm64.zip` from the same successful GitHub Actions artifact. Sign the iPhone IPA with the existing signing flow and install/update it on the XR. Install and open the separate Debug Mac app. Do not clear the iPhone app's data.
2. Connect and unlock the XR, trust the Mac if prompted, and run `./scripts/run-iproxy-usb.sh <XR-UDID>`. Confirm `lsof -nP -iTCP:50888 -iTCP:50889 -iTCP:50890 -sTCP:LISTEN` reports only `127.0.0.1` listeners.
3. Tap **Debug：启动 USB 回环探针** on the iPhone, then **Debug：USB 免码探针** on the Mac. No IP or pairing code should be entered. Record TLS-ready, HELLO / READY, received PCM byte growth, nonzero RMS/peak, and consumed sequence growth. Select CamMic in QuickTime and save/play a speech recording.
4. With capture still active and Wi-Fi enabled, from the Mac run `nc -vz -w 2 <iPhone-LAN-IP> 50889` and the same command for `50890`. Both must fail while USB is working. Stop capture, confirm output goes silent and queued PCM clears, then try a new USB connect: it must fail until capture is explicitly started again. Restart capture and verify the prior key cannot connect.
5. Check the Mac default input/output before and after. Confirm QuickTime selects CamMic, default speakers remain unchanged, and other audio devices remain present and functional. Repeat the existing Wi-Fi flow to confirm the 50888 path and established capture lifecycle remain intact.

## Reproducible protocol and HAL checks

Keep the forwarding script running in one terminal and explicitly start the iPhone USB probe. Stop the Debug Mac app's connection before running the transport validator because only one audio session is allowed:

```sh
./scripts/run-usb-handshake-validation.sh --lifecycle
```

The wrapper builds with Command Line Tools or Xcode. The validator has fixed loopback endpoints, four-second network deadlines, bounded receive buffers, and 180-second operator deadlines. It uses the shared framing and TLS implementation. It compares old/new keys in memory without logging keys, hashes, or session IDs. It verifies actual authenticated PCM, not merely Network.framework's `.ready` state. Its ACK means the test consumed a frame; the Mac app separately verifies HAL callback consumption.

The existing CoreAudio reader also supports a bounded input-only mode that never opens an output callback or injects tones:

```sh
clang -std=c11 -O2 scripts/test-cammic-coreaudio-loopback.c \
  -framework CoreAudio -framework CoreFoundation -lm -o /tmp/cammic-hal-capture
/tmp/cammic-hal-capture --capture-only active.wav
/tmp/cammic-hal-capture --capture-only disconnected.wav --expect-silence
```

The proxy policy fixtures, wrong PSK identity/key tests, delayed Mac initialization/cancellation/metric callbacks, listener constraints, and HAL input-only silence are covered by CI. Physical USB behavior remains tied to the dated XR record. First-use Mac public-key approval, pinned-key authentication, revocation, and encrypted session-key delivery are not implemented; these are prerequisites for a production USB entry point.
