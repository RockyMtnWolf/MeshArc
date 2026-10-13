# Third-party notices

MeshArc's original code is licensed under the [BSD 3-Clause License](LICENSE). This license does not replace the licenses or copyright notices of third-party components, including code adapted from upstream projects.

## Tailscale

MeshArc integrates the Tailscale userspace networking engine. The current source baseline is [Tailscale v1.86.5](https://github.com/tailscale/tailscale/tree/v1.86.5).

Copyright (c) 2020 Tailscale Inc & AUTHORS.

The upstream BSD 3-Clause License is reproduced in [LICENSES/Tailscale.txt](LICENSES/Tailscale.txt). Retain upstream copyright headers, attribution and license notices when modifying or redistributing Tailscale-derived code.

## Other dependencies

The [OpenHarmony Go toolchain](https://gitcode.com/openharmony-sig/ohos_golang_go), Go modules, native libraries and HarmonyOS packages retain their respective licenses. Their terms are not replaced by MeshArc's project license.

### Direct Go dependencies

Versions are from `native/go_bridge/go.mod`; these are direct module requirements, not a complete inventory of the selected build or its transitive dependencies.

| Module | Version | License | Included text |
| --- | --- | --- | --- |
| `tailscale.com` (local replace: `third_party/tailscale`) | v1.86.5 | BSD 3-Clause | [LICENSES/Tailscale.txt](LICENSES/Tailscale.txt) |
| `github.com/fatedier/frp` | v0.52.0 | Apache-2.0 | [LICENSES/FRP.txt](LICENSES/FRP.txt), vendored upstream text at `third_party/frp-compat/LICENSE` |
| `github.com/pelletier/go-toml/v2` | v2.2.0 | MIT | [LICENSES/Go-TOML.txt](LICENSES/Go-TOML.txt) |
| `github.com/tailscale/wireguard-go` | v0.0.0-20250716170648-1d0488a3d7da | MIT | [LICENSES/WireGuard-Go.txt](LICENSES/WireGuard-Go.txt) |
| `golang.org/x/sys` | v0.35.0 | BSD 3-Clause | [LICENSES/Go-X-Sys.txt](LICENSES/Go-X-Sys.txt) |
| `gopkg.in/yaml.v3` | v3.0.1 | MIT and Apache-2.0 (file-dependent) | [LICENSES/yaml.v3.txt](LICENSES/yaml.v3.txt), [LICENSES/yaml.v3-NOTICE.txt](LICENSES/yaml.v3-NOTICE.txt) |

FRP v0.52.0 is a compatibility fallback, not the latest FRP release. The source selected by `go.mod` is a locally compatibility-patched copy under `third_party/frp-compat`; it is **not an unmodified official upstream build**. Preserve the upstream copyright and Apache-2.0 license, shown in [LICENSES/FRP.txt](LICENSES/FRP.txt). The locally patched v0.52.0 build has been used for one existing TOML-based tunnel protocol test; this does not imply that Sakura's newer v0.51-based INI mode is supported, nor that multiple public tunnels or physical USB device I/O have been tested. `gopkg.in/yaml.v3` includes both license grants and a separate NOTICE file, reproduced separately.

The resolved Go-module license texts and notices, including transitive dependencies and the Go toolchain/runtime `LICENSE` and `PATENTS`, are retained under `LICENSES/dependencies/`. This does not certify completeness for non-Go native libraries, HarmonyOS system/runtime components, or embedded assets; review all components included in a specific release.
Tailscale, HarmonyOS, LocalSend and HosPlayer names and marks belong to their respective owners. MeshArc is an independent community project and is not affiliated with or endorsed by Tailscale Inc.
