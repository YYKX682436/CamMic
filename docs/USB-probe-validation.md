# USB no-code handshake feasibility probe

Status for 2026-10-26: implementation and repeatable probe entry are prepared; XR application-level acceptance is pending.

## Host and device evidence

- `NWParameters.requiredLocalEndpoint` selects a specific local IP address and port for listeners. [Apple's API reference](https://developer.apple.com/documentation/network/nwparameters/requiredlocalendpoint) lists it as available since iOS 12, so it is in the iOS 14.3 API surface. This is an API availability check, not proof of the iOS 14.3 runtime behavior.
- If this listener does not behave correctly on the XR, keep the boundary at IPv4 loopback and evaluate a BSD socket listener explicitly bound to `INADDR_LOOPBACK`, paired with a separately reviewed TLS-PSK adapter that preserves the current framing. Do not broaden the listener to all interfaces as a workaround.
- The attached device was read through USBMux as an iPhone XR (`iPhone11,8`) on iOS 14.3. Its UDID is intentionally not recorded in this repository.
- The updated `scripts/run-iproxy-usb.sh` was started for that paired device. `lsof` showed `iproxy` listening on `127.0.0.1:50888`, `127.0.0.1:50889`, and `127.0.0.1:50890`; the process was then stopped. This verifies the Mac-side proxy bind and USBMux device selection only.
- CamMic was not installed on the XR at inspection time, and this Mac has Command Line Tools but no full Xcode or iOS SDK. Therefore no iPhone listener, TLS handshake, protocol handshake, PCM delivery, Wi-Fi isolation attempt, or QuickTime recording was performed in this run.

## Test-only implementation boundary

The Debug-only probe has two device-side listeners: a plaintext init channel on `50889` and the existing TLS-PSK/CamMic protocol on `50890`. Both require local endpoint `127.0.0.1`. The init listener starts only after the user explicitly starts microphone capture and `AVAudioEngine.start()` succeeds. It handles at most eight one-shot requests per capture run. The Mac test button connects only to `127.0.0.1`; it does not accept a network address or retry over Wi-Fi.

Each capture run creates a 32-byte session key with `SecRandomCopyBytes`. Stop cancels both listeners and their active init connections, clears the key reference, and tears down the audio connection. A new run generates a different key. TLS-PSK uses the existing TLS 1.2 and CamMic HELLO / READY / PCM / ACK implementation. Release builds omit the USB listener, client, and UI entry points.

USBMux's paired-device trust is a system-level gate for the forwarded connection. The iOS app sees only its loopback peer and cannot distinguish the trusted Mac's CamMic process from another local process. The init response exposes the current key in plaintext to any client that can reach the loopback channel. This proves a no-pairing-code USB path under the trusted-host assumption; it does **not** establish strict application-level Mac identity. A production design needs first-use confirmation and a pinned Mac public key, then challenge-response and encryption of each session key to that key.

For a controlled personal setup where the trusted USB host is the security boundary, the public-key approval flow is not required to demonstrate this transport. For a production USB feature, it is needed if CamMic must distinguish its Mac app from another process on a paired Mac. The work is moderate rather than a transport rewrite: persistent Mac key material in Keychain, phone-side pinned-key storage and revocation, a first-use approval/fingerprint screen, signed nonce exchange, encryption of the per-run key, and lifecycle tests for reset/reinstall and stale requests. The public-key trust decision should happen before a Release USB entry point is added.

## Repeatable XR acceptance

1. Download `CamMic-USBProbe-Debug-iOS14-unsigned.ipa` and `CamMic-USBProbe-Debug-macOS-arm64.zip` from the same successful GitHub Actions artifact. Sign the iPhone IPA with the existing signing flow and install/update it on the XR. Install and open the separate Debug Mac app. Do not clear the iPhone app's data.
2. Connect and unlock the XR, trust the Mac if prompted, and run `./scripts/run-iproxy-usb.sh <XR-UDID>`. Confirm `lsof -nP -iTCP:50888 -iTCP:50889 -iTCP:50890 -sTCP:LISTEN` reports only `127.0.0.1` listeners.
3. Tap **Debug：启动 USB 回环探针** on the iPhone, then **Debug：USB 免码探针** on the Mac. No IP or pairing code should be entered. Record TLS-ready, HELLO / READY, received PCM byte growth, nonzero RMS/peak, and consumed sequence growth. Select CamMic in QuickTime and save/play a speech recording.
4. With capture still active and Wi-Fi enabled, from the Mac run `nc -vz -w 2 <iPhone-LAN-IP> 50889` and the same command for `50890`. Both must fail while USB is working. Stop capture, confirm output goes silent and queued PCM clears, then try a new USB connect: it must fail until capture is explicitly started again. Restart capture and verify the prior key cannot connect.
5. Check the Mac default input/output before and after. Confirm QuickTime selects CamMic, default speakers remain unchanged, and other audio devices remain present and functional. Repeat the existing Wi-Fi flow to confirm the 50888 path and established capture lifecycle remain intact.

Until the signed Debug IPA is installed and these steps are recorded on the XR, the iOS listener behavior, no-code TLS/audio handshake, Wi-Fi isolation, and CoreAudio microphone recording remain **NOT_VERIFIED**.
