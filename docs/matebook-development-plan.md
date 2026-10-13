# MateBook Pro S development and verification plan

## Safety boundary

- The only remote channel is Tailscale at `<REMOTE_TAILSCALE_IP>:39611`. Do not stop, uninstall, replace, log out, or change preferences of `io.github.tailscaleohos` or ClashBox.
- Use an external development copy with bundle `io.github.tailscaleohos.devtest`. Every ArkTS Want and notification target must use that identity. Independent application storage must not import the production credentials.
- A separate bundle does not isolate system VPN routing. Until USB or a LAN debugging channel is available, do not activate the development VPN, test VPN contention, kill the production backend, reboot, or change DNS/routes.
- Existing device-probe scripts hard-code the production identity and may reinstall it. Do not use them on this device.

## Environment observed on 2026-10-12

- Clean initial checkout, branch `main`, baseline `fd49406`.
- DevEco CLI 1.3.2; DevEco Studio and vendor HMS/OpenHarmony SDK components are installed.
- HDC connection succeeded; device reports HUAWEI MateBook Pro S, 2in1, API 26 Release, `OpenHarmony-7.0.0.105`.
- Production MeshArc and `org.xbgroup.clashboxLTS` are installed.
- Production crash-log query returned no records. This does not disprove crashes and does not establish a root cause.
- The clone lacks root `build-profile.json5`, OpenHarmony Go, the patched Tailscale source checkout, and `libtailscale_go.so`. Official build stops at the missing root profile; native compilation and signing remain prerequisites.
- Background-task, network-monitor and peer-reconnect host tests passed: 14, 8 and 10 cases respectively. These are not device stability evidence.

## Implementation progress

- Luna workers added command ownership/stop-timeout recovery and an API-26 desktop tray entry with an application-open menu. Direct settings actions, backend force-restart and startup integration are not yet implemented.
- New host suites passed: command recovery 8 cases, tray lifecycle 5 cases and isolated-copy safety 4 cases.
- Created an external copy at `<LOCAL_ISOLATED_COPY_PATH>`; verified all five application/ArkTS identity references use `io.github.tailscaleohos.devtest`. Development signing generation succeeded for that copy.
- Configured the official `@ohos` package registry; Hvigor dependencies installed. Full debug build reached native Ninja and failed because the Go shared library was not yet built. A linter invocation reporting zero checked files is not compilation evidence.
- Downloaded and SHA-256-verified official Windows Go 1.24.5 solely as a bootstrap compiler. Checked out OpenHarmony Go 1.24 branch at `302a5306b6fad2f47196360b82561d1db1f954cf` and Tailscale v1.86.5 at `db392aed39630023f969e1961fcbced785d09358`. Built the OpenHarmony compiler; completed its host standard-library/Go-command installation with host CGO disabled because Windows GCC is unavailable.
- Fixed CRLF-sensitive forward patch checks in `scripts/build-go.ps1` to use the same whitespace tolerance as its existing reverse checks. Built the patched native library successfully using vendor Clang. `go version -m` verifies Go 1.24.5, Tailscale 1.86.5, `GOOS=openharmony`, `GOARCH=arm64` and `CGO_ENABLED=1`; the host CGO workaround does not disable target CGO.
- Existing `vpnroute` Go host tests passed. This does not validate HarmonyOS shared-library runtime behavior.
- No development VPN has been activated. Production process and remote HDC remain reachable.
- Coexistence architecture and DNS/subnet limits are detailed in [clash-coexistence-design.md](clash-coexistence-design.md).

## Build and installation checkpoint

