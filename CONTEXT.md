# Context

**Local infrastructure session** — The interval between an explicit
`agentbrowse-infra enable` and `agentbrowse-infra disable`, backed by one
dedicated Apple-container application-data root. It is never started by
agentbrowse itself.
_Avoid: local daemon, fallback VM._

**Ownership receipt** — Machine-local evidence naming an exact image or other
resource created by agentbrowse-infra. A matching agentbrowse ownership label
is equivalent evidence for a Browser target.
_Avoid: cache manifest, cleanup allowlist._

**Runtime proof** — A bounded compatibility check for Rosetta, effective Linux
capabilities, direct TCP and UDP reachability, and `/dev/shm`. It requires an
already-enabled Local infrastructure session and cleans its probe containers.
_Avoid: health check, browser test._

**Direct address** — The host-reachable private IPv4 address Apple assigns to
one container. Local agentbrowse connections use it instead of Apple 0.8 port
publishing or an SSH tunnel.
_Avoid: published address, host port._
