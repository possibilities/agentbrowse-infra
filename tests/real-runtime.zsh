#!/bin/zsh

emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

readonly repo_root=${0:A:h:h}
readonly cli=$repo_root/bin/agentbrowse-infra
readonly container_bin=${CONTAINER_BIN:-/usr/local/bin/container}
readonly infra_root=${AGENTBROWSE_INFRA_ROOT:-${HOME}/Library/Application Support/agentbrowse-infra}

[[ ${AGENTBROWSE_REAL_TESTS:-} == 1 ]] || {
  print -u2 -r -- 'Set AGENTBROWSE_REAL_TESTS=1 to run the Apple-container Runtime proof.'
  return 2
}

cleanup() {
  if [[ $("$container_bin" system status 2>&1) != *'apiserver is running'* && -e $infra_root ]]; then
    "$cli" enable >/dev/null 2>&1 || true
  fi
  "$cli" disable >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

"$cli" enable
"$cli" pull docker.io/library/alpine:3.22
"$container_bin" system stop >/dev/null
"$cli" enable
status_output=$("$cli" status --json)
[[ $status_output == *'"ready":true'* ]]
"$cli" prove
status_output=$("$cli" status --json)
[[ $status_output == *'"blockers":[]'* ]]
"$cli" disable
trap - EXIT INT TERM

[[ $("$container_bin" system status 2>&1) != *'apiserver is running'* ]]
[[ ! -e $infra_root ]]
print -r -- 'real-runtime validation passed; local infrastructure is disabled'