- Official `devecocli build --modules entry --build-mode debug` completed with `BUILD SUCCESSFUL` in the isolated copy. Compiler warnings include desktop-only capability use and existing cross-device/API warnings; the build is not warning-free.
- Signed HAP: `<LOCAL_SIGNED_HAP_PATH>`.
- Read `pack.info` from the actual signed HAP: bundle identity is `io.github.tailscaleohos.devtest`, both VPN and status-bar extensions are present, and all native libraries are arm64-v8a.
- All `scripts/test-*.mjs` host tests passed: 58 cases, zero failures. The existing Go `vpnroute` test passed separately.
- First installation attempt could not reach HDC (`Device not found or connected`), before any successful transfer/install. HDC misleadingly returned exit code zero for these failures; output text must be checked as well as the exit code. Reconnecting the unchanged debugging endpoint is the next safe action.
- Reconnection succeeded. The signed development HAP installed successfully and `aa start` succeeded. Development PID was `11275`; production PID remained `6871` before and after this installation. Both original and development windows were listed separately.
- Development crash-log query found no records. Runtime logs contain system/theme/file warnings, so the startup smoke test is not evidence of warning-free or long-session stability.
- A UI minimize attempt by node ID could not find the target after focus moved to the remote desktop window. No coordinate fallback was used, and minimize/tray interaction is not counted as verified. Diagnostic tray registration logs were added for the next build.

## Work packages

1. **Command reliability:** regression tests for command ownership, lifecycle invalidation, stop timeouts and late callbacks; release command ownership on all preflight failures. Bound UI waiting without falsely claiming that a native operation has been terminated.
2. **Isolated build:** prepare a separate source copy and distinct labels/identity, provision native dependencies, build the current pinned engine first, register a development signing profile for the distinct bundle, inspect the packaged identity before installing.
3. **Desktop lifecycle:** use the official Desktop Extension Kit status-bar mechanism for a visible tray entry, right-click actions and window restoration. Register/unregister resources safely; keep phone/tablet behavior unchanged. Do not misrepresent simulated audio, video or downloads as legitimate background work.
4. **Crash/startup diagnostics:** gather bounded, redacted logs and fault records; move blocking native status/start operations off the UI thread with API-compatible asynchronous bridge functions. Measure startup and connect phases separately.
5. **Clash coexistence:** the official `net-vpnextension` guide explicitly permits only one active VPN service and rejects a second start. Evaluate one system TUN owner plus userspace/proxy integration; route exclusions alone cannot enable two VPN services. ClashBox master exposes frontend recovery, simulated download/location/PiP and desktop wrappers, but its README states the modified backend is not open. A configuration-only coexistence solution is not yet proven. No route changes on the sole remote channel.
6. **DNS/subnet settings:** surface effective settings, validation and failure feedback. Existing MagicDNS-disabled behavior must not be replaced merely by populating a DNS array: validate resolver integration, split DNS, socket bypass and subnet reachability. Preserve local-network access and prevent unintended default-route takeover.
7. **Startup:** expose the system-supported autostart status/settings path, require user opt-in and respect system permission limits. Restore connection only after preferences and lifecycle recovery are proven; do not use enterprise-only MDM APIs in an ordinary application.
8. **Engine migration:** recheck upstream versions and OpenHarmony Go support. Port and test patches against a compatible toolchain; do not lower the Go requirement or substitute Linux/Android shared libraries. Keep this separate from the first stability build.

## Acceptance evidence

| Stage | Required evidence |
| --- | --- |
| Host regression | Command and tray lifecycle tests plus existing focused suites |
| Build | Official debug build success, verified native arm64 dependencies and distinct HAP identity |
| Safe device smoke | Install distinct bundle; open/close/minimize, tray menus, no production VPN changes |
| Full device validation | Backup debug channel; login, connect/cancel/recovery, Clash coexistence, DNS/subnet peers, long background run, sleep/wake and opt-in startup |

Implementation, compilation, signing, installation and VPN connectivity must be reported separately. No phase is complete merely because a preceding phase passes.

## References

- Repository architecture: [development.md](development.md).
- Official desktop status-bar guide: `devecocli docs read 开发指南/基础功能/Desktop_Extension_Kit_桌面拓展服务/应用接入状态栏/statusbar-extension-guide`.
- Official autostart references: `devecocli docs search 开机自启动`.
- ClashBox upstream: https://github.com/xiaobaigroup/ClashBox/tree/master (reference only; review license before reuse).
