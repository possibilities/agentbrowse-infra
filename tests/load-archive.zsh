#!/bin/zsh

emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

readonly repo_root=${0:A:h:h}
readonly cli=$repo_root/bin/agentbrowse-infra
readonly created_scratch=$(mktemp -d "${${TMPDIR:-/tmp}%/}/agentbrowse-load-test.XXXXXX")
readonly scratch=$(cd -q -- "$created_scratch" && pwd -P)
readonly infra_root=$scratch/agentbrowse-infra
readonly fake_container=$scratch/container
readonly archive=$scratch/image.oci.tar
readonly digest=sha256:da9ee68cb9d2de0b3c26885ff3bdcf04c944254a36eb127219028ac017ff56f3
readonly tag=onkernel/chromium-headful:agentbrowse-offline-da9ee68cb9d2
readonly alias=onkernel/chromium-headful@$digest

cleanup() {
  [[ $scratch == /*/agentbrowse-load-test.* ]] || return 1
  rm -rf -- "$scratch"
}
trap cleanup EXIT INT TERM

fail() {
  print -u2 -r -- "load archive test: $*"
  return 1
}

mkdir -p -- "$infra_root"
print -r -- agentbrowse-infra-owned-v1 > "$infra_root/OWNED"
: > "$infra_root/owned-images"
: > "$scratch/images"
: > "$scratch/tag.log"
print -r -- fixture > "$archive"

cat > "$fake_container" <<'EOF'
#!/bin/zsh
emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

case "$1 $2" in
  'system status')
    print -r -- 'apiserver is running'
    print -r -- "application data root: $AGENTBROWSE_INFRA_ROOT/runtime"
    ;;
  'image list')
    [[ $3 == --quiet ]] || exit 64
    cat "$FAKE_IMAGE_STATE"
    ;;
  'image load')
    grep -Fqx -- "$FAKE_IMAGE_TAG" "$FAKE_IMAGE_STATE" \
      || print -r -- "$FAKE_IMAGE_TAG" >> "$FAKE_IMAGE_STATE"
    print -r -- "Loaded images: $FAKE_IMAGE_TAG"
    ;;
  'image inspect')
    ref=$3
    grep -Fqx -- "$ref" "$FAKE_IMAGE_STATE" || exit 1
    if [[ $ref == *:* && $ref != *@* ]]; then
      print -r -- '[{"name":"docker.io/onkernel/chromium-headful:agentbrowse-offline-da9ee68cb9d2","index":{"digest":"'$FAKE_IMAGE_DIGEST'"}}]'
    else
      print -r -- '[]'
    fi
    ;;
  'image tag')
    grep -Fqx -- "$3" "$FAKE_IMAGE_STATE" || exit 1
    print -r -- "$4" >> "$FAKE_IMAGE_STATE"
    print -r -- "$3 -> $4" >> "$FAKE_TAG_LOG"
    ;;
  *) exit 64 ;;
esac
EOF
chmod 755 "$fake_container"

run_cli() {
  AGENTBROWSE_INFRA_ROOT=$infra_root \
    CONTAINER_BIN=$fake_container \
    FAKE_IMAGE_STATE=$scratch/images \
    FAKE_IMAGE_TAG=$tag \
    FAKE_IMAGE_DIGEST=$digest \
    FAKE_TAG_LOG=$scratch/tag.log \
    "$cli" "$@"
}

run_cli load "$archive" >/dev/null
grep -Fqx -- "$tag" "$infra_root/owned-images" \
  || fail "loaded tag was not receipted"
grep -Fqx -- "$alias" "$infra_root/owned-images" \
  || fail "digest alias was not receipted"
grep -Fqx -- "$alias" "$scratch/images" \
  || fail "digest alias was not created"
grep -Fqx -- "$tag -> $alias" "$scratch/tag.log" \
  || fail "digest alias used the wrong source or target"

run_cli load "$archive" >/dev/null
[[ $(grep -Fxc -- "$alias" "$scratch/images") == 1 ]] \
  || fail "repeated load duplicated the digest alias"
[[ $(grep -Fxc -- "$alias" "$infra_root/owned-images") == 1 ]] \
  || fail "repeated load duplicated the receipt"

print -r -- "load archive tests passed"
