# Apple container 0.8.0 local fallback experiment

Test host: 16 GiB M4 MacBook Air, macOS, Apple `container` 0.8.0. macOS Local
Network permission remained denied.

## Results

| Gate | Result | Consequence |
| --- | --- | --- |
| Dedicated `--app-root` | Passed; idle root was about 14 MiB | Runtime state can be isolated and visibly reclaimed. |
| `linux/amd64` plus `--rosetta` | Passed; `uname -m` returned `x86_64` | The Chrome-for-Testing image can execute locally. |
| Effective capabilities | Passed; the process received the full capability mask | Docker's `--privileged` flag is not directly required for the tested namespace capabilities. |
| `/dev/shm` | Passed with `--tmpfs /dev/shm` | Apple sizes the tmpfs from guest memory; no Docker-style size option is needed. |
| Direct TCP and UDP | Passed over the container's `192.168.64.x` address | The local backend should return the Direct address. |
| Published TCP and UDP | Failed with reset/drop while Local Network permission was denied | Do not publish host ports in the secure configuration. |
| Built-in Apple builder, arm64 | Passed | Apple BuildKit itself works without Local Network permission. |
| Built-in Apple builder, amd64 | Failed; worker advertised only arm64 | Do not use `container build --platform linux/amd64`. |
| amd64 BuildKit container through Rosetta | Passed for a small OCI image | A no-Docker-daemon emergency build path is technically possible. |
| Exact Kernel/Neko source build | All Dockerfile stages passed; stopped during final OCI export at about 12.3 GiB combined logical usage | Routine enablement should pull from a registry or load an Artbird archive. |
| Exact published Kernel/Neko image | Passed CDP, Live View HTTP, WebRTC video, control, and input through Direct addresses | The local backend is workload-compatible without port publishing or SSH. |
| Apple OCI save/load | Passed with `alpine:3.22` and the locked Artbird-exported Kernel image across full disable and re-enable cycles | `load` receipts both the archive tag and a digest alias derived from inspected metadata, so the locked runtime reference works without a registry pull. |

The successful amd64 builder shape was one disposable
`moby/buildkit:buildx-stable-1` Apple container with two CPUs, 4 GiB memory,
Rosetta, and `--publish-socket`. Docker Buildx's remote driver connected to that
Unix socket. It required neither a Docker daemon nor macOS Local Network
permission.

## Resource behavior

The idle Apple services had no visible containers or images. A 512 MiB probe VM
was reclaimed after exact container deletion. The exact image build grew its
sparse builder disk to roughly 11 GiB before export; deleting the builder
returned the application-data root to 14 MiB immediately. All five exact probe
image references were then deleted, the service stopped, and the temporary
application-data root removed. Free disk returned to approximately 55 GiB.

The first offline-path check saved the owned `alpine:3.22` image as an
OCI-compatible tar archive and proved Apple's save/load half. The later live
Artbird check exported the locked Kernel platform digest through Docker Buildx,
loaded that archive after a full disable/re-enable cycle, created a
receipt-owned digest alias without a pull, and launched the Browser workload
from the exact runtime reference before final cleanup.

Apple 0.8.0 returns `[]` with exit status zero when inspecting a missing
container name, and a deleted fixed name can remain reserved after a service
restart even though the container inventory is empty. The Runtime proof treats
that exact empty result as absence and uses a unique, ownership-labeled name on
each run. A stopped service was also restarted through the explicit `enable`
path without losing its image receipt.

## Published image and Browser-target proof

Kernel's existing GitHub Actions workflow publishes `linux/amd64` images to
Docker Hub. Source commit `57858c774681c646c238043d5cb75a9ff61797c6` was
available as `onkernel/chromium-headful:57858c7`; its amd64 platform digest was
`sha256:da9ee68cb9d2de0b3c26885ff3bdcf04c944254a36eb127219028ac017ff56f3`.
Pinning the platform digest removes both tag mutability and the need for a
second registry.

Apple pulled that digest into about 3 GiB of local image storage. The exact
image started with two CPUs, 6 GiB memory, Rosetta, and `/dev/shm` tmpfs. No
ports were published. The container discovered its own Direct address before
executing `/wrapper` and exported that address as `NEKO_WEBRTC_NAT1TO1`; this is
the required local launch shape because Apple assigns the address at container
creation time.

At `192.168.64.2`, Live View HTTP and CDP were ready on the first check. CDP
reported Chrome 152.0.7977.42. Agentbrowse's existing headless native Live View
client then connected directly to port 8080, opened its data channel, decoded
and published a 1920×1080 video frame with zero failures, obtained control, and
sent one mapped pointer packet over WebRTC. macOS Local Network permission
remained denied throughout.

Targeted disable removed the labeled proof container and digest-pinned image,
reclaimed 3.51 GiB, stopped Apple services, and removed the marked application
root. Free disk returned to approximately 55 GiB.
