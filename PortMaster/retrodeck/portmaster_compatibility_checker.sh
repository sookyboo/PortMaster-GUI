#!/bin/bash
# Read-only PortMaster CFW compatibility audit, adapted for RetroDECK Flatpak.
# Research credit: bmdhacks — https://gist.github.com/bmdhacks/f26dbb60dc0ff0b9bc8e043fac8b813b
VERSION=1.0
SOURCE_URL=https://gist.github.com/bmdhacks/f26dbb60dc0ff0b9bc8e043fac8b813b
ARCH_REQUEST=auto DEEP=0 REPORT_OUT= TSV_OUT= VERBOSE=0 FAILURES=0 WARNINGS=0
declare -a IDS=() STATUSES=() ARCHES=() DETAILS=() FIXES=()

usage() { printf 'Usage: %s [--arch auto|aarch64|armhf|all] [--deep] [--report FILE] [--tsv FILE]\n' "$0"; }
while (($#)); do
  case "$1" in
    --arch) (($# >= 2)) || { usage >&2; exit 2; }; ARCH_REQUEST=$2; shift 2 ;;
    --deep) DEEP=1; shift ;;
    --report) (($# >= 2)) || { usage >&2; exit 2; }; REPORT_OUT=$2; shift 2 ;;
    --tsv) (($# >= 2)) || { usage >&2; exit 2; }; TSV_OUT=$2; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$ARCH_REQUEST" in auto|aarch64|armhf|all) ;; *) usage >&2; exit 2 ;; esac
is_flatpak() { [[ -n ${FLATPAK_ID:-} || -e /.flatpak-info ]]; }
scope_status() { if is_flatpak; then printf UNKNOWN; else printf '%s' "$1"; fi; }
record() {
  local id=$1 status=$2 arch=$3 detail=$4 fix=${5:-}
  IDS+=("$id"); STATUSES+=("$status"); ARCHES+=("$arch"); DETAILS+=("$detail"); FIXES+=("$fix")
  [[ $status == FAIL ]] && ((FAILURES+=1)); [[ $status == WARN ]] && ((WARNINGS+=1))
  if ((VERBOSE)) || [[ $status != PASS ]]; then printf '[%-7s] %-30s %-8s %s\n' "$status" "$id" "$arch" "$detail"; fi
}
has() { command -v "$1" >/dev/null 2>&1; }
check_cmd() {
  local name=$1 level=$2 path
  if ! has "$name"; then record "tool.$name" "$(scope_status "$level")" runtime 'Not visible in the RetroDECK runtime' 'Check the host firmware environment'; return; fi
  path=$(command -v "$name")
  if [[ $path == *busybox* ]]; then record "tool.$name" WARN runtime "BusyBox implementation: $path" 'Some options may differ from GNU tools'; else record "tool.$name" PASS runtime "$path"; fi
}
host_arch=$(uname -m 2>/dev/null || printf unknown)
case "$host_arch" in aarch64|arm64) native=aarch64 ;; armv*|arm) native=armhf ;; *) native=unknown ;; esac
declare -a TARGETS=()
case "$ARCH_REQUEST" in auto) [[ $native != unknown ]] && TARGETS+=("$native"); [[ $native == aarch64 ]] && TARGETS+=(armhf) ;; all) TARGETS=(aarch64 armhf) ;; *) TARGETS=("$ARCH_REQUEST") ;; esac
if is_flatpak; then record runtime.scope PASS runtime 'Flatpak sandbox; host files and devices may be hidden'; else record runtime.scope PASS runtime 'Direct system inspection'; fi
if [[ -x /bin/bash ]] && /bin/bash -c '[[ ${BASH_VERSINFO[0]} -ge 4 ]] && a=(ok) && [[ ${a[0],,} == ok ]]' >/dev/null 2>&1; then record shell.bash PASS runtime '/bin/bash supports required Bash features'; else record shell.bash FAIL runtime 'Compatible /bin/bash unavailable'; fi
for cmd in sed chmod mkdir cp mv rm ln cat tee sleep ls find grep awk tr cut head tail wc xargs md5sum tar unzip gzip gunzip mount umount; do check_cmd "$cmd" FAIL; done
for cmd in kill pidof pkill killall systemctl dos2unix xdelta3 dialog rsync 7z innoextract ffmpeg ar getconf swaymsg pw-metadata zramctl mkswap swapon swapoff dd strace gdb htop vmstat valgrind mksquashfs unsquashfs vim ldd readelf file perf; do check_cmd "$cmd" WARN; done
if has sudo || has doas; then record privilege.helper PASS runtime 'sudo/doas found; authorization not tested'; else record privilege.helper "$(scope_status FAIL)" runtime 'Neither sudo nor doas is visible'; fi
if has python3; then if python3 -c 'import lzma' >/dev/null 2>&1; then record python.lzma PASS runtime 'Python 3 lzma import succeeds'; else record python.lzma FAIL runtime 'Python 3 lacks lzma support'; fi; else record python.lzma "$(scope_status FAIL)" runtime 'python3 unavailable'; fi

