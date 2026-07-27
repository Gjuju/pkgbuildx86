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
resolve_boot_disk () {
	local src part
	src="$(findmnt -no SOURCE / 2>/dev/null)"
	# some Pi images report /dev/root, a symlink to the real partition
	[ -L "$src" ] && src="$(readlink -f "$src")"
	part="$(basename "${src:-none}")"

	BOOT_DISK="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)"
	[ -n "$BOOT_DISK" ] || BOOT_DISK="$part"

	# lsblk gave nothing usable: strip the partition suffix ourselves.
	# mmcblk0p2 -> mmcblk0, nvme0n1p1 -> nvme0n1, sda2 -> sda
	if [ ! -r "/sys/block/$BOOT_DISK/stat" ]; then
		case "$BOOT_DISK" in
			*p[0-9]*) BOOT_DISK="${BOOT_DISK%p[0-9]*}" ;;
			*[0-9])   BOOT_DISK="${BOOT_DISK%%[0-9]*}" ;;
		esac
	fi
	[ -r "/sys/block/$BOOT_DISK/stat" ]
}

disk_written_mb () {
	if [ -r "/sys/block/$BOOT_DISK/stat" ]; then
		# field 7 = sectors written, 512 bytes each
		awk '{print int($7 / 2048)}' "/sys/block/$BOOT_DISK/stat"
	else
		echo ""
	fi
}

# Raw /sys/block/<disk>/stat line, for the read and busy-time deltas. Fields:
# 3 = sectors read, 7 = sectors written, 10 = io_ticks (ms the disk was busy).
disk_stat () {
	[ -r "/sys/block/$BOOT_DISK/stat" ] && cat "/sys/block/$BOOT_DISK/stat"
}

# Aggregate CPU jiffies, for the iowait share. Fields after "cpu":
# user nice system idle iowait irq softirq steal ...
cpu_stat () {
	awk '/^cpu / {print}' /proc/stat
}

# Is this a bare SSH session, one a dropped link would kill? sudo's env_reset
# drops SSH_TTY, TMUX and STY, so walk the process tree instead. PPid comes from
# /proc/<pid>/status, not stat, whose comm field can itself contain spaces.
# Match on the executable, not just comm: a process can rewrite its own comm
# (bash does), while /proc/<pid>/exe still points at the real binary. We run as
# root, so the link is readable for every ancestor.
session_kind () {
	local pid="$PPID" name exe n=0
	while [ "$pid" -gt 1 ] && [ "$n" -lt 12 ]; do
		name="$(cat "/proc/$pid/comm" 2>/dev/null)"
		exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"
		case "${exe##*/} $name" in
			tmux*|*" tmux"*|screen*|*" screen"*|SCREEN*|*" SCREEN"*)
				echo multiplexed; return ;;
			sshd*|*" sshd"*)
				echo ssh; return ;;
		esac
		pid="$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null)"
		[ -n "$pid" ] || break
		n=$((n + 1))
	done
	echo local
}

# MB paged out to swap since boot (pswpout counts 4 KB pages)
swap_written_mb () {
	awk '/^pswpout/ {print int($2 * 4 / 1024)}' /proc/vmstat
}

#
# Environment
#

# This is a moOde benchmark: it builds what moOde's Install button builds, and
# reports figures only comparable between moOde systems. Refuse anything else
# now rather than failing late, after an hour of compiling.
if ! command -v moodeutl >/dev/null 2>&1 || [ ! -f "$SQLDB" ]; then
	echo "This script benchmarks the librespot build on a moOde player." >&2
	echo "It needs moOde installed (moodeutl and $SQLDB), and found neither." >&2
	exit 1
fi

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

# [ -r ] first: the 2>/dev/null covers tr, not the shell's own redirection error
MODEL=""
[ -r /proc/device-tree/model ] && MODEL="$(tr -d '\0' < /proc/device-tree/model)"
[ -n "$MODEL" ] || MODEL="$(awk -F': ' '/^Model/ {print $2; exit}' /proc/cpuinfo)"
[ -n "$MODEL" ] || MODEL="unknown"
RAM_MB="$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)"
CORES="$(nproc)"
DEB_ARCH="$(dpkg --print-architecture)"

