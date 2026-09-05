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
OCI export. Kernel's existing GitHub Actions pipeline already publishes an
amd64 Docker Hub image for each source SHA; the intended production path is to
pin and pull that image's platform digest. An OCI archive exported by Artbird
remains the offline bootstrap path.

Maintainers can create the offline archive with
`scripts/export-artbird-image.zsh IMAGE@sha256:DIGEST OUTPUT.oci.tar`. The
helper accepts only a full locked digest, exports only `linux/amd64` through
Artbird Buildx, and validates that the OCI archive preserves the locked manifest
digest before publishing it. See [the export and Apple-load
runbook](docs/artbird-image-export.md). `load` receipts the archive tag and
creates a receipt-owned digest alias from the inspected platform manifest, so
agentbrowse can use the same locked runtime reference after an offline load.

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
`ready: true` only after at least one receipt-owned image is present. Agentbrowse additionally requires its configured exact image before launching a target.

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

## Installation

For an editable fleet installation, run:

```sh
scripts/install.sh --install
```

The installer verifies this checkout's origin and command ownership, links
`~/.local/bin/agentbrowse-infra` to the executable here, and records the exact
deployed commit at `~/.local/state/agentbrowse-infra/deployed-sha`. It refuses
foreign destinations or receipts. Installation deploys only the command: it
never starts Apple container services or acquires an image.

Use `scripts/install.sh --uninstall` to remove a corroborated command link and
receipt. Uninstallation does not alter Local infrastructure session state; use
the explicit `agentbrowse-infra disable` lifecycle command for that.

## Hypeman

`agentbrowse-infra hypeman setup|enable|status|disable` manages an independent Hypeman runtime. `pull IMAGE` explicitly prepares an OCI image. Setup verifies pinned release archives and installs no resident startup job; enable starts the service explicitly. Disable stops owned instances and preserves all profile data.

On macOS the service uses `~/.local/share/ab-hypeman` to keep Unix socket paths short. Install Caddy and e2fsprogs first. Its system-Python supervisor relays owned guest CDP, Live View, and UDP endpoints through loopback. Setup detects the active Apple network when choosing a VZ subnet; `setup --subnet CIDR` explicitly changes that setting for the next service start.

The adjacent artbird repository's optional `ansible/playbooks/hypeman.yml` installs the same lifecycle helper and the Linux prerequisites. The helper owns an exact nftables table for private CDP and WebRTC forwarding; it never prunes Docker resources.

See `../agentbrowse/docs/hypeman.md` for the four-backend demo and configuration contract. Run `/usr/bin/python3 tests/hypeman.py` for hermetic TCP/UDP forwarding checks.

## Preserve profiles when stopping Apple container

`agentbrowse-infra stop` audits container ownership and stops the service while
preserving images, profiles and receipts. Use `enable` to start it again.
`disable` retains its stricter, destructive cleanup contract and refuses volumes.

When a client cannot access private VM addresses, explicitly run
`agentbrowse-infra relay enable` and configure the Apple backend with
`"accessMode": "loopback"`. The system-Python relay exposes CDP on
`127.0.0.1:9222+slot` and Live View HTTP on `127.0.0.1:18080+slot`; WebRTC
continues to use the guest's Direct address. It checks the owned service root
and browser labels on every reconciliation. `relay disable`, `stop` and
`disable` stop forwarding. Run `relay enable` again after restarting the service.
Neither relay starts a VM, changes macOS privacy settings, nor installs a login job.
