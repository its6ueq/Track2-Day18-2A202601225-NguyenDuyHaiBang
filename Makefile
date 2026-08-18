## Day 18 Lakehouse Lab — student UX
## Two paths: lightweight (default, pure Python) and Spark (Docker, optional).

VENV       := .venv
PY         := $(VENV)/bin/python
PIP        := $(VENV)/bin/pip
JUPYTER    := $(VENV)/bin/jupyter
JUPYTEXT   := $(VENV)/bin/jupytext
PYTEST     := $(VENV)/bin/pytest
COMPOSE    := docker compose -f docker/docker-compose.yml

.DEFAULT_GOAL := help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nLightweight path (default — no Docker):\n"} \
	      /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ─────────────────────────────────────────────────────────────
# Lightweight path (default) — pure Python, no Docker, no JVM
# ─────────────────────────────────────────────────────────────

setup: ## [lite] Create venv + install deps (~180 MB, ~20s with pip / ~4s with uv)
	@command -v uv >/dev/null 2>&1 && uv venv $(VENV) --python '>=3.10,<3.15' || python3 -m venv $(VENV)
	@$(PY) -c 'import sys; raise SystemExit(0 if (3,10)<=sys.version_info[:2]<(3,15) else 1)' \
	  || { echo "ERROR: need Python 3.10-3.14. Install 'uv' (auto-fetches one) or run: python3.12 -m venv .venv"; exit 1; }
	@command -v uv >/dev/null 2>&1 && uv pip install --python $(PY) -r requirements.txt \
	  || $(PIP) install -q -r requirements.txt
	@$(JUPYTEXT) --to notebook --update notebooks/*.py 2>/dev/null || $(JUPYTEXT) --to notebook notebooks/*.py
	@echo ""
	@echo "  ✓ Setup complete. Run 'make smoke' then 'make lab'."

smoke: ## [lite] ~15-second end-to-end smoke test (Delta + Iceberg + vectors)
	@$(PY) scripts/verify_lite.py

test: ## [lite] Run the pytest suite the instructor grades against
	@$(PYTEST) -q

lab: ## [lite] Open Jupyter Lab on http://localhost:8888
	@$(JUPYTEXT) --to notebook --update notebooks/*.py 2>/dev/null || true
	@$(JUPYTER) lab --notebook-dir=notebooks --ServerApp.token='' --no-browser

data: ## [lite] Generate 200K-row Bronze sample for NB4
	@$(PY) scripts/generate_data_lite.py

data-ai: ## [lite] Generate multimodal + agent-trajectory sample for NB7/NB8
	@$(PY) scripts/generate_ai_data.py

run-all: ## [lite] Execute every notebook headlessly (what CI does)
	@$(PY) scripts/run_all.py

simulate: ## [lite] Abuse the lab the way students do (12 scenarios; SIM_FAST=1 to skip venv builds)
	@$(PY) tests/simulate_students.py

clean: ## [lite] Wipe venv + lakehouse data
	rm -rf $(VENV) _lakehouse notebooks/.ipynb_checkpoints .pytest_cache

# ─────────────────────────────────────────────────────────────
# WSL2 on Windows — same two paths, plus the WSL-only guards
# (venv on ext4 when the repo sits on /mnt/*, python3-venv check, RAM check).
# Run these INSIDE the distro:  wsl -d Ubuntu
# ─────────────────────────────────────────────────────────────

WSL := scripts/wsl.sh

wsl-setup: ## [wsl] venv (on ext4) + deps — use instead of `make setup` under WSL
	@$(WSL) setup

wsl-smoke: ## [wsl] Smoke test against the WSL venv
	@$(WSL) smoke

wsl-test: ## [wsl] Pytest suite against the WSL venv
	@$(WSL) test

wsl-data: ## [wsl] Bronze sample for NB4 (lands on ext4, not /mnt)
	@$(WSL) data

wsl-data-ai: ## [wsl] Multimodal + agent traces for NB7/NB8
	@$(WSL) data-ai

wsl-run-all: ## [wsl] Execute all 8 notebooks headlessly — the grading gate
	@$(WSL) run-all

wsl-notebooks: ## [wsl] Execute notebooks/*.ipynb in place so outputs are saved (submission)
	@$(WSL) notebooks

wsl-lab: ## [wsl] Jupyter Lab bound 0.0.0.0 → http://localhost:8888 from Windows
	@$(WSL) lab

wsl-status: ## [wsl] Show python / venv / RAM / docker state of this distro
	@$(WSL) status

wsl-spark-up: ## [wsl] Docker path via Docker Desktop WSL integration
	@$(WSL) spark-up

wsl-spark-smoke: ## [wsl] scripts/verify.py inside the Spark container
	@$(WSL) spark-smoke

wsl-spark-down: ## [wsl] Stop the Docker stack
	@$(WSL) spark-down

wsl-clean: ## [wsl] Delete the WSL venv + generated lab data
	@$(WSL) clean

# ─────────────────────────────────────────────────────────────
# Spark on Apple `container` (optional) — macOS 15+, Apple silicon
# Same 3-service stack as the compose path, driven by `container run`,
# because Apple's runtime has no compose plugin and no Docker socket.
# ─────────────────────────────────────────────────────────────

AC := scripts/apple_container.sh

apple-up: ## [apple] Start MinIO + buckets + Spark/Jupyter via Apple `container`
	@$(AC) up

apple-smoke: ## [apple] Run scripts/verify.py in the Spark container
	@$(AC) smoke

apple-data: ## [apple] Generate the 1M-row Bronze table via Spark
	@$(AC) data

apple-status: ## [apple] Show containers + MinIO's injected IP
	@$(AC) status

apple-down: ## [apple] Stop and remove containers (MinIO data kept)
	@$(AC) down

apple-clean: ## [apple] Same as apple-down, plus delete _minio-data/
	@$(AC) clean

# ─────────────────────────────────────────────────────────────
# Spark + Docker path (optional, production-fidelity)
# ─────────────────────────────────────────────────────────────

spark-up: ## [spark] Start MinIO + Spark/Jupyter (Docker — first run pulls ~2 GB)
	$(COMPOSE) up -d
	@echo "  Jupyter → http://localhost:8888 (token: lakehouse)"
	@echo "  MinIO   → http://localhost:9001 (minioadmin / minioadmin)"

spark-smoke: ## [spark] Smoke test inside Spark container
	$(COMPOSE) exec -T spark python /workspace/scripts/verify.py

spark-data: ## [spark] Generate 1M-row Bronze (Spark version)
	$(COMPOSE) exec -T spark python /workspace/scripts/generate_data.py

spark-down: ## [spark] Stop Docker stack (data persists)
	$(COMPOSE) down

spark-clean: ## [spark] Stop AND wipe MinIO + ivy cache
	$(COMPOSE) down -v

.PHONY: help setup smoke test lab data data-ai run-all clean \
        simulate apple-up apple-smoke apple-data apple-status apple-down apple-clean \
        wsl-setup wsl-smoke wsl-test wsl-data wsl-data-ai wsl-run-all wsl-notebooks wsl-lab wsl-status wsl-spark-up wsl-spark-smoke wsl-spark-down wsl-clean \
        spark-up spark-smoke spark-data spark-down spark-clean
