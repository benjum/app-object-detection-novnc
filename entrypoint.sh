#!/bin/sh
# app-object-detection-novnc - branch B of the interactive contract: no native
# URL-token auth, so the nginx gate owns the single exposed port and everything
# else binds 127.0.0.1.
#
#   0.0.0.0:OSP_APP_PORT            nginx gate   <- the only thing off-node sees
#   127.0.0.1:OSP_APP_UPSTREAM_PORT websockify + noVNC static files
#   127.0.0.1:590<n>            Xvnc + fluxbox + PCManFM desktop
#
# This is app-novnc's entrypoint with three additions: uid-scoped XDG paths,
# the desktop-configuration seeding, and a desktop (PCManFM + a terminal)
# instead of a bare xterm. The VNC plumbing below is unchanged.
set -eu

# Scratch directory. The scheduler usually hands us a TMPDIR pointing at a host
# path like /scratch/$USER/job.12345 -- and Apptainer binds $HOME, /tmp and $PWD
# by default, NOT necessarily /scratch. Inside the container that path does not
# exist and the root filesystem is read-only, so `mkdir -p "$TMPDIR"` dies with
# "cannot create directory '/scratch': Read-only file system". Try the
# candidates in order and use the first one we can actually write to. Bind the
# real scratch in (`--bind /scratch`) if you want it used.
_pick_tmpdir() {
    for _d in "${TMPDIR:-}" /tmp "${HOME:-}"; do
        [ -n "$_d" ] || continue
        mkdir -p "$_d" 2>/dev/null || continue
        [ -w "$_d" ] || continue
        printf '%s' "$_d"
        return 0
    done
    return 1
}
_tmpdir_was="${TMPDIR:-}"
TMPDIR="$(_pick_tmpdir)" || {
    echo "[app] no writable scratch directory (tried TMPDIR, /tmp, HOME)" >&2
    exit 1
}
export TMPDIR
if [ -n "$_tmpdir_was" ] && [ "$_tmpdir_was" != "$TMPDIR" ]; then
    echo "[app] TMPDIR=$_tmpdir_was is not writable in this container; using $TMPDIR" >&2
fi

. /app/web/session-env.sh

: "${OSP_APP_UPSTREAM_PORT:=$((OSP_APP_PORT + 1))}"
: "${VNC_GEOMETRY:=1920x1080}"
export OSP_APP_UPSTREAM_PORT

# XDG scratch, scoped by uid. The Dockerfile's /tmp/.cache and /tmp/run are
# fine for a bare `docker run`, but under Apptainer /tmp is the compute node's,
# shared with every other user on it. dbus creates XDG_RUNTIME_DIR 0700 and
# tumbler writes a thumbnail cache under XDG_CACHE_HOME, so a fixed path means
# the second user on a node cannot write to a directory the first one owns --
# which shows up as a desktop with no thumbnails and no obvious reason why.
XDG_RUNTIME_DIR="$TMPDIR/run-$(id -u)"
XDG_CACHE_HOME="$TMPDIR/cache-$(id -u)"
MPLCONFIGDIR="$TMPDIR/matplotlib-$(id -u)"
YOLO_CONFIG_DIR="$TMPDIR/Ultralytics-$(id -u)"
export XDG_RUNTIME_DIR XDG_CACHE_HOME MPLCONFIGDIR YOLO_CONFIG_DIR
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME" "$MPLCONFIGDIR" "$YOLO_CONFIG_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

# matplotlib and ultralytics are the detector's, not the desktop's -- but the
# terminal that runs `detect` is a child of this script and inherits them, so
# they belong in the same block. Both libraries create their directory 0700.

# ---------------------------------------------------------------------------
# The session home.
#
# GTK, PCManFM and fluxbox all read their configuration from $HOME and there is
# no settings daemon in this image to tell them otherwise, so the desktop needs
# a writable home. Under Docker that is /home/ospuser (mode 1777, from the
# Dockerfile). Under Apptainer $HOME is the caller's real home, bound and
# writable -- which is where this configuration belongs anyway.
#
# If neither is writable (--no-home, an unwritable mount) fall back to a
# session-scoped directory rather than letting every GTK app fail separately.
_pick_home() {
    for _d in "${OSP_HOME:-}" "${HOME:-}" "$TMPDIR/ospuser-$(id -u)"; do
        [ -n "$_d" ] || continue
        mkdir -p "$_d" 2>/dev/null || continue
        [ -w "$_d" ] || continue
        printf '%s' "$_d"
        return 0
    done
    return 1
}
_home_was="${HOME:-}"
HOME="$(_pick_home)" || {
    echo "[app] no writable home directory for the desktop" >&2
    exit 1
}
export HOME
if [ -n "$_home_was" ] && [ "$_home_was" != "$HOME" ]; then
    echo "[app] HOME=$_home_was is not usable in this container; using $HOME" >&2
fi

