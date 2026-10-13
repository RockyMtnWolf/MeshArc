# Contributing to MeshArc

Documentation, translations, device testing and code contributions are welcome.

## Report a problem

Search [existing issues](https://github.com/RockyMtnWolf/MeshArc/issues) first, then include:

- App version and installation source.
- Device model and HarmonyOS version.
- Steps to reproduce, expected behavior and actual result.
- Whether exit nodes, subnet routes or another VPN are involved.
- Redacted diagnostics or screenshots when useful.

Remove authentication URLs, keys, tokens, personal account details, device identifiers, tailnet addresses, file paths and signing information before posting diagnostics publicly.

## Propose a change

1. For larger changes, open an issue describing the use case first.
2. Keep each pull request focused; preserve existing protocols, persisted formats and user data.
3. Keep the English and Chinese README consistent. For app UI changes, maintain both English and Chinese resources.
4. Describe the behavior change and validation; say explicitly when device testing was not performed.

For a local build, prepare DevEco Studio and the HarmonyOS SDK, the OpenHarmony Go toolchain, the pinned Tailscale source, and local signing configuration. On Windows PowerShell, copy `build-profile.example.json5` to the ignored `build-profile.json5`, configure signing, and run `./scripts/build.ps1`.

## Ways to help

- Improve onboarding, installation notes and troubleshooting.
- Refine the app's English and Chinese copy.
- Report real-device behavior across phones, tablets and 2in1 devices.
- Reproduce and narrow down network-transition, transfer or layout issues.

Check your diff before submitting. Exclude unrelated changes, generated build output, dependency directories and signing credentials. Keep `versionName`, `versionCode`, release notes and signing configuration consistent for a release; never commit private signing material.

## License

MeshArc uses the [BSD 3-Clause License](LICENSE). Preserve existing copyright notices and third-party license terms when contributing.