kernel_flag() {
  local flag=$1 severity=$2 value=
  if [[ -r /proc/config.gz ]] && has gzip; then value=$(gzip -dc /proc/config.gz 2>/dev/null | grep -m1 -E "^${flag}=" || :)
  elif [[ -r /boot/config-$(uname -r) ]]; then value=$(grep -m1 -E "^${flag}=" "/boot/config-$(uname -r)" 2>/dev/null || :); fi
  case "$value" in "$flag=y"|"$flag=m") record "kernel.$flag" PASS kernel "$value" ;; '') record "kernel.$flag" "$(scope_status UNKNOWN)" kernel 'Kernel configuration unavailable; capability may still exist at runtime' ;; *) record "kernel.$flag" "$severity" kernel "$value" ;; esac
}
for k in CONFIG_SQUASHFS CONFIG_SQUASHFS_ZLIB CONFIG_SQUASHFS_LZO CONFIG_SQUASHFS_XZ CONFIG_SQUASHFS_ZSTD CONFIG_BLK_DEV_LOOP CONFIG_INPUT_UINPUT; do kernel_flag "$k" FAIL; done
for k in CONFIG_ZRAM CONFIG_SWAP CONFIG_EXFAT_FS CONFIG_COMPAT CONFIG_PERF_EVENTS; do kernel_flag "$k" WARN; done
if [[ -e /dev/uinput ]]; then [[ -r /dev/uinput && -w /dev/uinput ]] && record input.uinput PASS system 'uinput accessible to current user' || record input.uinput WARN system 'uinput exists but is not read/write accessible'; else record input.uinput "$(scope_status FAIL)" system '/dev/uinput unavailable'; fi
if [[ -r /proc/filesystems ]] && grep -qw squashfs /proc/filesystems; then record fs.squashfs PASS system 'squashfs supported'; else record fs.squashfs "$(scope_status WARN)" system 'squashfs not visible in /proc/filesystems'; fi
if [[ -e /dev/loop-control || -e /dev/loop0 ]]; then record fs.loop PASS system 'loop devices exposed'; else record fs.loop "$(scope_status WARN)" system 'No loop device nodes visible'; fi
for p in /tmp /dev/shm; do [[ -d $p && -w $p ]] && record "fs.${p##*/}" PASS runtime "$p writable" || record "fs.${p##*/}" FAIL runtime "$p absent or unwritable"; done
[[ -n ${LD_PRELOAD:-} ]] && record conflict.ld_preload WARN runtime 'LD_PRELOAD is set' 'Avoid injecting libraries into PortMaster' || record conflict.ld_preload PASS runtime 'No inherited LD_PRELOAD'
[[ -n ${LD_LIBRARY_PATH:-} ]] && record conflict.library_path WARN runtime 'Inherited LD_LIBRARY_PATH is set' 'Verify bundled directories take precedence' || record conflict.library_path PASS runtime 'No inherited LD_LIBRARY_PATH'
for v in SDL_VIDEODRIVER SDL_AUDIODRIVER LIBGL_ALWAYS_SOFTWARE MESA_LOADER_DRIVER_OVERRIDE; do [[ -n ${!v:-} ]] && record "env.$v" WARN runtime "$v override is set" 'Check suitability for the device'; done
[[ -d /dev/snd ]] && record audio.devices PASS system '/dev/snd exists' || record audio.devices "$(scope_status WARN)" system 'ALSA device nodes unavailable'
if [[ -d /dev/dri ]]; then record graphics.drm PASS system '/dev/dri present'; elif [[ -e /dev/fb0 ]]; then record graphics.framebuffer PASS system 'Framebuffer found; DRM not required'; else record graphics.nodes "$(scope_status UNKNOWN)" system 'Neither DRM nor framebuffer visible'; fi
for p in /dev/tty0 /dev/tty1; do [[ -e $p ]] && record "tty.${p##*/}" PASS system 'TTY exists; access unverified' || record "tty.${p##*/}" "$(scope_status WARN)" system 'TTY unavailable'; done

