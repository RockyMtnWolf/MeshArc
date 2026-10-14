<div align="center">

**English** | [简体中文](README_zh.md)

# MeshArc

<img src="AppScope/resources/base/media/app_icon.png" width="96" alt="MeshArc app icon">

**A native Tailscale client for HarmonyOS, with FRP support and ClashBox coexistence.**

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-6.1%20%7C%20API%2023-007DFF?style=for-the-badge)](https://github.com/RockyMtnWolf/MeshArc)
[![OpenHarmony arm64](https://img.shields.io/badge/Native-OpenHarmony%20arm64-3DA5D9?style=for-the-badge)](https://github.com/RockyMtnWolf/MeshArc)
[![License](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg?style=for-the-badge)](LICENSE)

[Source repository](https://github.com/RockyMtnWolf/MeshArc) · [简体中文](README_zh.md)

</div>

---

MeshArc connects HarmonyOS devices to a Tailscale tailnet using a native VPN extension and the Tailscale userspace engine.

## Features

- **Tailnet:** device status, approved subnet routes, and exit-node selection.
- **Transfers and media:** Taildrop, Taildrive, LocalSend discovery, and integrations for Jellyfin, Emby, Plex, and HosPlayer.
- **Proxy coexistence:** a ClashBox userspace-proxy path with YAML repair/export; the optional inbound policy is TCP-only.
- **Embedded FRP:** TOML file import, multiple saved profiles, and independent workers. The included FRP v0.52.0 source has local compatibility patches; it is not an unmodified upstream build.
- **Desktop workflow:** tablet and 2-in-1 layouts, optional access protection, and title-bar close-to-tray behavior.

## Compatibility

| Item | Baseline |
| --- | --- |
| Platform | HarmonyOS 6.1 compatibility, API 23; compile SDK 26 |
| Native target | arm64; tablet and 2-in-1 layouts |
| Tailscale | `v1.86.5` |
| OpenHarmony Go | `1.24.5` |
| FRP | `v0.52.0` locally patched compatibility build |
| App version | `1.1.2` · build `100000007` |
| Bundle ID | `io.github.rockymtnwolf.mesharc` |

HarmonyOS allows one system VPN service at a time. To use MeshArc alongside ClashBox, enable coexistence in the network settings and follow the app's instructions to repair/export the Clash YAML. Other Clash-based clients have not been broadly tested. MagicDNS is disabled; use Tailscale IP addresses where needed.

## Tested and limitations

The maintainer has tested MeshArc on a MateBook Pro S, including peer connectivity, RDP, USB/IP, LocalSend discovery, FRP, and background use. These are device-use results, not a claim that every HarmonyOS device or network is issue-free.

FRP is based on locally compatibility-patched v0.52.0. The tested client configuration is TOML; Sakura-specific mode in the newer v0.51-based INI is not supported by stock v0.52.0.

Core Update checks upstream release metadata and exports a build-request manifest; on-device core download, compilation, signing, and installation are not implemented. Replacing the engine with a complete HAP update interrupts the VPN; live `.so` replacement is not implemented.

Optional background task keeping is available on PC/2-in-1 devices; it replaces the previous audio keepalive and does not play audio. Other device types do not request its restricted system permission. Background modes do not guarantee that the system will never terminate the app.

## Install

Check [GitHub Releases](https://github.com/RockyMtnWolf/MeshArc/releases) for the release package and notes. Release HAPs are unsigned; sign with credentials you are authorized to use before installation. Do not share private keys or provisioning profiles.

The app has been submitted for AppGallery review for PC/2-in-1 devices; it is not listed yet. No AppGallery download URL is available.

## Build

Prepare DevEco Studio and the HarmonyOS SDK, the OpenHarmony Go `1.24.5` toolchain, the Tailscale `v1.86.5` source, and local build/signing configuration. Copy `build-profile.example.json5` to the ignored `build-profile.json5`, configure your own signing settings, then run in Windows PowerShell:

```powershell
./scripts/build.ps1
```

For AppGallery submission, build the whole product as a Release `.app`, rather than renaming a `.hap`:

```powershell
devecocli build --product default --build-mode release
```

The `.app` is the store submission package; `.hap` files are module packages for local installation with an accepted signature.

The repository does not include signing credentials. A build without them produces an unsigned HAP; installation requires a device-accepted signature.

## License and credits

MeshArc is licensed under the [BSD 3-Clause License](LICENSE). Tailscale-derived code retains its upstream notices; other components retain their own licenses. See [third-party notices](THIRD_PARTY_NOTICES.md) and the included license texts in `LICENSES/`.

Thanks to [Tailscale](https://github.com/tailscale/tailscale), OpenHarmony Go contributors, and the upstream [flypigJ/Tailscale-OHOS](https://github.com/flypigJ/Tailscale-OHOS) project. MeshArc is an independent community project, not affiliated with or endorsed by Tailscale Inc.
