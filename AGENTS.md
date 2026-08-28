# Agent guidance

This repository owns the manually controlled local infrastructure used by
agentbrowse when its remote browser farm is unavailable.

- Apple `container` is the only supported local runtime. Do not introduce a
  resident daemon or a Docker-compatible VM without a new decision.
- No command except the explicit `enable` command may start Apple container
  services. In particular, status, proof, and agentbrowse provider paths must
  fail when the service is disabled.
- Cleanup is ownership based. A resource is removable only when an exact
  receipt or an agentbrowse ownership label proves it. Being stored beneath
  the dedicated application-data root is not sufficient proof.
- Keep real-runtime tests opt-in, bounded to one small VM at a time, and leave
  the service disabled after tests that enabled it.
- The supported host is macOS on Apple silicon. Keep the command line free of
  non-system runtime dependencies.
