#!/bin/zsh

emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

readonly PROGRAM=${0:t}
readonly DOCKER_BIN=${DOCKER_BIN:-docker}
readonly ARTBIRD_DOCKER_CONTEXT=${ARTBIRD_DOCKER_CONTEXT:-artbird}
typeset work_root=''

fail() {
  print -u2 -r -- "$PROGRAM: $*"
  return 1
}

cleanup() {
  [[ -n $work_root ]] || return 0
  [[ $work_root == /*/.agentbrowse-image-export.* ]] || {
    print -u2 -r -- "$PROGRAM: refusing cleanup of unexpected path: $work_root"
    return 1
  }
  rm -rf -- "$work_root"
}
trap cleanup EXIT INT TERM

usage() {
  cat <<'EOF'
Usage: export-artbird-image.zsh IMAGE@sha256:DIGEST OUTPUT.oci.tar

Export one exact linux/amd64 image from the Artbird Docker context as an OCI
archive. The output must not exist. The helper rejects mutable tags and rejects
an archive whose exported manifest digest differs from the requested digest.

Environment:
  DOCKER_BIN                Docker CLI (default: docker)
  ARTBIRD_DOCKER_CONTEXT    Docker context (default: artbird)
EOF
}

archive_member_present() {
  local member=$1 list=$2
  grep -Fqx -- "$member" "$list"
}

verify_blob() {
  local archive=$1 list=$2 digest=$3 destination=$4
  local hex member actual

  [[ $digest =~ '^sha256:[0-9a-f]{64}$' ]] || fail "archive contains a non-sha256 blob digest: $digest"
  hex=${digest#sha256:}
  member=blobs/sha256/$hex
  archive_member_present "$member" "$list" || fail "archive omits referenced blob: $digest"
  /usr/bin/tar -xOf "$archive" "$member" > "$destination" || fail "could not read referenced blob: $digest"
  actual=$(/usr/bin/shasum -a 256 "$destination")
  actual=${actual%% *}
  [[ $actual == $hex ]] || fail "archive blob content does not match its digest: $digest"
}

validate_oci_archive() {
  local archive=$1 expected_digest=$2 expected_ref=$3 validation=$4
  local layout=$validation/oci-layout index=$validation/index.json list=$validation/archive.list
  local manifest=$validation/manifest.json config=$validation/config.json layer=$validation/layer
  local version schema manifest_digest os arch compact archive_tag config_digest layer_digest
  local layer_index=0

  [[ -s $archive && ! -L $archive ]] || fail "Buildx did not create a regular nonempty archive"
  /usr/bin/tar -tf "$archive" > "$list" || fail "Buildx output is not a readable tar archive"
  archive_member_present oci-layout "$list" || fail "archive omits oci-layout"
  archive_member_present index.json "$list" || fail "archive omits index.json"
  /usr/bin/tar -xOf "$archive" oci-layout > "$layout" || fail "could not read oci-layout"
  /usr/bin/tar -xOf "$archive" index.json > "$index" || fail "could not read index.json"

  version=$(/usr/bin/plutil -extract imageLayoutVersion raw -o - -- "$layout" 2>/dev/null) || fail "archive has malformed oci-layout JSON"
  [[ $version == 1.0.0 ]] || fail "archive uses unsupported OCI layout version: $version"
  schema=$(/usr/bin/plutil -extract schemaVersion raw -o - -- "$index" 2>/dev/null) || fail "archive has malformed index.json"
  [[ $schema == 2 ]] || fail "archive index uses unsupported schema version: $schema"
  manifest_digest=$(/usr/bin/plutil -extract manifests.0.digest raw -o - -- "$index" 2>/dev/null) || fail "archive index has no image manifest"
  if /usr/bin/plutil -extract manifests.1.digest raw -o - -- "$index" >/dev/null 2>&1; then
    fail "archive index contains more than one manifest"
  fi
  [[ $manifest_digest == $expected_digest ]] || fail "export changed the locked manifest digest: expected $expected_digest, found $manifest_digest"
  os=$(/usr/bin/plutil -extract manifests.0.platform.os raw -o - -- "$index" 2>/dev/null) || fail "archive manifest omits its operating system"
  arch=$(/usr/bin/plutil -extract manifests.0.platform.architecture raw -o - -- "$index" 2>/dev/null) || fail "archive manifest omits its architecture"
  [[ $os == linux && $arch == amd64 ]] || fail "archive platform is $os/$arch, not linux/amd64"
  compact=$(tr -d '[:space:]' < "$index")
  archive_tag=${expected_ref##*:}
  [[ $compact == *\"io.containerd.image.name\":\"$expected_ref\"* ]] || \
    fail "archive index omits the expected containerd image name: $expected_ref"
  [[ $compact == *\"org.opencontainers.image.ref.name\":\"$archive_tag\"* ]] || \
    fail "archive index omits the expected OCI reference name: $archive_tag"

  verify_blob "$archive" "$list" "$manifest_digest" "$manifest"
  config_digest=$(/usr/bin/plutil -extract config.digest raw -o - -- "$manifest" 2>/dev/null) || fail "image manifest omits its config digest"
  verify_blob "$archive" "$list" "$config_digest" "$config"
  while layer_digest=$(/usr/bin/plutil -extract layers.$layer_index.digest raw -o - -- "$manifest" 2>/dev/null); do
    verify_blob "$archive" "$list" "$layer_digest" "$layer.$layer_index"
    (( layer_index += 1 ))
  done
  (( layer_index > 0 )) || fail "image manifest contains no layers"
}

export_image() {
  local image=$1 output=$2 repository digest digest_hex archive_ref output_parent
  local context_dir archive validation archive_sha

  [[ $image =~ '^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)+@sha256:[0-9a-f]{64}$' ]] || \
    fail "IMAGE must be a canonical registry/repository reference pinned by a full sha256 digest"
  repository=${image%@sha256:*}
  digest=${image##*@}
  digest_hex=${digest#sha256:}
  archive_ref=${repository}:agentbrowse-offline-${digest_hex[1,12]}

  [[ $output == /* && $output != / && $output != *//* && $output != */../* && $output != */.. && $output != */./* && $output != */. ]] || \
    fail "OUTPUT must be a normalized absolute path"
  [[ ! -e $output && ! -L $output ]] || fail "refusing to overwrite output: $output"
  output_parent=${output:h}
  [[ -d $output_parent && ! -L $output_parent ]] || fail "output parent is not a regular directory: $output_parent"
  [[ -w $output_parent ]] || fail "output parent is not writable: $output_parent"
  [[ $ARTBIRD_DOCKER_CONTEXT =~ '^[A-Za-z0-9][A-Za-z0-9_.-]*$' ]] || fail "invalid Docker context name: $ARTBIRD_DOCKER_CONTEXT"
  command -v "$DOCKER_BIN" >/dev/null 2>&1 || fail "Docker CLI was not found: $DOCKER_BIN"
  "$DOCKER_BIN" context inspect "$ARTBIRD_DOCKER_CONTEXT" >/dev/null || fail "Docker context is unavailable: $ARTBIRD_DOCKER_CONTEXT"

  work_root=$(mktemp -d "$output_parent/.agentbrowse-image-export.XXXXXX")
  context_dir=$work_root/context
  archive=$work_root/archive.oci.tar
  validation=$work_root/validation
  mkdir -p -- "$context_dir" "$validation"
  print -r -- "FROM $image" > "$context_dir/Dockerfile"

  "$DOCKER_BIN" --context "$ARTBIRD_DOCKER_CONTEXT" buildx build \
    --pull \
    --platform linux/amd64 \
    --provenance=false \
    --sbom=false \
    --progress=plain \
    --tag "$archive_ref" \
    --output "type=oci,dest=$archive" \
    "$context_dir"

  validate_oci_archive "$archive" "$digest" "$archive_ref" "$validation"
  [[ ! -e $output && ! -L $output ]] || fail "output appeared during export; refusing to overwrite it: $output"
  ln -- "$archive" "$output" || fail "could not publish archive without overwriting: $output"
  rm -f -- "$archive"
  archive_sha=$(/usr/bin/shasum -a 256 "$output")
  archive_sha=${archive_sha%% *}
  print -r -- "exported $image"
  print -r -- "archive reference: $archive_ref"
  print -r -- "archive sha256: $archive_sha"
  print -r -- "output: $output"
}

if [[ $# == 1 && ( $1 == --help || $1 == -h ) ]]; then
  usage
  exit 0
fi
[[ $# == 2 ]] || {
  usage >&2
  exit 2
}
export_image "$1" "$2"
