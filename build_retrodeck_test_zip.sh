#!/usr/bin/env bash
# Build the experimental RetroDECK ARMHF bundle and local RetroDECK ZIP.
# This is intentionally separate from the generic PortMaster ZIP builder.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
# alpha|beta|stable: on top of that channel's latest PortMaster.zip, so only the tools, libraries and
# mod_RetroDECK.txt come from this checkout. local: everything from this checkout (./do_release.sh test).
CHANNEL="${1:-stable}"
case "$CHANNEL" in alpha|beta|stable|local) ;; *) echo "usage: $0 [alpha|beta|stable|local]" >&2; exit 2 ;; esac

case "$(uname -m)" in
  aarch64|arm64) TOOL_ARCH=aarch64; CONTAINER_ARCH=arm64 ;;
  x86_64|amd64) TOOL_ARCH=x86_64; CONTAINER_ARCH=amd64 ;;
  *) echo "Unsupported host architecture: $(uname -m)" >&2; exit 2 ;;
esac

command -v podman >/dev/null || { echo "podman is required" >&2; exit 1; }

umask 077
BUILD_ROOT="${RD_BUILD_CACHE_DIR:-$REPO_DIR/build/retrodeck-test-zip}"
mkdir -p "$BUILD_ROOT/podman-cache/$TOOL_ARCH" "$BUILD_ROOT/runs"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd)"
CACHE_ROOT="$BUILD_ROOT/podman-cache/$TOOL_ARCH/storage"
WORK_DIR="$(mktemp -d "$BUILD_ROOT/runs/retrodeck-test-zip.XXXXXX")"
mkdir -m 700 "$WORK_DIR/runtime" "$WORK_DIR/runroot" "$WORK_DIR/tmp"
export XDG_RUNTIME_DIR="$WORK_DIR/runtime"
export TMPDIR="$WORK_DIR/tmp"

# Preserve Podman's image/layer cache between runs, while keeping the runtime
# socket and runroot private to this invocation. Use the configured storage
# driver instead of forcing VFS, which duplicates layers and consumes extra disk.
podman_cmd=(podman --root "$CACHE_ROOT" --runroot "$WORK_DIR/runroot")
if [[ -n "${RD_PODMAN_STORAGE_DRIVER:-}" ]]; then
  podman_cmd+=(--storage-driver "$RD_PODMAN_STORAGE_DRIVER")
fi
echo "Podman build cache: $CACHE_ROOT"
df -h "$BUILD_ROOT"

cleanup() {
  [[ -d "$WORK_DIR" ]] || return 0

  # The cached image store is outside WORK_DIR, so this only removes files
  # created by the current host process and must not touch the persistent cache.
  rm -rf -- "$WORK_DIR" 2>/dev/null || {
    echo "Could not clean temporary build directory: $WORK_DIR" >&2
    return 1
  }
}
trap cleanup EXIT

mkdir -p "$WORK_DIR/tools/$TOOL_ARCH"
"${podman_cmd[@]}" build \
  --layers \
  --platform "linux/$CONTAINER_ARCH" \
  --build-arg "RETRODECK_ARCH=$TOOL_ARCH" \
  --file "$REPO_DIR/Dockerfile.retrodeck-tools" \
  --target artifact \
  --output "type=local,dest=$WORK_DIR/tools/$TOOL_ARCH" \
  "$REPO_DIR"

"${podman_cmd[@]}" build \
  --layers \
  --platform "linux/$CONTAINER_ARCH" \
  --file "$REPO_DIR/experimental/armhf-runtime/Dockerfile" \
  --target artifact \
  --output "type=local,dest=$WORK_DIR/armhf-runtime-output" \
  "$REPO_DIR/experimental/armhf-runtime"

"${podman_cmd[@]}" build \
  --layers \
  --platform "linux/$CONTAINER_ARCH" \
  --file "$REPO_DIR/experimental/armhf-runtime/Dockerfile.graphics" \
  --target artifact \
  --output "type=local,dest=$WORK_DIR/mesa-output" \
  "$REPO_DIR/experimental/armhf-runtime"

if [[ "$CHANNEL" == local ]]; then
  PM_DIST_DIR="${PM_DIST_DIR:-$REPO_DIR/dist}" "$REPO_DIR/do_release.sh" test
  release_args=()
else
  release_args=("$CHANNEL")
fi

RD_INCLUDE_ARMHF_EXPERIMENTAL=1 \
RD_RETRODECK_TOOLS_DIR="$WORK_DIR/tools" \
RD_ARMHF_RUNTIME_DIR="$WORK_DIR/armhf-runtime-output/armhf-runtime" \
RD_ARMHF_MESA_DIR="$WORK_DIR/mesa-output/armhf-mesa" \
PM_DIST_DIR="${PM_DIST_DIR:-$REPO_DIR/dist}" \
  "$REPO_DIR/do_retrodeck_release.sh" "${release_args[@]}"

echo "Experimental test ZIP: ${PM_DIST_DIR:-$REPO_DIR/dist}/retrodeck.portmaster.zip"
