# 0001: Keep the Apple container runtime manual and directly addressed

Only `agentbrowse-infra enable` may start Apple container services, and
`disable` removes ownership-proven resources before stopping them. Agentbrowse
will passively select an already-enabled local backend and use each container's
host-reachable Direct address, avoiding both SSH and macOS Local Network
permission.
