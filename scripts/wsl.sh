#!/usr/bin/env bash
# Run the Day 18 Lakehouse Lab under WSL2 (Windows Subsystem for Linux).
#
# WHY THIS EXISTS
# ---------------
# WSL is plain Linux, so `make setup` looks like it should just work. Seven
# WSL-only traps say otherwise; each one below cost a real debugging session on
# Ubuntu 26.04 + Docker Desktop 4.78, and the fix is noted at its use site:
#
#   1. Repo on a Windows drive (/mnt/c, /mnt/d) = drvfs: 10-50x slower than
#      ext4 for the many small files a venv writes, and a .venv built there by
#      Windows Python collides with the Linux one -> venv goes to ext4.
#   2. delta-rs cannot finish NB7's inline-blob write on drvfs at all
#      ("Upload aborted") -> LAKEHOUSE_ROOT goes to ext4 too.
#   3. Ubuntu 26.04 ships only Python 3.14, which has no pyiceberg wheel; pip
#      then compiles Cython and dies on the missing gcc -> pick_python().
#   4. Ubuntu splits ensurepip into python3-venv -> checked up front.
#   5. WSL2 caps guest RAM at 50% of the host; Spark wants ~6 GB -> check_ram().
#   6. The Spark container starts Jupyter before its pip install finishes -> a
#      smoke test fired too early fails on `import delta` -> wait_deps().
#   7. Windows git checkouts are CRLF, which no Linux shell can parse -> fixed
#      repo-wide by .gitattributes, not by this script.
#
# Usage (from Windows):  wsl -d Ubuntu bash scripts/wsl.sh setup
#        (from inside):  scripts/wsl.sh {setup|smoke|test|data|data-ai|run-all|notebooks|lab|spark-up|spark-smoke|spark-data|spark-down|status|clean}
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

