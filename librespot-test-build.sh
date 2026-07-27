#!/bin/bash
#
# librespot-test-build.sh
#
# Builds the librespot .deb from a pkgbuild fork/branch and drops it in the home
# directory, then stops. Nothing is installed. Install it afterwards with:
#
#     cd ~ && sudo moodeutl --installpkg spotify
#
# Same build path as moOde's on-demand Spotify install (plugins repo,
# renderer/v8-librespot), so the timing is comparable: run as root, so
# rebuilder.lib.sh takes its EUID==0 branch and rust lives in /root/.cargo.
#
# Prints a summary block at the end - please copy that into your forum reply.
#
# Usage: sudo ./librespot-test-build.sh [options]
#   --jobs N       parallel rustc jobs, skips the prompt ('auto' to let
#                  build.sh decide, which is what pressing Enter does)
#   --auto         skip the prompt, let build.sh decide
#   --keep-clone   reuse the existing clone (just fetch + checkout the branch)
#
# Env overrides: REPO_URL, REPO_BRANCH
#

set -u

REPO_URL="${REPO_URL:-https://github.com/Gjuju/pkgbuildx86.git}"
REPO_BRANCH="${REPO_BRANCH:-test/librespot-cargo-jobs}"
SQLDB=/var/local/www/db/moode-sqlite3.db

KEEP_CLONE=0
JOBS=""
NO_PROMPT=0

while [ $# -gt 0 ]; do
	case "$1" in
		--keep-clone) KEEP_CLONE=1 ;;
		--jobs)       shift
		              JOBS="$1"; NO_PROMPT=1
		              [ "$JOBS" = auto ] && JOBS=""
		              [ -n "$JOBS" ] && ! printf '%s' "$JOBS" | grep -qE '^[1-9][0-9]*$' \
		                  && { echo "--jobs takes a number or 'auto'" >&2; exit 1; }
		              ;;
		--auto|--yes) NO_PROMPT=1 ;;
		# print the header comment, whatever line it starts on
		-h|--help)    awk 'NR > 2 && /^#/ {sub(/^# ?/, ""); print; next} NR > 2 {exit}' "$0"; exit 0 ;;
		*)            echo "Unknown option: $1" >&2; exit 1 ;;
	esac
	shift
done

# ${LOG:-} : these are usable before the log path is known (it depends on the
# home dir, which is resolved below and can itself fail).
log ()  { echo "$(date +'%H:%M:%S') $*" | tee -a "${LOG:-/dev/null}"; }
fail () { echo "** FAILED: $*" | tee -a "${LOG:-/dev/null}"; summary FAILED; exit 1; }

[ "$(id -u)" -eq 0 ] || { echo "run me as root: sudo $0 $*" >&2; exit 1; }

#
# Measurement helpers
#

# MB written to the whole disk backing / (not just the partition), so swap
# traffic is included - on a thrashing board that is most of the volume.
BOOT_DISK=""
disk_written_mb () {
	if [ -z "$BOOT_DISK" ]; then
		local src
		src="$(findmnt -no SOURCE / 2>/dev/null)"
		BOOT_DISK="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)"
		[ -z "$BOOT_DISK" ] && BOOT_DISK="$(basename "${src:-none}")"
	fi
	if [ -r "/sys/block/$BOOT_DISK/stat" ]; then
		# field 7 = sectors written, 512 bytes each
		awk '{print int($7 / 2048)}' "/sys/block/$BOOT_DISK/stat"
	else
		echo ""
	fi
}

# MB paged out to swap since boot (pswpout counts 4 KB pages)
swap_written_mb () {
	awk '/^pswpout/ {print int($2 * 4 / 1024)}' /proc/vmstat
}

#
# Environment
#

# Home dir of the player user: SUDO_USER when invoked through sudo, else the
# same resolution moodeutl's getUserID() uses (first entry in /home).
if [ -n "${SUDO_USER:-}" ]; then
	OWNER="$SUDO_USER"
else
	OWNER="$(ls /home/ 2>/dev/null | head -1)"
fi
HOME_DIR="$(getent passwd "$OWNER" | cut -d: -f6)"
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || { echo "cannot resolve home dir (OWNER=$OWNER)" >&2; exit 1; }

CLONE_DIR="$HOME_DIR/pkgbuildx86"
PKG_DIR="$CLONE_DIR/packages/librespot"
LOG="$HOME_DIR/librespot-test-build.log"
SAMPLES="$HOME_DIR/librespot-test-build.samples"

MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
[ -n "$MODEL" ] || MODEL="$(awk -F': ' '/^Model/ {print $2; exit}' /proc/cpuinfo)"
[ -n "$MODEL" ] || MODEL="unknown"
RAM_MB="$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)"
CORES="$(nproc)"
DEB_ARCH="$(dpkg --print-architecture)"
OS_REL="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"

ELAPSED=0
DISK_MB=""
SWAP_MB=""
SWAP_PEAK=""
USED_JOBS=""
DEB=""

summary () {
	local result="$1"
	{
		echo
		echo "===== copy this into your forum reply ====="
		printf "model    %s\n"           "$MODEL"
		printf "os       %s (%s, %s)\n"  "$OS_REL" "$(uname -m)" "$DEB_ARCH"
		printf "ram      %s MB, %s cores\n" "$RAM_MB" "$CORES"
		printf "rustc    %s\n"           "${RUSTC_VER:-not installed}"
		printf "jobs     %s (advised %s, %s)\n" "${USED_JOBS:-unknown}" "${ADVISED:-?}" "${JOBS_SOURCE:-?}"
		printf "branch   %s @ %s\n"      "$REPO_BRANCH" "${HEAD_SHA:-?}"
		printf "result   %s%s\n"         "$result" \
			"$([ "$ELAPSED" -gt 0 ] && printf " in %dm%02ds" $((ELAPSED / 60)) $((ELAPSED % 60)))"
		[ -n "$DISK_MB" ]   && printf "disk     %s MB written to %s\n" "$DISK_MB" "$BOOT_DISK"
		[ -n "$SWAP_MB" ]   && printf "swap     %s MB paged out, peak %s MB in use\n" "$SWAP_MB" "${SWAP_PEAK:-?}"
		[ -n "$DEB" ]       && printf "package  %s\n" "$(basename "$DEB")"
		echo "==========================================="
		echo "full log: $LOG"
	} | tee -a "$LOG"
}

#
# Main
#

: > "$LOG"
log "repo   $REPO_URL"
log "branch $REPO_BRANCH"
log "board  $MODEL - $RAM_MB MB, $CORES cores, $DEB_ARCH"

# How many parallel rustc this board can hold. Same formula as the branch under
# test: budget ~1 GB of RAM per job, clamp to [1, nproc]. MemTotal always reads a
# little under the physical size (CMA/GPU reserved), hence rounding to the
# nearest GB rather than down - a 2 GB board reports ~1900 MB.
ADVISED=$(( (RAM_MB + 512) / 1024 ))
[ "$ADVISED" -lt 1 ] && ADVISED=1
[ "$ADVISED" -gt "$CORES" ] && ADVISED=$CORES

cat <<EOF

  Board          $MODEL
  Memory         $RAM_MB MB, $CORES cores

  Each parallel rustc peaks at roughly 1.1 GB of RAM. Asking for more jobs than
  the RAM can hold pushes the build into swap, and on an SD card that costs both
  time and card wear: measured on a 1 GB Pi 3B+, 4 jobs took 81 min and crashed
  the board twice, where 1 job took 73 min and wrote far less.

  Advised for this board: $ADVISED job(s) out of $CORES cores.

EOF

# Offer 1, 2, 4 ... up to the core count rather than any integer: these are the
# values worth comparing across testers.
CHOICES=""
n=1
while [ "$n" -le "$CORES" ]; do
	CHOICES="$CHOICES $n"
	n=$((n * 2))
done
CHOICE_LIST="$(echo $CHOICES | tr ' ' ',' | sed 's/,/, /g')"

if [ "$NO_PROMPT" = 0 ] && [ -t 0 ]; then
	while :; do
		printf "  Jobs to use - %s - or just Enter for auto (advised: %s): " "$CHOICE_LIST" "$ADVISED"
		read -r reply || reply=""
		if [ -z "$reply" ]; then
			JOBS=""; break
		fi
		case " $CHOICES " in
			*" $reply "*)
				JOBS="$reply"
				[ "$JOBS" -gt "$ADVISED" ] && echo "  Note: above the advised $ADVISED, expect swapping."
				break
				;;
		esac
		echo "  Enter one of $CHOICE_LIST, or nothing for auto."
	done
	echo
fi

if [ -n "$JOBS" ]; then
	JOBS_SOURCE="chosen"
else
	JOBS_SOURCE="auto, decided by build.sh"
fi
log "jobs   ${JOBS:-auto} ($JOBS_SOURCE; advised $ADVISED)"

apt-get -y install git sqlite3 >/dev/null 2>&1 || fail "apt install git sqlite3"

