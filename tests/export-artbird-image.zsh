#!/bin/zsh

emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

readonly repo_root=${0:A:h:h}
readonly helper=$repo_root/scripts/export-artbird-image.zsh
readonly temp_parent=${${TMPDIR:-/tmp}%/}
readonly scratch=$(mktemp -d "$temp_parent/agentbrowse-artbird-export.XXXXXX")

cleanup() {
  [[ -n $scratch && $scratch == /*/agentbrowse-artbird-export.* ]] || return 1
  rm -rf -- "$scratch"
}
trap cleanup EXIT INT TERM

fail() {
  print -u2 -r -- "Artbird export test: $*"
  return 1
}

blob_digest() {
  local output
  output=$(/usr/bin/shasum -a 256 "$1")
  print -r -- sha256:${output%% *}
}

blob_size() {
  stat -f %z "$1"
}

make_fixture() {
  local root=$1
  local content=$root/content layout=$root/layout
  local config_digest layer_digest manifest_digest archive_ref
  mkdir -p -- "$content" "$layout/blobs/sha256"
  print -nr -- '{"architecture":"amd64","os":"linux"}' > "$content/config.json"
  print -nr -- 'fixture-layer' > "$content/layer.tar"
  config_digest=$(blob_digest "$content/config.json")
  layer_digest=$(blob_digest "$content/layer.tar")
  print -nr -- '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"'$config_digest'","size":'$(blob_size "$content/config.json")'},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"'$layer_digest'","size":'$(blob_size "$content/layer.tar")'}]}' > "$content/manifest.json"
  manifest_digest=$(blob_digest "$content/manifest.json")
  archive_ref=docker.io/example/browser:agentbrowse-offline-${${manifest_digest#sha256:}[1,12]}
  print -nr -- '{"imageLayoutVersion":"1.0.0"}' > "$layout/oci-layout"
  print -nr -- '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"'$manifest_digest'","size":'$(blob_size "$content/manifest.json")',"platform":{"architecture":"amd64","os":"linux"},"annotations":{"io.containerd.image.name":"'$archive_ref'","org.opencontainers.image.ref.name":"'${archive_ref##*:}'"}}]}' > "$layout/index.json"
  cp "$content/config.json" "$layout/blobs/sha256/${config_digest#sha256:}"
  cp "$content/layer.tar" "$layout/blobs/sha256/${layer_digest#sha256:}"
  cp "$content/manifest.json" "$layout/blobs/sha256/${manifest_digest#sha256:}"
  /usr/bin/tar -cf "$root/fixture.oci.tar" -C "$layout" oci-layout index.json blobs
  print -r -- "$manifest_digest"
}

readonly fixture_root=$scratch/fixture
readonly manifest_digest=$(make_fixture "$fixture_root")
readonly locked_image=docker.io/example/browser@$manifest_digest
readonly fake_docker=$scratch/docker
readonly docker_log=$scratch/docker.log
readonly context_log=$scratch/context.log

cat > "$fake_docker" <<'EOF'
#!/bin/zsh
emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
if [[ $1 == context && $2 == inspect ]]; then
  print -r -- "$3" > "$FAKE_CONTEXT_LOG"
  exit 0
fi
print -rl -- "$@" > "$FAKE_DOCKER_LOG"
typeset output='' context_dir=${@[-1]} argument
for argument in "$@"; do
  [[ $argument == type=oci,dest=* ]] && output=${argument#type=oci,dest=}
done
[[ -n $output ]] || exit 90
cp "$FAKE_OCI_ARCHIVE" "$output"
cp "$context_dir/Dockerfile" "$FAKE_DOCKERFILE_LOG"
EOF
chmod 755 "$fake_docker"

run_helper() {
  FAKE_OCI_ARCHIVE=$fixture_root/fixture.oci.tar \
    FAKE_DOCKER_LOG=$docker_log \
    FAKE_CONTEXT_LOG=$context_log \
    FAKE_DOCKERFILE_LOG=$scratch/Dockerfile.seen \
    DOCKER_BIN=$fake_docker \
    ARTBIRD_DOCKER_CONTEXT=artbird \
    "$helper" "$@"
}

assert_no_export_workdir() {
  local -a leftovers
  leftovers=("$scratch"/.agentbrowse-image-export.*(N))
  (( $#leftovers == 0 )) || fail "helper left an export work directory: $leftovers"
}

output=$scratch/browser.oci.tar
run_helper "$locked_image" "$output" >/dev/null
assert_no_export_workdir
[[ -s $output ]] || fail "helper did not publish an archive"
[[ $(<$context_log) == artbird ]] || fail "helper inspected the wrong Docker context"
grep -Fqx -- '--context' "$docker_log" || fail "Buildx invocation omitted the Docker context option"
grep -Fqx -- 'artbird' "$docker_log" || fail "Buildx invocation omitted the Artbird context"
grep -Fqx -- '--pull' "$docker_log" || fail "Buildx invocation omitted --pull"
grep -Fqx -- '--platform' "$docker_log" || fail "Buildx invocation omitted the platform option"
grep -Fqx -- 'linux/amd64' "$docker_log" || fail "Buildx invocation selected the wrong platform"
grep -Fqx -- '--provenance=false' "$docker_log" || fail "Buildx invocation did not disable provenance manifests"
grep -Fqx -- "FROM $locked_image" "$scratch/Dockerfile.seen" || fail "Dockerfile does not use the locked digest"

if run_helper docker.io/example/browser:mutable "$scratch/mutable.tar" >/dev/null 2>&1; then
  fail "mutable image reference was accepted"
fi
assert_no_export_workdir
[[ ! -e $scratch/mutable.tar ]] || fail "mutable image refusal left output"

if run_helper "$locked_image" "$output" >/dev/null 2>&1; then
  fail "existing output was overwritten"
fi
assert_no_export_workdir

wrong_digest=sha256:$(printf '%064d' 1)
if run_helper "docker.io/example/browser@$wrong_digest" "$scratch/wrong-digest.tar" >/dev/null 2>&1; then
  fail "archive with a changed manifest digest was accepted"
fi
assert_no_export_workdir
[[ ! -e $scratch/wrong-digest.tar ]] || fail "digest mismatch left output"

print -r -- not-a-tar > "$scratch/not-a-tar"
if FAKE_OCI_ARCHIVE=$scratch/not-a-tar \
  FAKE_DOCKER_LOG=$docker_log \
  FAKE_CONTEXT_LOG=$context_log \
  FAKE_DOCKERFILE_LOG=$scratch/Dockerfile.seen \
  DOCKER_BIN=$fake_docker \
  "$helper" "$locked_image" "$scratch/malformed.tar" >/dev/null 2>&1; then
  fail "malformed archive was accepted"
fi
assert_no_export_workdir
[[ ! -e $scratch/malformed.tar ]] || fail "malformed archive left output"

print -r -- "Artbird export tests passed"