library_dirs() { if [[ $1 == aarch64 ]]; then printf '%s\n' /lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu /lib64 /usr/lib64 /lib /usr/lib /usr/local/lib; else printf '%s\n' /lib/arm-linux-gnueabihf /usr/lib/arm-linux-gnueabihf /lib/armhf /usr/lib/armhf /lib32 /usr/lib32 /lib /usr/lib; fi; }
elf_matches() {
  local path=$1 arch=$2 desc
  has readelf || return 2
  desc=$(LC_ALL=C readelf -h "$path" 2>/dev/null) || return 2
  if [[ $arch == aarch64 ]]; then [[ $desc == *'Class: '*ELF64* && $desc == *'Machine: '*AArch64* ]]; return; fi
  [[ $desc == *'Class: '*ELF32* && $desc == *'Machine: '*ARM* ]]
}
find_lib() {
  local arch=$1 soname=$2 dir path result=1
  while IFS= read -r dir; do path=$dir/$soname; if [[ -e $path ]]; then if elf_matches "$path" "$arch"; then printf '%s' "$path"; return 0; else result=2; fi; fi; done < <(library_dirs "$arch")
  return "$result"
}
check_lib() {
  local arch=$1 soname=$2 severity=$3 result path status
  path=$(find_lib "$arch" "$soname"); result=$?
  if ((result == 0)); then record "lib.$soname" PASS "$arch" "$path"; return; fi
  status=$(scope_status "$severity")
  if ((result == 2)); then if has readelf; then record "lib.$soname" "$status" "$arch" 'Candidate has incompatible or unreadable ELF header'; else record "lib.$soname" UNKNOWN "$arch" 'Candidate found but ELF architecture cannot be verified'; fi
  else record "lib.$soname" "$status" "$arch" 'Compatible library not found in visible standard paths' 'Check host libraries outside the sandbox'; fi
}
required_libs=(libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libstdc++.so.6 libgcc_s.so.1 libz.so.1 libSDL2-2.0.so.0 libSDL2_mixer-2.0.so.0 libSDL2_image-2.0.so.0 libSDL2_ttf-2.0.so.0 libasound.so.2 libEGL.so.1 libGLESv2.so.2)
common_libs=(libpng16.so.16 libjpeg.so.62 libfreetype.so.6 libfontconfig.so.1 libopenal.so.1)
legacy_libs=(libFLAC.so.8 libjpeg.so.8 libavcodec.so.58 libavformat.so.58 libavutil.so.56 libswresample.so.3 libswscale.so.5 libvpx.so.6 libwebp.so.6 libaom.so.0 libdav1d.so.4 libcodec2.so.0.9 libx264.so.160 libx265.so.192 libwavpack.so.1)
for arch in "${TARGETS[@]}"; do
  required_severity=FAIL; [[ $ARCH_REQUEST == auto && $native == aarch64 && $arch == armhf ]] && required_severity=WARN
  [[ $arch == aarch64 ]] && loader=/lib/ld-linux-aarch64.so.1 || loader=/lib/ld-linux-armhf.so.3
  if [[ -e $loader ]]; then record abi.loader PASS "$arch" "$loader"; else record abi.loader "$(scope_status "$required_severity")" "$arch" "Dynamic loader not found at $loader in visible filesystem"; fi
  for lib in "${required_libs[@]}"; do check_lib "$arch" "$lib" "$required_severity"; done
  for lib in "${common_libs[@]}" "${legacy_libs[@]}"; do check_lib "$arch" "$lib" WARN; done