# Clone the fork and check out the branch under test. --keep-clone fetches the
# branch into the existing clone instead, so two branches can be compared back
# to back without re-cloning.
if [ "$KEEP_CLONE" = 1 ] && [ -d "$CLONE_DIR/.git" ]; then
	log "reusing clone, checking out $REPO_BRANCH"
	git -C "$CLONE_DIR" fetch --depth 1 origin "$REPO_BRANCH" || fail "git fetch $REPO_BRANCH"
	git -C "$CLONE_DIR" checkout -B "$REPO_BRANCH" FETCH_HEAD || fail "git checkout $REPO_BRANCH"
	git -C "$CLONE_DIR" clean -fdx >/dev/null 2>&1
else
	rm -rf "$CLONE_DIR"
	git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR" \
		|| fail "git clone $REPO_URL#$REPO_BRANCH"
fi
HEAD_SHA="$(git -C "$CLONE_DIR" log -1 --format='%h')"
log "head   $HEAD_SHA $(git -C "$CLONE_DIR" log -1 --format='%s')"

# rebuilder.lib.sh refuses to run without these; same dummy identity the plugin
# installer exports.
export DEBFULLNAME=User
export DEBEMAIL=User@Email.com
[ -n "$JOBS" ] && export CARGO_BUILD_JOBS="$JOBS"

# Sample swap usage every 30 s, keeping only the peak. The written-bytes figures
# are counter deltas and need no sampling. Read /proc/meminfo rather than free,
# whose column labels are translated and would not match under a non-en locale.
: > "$SAMPLES"
( while :; do
	awk '/^SwapTotal/ {t = $2} /^SwapFree/ {f = $2} END {print int((t - f) / 1024)}' /proc/meminfo >> "$SAMPLES"
	sleep 30
done ) &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null' EXIT

DISK_START="$(disk_written_mb)"
SWAP_START="$(swap_written_mb)"

cd "$PKG_DIR" || fail "no package dir $PKG_DIR"
log "** Building librespot - this takes 25 to 90 min depending on the board"
START=$SECONDS
./build.sh 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
ELAPSED=$((SECONDS - START))

sync
[ -n "$DISK_START" ] && DISK_MB=$(( $(disk_written_mb) - DISK_START ))
SWAP_MB=$(( $(swap_written_mb) - SWAP_START ))
SWAP_PEAK="$(sort -n "$SAMPLES" 2>/dev/null | tail -1)"
kill $SAMPLER 2>/dev/null

# The branch under test echoes the jobs count it picked; upstream main does not,
# where cargo silently defaults to one rustc per core.
USED_JOBS="$(awk -F'CARGO_BUILD_JOBS=' '/building librespot with CARGO_BUILD_JOBS=/ {split($2, a, " "); print a[1]}' "$LOG" | tail -1)"
[ -n "$USED_JOBS" ] || USED_JOBS="${CARGO_BUILD_JOBS:-$CORES (cargo default, no jobs cap on this branch)}"
RUSTC_VER="$(/root/.cargo/bin/rustc --version 2>/dev/null | awk '{print $2}')"

[ "$RC" -eq 0 ] || fail "build.sh returned $RC"
log "** Build OK in $((ELAPSED / 60))m$((ELAPSED % 60))s"

DEB="$(ls -1t "$PKG_DIR"/dist/binary/librespot_*.deb 2>/dev/null | head -1)"
[ -n "$DEB" ] || fail "no .deb in $PKG_DIR/dist/binary"

cp "$DEB" "$HOME_DIR/" || fail "cp to $HOME_DIR"
chown "$OWNER": "$HOME_DIR/$(basename "$DEB")"
chown -R "$OWNER": "$CLONE_DIR" 2>/dev/null
chown "$OWNER": "$LOG" "$SAMPLES" 2>/dev/null
log "** Package: $HOME_DIR/$(basename "$DEB")"

# moodeutl --installpkg builds the filename from cfg_plugin.version and tests it
# with a RELATIVE file_exists(), so it only finds a package named exactly this,
# and only when run from the home dir.
DB_VERSION="$(sqlite3 "$SQLDB" "SELECT version FROM cfg_plugin WHERE component='renderer' AND type='spotify-connect'" 2>/dev/null)"
EXPECTED="librespot_${DB_VERSION}_arm64.deb"
if [ -n "$DB_VERSION" ] && [ "$(basename "$DEB")" != "$EXPECTED" ]; then
	log "** NOTE: moodeutl --installpkg spotify expects $EXPECTED and will say"
	log "**       \"Package not found in home directory\". Install it directly:"
	log "**       sudo apt -y --allow-change-held-packages install $HOME_DIR/$(basename "$DEB")"
else
	log "** Now install it with:  cd ~ && sudo moodeutl --installpkg spotify"
fi

summary OK
sync
