#!/bin/zsh

emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

readonly repo_root=${0:A:h:h}
readonly cli=$repo_root/bin/agentbrowse-infra
readonly installer=$repo_root/scripts/install.sh
readonly artbird_export=$repo_root/scripts/export-artbird-image.zsh

zsh -n "$cli"
zsh -n "$repo_root/tests/real-runtime.zsh"
/bin/bash -n "$installer"
zsh -n "$repo_root/tests/install.zsh"
zsh -n "$artbird_export"
zsh -n "$repo_root/tests/export-artbird-image.zsh"
[[ -x $cli ]] || {
  print -u2 -r -- "not executable: $cli"
  return 1
}
[[ -x $installer ]] || {
  print -u2 -r -- "not executable: $installer"
  return 1
}
[[ -x $repo_root/tests/install.zsh ]] || {
  print -u2 -r -- "not executable: $repo_root/tests/install.zsh"
  return 1
}
[[ -x $artbird_export ]] || {
  print -u2 -r -- "not executable: $artbird_export"
  return 1
}
[[ -x $repo_root/tests/export-artbird-image.zsh ]] || {
  print -u2 -r -- "not executable: $repo_root/tests/export-artbird-image.zsh"
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

"$repo_root/tests/install.zsh"
"$repo_root/tests/export-artbird-image.zsh"

print -r -- "validation passed"