done
if [[ $native == aarch64 && " ${TARGETS[*]} " == *' armhf '* ]]; then record abi.armhf_execution UNKNOWN armhf '32-bit kernel execution capability is not proven by static inspection' 'Use a trusted armhf probe on target'; fi
pm_root=${XDG_DATA_HOME:-${HOME:-/nonexistent}/.local/share}/PortMaster
if [[ -d $pm_root ]]; then record portmaster.location PASS system "$pm_root"; for f in control.txt device_info.txt funcs.txt; do [[ -f $pm_root/$f ]] && record "portmaster.$f" PASS system 'Present; not sourced' || record "portmaster.$f" WARN system 'Missing'; done; else record portmaster.location UNKNOWN system 'PortMaster data directory not found'; fi
if ((DEEP)); then for arch in "${TARGETS[@]}"; do if has readelf; then libc=$(find_lib "$arch" libc.so.6) || libc=; if [[ -n $libc ]]; then versions=$(LC_ALL=C readelf --version-info "$libc" 2>/dev/null | grep -oE 'GLIBC_2\.[0-9]+' || :); if [[ $versions == *GLIBC_2.34* || $versions == *GLIBC_2.3[5-9]* || $versions == *GLIBC_2.[4-9][0-9]* ]]; then record abi.glibc_symbols PASS "$arch" 'GLIBC_2.34+ symbols found'; else record abi.glibc_symbols WARN "$arch" 'Could not establish GLIBC_2.34+ from version data'; fi; fi; fi; done; fi

write_report() {
  local i
  printf 'PortMaster CFW Compatibility Checker v%s\nHost architecture: %s\nRequested target: %s\nResearch credit: bmdhacks — %s\nScope: %s\nChecks: %d | Failures: %d | Warnings: %d\nUNKNOWN means not verified.\n\n' "$VERSION" "$host_arch" "$ARCH_REQUEST" "$SOURCE_URL" "$(if is_flatpak; then printf 'RetroDECK Flatpak runtime; host paths and devices may be hidden'; else printf 'Direct system inspection'; fi)" "${#IDS[@]}" "$FAILURES" "$WARNINGS"
  for ((i=0;i<${#IDS[@]};i++)); do printf '[%s] %s (%s): %s%s\n' "${STATUSES[i]}" "${IDS[i]}" "${ARCHES[i]}" "${DETAILS[i]}" "${FIXES[i]:+ — ${FIXES[i]}}"; done
  printf '\nNo system configuration was changed.\n'
}
if [[ -n $REPORT_OUT ]]; then write_report > "$REPORT_OUT" || { printf 'Unable to write report\n' >&2; exit 2; }; fi
if [[ -n $TSV_OUT ]]; then
  for ((i=0;i<${#IDS[@]};i++)); do detail=${DETAILS[i]//$'\t'/ }; detail=${detail//$'\n'/ }; printf '%s\t%s\t%s\t%s\n' "${STATUSES[i]}" "${IDS[i]}" "${ARCHES[i]}" "$detail"; done > "$TSV_OUT" || { printf 'Unable to write GUI results\n' >&2; exit 2; }
fi
printf '\nSummary: %d checks, %d failures, %d warnings. UNKNOWN means not verified.\nNo system configuration was changed.\n' "${#IDS[@]}" "$FAILURES" "$WARNINGS"
((FAILURES == 0)) || exit 1
