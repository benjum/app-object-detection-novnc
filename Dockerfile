FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# Three groups, kept separate so it is obvious what each one is for.
#
# 1. The VNC stack, identical to app-novnc. feh is not optional scenery:
#    fluxbox's default style carries a `background:` directive, which makes it
#    shell out to fbsetbg, which needs one of feh / Esetroot / display /
#    hsetroot to exist. With none of them installed fbsetbg pops its complaint
#    up as an xmessage dialog ON THE DESKTOP -- the first thing a user sees.
#
# 2. The desktop: PCManFM draws the background and the icons AND provides the
#    file windows; tumbler is what puts image thumbnails in them (without it
#    every photo is a generic icon, which defeats the purpose); ristretto is
#    the viewer; dbus-x11 is what tumbler and GTK's file chooser talk over.
#    An icon theme is not decoration either -- GTK apps with no icon theme
#    installed render as unlabelled blank squares.
#
# 3. Python, for the detector. Same CPU-only torch and ultralytics pins as
#    app-object-detection. libgl1/libglib2.0-0: opencv-python links libGL.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        tigervnc-standalone-server tigervnc-common xauth \
        novnc websockify \
        fluxbox xterm x11-utils \
        feh \
        nginx-light gettext-base \
        pcmanfm ristretto xfce4-terminal \
        tumbler tumbler-plugins-extra \
        dbus-x11 shared-mime-info xdg-utils desktop-file-utils \
        adwaita-icon-theme papirus-icon-theme gnome-themes-extra \
        librsvg2-common fonts-dejavu-core \
        python3 python3-venv \
        libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# noVNC's landing page is vnc.html and it needs query parameters to connect on
# its own. The gate strips the query string after the token exchange, so bake
# the parameters into an index page instead of relying on the URL.
RUN printf '%s\n' \
      '<!doctype html><title>Object detection desktop</title>' \
      '<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=true&resize=remote&reconnect=true">' \
      > /usr/share/novnc/index.html

# The X server needs this to exist before it can create its socket, and it
# will not create it itself as a non-root user.
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# A venv rather than `pip install --break-system-packages`: Ubuntu marks its
# system Python externally-managed (PEP 668), and a venv keeps the detector's
# pinned wheels from arguing with the apt-installed desktop's python bindings.
# Putting it first on PATH makes `python3` mean the venv's for the rest of the
# build; `detect` names /opt/venv/bin/python3 explicitly rather than trusting
# whatever PATH a user's shell ends up with.
RUN python3 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH

# CPU-only torch, installed before ultralytics so that ultralytics finds its
# torch/torchvision requirement already satisfied. PyPI's default torch wheel
# for Linux is the CUDA build: ~2.5 GB in the image, and every byte of it ends
# up in the .sif that gets copied to every compute node.
#
# For a GPU demo, delete this step and change the base image to
#   FROM nvidia/cuda:13.3.0-runtime-ubuntu24.04
# plus the desktop packages above -- pip will then pull the CUDA build of torch
# as an ordinary dependency of ultralytics.
RUN pip install --no-cache-dir \
        --index-url https://download.pytorch.org/whl/cpu \
        torch==2.13.0 torchvision==0.28.0

# Everything else is installed at build time too. Nothing may be fetched at
# run time: a .sif is read-only and compute nodes are often offline.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# The container user, created before the ENV block below so that HOME points at
# a directory that already exists during the rest of the build.
#
# 1777 rather than 0755: under `docker run --user <uid>` and under Apptainer the
# runtime uid is whatever the caller happens to be, not 1000, and the entrypoint
# has to be able to seed the desktop configuration into this directory. The
# sticky bit keeps one user from deleting another's files.
ARG OSP_UID=1000
RUN useradd --create-home --uid ${OSP_UID} --shell /bin/bash ospuser \
    && chmod 1777 /home/ospuser

