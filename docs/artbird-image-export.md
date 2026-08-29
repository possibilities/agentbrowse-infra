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
the receipt-owned loaded image and stops Apple services.

## Current proof boundary

Apple container 0.8.0 has already completed a save, full disable, re-enable,
load, and cleanup round-trip for a small OCI archive. The Artbird-produced
archive round-trip remains pending because SSH to Artbird timed out on
2026-08-28 and again on 2026-08-29. The helper's command construction and OCI
validation are covered hermetically, but do not claim the offline bootstrap as
runtime-proved until the commands above succeed with Artbird online and the
locked Kernel image.
