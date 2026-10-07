#!/usr/bin/env bash
# eotir-render.sh -- EOTIR Music Project render helper for LINUX (also works in WSL). No root needed.
#
# What it does, in plain words: it fetches a render job Ryan assigned to this helper from his private
# file server, makes the video on this computer, checks it, sends it back - and then looks for the next
# job, forever, until you press Q or close the window. Everything it installs lives in ONE folder
# (default ~/.local/share/eotir). Delete that folder and it is all gone.
#
# Same job contract, kit, signed self-update, error codes and reports as the Windows helper
# (windows/eotir-render.ps1); see videos/render-helper/README.md.
#
# Package layout (made by videos/render-helper/build_helper_package.py --platform linux):
#   eotir-render.sh  helper.json  helper_key  known_hosts  allowed_signers
#
# Options:
#   --check-only          test the computer + the connection to the server, then stop
#   --job ID              render a specific job id instead of "the next one assigned to me"
#   --home DIR            where tools/work files live (tests use a scratch folder)
#   --keep-files          do not delete the downloaded job and render after a successful upload
#   --once                make ONE video and stop (default: keep going to the next job)
#   --no-wait             if there is no job, say so and stop (default: wait and start by itself)
#   --poll-seconds N      how often to look for a job while waiting (default 180)
#   --max-wait-hours N    stop waiting after this long (default 0 = keep waiting until you press Q)
#   --no-update           do not check for a newer version of this script
#
# Unattended / VPS: run it inside tmux (or screen) so it survives your ssh session closing, and stop it with
#   touch ~/.local/share/eotir/STOP        (same as pressing Q: stops after the current video is delivered)
#   -h, --help            this text
#
# Design notes (read before editing):
#  * Everything runs inside functions and the file ends with `main "$@"; exit`, so bash has read the whole
#    file before anything executes. The self-updater replaces this file with `mv` (a new inode) and then
#    `exec`s it - overwriting a running shell script in place corrupts the run (bash reads scripts lazily).
#  * No `set -e`: failures are explicit (`fail CODE "message"`) so every one carries an error code + report.
#  * Every child process gets </dev/null so none of them can swallow the Q key or hang on the terminal.

set -u -o pipefail -E

# SCRIPT_BUILD is the MONOTONIC release number the self-updater compares (publish_update.py reads this line).
SCRIPT_BUILD=2
SCRIPT_VERSION="2026-10-06.2"

SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PKG_DIR="$(dirname "$SELF_PATH")"
ORIG_ARGS=("$@")

# ---------------------------------------------------------------- options
OPT_CHECK_ONLY=0; OPT_JOB=""; OPT_HOME=""; OPT_KEEP=0; OPT_ONCE=0; OPT_NOWAIT=0
OPT_POLL=180; OPT_MAXWAIT=0; OPT_NOUPDATE=0

usage() { sed -n '2,/^# Design notes/{/^# Design notes/!p}' "$SELF_PATH" | sed 's/^# \{0,1\}//'; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --check-only) OPT_CHECK_ONLY=1 ;;
            --job) OPT_JOB="${2:-}"; shift ;;
            --home) OPT_HOME="${2:-}"; shift ;;
            --keep-files) OPT_KEEP=1 ;;
            --once) OPT_ONCE=1 ;;
            --no-wait) OPT_NOWAIT=1 ;;
            --poll-seconds) OPT_POLL="${2:-180}"; shift ;;
            --max-wait-hours) OPT_MAXWAIT="${2:-0}"; shift ;;
            --no-update) OPT_NOUPDATE=1 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------- look and feel
if [ -t 1 ]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YEL=$'\e[33m'; C_CYAN=$'\e[36m'; C_MAG=$'\e[35m'
    C_GRAY=$'\e[90m'; C_WHITE=$'\e[97m'; C_OFF=$'\e[0m'
else
    C_RED=""; C_GREEN=""; C_YEL=""; C_CYAN=""; C_MAG=""; C_GRAY=""; C_WHITE=""; C_OFF=""
fi

LOG_FILE=""
logf() { [ -n "$LOG_FILE" ] && printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOG_FILE" 2>/dev/null; return 0; }
say()  { printf '%s%s%s\n' "${2:-$C_WHITE}" "$1" "$C_OFF"; logf "$1"; }
hint() { printf '   %s%s%s\n' "$C_GRAY" "$1" "$C_OFF"; logf "   $1"; }
good() { printf '   %s[OK] %s%s\n' "$C_GREEN" "$1" "$C_OFF"; logf "OK $1"; }
warn() { printf '   %s[!] %s%s\n' "$C_YEL" "$1" "$C_OFF"; logf "WARN $1"; }

fmt_time() {   # seconds -> "1h 2m" / "3m 4s" / "5s"
    local s=${1%.*}; [ -z "$s" ] || [ "$s" -lt 0 ] 2>/dev/null && { echo "figuring it out..."; return; }
    local h=$((s / 3600)) m=$(((s % 3600) / 60)) r=$((s % 60))
    if [ "$h" -gt 0 ]; then echo "${h}h ${m}m"; elif [ "$m" -gt 0 ]; then echo "${m}m ${r}s"; else echo "${r}s"; fi
}
fmt_mb() { awk -v b="${1:-0}" 'BEGIN{printf "%.1f MB", b/1048576}'; }
make_bar() {   # pct -> [####------]
    local pct=${1%.*}; [ -z "$pct" ] && pct=0; [ "$pct" -lt 0 ] && pct=0; [ "$pct" -gt 100 ] && pct=100
    local w=30 f=$(( 30 * pct / 100 )) i out=""
    for ((i = 0; i < w; i++)); do if [ "$i" -lt "$f" ]; then out+="#"; else out+="-"; fi; done
    printf '[%s]' "$out"
}

STEP_NAMES=("Checking your computer" "Getting the video tools ready" "Getting the EOTIR render kit" "Connecting to Ryan's server" "Downloading your video job" "Making the video" "Sending the finished video back")
STEP_WEIGHT=(2 6 14 2 8 58 10)
CUR_STEP=0; FIRST_STEP=1; STOP_REQUESTED=0

overall_pct() {   # phase pct (0-100) -> overall pct, counting only steps FIRST_STEP..7
    awk -v f="$FIRST_STEP" -v c="$CUR_STEP" -v ph="${1:-0}" -v w="${STEP_WEIGHT[*]}" \
        'BEGIN{n=split(w,a," "); t=0; b=0; for(i=f;i<=n;i++)t+=a[i]; for(i=f;i<c;i++)b+=a[i]; cur=a[c]*ph/100; printf "%d", 100*(b+cur)/t}'
}
term_width() { local w; w=$(tput cols 2>/dev/null || echo 100); echo $((w - 2)); }

# one redrawing line: "bar  pct%  detail"
show_progress() {
    local pct=${1%.*} detail="$2"; [ -z "$pct" ] && pct=0
    [ "$STOP_REQUESTED" = 1 ] && detail="$detail   [Q pressed: stopping after this video]"
    local line; line=$(printf '   %s %3d%%  %s' "$(make_bar "$pct")" "$pct" "$detail")
    local w; w=$(term_width); line="${line:0:$w}"
    printf '\r%s%-*s%s' "$C_CYAN" "$w" "$line" "$C_OFF"
}
end_line() { printf '\n'; }

start_step() {
    CUR_STEP=$1
    local ov; ov=$(overall_pct 0)
    printf '\n%s=== Step %d of %d: %s%s\n' "$C_YEL" "$1" "${#STEP_NAMES[@]}" "${STEP_NAMES[$1 - 1]}" "$C_OFF"
    printf '%s    Overall   %s %3d%%%s\n' "$C_MAG" "$(make_bar "$ov")" "$ov" "$C_OFF"
    logf "STEP $1: ${STEP_NAMES[$1 - 1]}"
}
end_step() { local ov; ov=$(overall_pct 100); printf '%s    Overall   %s %3d%%%s\n' "$C_MAG" "$(make_bar "$ov")" "$ov" "$C_OFF"; }

show_banner() {
    printf '%s' "$C_CYAN"
    cat <<'EOF'

   _____   ___   _____  ___  ____      __  __  _   _  ____   ___   ____
  | ____| / _ \ |_   _||_ _||  _ \    |  \/  || | | |/ ___| |_ _| / ___|
  |  _|  | | | |  | |   | | | |_) |   | |\/| || | | |\___ \  | | | |
  | |___ | |_| |  | |   | | |  _ <    | |  | || |_| | ___) | | | | |___
  |_____| \___/   |_|  |___||_| \_\   |_|  |_| \___/ |____/ |___| \____|