# A .sif is mounted read-only, so every library scratch path goes to /tmp and
# the model weights are baked in at a fixed absolute path. APP_MODEL is the
# same variable run.py reads, with the same default, so this image and the
# batch app resolve to identical weights.
#
# XDG_CACHE_HOME and XDG_RUNTIME_DIR get a uid suffix in entrypoint.sh rather
# than a fixed value here: under Apptainer /tmp is the compute node's, shared
# with everyone on it, and both directories are created 0700 by the things that
# use them. These are the fallbacks for a bare `docker run`.
ENV HOME=/home/ospuser \
    XDG_CACHE_HOME=/tmp/.cache \
    XDG_RUNTIME_DIR=/tmp/run \
    MPLCONFIGDIR=/tmp/matplotlib \
    YOLO_CONFIG_DIR=/tmp/Ultralytics \
    APP_MODEL=/app/yolo11n.pt

# Downloaded at build time into WORKDIR, i.e. /app/yolo11n.pt = $APP_MODEL.
# Swap for yolo26n.pt (newest generation) or a larger size (s/m/l/x) freely --
# the API is identical, only the weights file changes. Keep it in step with
# app-object-detection so the two produce comparable results.
RUN python3 -c "from ultralytics import YOLO; YOLO('yolo11n.pt')"

# Branch B of the interactive contract: VNC has no URL-token auth, so the
# nginx gate owns OSP_APP_PORT and websockify hides on OSP_APP_UPSTREAM_PORT.
# OSP_APP_TOKEN_NAME is deliberately NOT an ENV here. Its value is a parameter
# name, not a secret, but BuildKit's SecretsUsedInArgOrEnv check matches on
# the word TOKEN and warns. web/session-env.sh already defaults it to `token`,
# so the ENV was redundant.
ENV OSP_APP_PORT=6080 \
    OSP_APP_UPSTREAM_PORT=6081 \
    VNC_GEOMETRY=1920x1080
# VNC_DISPLAY is deliberately unset: entrypoint.sh walks :1, :2, ... for a
# free one, because display numbers are global to the node. Set it at run
# time only to demand a specific number.
EXPOSE 6080

# /etc/passwd group-writable so entrypoint can add an entry for the runtime uid
# when run as `--user "$(id -u):0"`. Harmless otherwise, and read-only under
# Apptainer, which supplies the entry itself.
RUN chmod g=u /etc/passwd /etc/group

COPY run.py /app/run.py
COPY bin/ /app/bin/
COPY desktop/ /app/desktop/
COPY web/ /app/web/
COPY entrypoint.sh /app/entrypoint.sh

# The wallpaper is generated, not committed: Pillow is already here as an
# ultralytics dependency, and a repo of shell and Dockerfiles has no business
# carrying a 2 MB PNG.
RUN python3 /app/desktop/make-wallpaper.py /app/desktop/wallpaper.png

# `detect` on PATH, and the launchers where the desktop looks for them.
# Symlinks rather than copies for the commands, so /app stays the one place
# anything of ours actually lives; real copies for the .desktop files, because
# update-desktop-database builds a cache keyed on this directory.
RUN ln -s /app/bin/detect      /usr/local/bin/detect \
    && ln -s /app/bin/detect-shell /usr/local/bin/detect-shell \
    && cp /app/desktop/applications/*.desktop /usr/share/applications/ \
    && chmod 0644 /usr/share/applications/osp-*.desktop \
    && update-desktop-database /usr/share/applications
# That chmod is not redundant with the `chmod -R a+rX /app` below: these copies
# live outside /app, so the recursive fix never reaches them, and a .desktop
# file the runtime user cannot read is a launcher that silently does not exist.

# Explicit modes. COPY preserves the build context's permissions, so a checkout
# made under a restrictive umask yields 0600/0700 files that the runtime user --
# `docker run --user`, or any user at all under Apptainer -- cannot even read.
# Git only tracks the exec bit, so this is not something the repo can guarantee.
RUN chmod -R a+rX /app /opt/venv \
    && chmod 0755 /app/entrypoint.sh \
                  /app/web/token-gate.sh /app/web/session-env.sh \
                  /app/bin/detect /app/bin/detect-shell \
                  /app/desktop/make-wallpaper.py

# The working directory is ospuser's home: it is where the desktop opens, where
# the Files window starts, and where run.py reads and writes. Docker gets it
# from WORKDIR; Apptainer ignores WORKDIR and uses the caller's directory,
# which comes to the same thing -- the session's working directory either way.
WORKDIR /home/ospuser
USER ospuser

ENTRYPOINT ["/app/entrypoint.sh"]
