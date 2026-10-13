# Getting started with MeshArc

[Project overview](../README.md)

## Install

### AppGallery

No AppGallery listing URL is available yet. Do not infer or construct a store URL from the bundle ID; check this guide again after an official listing is published.

### GitHub Releases

[GitHub Releases](https://github.com/RockyMtnWolf/MeshArc/releases) provides HAP builds and release notes. The beta HAP is unsigned and requires your own compatible signing materials before installation; it is not an AppGallery release. Read the notes for the package you choose.

The source project targets HarmonyOS 6.1 / API 23 and arm64. A downloaded HAP still needs to satisfy the installation and signing requirements of your device. Early `0.3.19-release` builds use a development provisioning profile and are not universally installable.

For local builds and device installation, use the [Windows development guide](development.md) or [macOS build guide](build-macos.md).

## Join your tailnet

1. Install and configure [Tailscale](https://tailscale.com/download) on the computers, NAS devices or servers you want to access.
2. Open MeshArc and complete browser sign-in with an account in the same tailnet.
3. Connect, approve the HarmonyOS VPN prompt, and wait for the connection to become ready.
4. Select a device to access a service, send files, or browse an existing Taildrive share.

Use Tailscale IP addresses; MagicDNS is currently disabled. Disconnect other system VPNs before connecting. After a device restart, open MeshArc and reconnect manually.

## Files, routes and media

- **Exit nodes and subnet routes:** configure the remote node and approve routes in your tailnet before using them in MeshArc.
- **Taildrop:** the receiving device must support file reception and be eligible under your tailnet's settings.
- **Taildrive:** configure the remote share and its access permissions first. Available file operations depend on those permissions.
- **Media:** Jellyfin, Emby or Plex must be running and reachable. MeshArc can pass server details to HosPlayer; sign in to your media account inside the player.
- **App and folder locks:** system authentication protects access through MeshArc on this device. Remote access remains governed by your tailnet and share permissions.

MeshArc does not expose remote services or change your tailnet access policy for you.

## Troubleshooting

Check that both devices are online in the same tailnet, the remote service is running, and your access policy permits the connection. Screen-off, network-transition and long-session reliability remain areas of active testing.

For persistent problems, search [existing issues](https://github.com/RockyMtnWolf/MeshArc/issues), then follow the [reporting guide](../CONTRIBUTING.md#report-a-problem). Include your MeshArc version, device model, HarmonyOS version and reproduction steps.