EOF
    printf '%s' "$C_MAG"
    cat <<'EOF'
   ____   ____    ___       _  _____   ____  _____
  |  _ \ |  _ \  / _ \     | || ____| / ___||_   _|
  | |_) || |_) || | | | _  | ||  _|  | |      | |
  |  __/ |  _ < | |_| || |_| || |___ | |___   | |
  |_|    |_| \_\ \___/  \___/ |_____| \____|  |_|
EOF
    printf '%s\n   ==============  R E N D E R   H E L P E R  (Linux)  ==============%s\n' "$C_YEL" "$C_OFF"
    printf '%s   Thank you for lending your computer to the EOTIR Music Project!%s\n\n' "$C_WHITE" "$C_OFF"
}

# Press Q to stop. Only when stdin is a real terminal. A Q during a video means "stop after it is delivered".
quit_pressed() {
    # Unattended (VPS, tmux, a service): `touch <home>/STOP` asks it to stop - immediately while waiting, otherwise after
    # the current video is delivered. Same meaning as pressing Q.
    if [ -n "${STOP_FILE:-}" ] && [ -e "$STOP_FILE" ]; then STOP_REQUESTED=1; fi
    if [ -t 0 ]; then
        local k
        while read -rsn1 -t 0.01 k 2>/dev/null; do [ "$k" = q ] || [ "$k" = Q ] && STOP_REQUESTED=1; done
    fi
    [ "$STOP_REQUESTED" = 1 ]
}
nap() {   # sleep N seconds but notice Q (returns 1 if Q was pressed)
    local s=$1
    if [ -t 0 ]; then
        local k
        if read -rsn1 -t "$s" k 2>/dev/null; then [ "$k" = q ] || [ "$k" = Q ] && { STOP_REQUESTED=1; return 1; }; fi
    else
        sleep "$s"
    fi
    return 0
}

# ---------------------------------------------------------------- small helpers
jget() {   # jget FILE dotted.key  -> value ('' if missing)
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
    for k in sys.argv[2].split('.'):
        d = d[k]
    print('' if d is None else d)
except Exception:
    print('')
PY
}
file_len() { [ -f "$1" ] && stat -c%s "$1" 2>/dev/null || echo 0; }
sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
unzip_to() {   # unzip_to ZIP DEST
    mkdir -p "$2"
    if command -v unzip >/dev/null 2>&1; then unzip -q -o "$1" -d "$2" </dev/null; else
        python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2" </dev/null
    fi
}

# ---------------------------------------------------------------- failures + error reports
ERR_CODE=""; ERR_MSG=""; JOB_ID_NOW=""; KIT_VER_NOW=""; REPORTED=0; LAST_LINE="?"
trap 'LAST_LINE=$LINENO' ERR

