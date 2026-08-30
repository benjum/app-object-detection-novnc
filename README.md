# app-object-detection-novnc

The desktop sibling of
[`app-object-detection`](https://github.com/OneSciencePlace/app-object-detection).
Same `run.py`, same weights, same outputs — but you get a terminal to run it
from and a file browser to look at the results in, both in a browser tab.

```
app-object-detection          app-object-detection-jupyter      this repo
run.py --image photo.jpg  ──▶  a notebook, cell by cell    ──▶  a desktop:
     one shot, batch                with a slider               detect + Files
              │                            │                          │
              └──── yolo11n.pt, <stem>_detected.jpg, detections.json ──┘
```

It is built on `app-novnc`: **branch B** of the interactive contract. VNC has
no URL-token auth, so the nginx gate owns the single exposed port and
everything else hides on loopback.

```
browser ──https──▶ Satellite ──http──▶ 0.0.0.0:OSP_APP_PORT          nginx gate
                                              │  cookie / 403
                                              ▼
                                       127.0.0.1:OSP_APP_UPSTREAM_PORT  websockify
                                              │  + noVNC static files
                                              ▼
                                       127.0.0.1:590<n>   Xvnc + fluxbox
                                                          + PCManFM + ristretto
```

## Contents

| File | Purpose |
|---|---|
| `Dockerfile` | The image. Weights at `/app/yolo11n.pt`; user `ospuser`, home `/home/ospuser`. |
| `run.py` | The program — **byte-for-byte** `app-object-detection`'s. |
| `bin/detect` | The wrapper users actually type. Adds a bare-filename form and `--open`. |
| `bin/detect-shell` | What the desktop's *Object detection* launcher opens: a terminal that has already printed the help. |
| `requirements.txt` | Pinned Python deps, held in step with the batch app. |
| `desktop/skel/` | Desktop configuration seeded into the session home at startup. |
| `desktop/applications/` | The `.desktop` launchers, installed to `/usr/share/applications`. |
| `desktop/make-wallpaper.py` | Generates the background at build time. |
| `entrypoint.sh` | The image ENTRYPOINT. Starts Xvnc, the desktop, websockify, then `exec`s the gate. |
| `web/` | The interactive session contract and the token gate. Copied verbatim from `app-novnc`. |
| `.github/workflows/build-and-push.yml` | Build + push both artifacts. App-agnostic — copy as-is. |

## Run it

```bash
TOKEN=$(openssl rand -hex 32)

docker run --rm --user "$(id -u):$(id -g)" \
  -p 6080:6080 -v "$PWD:/home/ospuser" \
  -e OSP_APP_PORT=6080 -e OSP_APP_TOKEN="$TOKEN" \
  ghcr.io/onescienceplace/app-object-detection-novnc:latest

apptainer pull oras://ghcr.io/onescienceplace/app-object-detection-novnc-sif:latest
apptainer run --env OSP_APP_PORT=6080 --env OSP_APP_TOKEN="$TOKEN" \
  app-object-detection-novnc-sif_latest.sif
```

Then open `https://<session>.<satellite-domain>/?token=$TOKEN`. A desktop comes
up with a Files window and a terminal already open on your working directory.

| Variable | Default | Meaning |
|---|---|---|
| `OSP_APP_PORT` | `6080` | the single port served — the nginx gate |
| `OSP_APP_TOKEN` | generated | per-session secret |
| `OSP_APP_TOKEN_NAME` | `token` | query parameter the token arrives in |
| `OSP_APP_UPSTREAM_PORT` | `6081` | loopback-only: websockify + noVNC |
| `VNC_DISPLAY` | auto | X display; RFB port is `5900 + n`. Unset by default — see below |
| `VNC_GEOMETRY` | `1920x1080` | desktop size |
| `APP_MODEL` | `/app/yolo11n.pt` | the baked-in weights; same variable `run.py` reads |
| `OSP_HOME` | `$HOME` | where the desktop configuration is seeded |
| `OSP_SEED_DESKTOP` | `1` | set `0` to add nothing to the home directory |

## `detect`

The command the desktop exists to make easy:

```bash
detect photo.jpg                    # the short form
detect --open photo.jpg             # ...and show the result when it finishes
detect photo.jpg --conf 0.4         # run.py's own flags, unchanged
detect --image photo.jpg --output-dir results
detect --help
```

It writes exactly what the batch app writes, into the current directory:
`<stem>_detected.jpg` and `detections.json`.

The wrapper adds precisely two things — the bare-filename shorthand and
`--open` — and hands everything else to `run.py` untouched. So a command you
worked out here runs unchanged against the batch container:

```bash
apptainer run app-object-detection-sif_latest.sif --image photo.jpg --conf 0.4
```

`--open` starts ristretto on the annotated image. Ristretto loads the whole
containing folder into its thumbnail strip, so the original is one arrow key
away at the same zoom — which is the comparison worth making, and the reason
the viewer is ristretto rather than the `feh` already in the base image.

## The desktop

fluxbox is the window manager, unchanged from `app-novnc`. On top of it:

- **PCManFM** does two jobs: `pcmanfm --desktop` draws the wallpaper, the
  Desktop icons and the right-click menu; a second invocation provides the file
  windows. The icon view has thumbnails on, so `photo.jpg` and
  `photo_detected.jpg` sit next to each other and the difference is visible
  before you open either.
- **tumbler** is what makes those thumbnails exist. It is dbus-activated, which
  is why `entrypoint.sh` starts a session bus. Without one you get generic
  file icons and no explanation.
- **ristretto** is the image viewer, wired to every image type through
  `~/.config/mimeapps.list`.
- **xfce4-terminal**, started `--disable-server` so it does not depend on the
  session bus at all. `xterm` is still installed as a fallback.
- **Papirus-Dark** icons and Adwaita GTK, with animations off: every frame of a
  fade is a full framebuffer update pushed down the websocket.

Four launchers ship in `/usr/share/applications` and are seeded onto the
Desktop: *Files*, *Terminal*, *Image Viewer*, and *Object detection* (which
opens `detect-shell` — a terminal that prints the help and lists the images
in the directory before handing you a prompt).

### Why the configuration is seeded rather than baked

There is no settings daemon in this image, so GTK, PCManFM and fluxbox each
read their configuration from `$HOME`. `/app` is inside the `.sif` and mounted
read-only, and under Apptainer `$HOME` is the caller's own directory, which the
image never sees at build time — so the only moment the configuration can be
put in place is startup.

`entrypoint.sh` copies `desktop/skel/` into the session home and **never
overwrites an existing file**: your `gtk-3.0/settings.ini`, your
`mimeapps.list` and your edited launchers survive a restart. What it adds is
`~/.config/gtk-3.0/settings.ini`, `~/.config/mimeapps.list`,
`~/.config/pcmanfm/default/`, `~/.fluxbox/menu`, `~/Desktop/osp-*.desktop` and
`~/README-object-detection.txt`. If you would rather it added nothing, set
`OSP_SEED_DESKTOP=0`.

### Home versus working directory

Under Docker they are the same: `USER ospuser`, `WORKDIR /home/ospuser`, and
that home is mode 1777 so the runtime uid — whatever `--user` you pass — can
write to it.

Under Apptainer they differ, and that is deliberate. `$HOME` is your real home,
which is where desktop configuration belongs. `$PWD` is the directory you ran
`apptainer run` from, which is where your images are. The Files window and the
terminal both open on `$PWD`; the Desktop launchers open `$HOME`. `run.py`
reads and writes relative paths, so results land beside their inputs either way.

## Design notes

Inherited from `app-novnc`, and the reasoning there applies verbatim:

**Display numbers are node-global.** The X lock (`/tmp/.X<n>-lock`) and socket
(`/tmp/.X11-unix/X<n>`) live in a `/tmp` that Apptainer usually shares with
every other user on the node, so the entrypoint walks `:1, :2, …` until one
takes rather than hardcoding `:1`.

**One port, one secret.** Only `OSP_APP_PORT` is bound on `0.0.0.0`. websockify
and Xvnc bind `127.0.0.1` and are unreachable from off-node. Xvnc runs
`-SecurityTypes None -localhost` with no VNC password on purpose: its only
client is websockify in this same container, and the browser-facing
authentication is the token gate.

**The autoconnect page.** noVNC's client is `vnc.html` and needs query
parameters, but the gate strips the query string after the token exchange — so
the image bakes an `index.html` that redirects to `vnc.html?autoconnect=true…`.

**Scratch paths.** The entrypoint does not trust `$TMPDIR`; it probes
`$TMPDIR`, `/tmp`, `$HOME` and says on stderr which it took.

Added here:

**More XDG paths get the uid suffix.** `app-novnc` sets `XDG_RUNTIME_DIR=/tmp/run`
as an `ENV`. On a shared node that is a fixed node-global name, and dbus creates
it `0700` — so the second user on the node cannot write to the first one's
directory. This entrypoint derives `XDG_RUNTIME_DIR`, `XDG_CACHE_HOME`,
`MPLCONFIGDIR` and `YOLO_CONFIG_DIR` from `$TMPDIR` and the uid, the same way
the nginx gate already scopes its own directory. The `ENV` values remain as the
fallback for a bare `docker run`. **Worth backporting to `app-novnc`.**

**A venv rather than `--break-system-packages`.** Ubuntu marks its system
Python externally-managed (PEP 668). `/opt/venv` keeps the detector's pinned
wheels from arguing with the apt-installed desktop's Python bindings, and goes
first on `PATH`. `detect` names `/opt/venv/bin/python3` explicitly rather than
trusting whatever `PATH` a user's shell ends up with.

## Pinned versions

| What | Version | Where |
|---|---|---|
| Base image | `ubuntu:26.04` | `Dockerfile` |
| Ultralytics | `8.4.131` | `requirements.txt` |
| torch / torchvision | `2.13.0` / `0.28.0`, CPU-only | `Dockerfile` |
| Model weights | `yolo11n.pt` | baked in at build time |
| Apptainer | `1.5.2` | `APPTAINER_VERSION` in the workflow |
| Actions | checkout v6, buildx v4, login v4, metadata v6, build-push v7 | the workflow |

The base is `ubuntu:26.04`, matching `app-novnc`, because the VNC and desktop
half is the finicky half and is worth keeping identical to the app that is
known to work. The consequence is that Python comes from Ubuntu rather than
from `python:3.14-slim`, so the interpreter's minor version may differ from
`app-object-detection`'s. The wheels are pinned identically, which is what
determines the results.

The image is CPU-only: PyPI's default torch wheel is the CUDA build, which adds
roughly 2 GB the `.sif` then carries to every compute node.

**One package name to watch.** XFCE's image viewer is `ristretto` on current
Ubuntu; it was `xfce4-ristretto` before 20.04. If the `apt-get install` line
fails, that is the name to check first.

## Build and test locally

Skip GitHub and the registry entirely:

```bash
docker build -t app-object-detection-novnc:dev .   # --platform linux/amd64 on Apple Silicon
docker run --rm --user "$(id -u):$(id -g)" \
  -p 6080:6080 -v "$PWD:/home/ospuser" \
  -e OSP_APP_PORT=6080 -e OSP_APP_TOKEN=localdev app-object-detection-novnc:dev

docker save app-object-detection-novnc:dev -o aodn.tar
apptainer build aodn.sif docker-archive://aodn.tar
apptainer run --env OSP_APP_PORT=6080 --env OSP_APP_TOKEN=localdev aodn.sif
```

Open `http://localhost:6080/?token=localdev`. Use *localhost*, not the host's
IP: the gate's cookie is marked `Secure`, and browsers make an exception for
`http://localhost` but not for any other plain-http origin, where the cookie is
dropped and every page load needs `?token=` again.

Worth checking specifically, and only the `.sif` exercises them: that the
desktop configuration was seeded into a writable home rather than failing
silently; that thumbnails appear in the Files window (if they do not, the
session bus did not come up — the entrypoint says so on stderr); and that
`detect` runs with no network at all.

### Why `--user`

The image already sets `USER ospuser` (uid 1000), so a bare `docker run` does
not write root-owned files. But uid 1000 is probably not *you*: on Linux,
anything the container writes into a bind mount still comes out owned by 1000,
and if the mounted directory is yours the container may not be able to write to
it at all. `--user "$(id -u):$(id -g)"` fixes both and matches how Apptainer
runs it — Apptainer is always the invoking user.

To reclaim files a previous run left behind:

```bash
sudo chown -R "$(id -u):$(id -g)" .
```

That uid has no `/etc/passwd` entry inside the container, so `whoami` fails and
`ls -l` shows bare numbers. Nothing actually breaks — only code calling
`getpwuid()` notices — and Apptainer generates the entry itself. If you want a
name locally:

```bash
# 1. Let the entrypoint add one. /etc/passwd is group-writable in this image,
#    so running with group 0 is enough. You become `ospuser`.
docker run --rm --user "$(id -u):0" ...

# 2. Or show the container your real identity, keeping your own gid.
docker run --rm --user "$(id -u):$(id -g)" \
  -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro ...
```

Set `OSP_APP_USER` to change the name option 1 uses.

`apptainer build` from a local archive needs no root and no fakeroot. Test the
`.sif` and not just the image: read-only-filesystem bugs never show up under
`docker run`.
