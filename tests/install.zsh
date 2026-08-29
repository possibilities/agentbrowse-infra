#!/bin/zsh

emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

readonly repo_root=${0:A:h:h}
readonly installer=$repo_root/scripts/install.sh
readonly source_command=$repo_root/bin/agentbrowse-infra
readonly expected_sha=$(git -C "$repo_root" rev-parse HEAD)
readonly temp_parent=${${TMPDIR:-/tmp}%/}
readonly scratch=$(mktemp -d "$temp_parent/agentbrowse-infra-install.XXXXXX")

cleanup() {
  [[ -n $scratch && $scratch == /*/agentbrowse-infra-install.* ]] || return 1
  rm -rf -- "$scratch"
}
trap cleanup EXIT INT TERM

fail() {
  print -u2 -r -- "installer test: $*"
  return 1
}

new_layout() {
  local name=$1 root=$scratch/$1
  mkdir -p -- "$root/bin" "$root/state"
  chmod 700 "$root"
  chmod 755 "$root/bin"
  chmod 700 "$root/state"
  print -r -- "$root"
}

run_installer() {
  local root=$1
  shift
  AGENTBROWSE_INFRA_INSTALL_BIN_DIR=$root/bin \
    AGENTBROWSE_INFRA_INSTALL_STATE_DIR=$root/state \
    "$installer" "$@"
}

assert_refusal() {
  local expected=$1 root=$2 output
  shift 2
  if output=$(run_installer "$root" "$@" 2>&1); then
    fail "installer unexpectedly succeeded: $output"
  fi
  [[ $output == *$expected* ]] || fail "refusal omitted '$expected': $output"
}

layout=$(new_layout normal)
run_installer "$layout" --install >/dev/null
[[ -L $layout/bin/agentbrowse-infra ]] || fail "installed command is not a symlink"
[[ $(readlink "$layout/bin/agentbrowse-infra") == $source_command ]] || fail "installed command points at the wrong source"
[[ $(<$layout/state/deployed-sha) == $expected_sha ]] || fail "deployed receipt records the wrong SHA"
[[ $(stat -f %Lp "$layout/state/deployed-sha") == 600 ]] || fail "deployed receipt mode is not 0600"
first_inode=$(stat -f %i "$layout/state/deployed-sha")
run_installer "$layout" --install >/dev/null
[[ $(stat -f %i "$layout/state/deployed-sha") != $first_inode ]] || fail "repeat install did not replace the receipt atomically"

foreign=$(new_layout foreign-command)
print -r -- foreign > "$foreign/bin/agentbrowse-infra"
assert_refusal "refusing foreign command path" "$foreign" --install
[[ $(<$foreign/bin/agentbrowse-infra) == foreign ]] || fail "foreign command was changed"

foreign_link=$(new_layout foreign-link)
ln -s /bin/echo "$foreign_link/bin/agentbrowse-infra"
assert_refusal "refusing foreign command symlink" "$foreign_link" --install
[[ $(readlink "$foreign_link/bin/agentbrowse-infra") == /bin/echo ]] || fail "foreign symlink was changed"

uncorroborated=$(new_layout uncorroborated-receipt)
print -r -- "$expected_sha" > "$uncorroborated/state/deployed-sha"
chmod 600 "$uncorroborated/state/deployed-sha"
assert_refusal "uncorroborated deployed receipt" "$uncorroborated" --install
[[ -f $uncorroborated/state/deployed-sha ]] || fail "uncorroborated receipt was removed"

unsafe=$(new_layout unsafe-directory)
chmod 777 "$unsafe/bin"
assert_refusal "unsafe writable bin directory" "$unsafe" --install
[[ ! -e $unsafe/bin/agentbrowse-infra ]] || fail "unsafe destination was mutated"

wrong_origin=$(new_layout wrong-origin)
if output=$(AGENTBROWSE_INFRA_INSTALL_BIN_DIR=$wrong_origin/bin \
  AGENTBROWSE_INFRA_INSTALL_STATE_DIR=$wrong_origin/state \
  AGENTBROWSE_INFRA_INSTALL_EXPECTED_ORIGIN=https://example.invalid/foreign.git \
  "$installer" --install 2>&1); then
  fail "foreign origin unexpectedly succeeded: $output"
fi
[[ $output == *"source with foreign origin"* ]] || fail "foreign-origin refusal was unclear: $output"
[[ ! -e $wrong_origin/bin/agentbrowse-infra ]] || fail "foreign-origin attempt installed a command"

no_runtime=$(new_layout no-runtime)
fake_bin=$no_runtime/fake-bin
mkdir -p -- "$fake_bin"
cat > "$fake_bin/container" <<EOF
#!/bin/sh
touch "$no_runtime/runtime-invoked"
exit 99
EOF
chmod 755 "$fake_bin/container"
PATH="$fake_bin:$PATH" run_installer "$no_runtime" --install >/dev/null
[[ ! -e $no_runtime/runtime-invoked ]] || fail "installer invoked Apple container"

run_installer "$layout" --uninstall >/dev/null
[[ ! -e $layout/bin/agentbrowse-infra && ! -L $layout/bin/agentbrowse-infra ]] || fail "uninstall retained the command"
[[ ! -e $layout/state/deployed-sha ]] || fail "uninstall retained the receipt"
run_installer "$layout" --uninstall >/dev/null

print -r -- "installer tests passed"