build_report() {   # build_report CODE -> path
    local code="$1" rp="$LOGS/ERROR-REPORT-$(date +%Y%m%d-%H%M%S)-$code.txt" step="before step 1"
    [ "$CUR_STEP" -gt 0 ] && step="$CUR_STEP of ${#STEP_NAMES[@]} - ${STEP_NAMES[$CUR_STEP - 1]}"
    {
        echo "=== EOTIR RENDER HELPER (LINUX) - ERROR REPORT ==="
        echo "Error code : $code"
        echo "Step       : $step"
        echo "When (UTC) : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Running for: $(fmt_time $(( $(date +%s) - START_EPOCH )))"
        echo "Helper     : ${USER_NAME:-"(config not read yet)"}"
        echo "Job        : ${JOB_ID_NOW:-"(none picked yet)"}"
        echo "Message    : $ERR_MSG"
        echo; echo "--- technical detail ---"
        echo "Script line (last non-zero command): $LAST_LINE"
        echo; echo "--- this computer ---"
        echo "OS            : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") ($(uname -srm))"
        grep -qi microsoft /proc/version 2>/dev/null && echo "Environment   : WSL"
        echo "bash          : $BASH_VERSION"
        echo "CPU threads   : $(nproc 2>/dev/null)"
        echo "Memory        : $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null)"
        echo "Free disk     : $(df -h "$HOME_DIR" 2>/dev/null | awk 'NR==2 {print $4}') on $HOME_DIR"
        echo "Script version: $SCRIPT_VERSION (build $SCRIPT_BUILD)"
        echo "Node          : $(node -v 2>/dev/null || echo 'not available')"
        echo "Kit           : ${KIT_VER_NOW:-n/a}"
        echo "Helper account: ${USER_NAME:-n/a}  server ${HOST:-n/a}:${PORT:-n/a}"
        for t in sftp curl tar python3 unzip ssh-keygen sha256sum; do printf '%-14s: %s\n' "$t" "$(command -v $t || echo MISSING)"; done
        echo; echo "--- main log (last part) ---"
        tail -c 6000 "$LOG_FILE" 2>/dev/null
        local f
        for f in $(ls -t "$LOGS"/*.log 2>/dev/null | head -5); do
            [ "$f" = "$LOG_FILE" ] && continue
            [ "$f" -ot "$START_MARK" ] && continue
            echo; echo "--- $(basename "$f") (last part) ---"; tail -c 4000 "$f" | tr '\r' '\n'
        done
    } >"$rp" 2>&1
    echo "$rp"
}

report_and_exit() {
    local code="${ERR_CODE:-E-SCRIPT-L$LAST_LINE}" rp="" sent=0
    REPORTED=1
    if [ -n "${LOGS:-}" ] && [ -d "$LOGS" ]; then
        rp=$(build_report "$code")
        printf '\n%s   (Writing a report and sending it to Ryan...)%s\n' "$C_GRAY" "$C_OFF"
        if [ -n "${KEY_PATH:-}" ] && [ -f "$KEY_PATH" ]; then
            local ts; ts=$(date +%Y%m%d-%H%M%S)
            sftp_run "-mkdir \"results/$USER_NAME/_reports\"" "put \"$rp\" \"results/$USER_NAME/_reports/${ts}_${code}.txt\"" && [ "$SFTP_CODE" -eq 0 ] && sent=1
        fi
    fi
    printf '\n\n%s------------------------------------------------------------%s\n' "$C_RED" "$C_OFF"
    printf '%s  Oops - something did not work. Nothing on your computer is harmed.%s\n\n' "$C_RED" "$C_OFF"
    printf '%s  ERROR CODE:    %s%s\n' "$C_YEL" "$code" "$C_OFF"
    printf '%s  What happened: %s%s\n\n' "$C_YEL" "${ERR_MSG:-an unexpected problem (see the report)}" "$C_OFF"
    if [ "$sent" = 1 ]; then
        printf '%s  A full report was sent to Ryan automatically.%s\n  Just tell him the ERROR CODE above - he already has the details.\n' "$C_GREEN" "$C_OFF"
    else
        printf '%s  The report could not be sent automatically (no connection?).%s\n  Please send Ryan the ERROR CODE above and this file:\n' "$C_YEL" "$C_OFF"
        [ -n "$rp" ] && printf '%s     %s%s\n' "$C_CYAN" "$rp" "$C_OFF"
    fi
    printf '\n  You can also just run this again - it picks up where it left off.\n'
    printf '%s------------------------------------------------------------%s\n' "$C_RED" "$C_OFF"
    exit 1
}
fail() { ERR_CODE="$1"; ERR_MSG="$2"; logf "FAIL [$1] $2"; report_and_exit; }

on_exit() {
    local rc=$?
    # stop anything we started in the background
    local p; for p in $(jobs -p 2>/dev/null); do kill "$p" 2>/dev/null; done
    # an unexpected crash (not one of our own fail calls) still gets a code + report
    if [ "$rc" -ne 0 ] && [ "$REPORTED" = 0 ] && [ "$rc" -ne 130 ] && [ "$rc" -ne 2 ] && [ "$rc" -ne 143 ]; then
        ERR_CODE="E-SCRIPT-L$LAST_LINE"; ERR_MSG="${ERR_MSG:-unexpected error (exit $rc)}"; trap - EXIT
        report_and_exit
    fi
}
on_signal() { printf '\n%sStopped.%s\n' "$C_YEL" "$C_OFF"; REPORTED=1; exit 130; }

# ---------------------------------------------------------------- SFTP to Ryan's server
TRANSIENT='kex_exchange_identification|Connection reset|Connection closed|Connection timed out|Connection refused|Broken pipe|ssh_exchange_identification|Could not resolve|Network is unreachable|No route to host'
SFTP_OUT=""; SFTP_CODE=0
build_sftp_opts() {
    SFTP_OPTS=(-P "$PORT" -i "$KEY_PATH" -o BatchMode=yes -o IdentitiesOnly=yes -o "UserKnownHostsFile=$KNOWN" \
        -o StrictHostKeyChecking=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=8)
}
# Run a short command list and wait. A leading '-' lets that command fail without stopping the batch. Dropped
# connections (Vector's sshd throttles bursts: "kex_exchange_identification: Connection reset") are retried.
sftp_run() {
    local bf; bf=$(mktemp "$TMP/b.XXXXXX"); printf '%s\n' "$@" >"$bf"
    local try=0 delays=(4 10 20)
    while :; do
        SFTP_OUT=$(sftp -b "$bf" "${SFTP_OPTS[@]}" "$USER_NAME@$HOST" </dev/null 2>&1); SFTP_CODE=$?
        logf "sftp [$(printf '%s ; ' "$@")] -> exit $SFTP_CODE$([ $try -gt 0 ] && echo " (retry $try)")"
        if [ "$SFTP_CODE" -eq 0 ] || ! grep -Eq "$TRANSIENT" <<<"$SFTP_OUT" || [ "$try" -ge 3 ]; then break; fi
        sleep "${delays[$try]}"; try=$((try + 1))
    done
    rm -f "$bf"
    return 0
}
BG_PID=0; BG_CODE=0
sftp_bg() {   # sftp_bg TAG lines... -> starts in the background, sets BG_PID
    local tag="$1"; shift
    local bf="$TMP/bg_$tag.batch"; printf '%s\n' "$@" >"$bf"
    sftp -b "$bf" "${SFTP_OPTS[@]}" "$USER_NAME@$HOST" </dev/null >"$TMP/sftp_$tag.out" 2>&1 &
    BG_PID=$!
}
remote_size() {   # remote_size PATH -> size in bytes, or -1
    sftp_run "ls -l \"$1\""
    [ "$SFTP_CODE" -ne 0 ] && { echo -1; return; }
    # the size is column 5 of the long listing ("-rw-rw---- ? 1004 1004 295659266 Oct 5 18:48 path")
    local sz; sz=$(awk '$1 ~ /^[-d]/ {print $5; exit}' <<<"$SFTP_OUT")
    echo "${sz:--1}"
}
explain_connect_error() {
    case "$1" in
        *"Permission denied"*) echo "The server did not accept this computer's key. Ryan may need to re-enable it." ;;
        *"REMOTE HOST IDENTIFICATION"*|*"Host key verification"*) echo "The server's ID did not match what we expected. Please do NOT continue - tell Ryan right away." ;;
        *"timed out"*|*"refused"*|*"Could not resolve"*|*"No route"*|*"unreachable"*) echo "Could not reach the server. Check that your internet is working. If it is, the server may be busy for a moment." ;;
        *"banned"*|*"Connection closed"*|*"Connection reset"*) echo "The server closed the connection. If you tried several times it may have paused you for a while. Wait an hour and try again, or tell Ryan." ;;
        *) echo "The connection failed." ;;
    esac
}

# Poll a byte counter (a local file's size) and draw bar + speed + ETA until PID exits.
watch_transfer() {   # watch_transfer PID FILE TOTAL_BYTES LABEL
    local pid=$1 file=$2 total=$3 label=$4 t0 b last_b last_t now speed=0 pct eta
    t0=$(date +%s); last_b=$(file_len "$file"); last_t=$t0
    while kill -0 "$pid" 2>/dev/null; do
        b=$(file_len "$file"); now=$(date +%s)
        if [ $((now - last_t)) -ge 1 ]; then
            speed=$(awk -v b="$b" -v lb="$last_b" -v dt=$((now - last_t)) -v s="$speed" 'BEGIN{i=(b-lb)/dt; if(s==0) print i; else print 0.7*s+0.3*i}')
            last_b=$b; last_t=$now
        fi
        if [ "${total%.*}" -gt 0 ] 2>/dev/null; then
            pct=$(awk -v b="$b" -v t="$total" 'BEGIN{printf "%d", 100*b/t}')
            eta=$(awk -v b="$b" -v t="$total" -v s="$speed" 'BEGIN{if(s>1) printf "%d", (t-b)/s; else print -1}')
            show_progress "$pct" "$label  $(fmt_mb "$b") of $(fmt_mb "$total")  $(fmt_mb "$speed")/s  about $(fmt_time "$eta") left"
        else
            show_progress 50 "$label  $(fmt_mb "$b") so far"
        fi
        quit_pressed >/dev/null
        sleep 0.5
    done
    wait "$pid" 2>/dev/null; BG_CODE=$?
    show_progress 100 "$label  finished in $(fmt_time $(( $(date +%s) - t0 )))"; end_line
}
download_file() {   # download_file URL DEST LABEL
    local url="$1" dest="$2" label="$3" total=0 h
    h=$(curl -sIL --max-time 30 "$url" </dev/null 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:" {v=$2} END{print v+0}')
    [ -n "$h" ] && total=$h
    curl -fsSL --retry 3 -C - -o "$dest" "$url" </dev/null 2>"$TMP/curl.err" &
    local pid=$!
    watch_transfer "$pid" "$dest" "$total" "$label"
    [ "$BG_CODE" -ne 0 ] && fail "E-DOWNLOAD" "Download of $label failed (code $BG_CODE). Is your internet working?"
}
spin_wait() {   # spin_wait PID LABEL LOGFILE -> waits, drawing a spinner; sets BG_CODE
    local pid=$1 label=$2 lg=$3 t0 i=0 el last sp='|/-\'
    t0=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        el=$(( $(date +%s) - t0 )); last=""
        [ -f "$lg" ] && last=$(tail -c 300 "$lg" 2>/dev/null | tr '\r' '\n' | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-60)
        show_progress "$(awk -v e="$el" 'BEGIN{printf "%d", 95*(1-exp(-e/150))}')" "${sp:$((i % 4)):1} $label  working for $(fmt_time $el)  $last"
        i=$((i + 1)); sleep 0.4
    done
    wait "$pid" 2>/dev/null; BG_CODE=$?
    show_progress 100 "$label done in $(fmt_time $(( $(date +%s) - t0 )))"; end_line
}

# ---------------------------------------------------------------- self-update (signed)
# The updater pulls from a PUBLIC repo, so that repo is NOT trusted: an update is accepted only if latest.json
# carries a valid ssh-keygen -Y signature from Ryan's release key (public half = allowed_signers, shipped in this
# package). A build number that is not newer is ignored (no rollback). Only the files named below can be replaced;
# helper.json / helper_key / known_hosts never are.
UPDATE_ALLOWED=("eotir-render.sh" "How It Works.html")
RELAUNCHED=0

check_for_update() {
    [ "$OPT_NOUPDATE" = 1 ] && return 0
    local base="${UPDATE_URL%/}" signers="$PKG_DIR/allowed_signers"
    if [ -z "$base" ] || [ ! -f "$signers" ]; then logf "updates: not configured"; return 0; fi
    say "Checking for a newer version of this helper..."
    local d="$TMP/upd"; rm -rf "$d"; mkdir -p "$d"
    if ! curl -fsSL --max-time 25 --retry 1 -o "$d/latest.json" "$base/latest.json" </dev/null 2>/dev/null \
       || ! curl -fsSL --max-time 25 --retry 1 -o "$d/latest.json.sig" "$base/latest.json.sig" </dev/null 2>/dev/null; then
        hint "(Could not check for updates just now - that is fine, carrying on.)"; return 0
    fi
    local vout; vout=$(ssh-keygen -Y verify -f "$signers" -I eotir-helper-release -n eotir-render-helper -s "$d/latest.json.sig" <"$d/latest.json" 2>&1); local vrc=$?
    logf "signature check rc=$vrc: $vout"
    if [ "$vrc" -ne 0 ] || [[ "$vout" != Good* ]]; then
        warn "An update was found but its signature did not check out, so it was IGNORED. Carrying on with this version. (Please tell Ryan.)"; return 0
    fi
    local nb nv nn
    nb=$(jget "$d/latest.json" linux.build); nv=$(jget "$d/latest.json" linux.version); nn=$(jget "$d/latest.json" linux.notes)
    [ -z "$nb" ] && { logf "update manifest has no linux block"; good "This helper is up to date (version $SCRIPT_VERSION)."; return 0; }
    if [ "$nb" -le "$SCRIPT_BUILD" ] 2>/dev/null; then good "This helper is up to date (version $SCRIPT_VERSION)."; return 0; fi
    say ""; say "A newer version of this helper is available: $nv" "$C_YEL"
    [ -n "$nn" ] && hint "What's new: $nn"
    local ans="y"
    if [ -t 0 ]; then read -r -p "   Update now? Press Enter for yes, or type n to skip: " ans || ans="n"; fi
    case "$ans" in n*|N*) hint "Okay - keeping the current version for now."; return 0 ;; esac

    # download + verify every file against the SIGNED manifest before touching anything
    local lines; lines=$(python3 - "$d/latest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding='utf-8'))
for f in m.get('linux', {}).get('files', []):
    print('%s\t%s\t%s' % (f['path'], f['sha256'], f['bytes']))
PY
)
    local p sha bytes allowed a
    mkdir -p "$d/new"
    while IFS=$'\t' read -r p sha bytes; do
        [ -z "$p" ] && continue
        allowed=0; for a in "${UPDATE_ALLOWED[@]}"; do [ "$a" = "$p" ] && allowed=1; done
        [ "$allowed" = 0 ] && { logf "update: ignoring non-allowed path $p"; continue; }
        local enc; enc=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$p")
        if ! curl -fsSL --max-time 60 -o "$d/new/$p" "$base/files/$enc" </dev/null 2>/dev/null; then warn "Could not download $p; staying on the current version."; return 0; fi
        if [ "$(sha_of "$d/new/$p")" != "$sha" ] || [ "$(file_len "$d/new/$p")" != "$bytes" ]; then warn "$p did not match its checksum; update cancelled."; return 0; fi
    done <<<"$lines"
    if [ -f "$d/new/eotir-render.sh" ] && ! bash -n "$d/new/eotir-render.sh" 2>/dev/null; then warn "The new script does not parse; update cancelled."; return 0; fi
    # Install: temp name in the SAME folder + mv (atomic, new inode) - never overwrite the running script in place.
    for p in "${UPDATE_ALLOWED[@]}"; do
        [ -f "$d/new/$p" ] || continue
        [ -f "$PKG_DIR/$p" ] && cp -f "$PKG_DIR/$p" "$PKG_DIR/$p.bak" 2>/dev/null
        cp -f "$d/new/$p" "$PKG_DIR/$p.new.$$" && { [ "$p" = "eotir-render.sh" ] && chmod +x "$PKG_DIR/$p.new.$$"; mv -f "$PKG_DIR/$p.new.$$" "$PKG_DIR/$p"; } \
            || { warn "Could not install the update here; staying on the current version."; return 0; }
    done
    good "Updated to $nv. Restarting the helper with the new version..."
    RELAUNCHED=1
    exec "$SELF_PATH" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
}

# ---------------------------------------------------------------- finding this helper's next job
JOBDIR=""; J_ID=""; J_PROJ=""; J_OUT=""; J_EXPECT=0; J_FPS=30; J_FRAMES=""; J_ZBYTES=0; J_ZSHA=""; J_KITVER=""; J_NOTE=""
# Sets J_* for the oldest unfinished job assigned to this helper and returns 0, or returns 1 if there is none.
# Returns 2 on a listing failure (message in LIST_ERR).
LIST_ERR=""
get_next_job() {   # get_next_job QUIET(0|1)
    local quiet="$1"
    sftp_run "ls -1 jobs"
    [ "$SFTP_CODE" -ne 0 ] && { LIST_ERR="Could not look at the job list. $(explain_connect_error "$SFTP_OUT")"; return 2; }
    local ids; ids=$(sed 's#^.*/##; s/[[:space:]]*$//' <<<"$SFTP_OUT" | grep -Ev '^$|^_|^sftp>' || true)
    local jd="$TMP/jobs"; mkdir -p "$jd"; rm -f "$jd"/*.json
    sftp_run "-ls -1 results/$USER_NAME"
    sed 's#^.*/##; s/[[:space:]]*$//' <<<"$SFTP_OUT" >"$TMP/done.txt"
    local want=() id lines=()
    for id in $ids; do [ -z "$OPT_JOB" ] || [ "$id" = "$OPT_JOB" ] && want+=("$id"); done
    [ "${#want[@]}" -eq 0 ] && return 1
    # ONE connection for all job.json files (a '-' prefix lets a missing one fail without stopping the batch)
    for id in "${want[@]}"; do lines+=("-get \"jobs/$id/job.json\" \"$jd/$id.json\""); done
    sftp_run "${lines[@]}"
    local picked; picked=$(python3 - "$jd" "$USER_NAME" "$TMP/done.txt" "$quiet" 2>"$TMP/pick.err" <<'PY'
import glob, json, os, shlex, sys
jd, user, donef, quiet = sys.argv[1:5]
done = set(l.strip() for l in open(donef, encoding='utf-8') if l.strip())
best = None
for p in glob.glob(os.path.join(jd, '*.json')):
    try:
        j = json.load(open(p, encoding='utf-8'))
    except Exception:
        continue
    if j.get('assigned_to') != user:
        continue
    if j.get('out_name') in done:
        if quiet != '1':
            sys.stderr.write('ALREADY\t%s\n' % j.get('out_name'))
        continue
    if best is None or str(j.get('created_at', '')) < str(best.get('created_at', '')):
        best = j
if best is None:
    sys.exit(1)
z = best.get('zip') or {}
vals = {
    'J_ID': best.get('job_id', ''), 'J_PROJ': best.get('proj_id', ''), 'J_OUT': best.get('out_name', ''),
    'J_EXPECT': best.get('expected_duration', 0), 'J_FPS': best.get('fps', 30), 'J_FRAMES': best.get('frames') or '',
    'J_ZBYTES': z.get('bytes', 0), 'J_ZSHA': z.get('sha256', ''), 'J_KITVER': best.get('kit_version') or '',
    'J_NOTE': best.get('note') or '',
}
for k, v in vals.items():
    print('%s=%s' % (k, shlex.quote(str(v))))
PY
    )
    local rc=$?
    if [ "$quiet" != 1 ]; then while IFS=$'\t' read -r tag nm; do [ "$tag" = ALREADY ] && hint "Already finished earlier: $nm"; done <"$TMP/pick.err"; fi
    [ "$rc" -ne 0 ] || [ -z "$picked" ] && return 1
    eval "$picked"
    return 0
}

# ---------------------------------------------------------------- Chrome's system libraries (Linux only)
chrome_missing_libs() {   # prints the missing shared libraries of Remotion's Chrome, one per line
    local bin; bin=$(find "$COMPOSER/node_modules/.remotion" -name chrome-headless-shell -type f 2>/dev/null | head -1)
    [ -z "$bin" ] && return 0
    ldd "$bin" 2>/dev/null </dev/null | awk '/not found/ {print $1}'
}
apt_chrome_packages() {   # the list from Remotion's Linux docs; Ubuntu 24.04 renamed libasound2 -> libasound2t64
    local alsa=libasound2
    apt-cache show libasound2t64 >/dev/null 2>&1 && alsa=libasound2t64
    echo "libnss3 libdbus-1-3 libatk1.0-0 $alsa libxrandr2 libxkbcommon-dev libxfixes3 libxcomposite1 libxdamage1 libgbm-dev libcups2 libcairo2 libpango-1.0-0 libatk-bridge2.0-0"
}

# ================================================================= MAIN
START_EPOCH=$(date +%s)
main() {
    parse_args "$@"

    # keep the machine awake while we work (systemd only; silently skipped on WSL / over ssh without polkit)
    if [ -z "${EOTIR_INHIBITED:-}" ] && command -v systemd-inhibit >/dev/null 2>&1 \
       && timeout 5 systemd-inhibit --what=idle:sleep --who="EOTIR render helper" --why="test" true </dev/null >/dev/null 2>&1; then
        export EOTIR_INHIBITED=1
        exec systemd-inhibit --what=idle:sleep --who="EOTIR render helper" --why="Rendering a video for the EOTIR Music Project" "$SELF_PATH" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    fi

    trap on_exit EXIT
    trap on_signal INT TERM
    [ -t 1 ] && clear
    show_banner

    HOME_DIR="${OPT_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/eotir}"
    mkdir -p "$HOME_DIR/tmp" "$HOME_DIR/logs" "$HOME_DIR/keys"
    TMP="$HOME_DIR/tmp"; LOGS="$HOME_DIR/logs"; STOP_FILE="$HOME_DIR/STOP"
    if [ -e "$STOP_FILE" ]; then rm -f "$STOP_FILE"; hint "(Removed an old STOP file left over from an earlier run.)"; fi
    LOG_FILE="$LOGS/helper-$(date +%Y%m%d-%H%M%S).log"; START_MARK="$LOG_FILE"
    logf "start; pkg=$PKG_DIR home=$HOME_DIR script=$SCRIPT_VERSION build=$SCRIPT_BUILD"

    say "Here is what is going to happen. You do not need to do anything - just leave this window open:"
    hint "1. We check your computer is ready."
    hint "2. We download the tools needed to make the video (first time only, a few minutes)."
    hint "3. We find the video Ryan set aside for you and download its pictures and music."
    hint "4. Your computer makes the video. THIS IS THE LONG PART (often 1 to 2 hours)."
    hint "5. We send the finished video back to Ryan - then look for the next one."
    say ""
    say "Please:  keep this window open  |  keep your computer plugged in  |  press Q to stop." "$C_YEL"

    # ---------- Step 1: computer check
    start_step 1
    say "Making sure your computer is ready to help..."
    case "$(uname -s)" in Linux) ;; *) fail "E-CHECK-OS" "This helper is for Linux (or WSL). On Windows use the Windows helper." ;; esac
    local arch; case "$(uname -m)" in x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; *) fail "E-CHECK-OS64" "Unsupported CPU type: $(uname -m)." ;; esac
    good "Linux $(uname -r) ($arch)$(grep -qi microsoft /proc/version 2>/dev/null && echo ', running in WSL')."
    local missing=() t
    for t in curl tar gzip sftp ssh-keygen sha256sum python3; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
    if [ "${#missing[@]}" -gt 0 ]; then
        local hintcmd="install them with your package manager"
        command -v apt-get >/dev/null 2>&1 && hintcmd="sudo apt-get install -y curl tar gzip openssh-client coreutils python3 unzip"
        command -v dnf >/dev/null 2>&1 && hintcmd="sudo dnf install -y curl tar gzip openssh-clients coreutils python3 unzip"
        command -v pacman >/dev/null 2>&1 && hintcmd="sudo pacman -S --needed curl tar gzip openssh coreutils python unzip"
        fail "E-CHECK-TOOLS" "Missing tools: ${missing[*]}. Try: $hintcmd"
    fi
    good "The tools we need are installed."
    local free_gb; free_gb=$(df -Pk "$HOME_DIR" | awk 'NR==2 {printf "%.1f", $4/1048576}')
    awk -v f="$free_gb" 'BEGIN{exit !(f<15)}' && fail "E-CHECK-DISK" "Not enough free space: $free_gb GB free. We need about 15 GB. Please free some space and run this again."
    good "$free_gb GB free disk space - plenty."
    local ram; ram=$(awk '/MemTotal/ {printf "%.1f", $2/1048576}' /proc/meminfo)
    if awk -v r="$ram" 'BEGIN{exit !(r<8)}'; then warn "Only $ram GB of memory. Making the video may be slow or fail. We will try anyway."; else good "$ram GB memory and $(nproc) processor threads."; fi
    [ -f "$PKG_DIR/helper.json" ] || fail "E-CHECK-TOOLS" "helper.json is missing next to this script."
    HOST=$(jget "$PKG_DIR/helper.json" host); PORT=$(jget "$PKG_DIR/helper.json" port)
    USER_NAME=$(jget "$PKG_DIR/helper.json" user); UPDATE_URL=$(jget "$PKG_DIR/helper.json" update_url)
    good "This computer is signed up as helper '$USER_NAME'."
    # The private key must be readable only by you, or ssh refuses it.
    KEY_PATH="$HOME_DIR/keys/helper_key"; KNOWN="$HOME_DIR/keys/known_hosts"
    cp -f "$PKG_DIR/helper_key" "$KEY_PATH" && chmod 600 "$KEY_PATH"
    cp -f "$PKG_DIR/known_hosts" "$KNOWN"
    build_sftp_opts
    end_step

    check_for_update

    say ""; say "Quick test: can we reach Ryan's server?"
    sftp_run "ls"
    [ "$SFTP_CODE" -ne 0 ] && { logf "$SFTP_OUT"; fail "E-CONNECT" "Could not connect. $(explain_connect_error "$SFTP_OUT")"; }
    good "Connected to Ryan's server. The connection is secure and the server is who it says it is."
    if [ "$OPT_CHECK_ONLY" = 1 ]; then say ""; say "All checks passed. You are ready!" "$C_GREEN"; REPORTED=1; exit 0; fi

    # ---------- Step 2: Node
    start_step 2
    local node_root="$HOME_DIR/node" node_bin
    node_bin=$(find "$node_root" -maxdepth 3 -name node -type f -path '*/bin/node' 2>/dev/null | head -1)
    if [ -z "$node_bin" ]; then
        say "Downloading a small tool called Node.js (it runs the video maker). Only needed once."
        hint "It is a free, well-known program. It goes in your Eotir folder only - nothing else on your computer changes."
        mkdir -p "$node_root"
        local base="https://nodejs.org/dist/latest-v22.x"
        download_file "$base/SHASUMS256.txt" "$TMP/SHASUMS256.txt" "checking the latest version"
        local line want zipname
        line=$(grep -E "node-v22\.[0-9.]+-linux-$arch\.tar\.gz\$" "$TMP/SHASUMS256.txt" | head -1)
        [ -z "$line" ] && fail "E-NODE-LIST" "Could not find the Node.js download for $arch. Please tell Ryan."
        want=${line%% *}; zipname=${line##* }
        download_file "$base/$zipname" "$TMP/$zipname" "Node.js"
        say "Checking the download is genuine..."
        [ "$(sha_of "$TMP/$zipname")" = "$want" ] || { rm -f "$TMP/$zipname"; fail "E-NODE-SUM" "The Node.js download did not match its checksum. Please run this again; if it keeps happening tell Ryan."; }
        good "Download verified."
        say "Unpacking..."
        tar -xzf "$TMP/$zipname" -C "$node_root" </dev/null || fail "E-NODE-UNPACK" "Could not unpack Node.js."
        rm -f "$TMP/$zipname"
        node_bin=$(find "$node_root" -maxdepth 3 -name node -type f -path '*/bin/node' | head -1)
    else good "Node.js is already here - skipping."; fi
    export PATH="$(dirname "$node_bin"):$PATH"
    good "Node.js ready ($(node -v </dev/null))."
    end_step

    # ---------- Step 3: kit
    start_step 3
    sftp_run "get \"jobs/_kit/kit.json\" \"$TMP/kit.json\""
    [ "$SFTP_CODE" -ne 0 ] && { logf "$SFTP_OUT"; fail "E-KIT-MISSING" "Could not find the render kit on the server. Please tell Ryan (the kit may not be uploaded yet)."; }
    local kit_version kit_file kit_bytes kit_sha
    kit_version=$(jget "$TMP/kit.json" version); kit_file=$(jget "$TMP/kit.json" file)
    kit_bytes=$(jget "$TMP/kit.json" bytes); kit_sha=$(jget "$TMP/kit.json" sha256)
    KIT_VER_NOW="$kit_version"
    local kit_dir="$HOME_DIR/k/${kit_sha:0:8}"; COMPOSER="$kit_dir/remotion-composer"
    if [ ! -f "$kit_dir/READY" ]; then
        say "Downloading the EOTIR render kit (version $kit_version)..."
        hint "This is the video-making recipe Ryan uses, so your video comes out identical to his."
        sftp_bg kit "get \"jobs/_kit/$kit_file\" \"$TMP/$kit_file\""
        watch_transfer "$BG_PID" "$TMP/$kit_file" "$kit_bytes" "render kit"
        [ "$BG_CODE" -ne 0 ] && fail "E-KIT-DL" "Could not download the render kit."
        [ "$(sha_of "$TMP/$kit_file")" = "$kit_sha" ] || fail "E-KIT-SUM" "The render kit did not match its checksum. Tell Ryan."
        good "Kit downloaded and verified."
        rm -rf "$kit_dir"; mkdir -p "$kit_dir"
        unzip_to "$TMP/$kit_file" "$kit_dir" || fail "E-KIT-UNPACK" "Could not unpack the render kit."
        rm -f "$TMP/$kit_file"
        say "Installing the video-making parts (this downloads a few hundred MB; first time only)..."
        hint "You may see the bar move slowly. That is normal - it is fetching lots of small pieces."
        ( cd "$COMPOSER" && npm ci --no-audit --no-fund </dev/null >"$LOGS/npm-ci.log" 2>"$LOGS/npm-ci.err.log" ) &
        spin_wait $! "installing" "$LOGS/npm-ci.log"
        [ "$BG_CODE" -ne 0 ] && fail "E-KIT-NPM" "Installing the video tools failed. Please send Ryan the file: $LOGS/npm-ci.log"
        say "Getting the built-in video browser Remotion uses (one more download)..."
        ( cd "$COMPOSER" && ./node_modules/.bin/remotion browser ensure </dev/null >"$LOGS/browser-ensure.log" 2>"$LOGS/browser-ensure.err.log" ) &
        spin_wait $! "browser" "$LOGS/browser-ensure.log"
        [ "$BG_CODE" -ne 0 ] && fail "E-KIT-BROWSER" "Could not get the video browser. Please send Ryan the file: $LOGS/browser-ensure.log"
        # Chrome needs a handful of system libraries on Linux; detect, and offer the exact install command.
        local libs; libs=$(chrome_missing_libs)
        if [ -n "$libs" ]; then
            warn "The video browser needs some system libraries that are missing: $(echo $libs | tr '\n' ' ')"
            if command -v apt-get >/dev/null 2>&1; then
                local pk; pk=$(apt_chrome_packages)
                say "To install them, run:   sudo apt-get install -y $pk" "$C_CYAN"
                local ans="n"
                if [ -t 0 ] && command -v sudo >/dev/null 2>&1; then read -r -p "   Run that now with sudo? [y/N] " ans || ans="n"; fi
                case "$ans" in y*|Y*) sudo apt-get install -y $pk </dev/null ;; esac
                libs=$(chrome_missing_libs)
            fi
            [ -n "$libs" ] && fail "E-KIT-LIBS" "Still missing system libraries for the video browser: $(echo $libs | tr '\n' ' '). Install them (Remotion's Linux dependency list) and run this again."
        fi
        date -u +%FT%TZ >"$kit_dir/READY"
        good "Render kit installed."
    else good "Render kit $kit_version is already installed - skipping."; fi
    end_step

    # ---------- From here on it is a LOOP: find a job (waiting if there is none), make it, deliver it - then look
    # for the next one, until Q is pressed (or --once / --no-wait / --job say otherwise).
    while :; do
        [ "$STOP_REQUESTED" = 1 ] && break

        # ---------- Step 4: find the job
        start_step 4
        say "Looking for a video job set aside for you..."
        get_next_job 0; local rc=$?
        [ "$rc" -eq 2 ] && fail "E-JOB-LIST" "$LIST_ERR"
        if [ "$rc" -ne 0 ]; then
            if [ "$OPT_NOWAIT" = 1 ]; then
                say ""; say "There is no new video job for you right now." "$C_GREEN"
                say "That is fine! Ryan will message you when there is one. You can close this window."; REPORTED=1; exit 0
            fi
            say ""; say "There is no video job for you yet - and that is completely fine!" "$C_GREEN"
            say "Leave this window open. The moment Ryan queues a video for you, it starts all by itself."
            if [ "$OPT_MAXWAIT" -gt 0 ] 2>/dev/null; then hint "We look every $(awk -v p="$OPT_POLL" 'BEGIN{printf "%.1f", p/60}') minutes, for up to $OPT_MAXWAIT hours."
            else hint "We look every $(awk -v p="$OPT_POLL" 'BEGIN{printf "%.1f", p/60}') minutes and keep going until you stop us."; fi
            hint "To stop: press the Q key, or just close this window; unattended: touch $STOP_FILE"
            local wstart fails=0 nextt left
            wstart=$(date +%s)
            while [ "$rc" -ne 0 ]; do
                nextt=$(( $(date +%s) + OPT_POLL ))
                while [ "$(date +%s)" -lt "$nextt" ]; do
                    if quit_pressed >/dev/null; then end_line; say ""; say "OK - stopping, as you asked. Thank you for helping!" "$C_GREEN"; REPORTED=1; exit 0; fi
                    left=$(( nextt - $(date +%s) ))
                    show_progress "$(( 100 - 100 * left / OPT_POLL ))" "waiting for a job   next look in $(fmt_time $left)   waiting so far: $(fmt_time $(( $(date +%s) - wstart )))   (Q to stop)"
                    nap 1 || true
                done
                end_line
                if [ "$OPT_MAXWAIT" -gt 0 ] 2>/dev/null && [ $(( $(date +%s) - wstart )) -ge $(( OPT_MAXWAIT * 3600 )) ]; then
                    say ""; say "Nothing came up in $OPT_MAXWAIT hours, so we are stopping to save your electricity." "$C_YEL"
                    say "Open this again whenever Ryan messages you that there is a video for you."; REPORTED=1; exit 0
                fi
                # a hiccup in the connection while waiting is not an error: keep waiting, give up only after 5 in a row
                get_next_job 1; rc=$?
                if [ "$rc" -eq 2 ]; then fails=$((fails + 1)); logf "wait: job check failed ($fails/5): $LIST_ERR"; [ "$fails" -ge 5 ] && fail "E-JOB-LIST" "Lost the connection to the server while waiting. $LIST_ERR"; rc=1
                else fails=0; fi
            done
            end_line; say "A video job just arrived - starting!" "$C_GREEN"
        fi
        JOB_ID_NOW="$J_ID"
        good "Found your job: $J_ID"
        hint "It will make '$J_OUT' - about $(fmt_time "${J_EXPECT%.*}") of video."
        [ -n "$J_NOTE" ] && hint "Note from Ryan: $J_NOTE"
        hint "Press Q at any time to stop after this video (or just close the window)."
        [ -n "$J_KITVER" ] && [ "$J_KITVER" != "$kit_version" ] && warn "This job was prepared with kit $J_KITVER but the server's kit is $kit_version. Continuing; tell Ryan if the result looks odd."
        end_step

        # ---------- Step 5: download the job
        start_step 5
        local work="$HOME_DIR/work/$J_ID" jz; mkdir -p "$work"; jz="$work/job.zip"
        # A job can be REBUILT under the same id (make_job --replace). Anything left from an earlier VERSION of it - the zip
        # (same byte size, different contents: found by test), unpacked files and above all a finished render of the OLD
        # assets - must never be reused. The zip's SHA-256 is the job's identity; purge everything when it changes.
        # Leftovers from a run that predates the identity file are kept only if their zip provably IS the current zip.
        local idf="$work/job.identity" prev=""
        if [ -f "$idf" ]; then prev=$(tr -d '[:space:]' <"$idf"); elif [ -f "$jz" ] && [ "$(file_len "$jz")" = "$J_ZBYTES" ]; then prev=$(sha_of "$jz"); fi
        if [ -n "$(ls -A "$work" 2>/dev/null | grep -v '^job.identity$')" ] && [ "$prev" != "$J_ZSHA" ]; then
            hint "This job was updated since the last time (or its old files cannot be trusted) - starting it fresh."
            find "$work" -mindepth 1 -delete
        fi
        printf '%s\n' "$J_ZSHA" >"$idf"
        if [ "$(file_len "$jz")" != "$J_ZBYTES" ]; then
            say "Downloading the pictures, video clips and music ($(fmt_mb "$J_ZBYTES"))..."
            hint "If your internet drops, just run this again - it carries on where it stopped."
            sftp_bg job "reget \"jobs/$J_ID/job.zip\" \"$jz\""
            watch_transfer "$BG_PID" "$jz" "$J_ZBYTES" "job files"
            [ "$BG_CODE" -ne 0 ] && fail "E-JOB-DL" "The download did not finish. Please run this again - it will resume."
        else good "Job files already downloaded."; fi
        say "Checking nothing was damaged in the download..."
        if [ "$(sha_of "$jz")" != "$J_ZSHA" ]; then rm -f "$jz"; fail "E-JOB-SUM" "The job file was damaged in transit. Please run this again."; fi
        good "Download is perfect."
        say "Unpacking..."
        local ex="$work/extract"; rm -rf "$ex"; unzip_to "$jz" "$ex" || fail "E-JOB-UNPACK" "Could not unpack the job."
        local pub_dest="$COMPOSER/public/$J_PROJ"; rm -rf "$pub_dest"; mkdir -p "$COMPOSER/public"
        mv "$ex/public/$J_PROJ" "$pub_dest" || fail "E-JOB-UNPACK" "The job does not contain its picture folder. Tell Ryan."
        local props="$ex/remotion_props.json"
        [ -f "$props" ] || fail "E-JOB-PROPS" "The job is missing its instructions file. Tell Ryan."
        good "Everything is in place."
        end_step

        # ---------- Step 6: render
        start_step 6
        local outf="$work/$J_OUT" marker="$work/$J_OUT.verified" reuse=0 dur="" size=0 render_secs=0
        # A render that already passed its checks is never thrown away: if the upload failed, running this again must NOT
        # cost another 1-2 hours. The marker records size + length of the exact file.
        if [ -f "$outf" ] && [ -f "$marker" ]; then
            local mk_bytes mk_job; mk_bytes=$(jget "$marker" bytes); mk_job=$(jget "$marker" job_id)
            [ "$mk_bytes" = "$(file_len "$outf")" ] && [ "$mk_job" = "$J_ID" ] && reuse=1
        fi
        if [ "$reuse" = 1 ]; then
            dur=$(jget "$marker" duration); size=$(jget "$marker" bytes); render_secs=$(jget "$marker" render_seconds)
            good "Your finished video from the earlier run is still here and was already checked."
            hint "No need to make it again - we go straight to sending it."
        else
            rm -f "$outf" "$marker"
            local total_frames; total_frames=$(awk -v d="$J_EXPECT" -v f="$J_FPS" 'BEGIN{printf "%d", d*f+0.5}')
            [ "$total_frames" -lt 1 ] && total_frames=1
            local rargs=(render Explainer "--props=$props" "--output=$outf" --codec=h264 --crf=18 --timeout=120000)
            if [ -n "$J_FRAMES" ]; then
                rargs+=("--frames=$J_FRAMES"); total_frames=$(( ${J_FRAMES#*-} - ${J_FRAMES%-*} + 1 ))
                warn "This is a SHORT TEST job (frames $J_FRAMES). It will finish quickly."
            fi
            say "Now your computer makes the video. This is the long part - the bar will tell you how it is going."
            hint "Your fans may spin up and your computer will work hard. That is normal and safe."
            local rlog="$LOGS/render-$J_ID.log" rerr="$LOGS/render-$J_ID.err.log" t0 first_t="" first_n=0 phase="getting ready" el n tot eta rate tail enc
            t0=$(date +%s)
            ( cd "$COMPOSER" && ./node_modules/.bin/remotion "${rargs[@]}" </dev/null >"$rlog" 2>"$rerr" ) &
            local rpid=$!
            while kill -0 "$rpid" 2>/dev/null; do
                tail=$(tail -c 6000 "$rlog" "$rerr" 2>/dev/null | tr '\r' '\n')
                el=$(( $(date +%s) - t0 ))
                n=$(grep -o 'Rendered [0-9]*/[0-9]*' <<<"$tail" | tail -1)
                enc=$(grep -o 'Encoded [0-9]*/[0-9]*' <<<"$tail" | tail -1)
                if [ -n "$n" ]; then
                    local cur=${n#Rendered }; cur=${cur%/*}; tot=${n#*/}; [ "$tot" -gt 0 ] 2>/dev/null && total_frames=$tot
                    if [ -z "$first_t" ] && [ "$cur" -gt 0 ]; then first_t=$(date +%s); first_n=$cur; fi
                    eta=-1
                    if [ -n "$first_t" ] && [ "$cur" -gt "$first_n" ]; then eta=$(awk -v c="$cur" -v f="$first_n" -v t="$total_frames" -v s="$first_t" -v now="$(date +%s)" 'BEGIN{r=(c-f)/(now-s); if(r>0) printf "%d", (t-c)/r; else print -1}'); fi
                    local detail="drawing the frames: frame $cur of $total_frames   running $(fmt_time $el)   about $(fmt_time $eta) left"
                    if [ -n "$enc" ] && [ "$cur" -ge "$total_frames" ]; then detail="packaging the video file: ${enc#Encoded } of $total_frames   running $(fmt_time $el)"; fi
                    show_progress "$(( 100 * cur / total_frames ))" "$detail"
                else
                    show_progress "$(awk -v e="$el" 'BEGIN{v=e/12; if(v>5) v=5; printf "%d", v}')" "$phase   running $(fmt_time $el)"
                fi
                nap 2 || true
            done
            wait "$rpid"; local rrc=$?
            end_line
            if [ "$rrc" -ne 0 ] || [ ! -f "$outf" ]; then fail "E-RENDER" "The video maker stopped with a problem. Please send Ryan these two files: $rlog  and  $rerr"; fi
            render_secs=$(( $(date +%s) - t0 ))
            good "Video made in $(fmt_time $render_secs)."
            say "Checking the video is the right length..."
            dur=$("$COMPOSER/node_modules/.bin/remotion" ffprobe -v error -show_entries format=duration -of csv=p=0 "$outf" 2>/dev/null </dev/null | tr -d '[:space:]')
            [[ "$dur" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "E-VERIFY-PROBE" "Could not read the finished video's length. Tell Ryan."
            local expect tol minsize
            if [ -n "$J_FRAMES" ]; then expect=$(awk -v t="$total_frames" -v f="$J_FPS" 'BEGIN{print t/f}'); tol=1.5; minsize=102400
            else expect=$J_EXPECT; tol=3.0; minsize=1048576; fi
            logf "duration $dur expected $expect"
            awk -v d="$dur" -v e="$expect" -v t="$tol" 'BEGIN{x=d-e; if(x<0)x=-x; exit !(x>t)}' && \
                fail "E-VERIFY-LENGTH" "The video is $(printf '%.1f' "$dur")s long but should be about $(printf '%.1f' "$expect")s. Not sending it. Please tell Ryan."
            size=$(file_len "$outf")
            [ "$size" -lt "$minsize" ] && fail "E-VERIFY-SIZE" "The finished video is suspiciously small. Not sending it. Please tell Ryan."
            good "Length $(printf '%.1f' "$dur")s, size $(fmt_mb "$size"). Looks right!"
            printf '{"job_id": "%s", "bytes": %s, "duration": %s, "render_seconds": %s}\n' "$J_ID" "$size" "$dur" "$render_secs" >"$marker"
        fi
        end_step

        # ---------- Step 7: upload
        start_step 7
        local rdir="results/$USER_NAME" sha part final have verb
        sha=$(sha_of "$outf")
        # The partial's name carries this exact file's hash, so a resumed upload (reput) can only ever continue a partial of
        # THIS file - never splice onto a half-file from a different render of the same name.
        part="$rdir/$J_OUT.${sha:0:8}.partial"; final="$rdir/$J_OUT"
        say "Sending the finished video back to Ryan ($(fmt_mb "$size"))..."
        hint "Uploading can take a while on home internet. If it stops, run this again - it carries on where it stopped."
        # sftp's `reput` ONLY works when a partial already exists on the server, so choose by what is actually there:
        # nothing -> put | smaller partial -> reput (resume) | exact size -> nothing to send | bigger -> start over
        have=$(remote_size "$part")
        local cmds=()
        if [ "$have" -gt "$size" ]; then cmds+=("-rm \"$part\""); have=0; fi
        [ "$have" -gt 0 ] && [ "$have" -lt "$size" ] && hint "Found $(fmt_mb "$have") of your video already on the server - carrying on from there."
        verb=put; [ "$have" -gt 0 ] && [ "$have" -lt "$size" ] && verb=reput
        if [ "$have" -eq "$size" ]; then hint "The whole video is already on the server - just finishing up."; sftp_bg up "ls \"$part\""
        else cmds+=("$verb \"$outf\" \"$part\""); sftp_bg up "${cmds[@]}"; fi
        local upid=$BG_PID ut0 remote=0 lastpoll=0 el2 pct eta2 sp='|/-\' si=0
        ut0=$(date +%s)
        while kill -0 "$upid" 2>/dev/null; do
            if [ $(( $(date +%s) - lastpoll )) -ge 30 ]; then local rs; rs=$(remote_size "$part"); [ "$rs" -ge 0 ] && remote=$rs; lastpoll=$(date +%s); fi
            el2=$(( $(date +%s) - ut0 )); pct=$(( 100 * remote / size ))
            eta2=-1; [ "$remote" -gt 0 ] && [ "$el2" -gt 5 ] && eta2=$(awk -v r="$remote" -v s="$size" -v e="$el2" 'BEGIN{printf "%d", (s-r)/(r/e)}')
            show_progress "$pct" "${sp:$((si % 4)):1} sent $(fmt_mb "$remote") of $(fmt_mb "$size")   about $(fmt_time $eta2) left"; si=$((si + 1))
            quit_pressed >/dev/null; sleep 0.8
        done
        wait "$upid"; local urc=$?
        end_line
        [ "$urc" -ne 0 ] && fail "E-UPLOAD" "The upload did not finish. Please run this again - it carries on where it stopped, and your finished video is kept so nothing is made twice."
        say "Checking Ryan's server received every byte..."
        have=$(remote_size "$part")
        [ "$have" != "$size" ] && fail "E-UPLOAD-SIZE" "The server has $have bytes but we sent $size. Please run this again."
        local report="$work/$J_OUT.json"
        printf '{\n  "job_id": "%s",\n  "helper": "%s",\n  "out_name": "%s",\n  "bytes": %s,\n  "sha256": "%s",\n  "duration": %s,\n  "render_seconds": %s,\n  "cores": %s,\n  "platform": "linux",\n  "kit_version": "%s",\n  "finished_utc": "%s"\n}\n' \
            "$J_ID" "$USER_NAME" "$J_OUT" "$size" "$sha" "$dur" "$render_secs" "$(nproc)" "$kit_version" "$(date -u +%FT%TZ)" >"$report"
        # Finalize in two steps that are each safe to repeat: 1) put the video in place (skipped if the final file is already
        # there at the right size); 2) put the report.
        if [ "$(remote_size "$final")" != "$size" ]; then
            sftp_run "-rm \"$final\"" "rename \"$part\" \"$final\""
            if [ "$SFTP_CODE" -ne 0 ] && [ "$(remote_size "$final")" != "$size" ]; then logf "$SFTP_OUT"; fail "E-UPLOAD-FINAL" "The video arrived but could not be finalized. Tell Ryan - it is safe on his server."; fi
        fi
        sftp_run "put \"$report\" \"$final.json\""
        [ "$SFTP_CODE" -ne 0 ] && { logf "$SFTP_OUT"; fail "E-UPLOAD-FINAL" "The video arrived but its report could not be sent. Tell Ryan - the video is safe on his server."; }
        good "Delivered! Ryan's server has your video."
        end_step

        if [ "$OPT_KEEP" = 0 ]; then
            hint "Cleaning up the big temporary files to give your disk space back..."
            rm -rf "$work" "$pub_dest"
        fi
        printf '\n%s============================================================%s\n' "$C_GREEN" "$C_OFF"
        printf '%s   ALL DONE - THANK YOU!%s\n' "$C_GREEN" "$C_OFF"
        printf "%s   '%s' is on its way into the EOTIR Music Project.%s\n" "$C_GREEN" "$J_OUT" "$C_OFF"
        printf '%s   Total time for this run: %s%s\n' "$C_GREEN" "$(fmt_time $(( $(date +%s) - START_EPOCH )))" "$C_OFF"
        printf '%s============================================================%s\n' "$C_GREEN" "$C_OFF"
        if [ "$OPT_ONCE" = 1 ] || [ -n "$OPT_JOB" ] || quit_pressed >/dev/null; then
            [ "$STOP_REQUESTED" = 1 ] && say "Stopping, as you asked."
            say "You can close this window."
            break
        fi
        say ""; say "Looking for the next video for you...  (press Q at any time to stop)" "$C_CYAN"
        FIRST_STEP=4
    done
    REPORTED=1
    return 0
}

main "$@"
exit $?
