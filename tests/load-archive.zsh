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
readonly foreign=foreign.example/browser:existing
readonly partial=onkernel/chromium-headful:partial-load

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
: > "$scratch/load.log"
: > "$scratch/delete.log"
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
    print -r -- "$FAKE_IMAGE_TAG" >> "$FAKE_LOAD_LOG"
    grep -Fqx -- "$FAKE_IMAGE_TAG" "$FAKE_IMAGE_STATE" \
      || print -r -- "$FAKE_IMAGE_TAG" >> "$FAKE_IMAGE_STATE"
    if [[ $FAKE_LOAD_MODE == partial-fail ]]; then
      print -u2 -r -- 'simulated partial load failure'
      exit 42
    fi
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
  'image delete')
    ref=$3
    grep -Fqx -- "$ref" "$FAKE_IMAGE_STATE" || exit 1
    print -r -- "$ref" >> "$FAKE_DELETE_LOG"
    if [[ $FAKE_DELETE_MODE == fail ]]; then
      print -u2 -r -- 'simulated image delete failure'
      exit 43
    fi
    grep -Fvx -- "$ref" "$FAKE_IMAGE_STATE" > "$FAKE_IMAGE_STATE.next" || true
    mv -- "$FAKE_IMAGE_STATE.next" "$FAKE_IMAGE_STATE"
    ;;
  *) exit 64 ;;
esac
EOF
chmod 755 "$fake_container"

run_cli() {
  AGENTBROWSE_INFRA_ROOT=$infra_root \
    CONTAINER_BIN=$fake_container \
    FAKE_IMAGE_STATE=$scratch/images \
    FAKE_IMAGE_TAG=${TEST_IMAGE_TAG:-$tag} \
    FAKE_IMAGE_DIGEST=$digest \
    FAKE_TAG_LOG=$scratch/tag.log \
    FAKE_LOAD_LOG=$scratch/load.log \
    FAKE_DELETE_LOG=$scratch/delete.log \
    FAKE_LOAD_MODE=${TEST_LOAD_MODE:-success} \
    FAKE_DELETE_MODE=${TEST_DELETE_MODE:-success} \
    "$cli" "$@"
}

print -r -- "$foreign" > "$scratch/images"
: > "$infra_root/owned-images"
if foreign_output=$(run_cli load "$archive" 2>&1); then
  fail "load accepted a pre-existing unreceipted image"
fi
[[ $foreign_output == *"pre-existing image lacks an ownership receipt: $foreign"* ]] \
  || fail "foreign pre-state refusal omitted the exact image"
[[ ! -s $scratch/load.log ]] || fail "foreign pre-state invoked image load"
[[ $(<$scratch/images) == $foreign ]] || fail "foreign pre-state was mutated"

print -r -- "$foreign" > "$scratch/images"
print -r -- "$foreign" > "$infra_root/owned-images"
: > "$scratch/delete.log"
if partial_output=$(TEST_IMAGE_TAG=$partial TEST_LOAD_MODE=partial-fail run_cli load "$archive" 2>&1); then
  fail "partially mutating image load unexpectedly succeeded"
else
  partial_status=$?
fi
[[ $partial_status == 42 ]] || fail "partial load did not preserve its original exit status"
[[ $partial_output == *'simulated partial load failure'* ]] \
  || fail "partial load did not preserve its original failure output"
grep -Fqx -- "$foreign" "$scratch/images" || fail "partial cleanup removed a pre-existing image"
[[ $(grep -Fxc -- "$partial" "$scratch/images") == 0 ]] \
  || fail "partial cleanup left an unreceipted image"
[[ $(<$infra_root/owned-images) == $foreign ]] \
  || fail "partial cleanup claimed or changed a pre-existing receipt"
[[ $(<$scratch/delete.log) == $partial ]] \
  || fail "partial cleanup did not delete exactly the newly created image"

print -r -- "$foreign" > "$scratch/images"
print -r -- "$foreign" > "$infra_root/owned-images"
: > "$scratch/delete.log"
if deferred_output=$(TEST_IMAGE_TAG=$partial TEST_LOAD_MODE=partial-fail TEST_DELETE_MODE=fail run_cli load "$archive" 2>&1); then
  fail "partially mutating image load with failed cleanup unexpectedly succeeded"
else
  deferred_status=$?
fi
[[ $deferred_status == 42 ]] \
  || fail "failed partial cleanup did not preserve the original load exit status"
[[ $deferred_output == *'simulated partial load failure'* ]] \
  || fail "failed partial cleanup did not preserve the original load output"
[[ $deferred_output == *"recorded it for later disable: $partial"* ]] \
  || fail "failed partial cleanup omitted the deferred ownership warning"
grep -Fqx -- "$foreign" "$scratch/images" \
  || fail "failed partial cleanup removed the foreign pre-state"
grep -Fqx -- "$partial" "$scratch/images" \
  || fail "failed partial cleanup unexpectedly lost the new image"
[[ $(grep -Fxc -- "$foreign" "$infra_root/owned-images") == 1 ]] \
  || fail "failed partial cleanup changed the foreign receipt"
[[ $(grep -Fxc -- "$partial" "$infra_root/owned-images") == 1 ]] \
  || fail "failed partial cleanup did not receipt the exact new image"
while IFS= read -r ref; do
  [[ -n $ref ]] || continue
  grep -Fqx -- "$ref" "$infra_root/owned-images" \
    || fail "failed partial cleanup left an unreceipted image: $ref"
done < "$scratch/images"
[[ $(<$scratch/delete.log) == $partial ]] \
  || fail "failed partial cleanup attempted deletion of the wrong image"

: > "$scratch/images"
: > "$infra_root/owned-images"
: > "$scratch/load.log"
: > "$scratch/delete.log"

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
