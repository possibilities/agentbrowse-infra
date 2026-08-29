# Export a locked image from Artbird

The offline bootstrap path is an OCI image-layout archive, not Docker's legacy
`image save` format. Export only the exact `linux/amd64` platform digest recorded
in agentbrowse's image lock:

```sh
LOCKED_IMAGE='docker.io/onkernel/chromium-headful@sha256:da9ee68cb9d2de0b3c26885ff3bdcf04c944254a36eb127219028ac017ff56f3'
ARCHIVE="$PWD/kernel-headful.oci.tar"
scripts/export-artbird-image.zsh "$LOCKED_IMAGE" "$ARCHIVE"
```

The explicit maintainer helper uses the `artbird` Docker context and a
single-`FROM` Buildx export. It disables provenance and SBOM side manifests,
requests only `linux/amd64`, writes atomically, and refuses to overwrite an
existing path. Before publishing the archive it parses the OCI layout, verifies
every referenced blob, and requires the exported manifest digest to remain the
locked digest. A Buildx version that rewrites that manifest therefore fails
closed instead of producing an archive agentbrowse cannot address by its lock.

The helper neither starts Apple container services nor loads the result. On the
destination Mac, use the manual lifecycle:

```sh
bin/agentbrowse-infra enable
bin/agentbrowse-infra load "$ARCHIVE"
/usr/local/bin/container image inspect "$LOCKED_IMAGE"
bin/agentbrowse-infra disable
```

The final `inspect` is the compatibility gate: Apple must address the loaded
content by the same locked digest. Always finish with `disable`, which removes
the receipt-owned archive tag and digest alias and stops Apple services. The
`load` command creates that alias from the loaded image's inspected platform
digest; it never contacts a registry.

## Runtime proof

The complete locked-image round-trip passed on 2026-08-29 with Artbird online.
Buildx exported the exact manifest
`sha256:da9ee68cb9d2de0b3c26885ff3bdcf04c944254a36eb127219028ac017ff56f3`
as a 930-MiB OCI archive whose SHA-256 was
`b841f21e910e40211468b5e728f8782c76bf5bc49731259133139b823d7e15e2`.
Apple container 0.8.0 loaded it, `agentbrowse-infra load` created the
digest-addressable alias without a pull, and digest inspection succeeded.
Agentbrowse then started the Browser workload from that alias with 2 CPUs and
6 GiB, and Direct CDP plus Live View HTTP both answered at `192.168.64.2`.
Provider cleanup removed the target; `disable` removed both image references,
reclaimed 3.5 GB, stopped/unregistered Apple services, and removed the owned
application root.