# Seed the desktop configuration: GTK theme, PCManFM's desktop and thumbnail
# settings, the file-type associations, the fluxbox menu, the Desktop
# launchers and the README.
#
# Copied in rather than baked into the home directory at build time, for the
# same reason the tutorial notebook is copied in app-object-detection-jupyter:
# /app is inside the .sif and mounted read-only, and under Apptainer $HOME is
# the user's own directory, which the image never sees at build time.
#
# Nothing is ever overwritten. Your gtk settings, your mimeapps.list and your
# edited launchers survive a restart. Set OSP_SEED_DESKTOP=0 to add nothing at
# all -- the defaults are then whatever your home directory already has.
: "${OSP_SEED_DESKTOP:=1}"

_seed_home() {
    if [ "$OSP_SEED_DESKTOP" = "0" ]; then
        echo "[app] OSP_SEED_DESKTOP=0; leaving $HOME alone."
        return 0
    fi
    [ -d /app/desktop/skel ] || return 0
    if [ ! -w "$HOME" ]; then
        echo "[app] $HOME is not writable; desktop configuration not seeded." >&2
        return 0
    fi

    # The walks are redirected from a file rather than piped in. A `find | while`
    # runs the loop body in a subshell, where the counters below would be
    # incremented and then thrown away -- and the counts are the whole point of
    # the message at the end. Both walks are relative to skel, so no path is
    # ever built from a name we did not put there ourselves.
    _list="$TMPDIR/seed-list.$$"

    # -type d first, so the destinations exist before the files arrive.
    (cd /app/desktop/skel && find . -mindepth 1 -type d -print) > "$_list"
    while IFS= read -r _d; do
        mkdir -p "$HOME/${_d#./}" 2>/dev/null || true
    done < "$_list"

    _new=0
    _kept=0
    (cd /app/desktop/skel && find . -type f -print) > "$_list"
    while IFS= read -r _f; do
        _rel="${_f#./}"
        if [ -e "$HOME/$_rel" ]; then
            _kept=$((_kept + 1))
            continue
        fi
        cp "/app/desktop/skel/$_rel" "$HOME/$_rel" 2>/dev/null || continue
        chmod u+w "$HOME/$_rel" 2>/dev/null || true
        echo "[app] seeded ~/$_rel"
        _new=$((_new + 1))
    done < "$_list"
    rm -f "$_list"

    # PCManFM will not launch a .desktop file on the desktop unless it is
    # executable -- it shows it as a text file instead. (Even then it asks what
    # to do with it, unless quick_exec=1 is set in libfm.conf; both are
    # required.)
    chmod u+x "$HOME"/Desktop/*.desktop 2>/dev/null || true

    echo "[app] desktop config: ${_new} file(s) seeded, ${_kept} already yours"
    if [ "$_kept" -gt 0 ]; then
        # Worth saying out loud. Never overwriting is what protects a user's
        # edits, but it also means a home directory carried over from an older
        # image keeps that image's defaults and silently misses fixes.
        echo "[app] existing files are never overwritten. To take this image's"
        echo "[app] defaults instead, remove them and restart:"
        echo "[app]   rm -rf ~/.config/pcmanfm ~/.config/gtk-3.0 ~/.fluxbox/menu ~/Desktop"
    fi
    return 0
}
_seed_home

# Versions of this image before the fix seeded a libfm.conf into the pcmanfm
# profile directory, where libfm never looks for it. Harmless to leave, but
# it is exactly the file someone will find and edit while wondering why
# nothing changes.
if [ -f "$HOME/.config/pcmanfm/default/libfm.conf" ]; then
    echo "[app] note: ~/.config/pcmanfm/default/libfm.conf is left over from an" >&2
    echo "[app] older image. libfm does not read that path; the settings now come" >&2
    echo "[app] from /etc/xdg/libfm/libfm.conf. The file is safe to delete." >&2
fi

mkdir -p "$HOME/Desktop" 2>/dev/null || true

# X only creates /tmp/.X11-unix when it is running as root, which we never
# are. Under Docker the Dockerfile pre-creates it; under Apptainer /tmp is
# usually bind-mounted from the host and this is the line that matters.
mkdir -p /tmp/.X11-unix 2>/dev/null || true

# An MIT-MAGIC-COOKIE under /tmp. The X server has to authenticate its local
# clients somehow and we cannot write to the image or assume a usable HOME.
XAUTHORITY="$TMPDIR/Xauthority"
export XAUTHORITY
: > "$XAUTHORITY"
XAUTH_COOKIE="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"

XVNC_LOG="$TMPDIR/xvnc.log"

cleanup() {
    kill ${XVNC_PID:-} ${WM_PID:-} ${DESKTOP_PID:-} ${TERM_PID:-} \
         ${FILES_PID:-} ${WS_PID:-} ${DBUS_SESSION_BUS_PID:-} 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Try one display number. Returns 0 and sets VNC_DISPLAY/VNC_PORT on success.
#
# -SecurityTypes None and no VNC password are deliberate: Xvnc listens on
# localhost only, its sole client is websockify in this same container, and
# the browser-facing authentication is the token gate. A VNC password here
# would be a second secret protecting a socket nobody can reach.
try_display() {
    _d=":$1"
    _p=$((5900 + $1))
    xauth -f "$XAUTHORITY" add "$_d" . "$XAUTH_COOKIE" 2>/dev/null || return 1

    Xvnc "$_d" \
        -rfbport "$_p" \
        -localhost \
        -SecurityTypes None \
        -geometry "$VNC_GEOMETRY" \
        -depth 24 \
        -auth "$XAUTHORITY" \
        -AlwaysShared \
        -desktop "app-object-detection-novnc" >>"$XVNC_LOG" 2>&1 &
    XVNC_PID=$!

    # Wait for the display to answer rather than sleeping and hoping. Bail out
    # early if Xvnc has already died -- that is the "display taken" case.
    _i=0
    while ! DISPLAY="$_d" xdpyinfo >/dev/null 2>&1; do
        kill -0 "$XVNC_PID" 2>/dev/null || return 1
        _i=$((_i + 1))
        [ "$_i" -lt 100 ] || return 1
        sleep 0.1
    done

    VNC_DISPLAY="$_d"
    VNC_PORT="$_p"
    return 0
}

# X display numbers are global to the node: the lock (/tmp/.X<n>-lock) and the
# socket (/tmp/.X11-unix/X<n>) live in a /tmp that Apptainer usually shares with
# every other user on it. Hardcoding :1 means the second session on a node dies
# with "Server is already active for display 1", so walk until one takes.
# Setting VNC_DISPLAY explicitly opts out and demands that exact number.
if [ -n "${VNC_DISPLAY:-}" ]; then
    try_display "${VNC_DISPLAY#:}" || {
        echo "[novnc] display ${VNC_DISPLAY} is not available:" >&2
        tail -5 "$XVNC_LOG" >&2
        exit 1
    }
else
    _n=1
    until try_display "$_n"; do
        _n=$((_n + 1))
        [ "$_n" -le 64 ] || {
            echo "[novnc] no free X display between :1 and :64" >&2
            tail -5 "$XVNC_LOG" >&2
            exit 1
        }
    done
fi

export DISPLAY="$VNC_DISPLAY"
echo "[novnc] Xvnc ready on $VNC_DISPLAY (rfb $VNC_PORT)"

# A session bus. tumbler -- the thumbnailer that puts pictures on the file
# icons instead of generic placeholders -- is dbus-activated and does nothing
# without one. GTK's file chooser and the mime cache use it too. The terminals
# are launched --disable-server precisely so that they do NOT depend on it.
if command -v dbus-launch >/dev/null 2>&1; then
    eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
    if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        export DBUS_SESSION_BUS_ADDRESS
        echo "[desktop] session bus up (thumbnails enabled)"
    else
        echo "[desktop] no session bus; thumbnails will be generic icons" >&2
    fi
fi

# The window manager, then the desktop, then the two windows the user needs.
#
# fluxbox first so that everything opened after it gets a title bar. PCManFM
# draws the wallpaper and the Desktop icons; it is a separate invocation from
# the file windows, which is why it gets its own pid.
fluxbox >"$TMPDIR/fluxbox.log" 2>&1 &
WM_PID=$!

pcmanfm --desktop --profile default >"$TMPDIR/pcmanfm-desktop.log" 2>&1 &
DESKTOP_PID=$!

# These two open on the *working* directory, not on $HOME. Under Docker they
# are the same place. Under Apptainer $HOME holds the configuration and $PWD
# holds the user's images, and the images are what they came for.
pcmanfm "$PWD" >"$TMPDIR/pcmanfm.log" 2>&1 &
FILES_PID=$!

xfce4-terminal --disable-server \
    --title="Object detection" \
    --working-directory="$PWD" \
    --geometry=104x30+90+70 \
    --command=detect-shell >"$TMPDIR/terminal.log" 2>&1 &
TERM_PID=$!

echo "[desktop] working directory: $PWD"
echo "[desktop] home             : $HOME"
echo "[app]     model            : ${APP_MODEL:-/app/yolo11n.pt}"
echo "[app]     run detection with: detect --open <image>"

# websockify serves the noVNC client AND bridges the websocket to Xvnc, all on
# loopback. Everything the browser fetches comes back through the gate.
websockify --web=/usr/share/novnc \
    "127.0.0.1:${OSP_APP_UPSTREAM_PORT}" "127.0.0.1:${VNC_PORT}" \
    >"$TMPDIR/websockify.log" 2>&1 &
WS_PID=$!

echo "[novnc] websockify on 127.0.0.1:${OSP_APP_UPSTREAM_PORT} -> 127.0.0.1:${VNC_PORT}"

exec /app/web/token-gate.sh
