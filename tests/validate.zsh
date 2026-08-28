#!/bin/zsh

emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

readonly repo_root=${0:A:h:h}
readonly cli=$repo_root/bin/agentbrowse-infra

zsh -n "$cli"
zsh -n "$repo_root/tests/real-runtime.zsh"
[[ -x $cli ]] || {
  print -u2 -r -- "not executable: $cli"
  return 1
}
[[ -x $repo_root/tests/real-runtime.zsh ]] || {
  print -u2 -r -- "not executable: $repo_root/tests/real-runtime.zsh"
  return 1
}

help=$($cli --help)
for command in enable pull load prove status disable; do
  [[ $help == *"$command"* ]] || {
    print -u2 -r -- "help omits $command"
    return 1
  }
done

grep -Fq -- 'dev.agentbrowse.infra' "$cli"
grep -Fq -- 'dev.agentbrowse.backend' "$cli"
grep -Fq -- 'refusing cleanup' "$cli"

print -r -- "validation passed"