# moOde's own identity, so reports are comparable between testers: the release
# pins which librespot version and rustc pin are in play. pirev is tab
# separated (code, type, rev, mem, manufacturer, processor ...), squeeze it.
MOODE_REL="$(moodeutl --mooderel 2>/dev/null | tr -d '\n')"
PIREV="$(moodeutl --pirev 2>/dev/null | tr '\t' ' ' | tr -s ' ')"
OS_REL="$(moodeutl --osinfo 2>/dev/null | tr -d '\n')"
[ -n "$OS_REL" ] || OS_REL="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"

ELAPSED=0
DISK_MB=""
SWAP_MB=""
SWAP_PEAK=""
IOWAIT_PCT=""
DISK_READ_MB=""
DISK_BUSY_PCT=""
LOAD_PEAK=""
USED_JOBS=""
DEB=""

summary () {
	local result="$1"
	{
		echo
		echo "===== copy this into your forum reply ====="
		printf "moode    %s\n"           "${MOODE_REL:-unknown}"
		printf "model    %s\n"           "$MODEL"
		[ -n "$PIREV" ] && printf "pirev    %s\n" "$PIREV"
		printf "os       %s (%s)\n"      "$OS_REL" "$DEB_ARCH"
		printf "ram      %s MB, %s cores\n" "$RAM_MB" "$CORES"
		printf "rustc    %s\n"           "${RUSTC_VER:-not installed}"
		printf "jobs     %s %s (%s advised)\n" "${USED_JOBS:-unknown}" "${JOBS_SOURCE:-?}" "${ADVISED:-?}"
		printf "branch   %s @ %s\n"      "$REPO_BRANCH" "${HEAD_SHA:-?}"
		printf "result   %s%s\n"         "$result" \
			"$([ "$ELAPSED" -gt 0 ] && printf " in %dm%02ds" $((ELAPSED / 60)) $((ELAPSED % 60)))"
		# Print these as a block, "n/a" rather than a missing line: a report with a
		# hole in it is unreadable, and n/a is itself a finding worth seeing. When
		# the build never started, say so once instead of four misleading n/a.
		if [ "$ELAPSED" -eq 0 ]; then
			printf "system   not measured, the build did not start\n"
		else
			if [ -n "$DISK_MB" ]; then
				printf "disk     %s MB written to %s\n" "$DISK_MB" "$BOOT_DISK"
			else
				printf "disk     n/a (no readable counter for the disk holding /)\n"
			fi
			printf "swap     %s MB paged out, peak %s MB in use\n" "${SWAP_MB:-n/a}" "${SWAP_PEAK:-n/a}"
			printf "load     peak %s (1 min avg, %s cores), sampled every 30 s\n" "${LOAD_PEAK:-n/a}" "$CORES"
			printf "io       %s%% iowait, card busy %s%% of the build, %s MB read\n" \
				"${IOWAIT_PCT:-n/a}" "${DISK_BUSY_PCT:-n/a}" "${DISK_READ_MB:-n/a}"
		fi
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
log "moode  ${MOODE_REL:-unknown}"

# A long full-load build on a small board can starve MPD. Warn, do not refuse:
# it is the tester's player and their call.
if command -v mpc >/dev/null 2>&1 && mpc status 2>/dev/null | grep -q '^\[playing\]'; then
	log "[!] MPD is playing. This build loads every core for a long time and can"
	log "[!] cause audio dropouts. Stop playback for a clean run."
fi

# A dropped SSH session takes the build with it, and this one runs for up to
# 90 min. Warn only when there is no multiplexer to survive it.
if [ "$(session_kind)" = ssh ]; then
	log "[!] Bare SSH session. This build runs up to 90 min and dies with the"
	log "[!] connection - laptop sleeping, wifi dropping, terminal closed."
	log "[!] Ctrl-C now and restart it under a multiplexer that survives:"
	log "[!]   tmux new -s build      (Ctrl-b then d detaches, tmux attach -t build)"
	log "[!] See 'Running over SSH' in use.md for the nohup alternative."
fi

# Resolve the counters now, not after a 70 min build: a tester who is going to
# get "n/a" in the report should know before starting, not after.
if resolve_boot_disk; then
	log "disk   counters on $BOOT_DISK"
else
	log "[!] no readable /sys/block/*/stat for the disk holding / - the disk and io"
	log "[!] figures will read n/a. The build itself is unaffected."
fi

# How many parallel rustc this board can hold. Same formula as the branch under
# test: budget 512 MB of RAM per job, clamp to [1, nproc]. The +512 absorbs what
# MemTotal under-reports (CMA/GPU reserved), so a 1 GB board announcing ~905 MB
# still lands on 2 jobs.
ADVISED=$(( (RAM_MB + 512) / 512 ))
[ "$ADVISED" -lt 1 ] && ADVISED=1
[ "$ADVISED" -gt "$CORES" ] && ADVISED=$CORES

cat <<EOF

  Board          $MODEL
  Memory         $RAM_MB MB, $CORES cores

  moOde builds this package with one compiler job per core, so $CORES jobs on this
  board. That is the default this test compares against.

  Each parallel rustc can peak at roughly 1.1 GB of RAM, so a small board is
  always oversubscribed and leans on swap. What matters is by how much.
  Measured on 1 GB boards: 2 jobs built it in 39 min without trouble, while
  4 jobs took 81 min and crashed the board twice.

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
	JOBS_SOURCE="auto"
fi
log "jobs   ${JOBS:-auto}, advised $ADVISED"

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

# Sample swap in use and load average every 30 s, keeping only the peaks. The
# written-bytes figures are counter deltas and need no sampling. Read
# /proc/meminfo rather than free, whose column labels are translated and would
# not match under a non-en locale. Two columns: swap MB, 1 min load.
: > "$SAMPLES"
( while :; do
	echo "$(awk '/^SwapTotal/ {t = $2} /^SwapFree/ {f = $2} END {print int((t - f) / 1024)}' /proc/meminfo) $(cut -d' ' -f1 /proc/loadavg)" >> "$SAMPLES"
	sleep 30
done ) &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null' EXIT

DISK_START="$(disk_written_mb)"
DISK_STAT_START="$(disk_stat)"
CPU_STAT_START="$(cpu_stat)"
SWAP_START="$(swap_written_mb)"

cd "$PKG_DIR" || fail "no package dir $PKG_DIR"
log "** Building librespot - 25 to 90 min depending on the board, about 90 on a 1 GB Pi 3B+"
START=$SECONDS
./build.sh 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}
ELAPSED=$((SECONDS - START))

sync
[ -n "$DISK_START" ] && DISK_MB=$(( $(disk_written_mb) - DISK_START ))
SWAP_MB=$(( $(swap_written_mb) - SWAP_START ))

# MB read from the card, and the share of the build during which it was busy
# (io_ticks is in ms). A card busy most of the build is the I/O bound case.
if [ -n "$DISK_STAT_START" ] && [ "$ELAPSED" -gt 0 ]; then
	DISK_READ_MB="$(LC_ALL=C awk -v s="$DISK_STAT_START" '{split(s, b); print int(($3 - b[3]) / 2048)}' <<< "$(disk_stat)")"
	DISK_BUSY_PCT="$(LC_ALL=C awk -v s="$DISK_STAT_START" -v e="$ELAPSED" '{split(s, b); printf "%.0f", ($10 - b[10]) / (e * 1000) * 100}' <<< "$(disk_stat)")"
fi

# Share of CPU time spent waiting on I/O rather than computing. Fuzzy on
# multi-core, but it is the number that separates "compiling" from "thrashing".
IOWAIT_PCT="$(LC_ALL=C awk -v s="$CPU_STAT_START" '
	{
		split(s, b)
		for (i = 2; i <= NF; i++) { tot += $i - b[i] }
		if (tot > 0) printf "%.0f", ($6 - b[6]) / tot * 100
	}' <<< "$(cpu_stat)")"
# LC_ALL=C: loadavg always uses a dot, so keep awk's numeric parsing off the
# user's locale whatever awk implementation this board ships.
SWAP_PEAK="$(LC_ALL=C awk 'NR == 1 || $1 > m {m = $1} END {print m + 0}' "$SAMPLES" 2>/dev/null)"
LOAD_PEAK="$(LC_ALL=C awk 'NR == 1 || $2 > m {m = $2} END {printf "%.2f", m}' "$SAMPLES" 2>/dev/null)"
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
