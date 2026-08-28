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

Apple 0.8.0 returns `[]` with exit status zero when inspecting a missing
container name, and a deleted fixed name can remain reserved after a service
restart even though the container inventory is empty. The Runtime proof treats
that exact empty result as absence and uses a unique, ownership-labeled name on
each run. A stopped service was also restarted through the explicit `enable`
path without losing its image receipt.

## Remaining workload proof

The exact final image was not loaded because the bounded build was canceled at
the disk ceiling. Once the exact SHA-tagged image is available from a registry
or Artbird OCI export, run the Browser-target proof: container start at two CPUs
and initially 6 GiB memory, CDP on 9222, Live View HTTP on 8080, and direct UDP
to Neko's configured mux port. Raise memory to 8 GiB only if readiness fails.