if [ -t 1 ]; then C_INFO=$'\033[36m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'
else C_INFO=''; C_WARN=''; C_ERR=''; C_OFF=''; fi
log()  { printf '%s>>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
warn() { printf '%s!!%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%sxx%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null \
  || die "not running under WSL. On native Linux/macOS use: make setup && make smoke"

# ── venv location ────────────────────────────────────────────────────────────
# On a /mnt/* checkout the venv goes to ext4 and the repo keeps only the data.
# WSL_VENV overrides both branches for anyone who wants it elsewhere.
case "$REPO" in
  /mnt/*) ON_DRVFS=1 ;;
  *)      ON_DRVFS=0 ;;
esac
if [ "$ON_DRVFS" = 1 ]; then
  DEFAULT_VENV="${HOME:-/root}/.cache/day18-lakehouse/venv"
else
  DEFAULT_VENV="$REPO/.venv"
fi
VENV="${WSL_VENV:-$DEFAULT_VENV}"
PY="$VENV/bin/python"

# ── lakehouse data location ──────────────────────────────────────────────────
# Same reason, sharper failure. delta-rs writes Parquet through object_store's
# LocalFileSystem, which stages to a temp file and renames. On drvfs that path
# breaks down on NB7's inline-blob table (the biggest write in the lab):
#
#   _internal.DeltaError: Failed to parse parquet:
#   External: Generic LocalFileSystem error: Upload aborted
#
# NB1-NB6 survive on drvfs; NB7 does not, so `run-all` dies two notebooks from
# the end after ~5 minutes. scripts/lakehouse.py already honours LAKEHOUSE_ROOT
# (it is the same switch used to point the lab at s3://), so point it at ext4.
if [ "$ON_DRVFS" = 1 ]; then
  DEFAULT_LAKEHOUSE="${HOME:-/root}/.cache/day18-lakehouse/_lakehouse"
else
  DEFAULT_LAKEHOUSE="$REPO/_lakehouse"
fi
LAKEHOUSE_ROOT="${LAKEHOUSE_ROOT:-$DEFAULT_LAKEHOUSE}"
export LAKEHOUSE_ROOT

MAKE=(make VENV="$VENV")

PYBIN=""        # interpreter make will build the venv from (see pick_python)
SHIM="$VENV.shim"

# Pick an interpreter that actually has WHEELS, not just a supported version.
#
# The lab supports 3.10-3.14, but "supported" and "installs in 20 seconds" are
# different claims on Linux. Ubuntu 26.04 ships ONLY python3.14, and pyiceberg
# has no cp314 manylinux wheel: pip falls back to compiling its Cython
# `decoder_fast` extension, which on a stock distro dies after ~14 minutes with
#
#     error: [Errno 2] No such file or directory: 'x86_64-linux-gnu-gcc'
#
# So: prefer 3.12/3.13 (wheels for every dep), fall back to a uv-managed
# interpreter, and only then to the system one — telling the student up front
# what compiling will cost them.
pick_python() {
  local c v
  if [ -n "${WSL_PYTHON:-}" ]; then
    command -v "$WSL_PYTHON" >/dev/null 2>&1 || die "WSL_PYTHON=$WSL_PYTHON not found"
    PYBIN="$(command -v "$WSL_PYTHON")"; return
  fi
  for c in python3.12 python3.13 python3.11 python3.10; do
    if command -v "$c" >/dev/null 2>&1; then PYBIN="$(command -v "$c")"; return; fi
  done
  if command -v uv >/dev/null 2>&1; then
    log "No wheel-friendly system Python; fetching a uv-managed CPython 3.12 ..."
    uv python install 3.12 >/dev/null 2>&1 || true
    c="$(uv python find 3.12 2>/dev/null || true)"
    if [ -n "$c" ] && [ -x "$c" ]; then PYBIN="$c"; return; fi
  fi
  command -v python3 >/dev/null 2>&1 \
    || die "no python3. Run: sudo apt update && sudo apt install -y python3 python3-venv python3-pip"
  v="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  python3 -c 'import sys; raise SystemExit(0 if (3,10)<=sys.version_info[:2]<(3,15) else 1)' \
    || die "need Python 3.10-3.14, found $v"
  if [ "$v" = "3.14" ] && ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    die "$(cat <<EOF
only Python 3.14 here, and pyiceberg has no cp314 wheel — pip must compile it,
but this distro has no C compiler. Pick one:

  A. uv fetches a 3.12 with wheels (fast, ~30s, no apt, no sudo):
       curl -LsSf https://astral.sh/uv/install.sh | sh && . \$HOME/.local/bin/env
       scripts/wsl.sh setup

  B. distro Python 3.12 (if your release still has it):
       sudo apt update && sudo apt install -y python3.12 python3.12-venv

  C. compile pyiceberg from source (~200 MB of toolchain, several minutes):
       sudo apt update && sudo apt install -y build-essential python3-dev
EOF
)"
  fi
  PYBIN="$(command -v python3)"
}

require_python() {
  pick_python
  # Ubuntu/Debian split ensurepip into python3-venv. Catch it here: the error
  # make would print otherwise blames venv, not the missing apt package.
  "$PYBIN" -c 'import ensurepip' >/dev/null 2>&1 || command -v uv >/dev/null 2>&1 \
    || die "python3-venv missing (no ensurepip) for $PYBIN. Run: sudo apt update && sudo apt install -y python3-venv python3-pip"
}

# Put the chosen interpreter first on PATH as plain `python3`, then let the
# Makefile do the work unchanged — both branches of its setup rule (`uv venv`
# and `python3 -m venv`) resolve python3 through PATH, so this steers them
# without forking the build logic.
make_with_python() {
  mkdir -p "$SHIM"
  ln -sf "$PYBIN" "$SHIM/python3"
  PATH="$SHIM:$PATH" UV_PYTHON="$PYBIN" "${MAKE[@]}" "$@"
}

setup() {
  require_python
  if [ "$ON_DRVFS" = 1 ]; then
    warn "Repo is on a Windows drive ($REPO) — drvfs I/O is slow and delta-rs cannot finish NB7's write there."
    warn "Venv goes to      $VENV"
    warn "Lakehouse data to $LAKEHOUSE_ROOT   (override: LAKEHOUSE_ROOT=…)"
    warn "For the fastest lab, clone into the Linux filesystem instead: ~/Day18-Lakehouse-Lab"
  fi
  mkdir -p "$(dirname "$VENV")"
  log "make setup  (python: $PYBIN $("$PYBIN" -V 2>&1 | awk '{print $2}'), VENV=$VENV)"
  make_with_python setup
  echo
  log "Done. Next:  scripts/wsl.sh smoke"
}

need_venv() { [ -x "$PY" ] || die "venv missing at $VENV — run: scripts/wsl.sh setup"; }

smoke()   { need_venv; "${MAKE[@]}" smoke; }
test_()   { need_venv; "${MAKE[@]}" test; }
data()    { need_venv; "${MAKE[@]}" data; }
data_ai() { need_venv; "${MAKE[@]}" data-ai; }
run_all() { need_venv; "${MAKE[@]}" run-all; }

# `run-all` executes the .py sources — fast, and the right gate for grading.
# It does NOT touch the .ipynb files, so a student who only ran it submits
# notebooks with zero output cells, which the rubric rejects ("eight executed
# notebooks, output cells preserved"). This runs the real notebooks in place.
notebooks() {
  need_venv
  "$VENV/bin/jupytext" --to notebook --update "$REPO"/notebooks/*.py >/dev/null 2>&1 || true
  local f fails=0
  for f in "$REPO"/notebooks/0*.ipynb; do
    log "executing $(basename "$f") ..."
    if ! "$VENV/bin/jupyter" nbconvert --to notebook --execute --inplace \
           --ExecutePreprocessor.timeout=900 "$f" >/dev/null 2>&1; then
      warn "FAILED $(basename "$f")"
      fails=$((fails + 1))
    fi
  done
  [ "$fails" -eq 0 ] || die "$fails notebook(s) failed to execute"
  log "8 notebooks executed, outputs preserved. Submit them with: git add -f notebooks/*.ipynb"
}

lab() {
  need_venv
  # Bind 0.0.0.0, not the default loopback. WSL2 localhost forwarding covers
  # 127.0.0.1 on most builds, but it silently stops working when mirrored
  # networking is off or a VPN grabs the interface; 0.0.0.0 works in both.
  # --allow-root matters because many WSL distros still run as root.
  "$VENV/bin/jupytext" --to notebook --update notebooks/*.py >/dev/null 2>&1 || true
  log "Jupyter Lab -> http://localhost:8888   (Ctrl-C to stop)"
  "$VENV/bin/jupyter" lab \
    --notebook-dir=notebooks --ServerApp.token='' --ServerApp.ip=0.0.0.0 \
    --no-browser --allow-root
}

require_docker() {
  command -v docker >/dev/null 2>&1 \
    || die "docker not found in this distro. Enable Docker Desktop > Settings > Resources > WSL integration for it, or install the engine: curl -fsSL https://get.docker.com | sh"
  docker info >/dev/null 2>&1 \
    || die "docker CLI found but no daemon. Start Docker Desktop (WSL integration on), or: sudo service docker start"
  docker compose version >/dev/null 2>&1 \
    || die "'docker compose' (v2) plugin missing. Update Docker Desktop, or: sudo apt install -y docker-compose-plugin"
}

check_ram() {
  local kb gb
  kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
  gb=$(( kb / 1024 / 1024 ))
  if [ "$gb" -lt 8 ]; then
    warn "WSL guest has ${gb} GB RAM; the Spark stack wants ~6 GB free and gets OOM-killed under that."
    warn "Raise it in C:\\Users\\<you>\\.wslconfig, then run 'wsl --shutdown' from Windows:"
    warn '    [wsl2]'
    warn '    memory=8GB'
  fi
}

COMPOSE=(docker compose -f docker/docker-compose.yml)

# The container starts Jupyter BEFORE `pip install --user` has finished, so a
# smoke test fired right after `up -d` fails with "No module named 'delta'" and
# looks like a broken lab. Gate on the import actually working.
wait_deps() {
  local i
  for i in $(seq 1 60); do
    if "${COMPOSE[@]}" exec -T spark python -c 'import delta, pyspark' >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

spark_up() {
  require_docker
  check_ram
  log "docker compose up (first run pulls ~2 GB) ..."
  "${COMPOSE[@]}" up -d
  log "Waiting for in-container deps (pip install --user, first run only) ..."
  wait_deps || die "delta/pyspark still not importable after 300s. Check: docker compose -f docker/docker-compose.yml logs spark"
  echo
  log "Jupyter  http://localhost:8888  (token: lakehouse)"
  log "MinIO    http://localhost:9001  (minioadmin / minioadmin)"
  log "Next:  scripts/wsl.sh spark-smoke"
}
spark_smoke() {
  require_docker
  wait_deps || die "spark container not ready. Run: scripts/wsl.sh spark-up"
  "${COMPOSE[@]}" exec -T spark python /workspace/scripts/verify.py
}
spark_data()  { require_docker; "${COMPOSE[@]}" exec -T spark python /workspace/scripts/generate_data.py; }
spark_down()  { require_docker; "${COMPOSE[@]}" down; }

status() {
  local where
  if [ "$ON_DRVFS" = 1 ]; then where='Windows drive - slow drvfs'; else where='Linux filesystem'; fi
  echo "repo        $REPO  ($where)"
  local c cands=""
  for c in python3.10 python3.11 python3.12 python3.13 python3.14 python3; do
    if command -v "$c" >/dev/null 2>&1; then cands="$cands $("$c" -V 2>&1 | awk '{print $2}')"; fi
  done
  echo "python      $(echo "$cands" | tr ' ' '\n' | sort -uV | tr '\n' ' ')"
  if ! command -v python3.10 >/dev/null 2>&1 && ! command -v python3.11 >/dev/null 2>&1 \
     && ! command -v python3.12 >/dev/null 2>&1 && ! command -v python3.13 >/dev/null 2>&1 \
     && ! command -v uv >/dev/null 2>&1 \
     && python3 -c 'import sys; raise SystemExit(0 if sys.version_info[:2]==(3,14) else 1)' 2>/dev/null; then
    echo "            ^ only 3.14: pyiceberg has no cp314 wheel — install uv or build-essential (setup explains)"
  fi
  if [ -x "$PY" ]; then echo "venv        $VENV  ($("$PY" -V 2>&1))"
  else                  echo "venv        $VENV  (not built)"; fi
  echo "lakehouse   $LAKEHOUSE_ROOT  ($([ -d "$LAKEHOUSE_ROOT" ] && du -sh "$LAKEHOUSE_ROOT" 2>/dev/null | awk '{print $1}' || echo 'empty'))"
  echo "resources   $(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 / 1024 )) GB RAM / $(nproc) cpus"
  if command -v docker >/dev/null 2>&1; then
    local daemon
    if docker info >/dev/null 2>&1; then daemon=up; else daemon=DOWN; fi
    echo "docker      $(docker --version 2>&1 | head -1)  daemon: $daemon"
  else
    echo "docker      not installed (the lightweight path does not need it)"
  fi
}

clean() {
  log "Removing $VENV, $LAKEHOUSE_ROOT and generated lab data"
  rm -rf "$VENV" "$SHIM" "$LAKEHOUSE_ROOT" \
         "$REPO/_lakehouse" "$REPO/notebooks/.ipynb_checkpoints" "$REPO/.pytest_cache"
  log "Clean."
}

case "${1:-}" in
  setup)       setup ;;
  smoke)       smoke ;;
  test)        test_ ;;
  data)        data ;;
  data-ai)     data_ai ;;
  run-all)     run_all ;;
  notebooks)   notebooks ;;
  lab)         lab ;;
  spark-up)    spark_up ;;
  spark-smoke) spark_smoke ;;
  spark-data)  spark_data ;;
  spark-down)  spark_down ;;
  status)      status ;;
  clean)       clean ;;
  *) cat <<'EOF'
Day 18 Lakehouse Lab on WSL2.

  setup        venv + deps (venv lands on ext4 when the repo is on /mnt/*)
  smoke        9-check offline smoke test
  test         pytest suite the instructor grades against
  data         Bronze sample for NB4
  data-ai      multimodal + agent traces for NB7/NB8
  run-all      execute all 8 notebooks headlessly (grading gate)
  notebooks    execute notebooks/*.ipynb IN PLACE so outputs are saved (for submission)
  lab          Jupyter Lab on http://localhost:8888 (bound 0.0.0.0)
  status       what this distro has: python, venv, RAM, docker
  clean        delete the venv + generated lab data

  spark-up / spark-smoke / spark-data / spark-down
               optional Docker path (needs Docker Desktop WSL integration, ~8 GB RAM)

From Windows:  wsl -d Ubuntu bash scripts/wsl.sh setup
Override venv: WSL_VENV=~/venvs/day18 scripts/wsl.sh setup
EOF
     exit 1 ;;
esac
