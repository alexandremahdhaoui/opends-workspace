# opends-workspace

The shared workspace files for the OpenDS project.

OpenDS is a Rust tool for Windows. It reads a DualSense or DualShock 4. It maps the pad to keyboard and mouse. It presents the pad to games as an Xbox pad through a small Windows driver. It is independent from DS4Windows.

## The repos

| Repo | Owns |
|---|---|
| [opends-spec](https://github.com/alexandremahdhaoui/opends-spec) | Every config key and the driver protocol |
| [opends-core](https://github.com/alexandremahdhaoui/opends-core) | The domain logic. No I/O. |
| [opends-app](https://github.com/alexandremahdhaoui/opends-app) | The app, the installer, and the Windows adapters |
| [opends-uhid](https://github.com/alexandremahdhaoui/opends-uhid) | The Windows driver |

## What lives here

- `workspace/`. The `Cargo.toml`, `go.work`, and `pnpm-workspace.yaml` shared across the repos above.
- `hack/sync.sh`. Copies those files, plus this workspace's `CLAUDE.md`, out to the parent directory where all repos sit side by side.

## Build and test

```sh
forge build
forge test-all
```

## Security posture

No socket, checked by an automated build stage. No third party code is ever built or run. No auto updater. Zero kernel code of our own.

## License

Apache License 2.0.
