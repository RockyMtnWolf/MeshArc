<div align="center">

**English** | [简体中文](README_zh.md)

# MeshArc

<img src="AppScope/resources/base/media/app_icon.png" width="96" alt="MeshArc app icon">

**A native Tailscale client for HarmonyOS, with a focus on desktop and advanced network workflows.**

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-6.1%20%7C%20API%2023-007DFF?style=for-the-badge)](https://github.com/RockyMtnWolf/MeshArc)
[![Architecture](https://img.shields.io/badge/Native-OpenHarmony%20arm64-3DA5D9?style=for-the-badge)](docs/development.md)
[![License](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg?style=for-the-badge)](LICENSE)

[Source repository](https://github.com/RockyMtnWolf/MeshArc) · [简体中文](README_zh.md)

</div>

---

MeshArc connects HarmonyOS devices to a Tailscale tailnet. It packages the Tailscale userspace engine as an OpenHarmony arm64 native library and provides a HarmonyOS VPN extension and ArkUI interface.

## Features

- **Tailnet connectivity:** authenticate to Tailscale, inspect device state, and reach peers by Tailscale IP. Approved subnet routes and exit-node selection are available in the client; DNS behavior has limitations below.
- **File and media workflows:** Taildrop transfer, Taildrive shares, and discovery links for Jellyfin, Emby, Plex, and HosPlayer.
- **Desktop-oriented tools:** adaptive layouts for phones, tablets, and 2-in-1 devices; ClashBox YAML repair/export with an explicit TCP-only inbound option; and an embedded FRP client with multiple profiles, independent workers, and TOML file import.
- **Desktop lifecycle:** the window close action uses HarmonyOS `hideAbility` to support tray-resident behavior.
- **Privacy controls:** optional app access protection and local configuration management.

## Compatibility

| Item | Current project baseline |
| --- | --- |
| Platform | HarmonyOS 6.1 compatibility, API 23; compile SDK 26 |
| Device/native target | arm64; phone, tablet, and 2-in-1 layouts |
| Tailscale engine | `1.86.5` (pinned) |
| FRP client | `0.52.0` compatibility fallback (not latest) |
| OpenHarmony Go | `1.24.5` (project toolchain baseline) |
| Release bundle ID | `io.github.rockymtnwolf.mesharc` |

The checked-in app configuration now uses the independent MeshArc bundle ID above. This source change does not establish AppGallery availability/approval or release signing. The project source URL is [RockyMtnWolf/MeshArc](https://github.com/RockyMtnWolf/MeshArc); check that repository for publication timing and current availability. MagicDNS is disabled; use Tailscale IP addresses where applicable. Reconnection after device restart may require user action, and HarmonyOS permits only one system VPN service at a time.

## Verification and limitations

- **Coexistence and peer discovery:** with Clash VPN active, the latest independent HAP's manual transfer refresh showed exactly two online LocalSend peers and no disconnected entries. The home native probe showed three peers as direct, at 84/35/14 ms, without a recovering state. ClashBox coexistence with outbound RDP and inbound USB/IP was also confirmed. These observations do not establish DNS, UDP, subnet-route, all-peer transfer, or general multi-VPN support.
- **FRP:** the v0.52.0 compatibility HAP built and installed; its existing profile started and the embedded native phase connected to frps. A Windows USB/IP `devlist` request through that single existing mapping returned protocol version `0x111`, command `0x5`, status `0`, and one device. This verifies one tunnel's external protocol response, not physical USB attachment or read/write, nor multiple public tunnels. Sakura-specific mode in the newer v0.51-based INI is not supported by the stock v0.52 client; the original TOML path was the one verified. Do not interpret a `running` worker state alone as public reachability.
- **FRP import, UI, and short background check:** importing the existing TOML through the system FilePicker preserved the domain, user, TLS flags, and existing port in the form, with no `NoSuchFile`/`ENOENT`; this did not save another profile or request a new port. Visual review of screenshots 51/52/53/66/74 found no mask or footer overlap, evenly enlarged five navigation icons, and a visible TCP protocol label; review of the second mapping page remains in progress. After closing the title-bar window with `hideAbility`, the main window disappeared from the window list while the existing USB/IP mapping continued to answer `devlist` with status 0 and one device, both immediately and after about one minute. This is a short background check, not force-quit or long-duration keepalive evidence.
- **Core updates:** the current feature checks upstream release metadata and can export a build-request manifest. It does not automatically fetch source, build/sign the core, or install an update on-device. Replacing the engine as a complete HAP upgrade interrupts the VPN; live `.so` replacement is not implemented.
- **LocalSend:** the described device-side discovery/status scenario is verified; broad interoperability and completed file-transfer coverage remain unverified.
- **Distribution:** no AppGallery listing is available yet. The root beta HAP for build `100000005` is unsigned and unpublished. An unsigned HAP cannot be normally installed; configure and use your own authorized signing credentials in DevEco Studio. Never publish signing keys or profiles.

Build results, automated tests, device observations, and external-network acceptance are separate evidence. See the [beta verification record](docs/2026-10-13-release-beta1.md) and [engineering checklist](docs/2026-10-13-change-checklist.md).

## Build

A fresh clone is **not** a one-command build. Prepare DevEco Studio with the HarmonyOS SDK, the OpenHarmony Go 1.24.5 toolchain, the Tailscale `v1.86.5` source checkout, and local signing configuration. See [development and Windows build instructions](docs/development.md) and [macOS instructions](docs/build-macos.md).

On Windows PowerShell, after preparing those dependencies and copying `build-profile.example.json5` to the ignored local `build-profile.json5`:

```powershell
./scripts/build.ps1
```

The build scripts produce a HAP; installation requires a valid signature accepted by the target device. An unsigned HAP is not a normal installable release package.

## Project details

| Area | Details |
| --- | --- |
| Application | MeshArc; developer/owner: 蒋厚斌 |
| Privacy contact | 1299177969@qq.com |
| Feedback | smartwolf@stu.xidian.edu.cn |
| Source home | [RockyMtnWolf/MeshArc](https://github.com/RockyMtnWolf/MeshArc) |
| Upstream provenance | Derived from [flypigJ/Tailscale-OHOS](https://github.com/flypigJ/Tailscale-OHOS); this project is independently maintained. |

## License and attribution

MeshArc source is distributed under the [BSD 3-Clause License](LICENSE). Tailscale-derived code retains its upstream copyright notices and BSD license; third-party dependencies retain their own terms. See [third-party notices](THIRD_PARTY_NOTICES.md) and `LICENSES/` before redistribution.

Thanks to [Tailscale](https://github.com/tailscale/tailscale), the OpenHarmony Go contributors, and the upstream `flypigJ/Tailscale-OHOS` project. MeshArc is an independent community project and is not affiliated with or endorsed by Tailscale Inc. HarmonyOS and other product names belong to their respective owners.
