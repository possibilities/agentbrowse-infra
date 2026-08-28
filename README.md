# agentbrowse-infra

Manually controlled local infrastructure for agentbrowse when the remote
browser farm is unavailable. It uses Apple `container` without Docker Desktop,
Colima, or a resident VM.

The service is intentionally passive: agentbrowse may use it when it is
already enabled, but must never start it. If both the remote farm and this
local infrastructure are unavailable, browser launch fails with a recovery
message rather than silently consuming local resources.

## Lifecycle

```sh
bin/agentbrowse-infra enable
bin/agentbrowse-infra pull REGISTRY/agentbrowse/kernel-headful:REVISION
bin/agentbrowse-infra prove
bin/agentbrowse-infra status
bin/agentbrowse-infra disable
```

`enable` is the only command that starts Apple container services. It uses a
dedicated application-data root under
`~/Library/Application Support/agentbrowse-infra`, so Apple container's sparse
disks and service state have a visible home. If the Apple service stops
unexpectedly, another explicit `enable` reuses only complete, correctly marked
state and preserves its ownership receipts.

`pull` and `load` are explicit image-acquisition operations. Local image builds
are deliberately absent from the normal lifecycle. Apple 0.8.0's built-in
BuildKit worker is arm64-only, but an amd64 BuildKit container can build through
Rosetta over a private Unix socket. That path built every stage of the exact
Kernel/Neko image, then crossed the 12 GiB development-box budget during final
OCI export. The intended production path is therefore a private registry
populated by the existing image build pipeline. An OCI archive exported by
Artbird is the offline bootstrap path.

`prove` requires the service to be enabled already. It runs one 512 MiB,
one-CPU VM at a time and checks amd64 execution through Rosetta, effective
Linux capabilities, `/dev/shm`, and direct TCP and UDP from the host. It does
not test Apple port publishing because the secure configuration keeps macOS
Local Network permission denied.

`disable` audits before changing anything. It accepts only:

- containers labeled `dev.agentbrowse.infra=true`; or
- Browser targets labeled both `dev.agentbrowse.managed=true` and
  `dev.agentbrowse.backend=apple-container-local`;
- exact image references written to the ownership receipt; and
- the Apple-created `default` network.

Any other container, image, network, volume, or builder is a cleanup blocker.
When the audit is clean, `disable` removes exact owned resources, stops the
service, verifies that it stopped, and removes the marked application-data
root. It never invokes a global prune operation.

## Readiness versus enablement

An enabled service is not necessarily ready for agentbrowse. `status` reports
`ready: true` only after at least one receipt-owned image is present. The later
agentbrowse integration will additionally require its configured exact image
before selecting this backend.

Use `status --json` for a stable machine-readable document. Configuration must
list the remote backend first and this local backend second; probing that list
does not grant permission to run `enable`.

## Development

```sh
tests/validate.zsh
AGENTBROWSE_REAL_TESTS=1 tests/real-runtime.zsh
```

The real Runtime proof is intentionally opt-in because it changes machine
state. Its wrapper explicitly enables the service and always disables it in a
trap; the `prove` command itself still refuses to enable the service.
