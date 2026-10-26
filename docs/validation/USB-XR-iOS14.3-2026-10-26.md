# XR / iOS 14.3 USB feasibility record

Date: 2026-10-26, Asia/Shanghai. Physical device: iPhone XR (`iPhone11,8`), iOS 14.3. Host: arm64 Mac, macOS 27.0.1, installed CamMic HAL. The UDID, pairing code, session keys and session IDs are intentionally absent from this record.

The iPhone ran `CamMic-USBProbe-Debug-iOS14-dc1dc5d.ipa`, built by [Actions 40274327815](https://github.com/YYKX682436/CamMic/actions/runs/40274327815) from `dc1dc5d2d041a43f984ee3bc9e91ed39fc286a38` and installed by the operator through TrollStore. IPA SHA-256: `4133db94c781bff37605d65e510ea94757bde1b32319e3872ff8791d3614fda3`. Subsequent work changed the Mac client and validation tools; the accepted iOS listener/capture/shared protocol source was unchanged.

The initial Mac app came from that same CI artifact. The `.waiting` cleanup update was then built locally from the final working source with Apple Swift 6.4, target macOS 13, signed ad hoc as a separate temporary validation app, and used for the physical unplug and Wi-Fi regression checks. Full Xcode/XCTest is unavailable on this host, so automated XCTest runs belong to CI.

## Observed results

| Check | Physical observation | Result |
| --- | --- | --- |
| Mac forwarding | `iproxy --local --udid <selected-device> --source 127.0.0.1`; `lsof` showed only IPv4 `127.0.0.1:50888/50889/50890` listeners | PASS |
| iOS listener repair | On-device log identified duplicate `requiredLocalEndpoint` port plus `NWListener(on:)`; removing the second port selection let both loopback services start | PASS |
| No IP or code entered for USB | Both normal IP and pairing fields were blank; Debug USB button completed initialization, TLS and HELLO / READY | PASS |
| Sustained real USB PCM | First Mac run: 15,311 packets, 29,397,120 bytes, consumed sequence 15,303, protocol errors 0; RMS/peak nonzero | PASS |
| Negotiated PSK transport | Standalone shared-code validator negotiated TLS 1.2 PSK cipher `0x00A8`, then validated HELLO / READY and increasing PCM frames | PASS |
| Wrong key | Explicit TLS `-9820: bad MAC`; iPhone log also recorded decryption/bad-record-MAC handshake failure | PASS |
| Wrong PSK identity | Explicit TLS `-9864: unknown PSK identity`; iPhone log recorded `PSK_IDENTITY_NOT_FOUND` | PASS |
| Concurrent Mac session | Second correct-key audio session rejected; primary session continued from its first frame to 109 packets | PASS |
| Reconnect | New protocol session ID and sequence; shared receive validation rejected stale/gapped frames | PASS (physical reconnect plus protocol tests) |
| User stops capture | Init response unavailable and new audio connection reset; the request did not start capture | PASS |
| User restarts capture | New key differed in memory; prior key received `bad MAC`; new key received 104 PCM packets / 199,680 bytes | PASS |
| Wi-Fi isolation | With USB probe capture active and Wi-Fi enabled, `192.168.31.175:50889` and `:50890` both returned `Connection refused`; address was later confirmed by successful ordinary Wi-Fi audio with physical USB absent | PASS |
| Physical USB unplug | Device disappeared from USBMux's USB list; operator confirmed phone remained in foreground capture | PASS |
| Unplug silence and buffer clearing | CoreAudio capture started 0.255 s after USB disappearance was detected. Following 3.008 s / 144,384 frames had RMS 0 and peak 0. Mac showed queue 0, protocol errors 0 | PASS |
| No wireless fallback | While USB remained unplugged and Wi-Fi was enabled, a new Debug USB attempt failed at init; 0 packets, 0 bytes and empty playback buffer | PASS |
| Existing Wi-Fi path | Operator explicitly switched to normal capture and entered its code only in the secure Mac field. Same IP completed TLS/protocol/audio; 2,668 packets / 5,122,560 bytes, protocol errors 0 | PASS (smoke regression) |
| CamMic HAL | Public input and hidden output UID, plug-in identity, owners and controls passed. Input-only captures had nonzero USB RMS 0.006033396 / peak 0.025909424 and Wi-Fi RMS 0.009029113 / peak 0.050201416 | PASS |
| Other audio configuration | Full `system_profiler SPAudioDataType -json` before/after snapshots were equal. Default input remained CamMic, default output remained Mac mini speakers; Bluetooth speaker and HDMI monitor remained listed | PASS for inventory/defaults |

USB disappearance was sampled by a bounded USB-only device-list observer every 0.2 seconds. The 0.255-second value is relative to observed disappearance, not an electrical cable-edge timestamp or acoustic latency measurement. No default device was changed by these checks. Bluetooth/HDMI acoustic playback was not individually retested.

## Retained local evidence

Only sanitized protocol output is committed: [USB-XR-iOS14.3-2026-10-26.txt](USB-XR-iOS14.3-2026-10-26.txt). Local files are under `dist/usb-probe-xr-validation/` (ignored by Git):

- `CamMic-USB-XR-iOS14.3-dc1dc5d.m4a`: QuickTime explicitly selected CamMic, 48 kHz stereo, 22.718667 seconds, RMS 0.067297892 and peak 0.913391113 after decoding; 2,177,840 nonzero samples. SHA-256 `a3bfcb3756bc7bcae736d541d1b67323e277a3f39c1b3e171bf66b60e58c9ab8`.
- `physical-usb-disconnect-silence.wav`: actual HAL input after USB disappearance, digital zero. SHA-256 `be69c31f860d3d0492bc7cd9b9418fc7a28233a076ee9f901395590b87ab4182`.
- Redacted handshake log, PCM measurement summaries, Wi-Fi refusal results, physical-disconnect timing and device inventory comparison.

The audio remains local and was not uploaded to GitHub. Non-silence was verified numerically; no independent speech transcription or acoustic content assessment is claimed.

## Identity boundary and next stage

USB loopback and no-code audio are feasible on this XR in the tested already-trusted Mac setup. The supplied forwarding script now checks existing pairing before starting. An untrusted Mac/custom-port access test was not performed and remains **NOT_VERIFIED**; this record does not claim a universal system trust gate on all USBMux app ports. System trust also does not identify the CamMic Mac process. Another process with forwarding access, or a process on the iPhone with loopback access, can request the plaintext current key while capture is active. A fixed PSK identity string identifies the protocol and is not a persistent Mac identity.

The production prerequisite is explicit first-use approval of a Mac public key, phone-side pinning and revocation, a fresh signed nonce exchange, and encryption of the per-capture key to that pinned key. Mac private material belongs in Keychain. Reinstall/reset, stale challenge, multiple approved Macs and replacement/revocation policies need dedicated lifecycle tests. This is additional identity/state work while retaining the current TLS/audio framing and HAL.

The transport result is sufficient to begin stage ②-2 design. A Release automatic USB connection must make that identity decision before exposing its initialization service. The current plaintext Debug bootstrap is not a production authentication scheme. Automatic discovery, lock-screen capture, menu-bar UI, and latency optimization were not added.

Historical note: the paragraph above proposed application-level Mac identity as a prerequisite based on the stage ②-1 design. For stage ②-2, the user explicitly chose to omit that app-level trust flow and accept the USB trust boundary described above. This record remains evidence for the old Debug build only; it does not claim that every host is blocked from custom USBMux ports or verify the stage ②-2 Release implementation.
