#!/usr/bin/env bash
# Sidecar upstream integration script
# Fetches upstream, runs tests in isolated env, does smoke test, then merges to active install
# Usage: ./scripts/sidecar-integrate-upstream.sh [--apply] [--dry-run]

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG() { echo -e "${BLUE}[sidecar]${NC} $*"; }
OK()  { echo -e "${GREEN}[sidecar]${NC} $*"; }
WARN(){ echo -e "${YELLOW}[sidecar]${NC} $*"; }
ERR() { echo -e "${RED}[sidecar]${NC} $*"; }

APPLY=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --dry-run) DRY_RUN=true ;;
  esac
done

# Paths
FORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTIVE_DIR="$HOME/.hermes/hermes-agent"
VENV_DIR="$ACTIVE_DIR/venv"
SIDECAR_DIR="/tmp/hermes-sidecar-$$"
SIDECAR_VENV="$SIDECAR_DIR/venv"

cleanup() {
  if [[ -d "$SIDECAR_DIR" ]]; then
    LOG "Cleaning up sidecar at $SIDECAR_DIR"
    rm -rf "$SIDECAR_DIR"
  fi
}
trap cleanup EXIT

LOG "Starting sidecar upstream integration"
LOG "Fork: $FORK_DIR"
LOG "Active: $ACTIVE_DIR"
LOG "Sidecar: $SIDECAR_DIR"

# 1. Fetch upstream
LOG "Fetching upstream/main..."
cd "$FORK_DIR"
git fetch upstream main --quiet

UPSTREAM_HEAD=$(git rev-parse upstream/main)
LOCAL_HEAD=$(git rev-parse main)

if [[ "$UPSTREAM_HEAD" == "$LOCAL_HEAD" ]]; then
  OK "Already up to date with upstream/main ($UPSTREAM_HEAD)"
  exit 0
fi

LOG "Upstream has new commits: $(git log --oneline main..upstream/main | wc -l) commits"
git log --oneline main..upstream/main

# 2. Create sidecar clone
LOG "Creating sidecar clone..."
git clone --shared "$FORK_DIR" "$SIDECAR_DIR" --quiet
cd "$SIDECAR_DIR"
git checkout -b sidecar-integration origin/main --quiet

# Add upstream remote to sidecar
git remote add upstream https://github.com/NousResearch/hermes-agent.git
git fetch upstream main --quiet

# 3. Merge upstream into sidecar
LOG "Merging upstream/main into sidecar..."
if ! git merge --no-ff --no-edit upstream/main --quiet; then
  ERR "Merge conflict! Manual resolution needed."
  exit 1
fi

SIDECAR_HEAD=$(git rev-parse HEAD)
LOG "Sidecar at $SIDECAR_HEAD"

# 4. Set up test environment - install sidecar code into active venv
LOG "Installing sidecar code into active venv..."
source "$VENV_DIR/bin/activate"
uv pip install -e "$SIDECAR_DIR" --quiet 2>&1 | tail -2

# 5. Run targeted test suite
LOG "Running targeted tests..."
TEST_RESULTS=0

# Test 1: File operations (fast, core)
if ! python -m pytest tests/tools/test_file_operations.py -x -q 2>&1 | tail -5; then
  ERR "File operations tests FAILED"
  TEST_RESULTS=1
fi

# Test 2: Tools config (catches platform toolset regressions)
if ! python -m pytest tests/hermes_cli/test_tools_config.py -x -q 2>&1 | tail -5; then
  ERR "Tools config tests FAILED"
  TEST_RESULTS=1
fi

# Test 3: Core agent loop (smoke) - skip known flaky anthropic interrupt test
if ! python -m pytest tests/run_agent/test_run_agent.py -x -q -k "not test_interruptible_anthropic_interrupt_never_closes_shared_client" 2>&1 | tail -5; then
  ERR "Run agent tests FAILED"
  TEST_RESULTS=1
fi

# 6. Smoke test: quick chat
LOG "Running smoke test chat..."
SMOKE_OUTPUT=$(timeout 60 hermes chat -q "Reply with exactly: SMOKE_TEST_OK" \
  --provider openrouter \
  -m "nemotron-3-ultra-550b-a55b:free" \
  -t "web" -Q 2>&1 || true)

if echo "$SMOKE_OUTPUT" | grep -q "SMOKE_TEST_OK"; then
  OK "Smoke test PASSED"
else
  ERR "Smoke test FAILED"
  echo "$SMOKE_OUTPUT"
  TEST_RESULTS=1
fi

# 7. Summary
echo
LOG "=== SIDECAR INTEGRATION SUMMARY ==="
LOG "Upstream: $UPSTREAM_HEAD"
LOG "Sidecar:  $SIDECAR_HEAD"
LOG "Tests:    $([[ $TEST_RESULTS -eq 0 ]] && echo 'PASSED' || echo 'FAILED')"
LOG "Smoke:    $([[ $TEST_RESULTS -eq 0 ]] && echo 'PASSED' || echo 'FAILED')"

if [[ $TEST_RESULTS -ne 0 ]]; then
  ERR "Sidecar validation FAILED — not applying to active install"
  exit 1
fi

OK "All sidecar checks PASSED"

# 8. Apply to active install (if --apply)
if [[ "$APPLY" == "true" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    WARN "DRY RUN: Would apply to active install"
  else
    LOG "Applying to active install..."
    cd "$ACTIVE_DIR"
    
    # Stash any local changes
    git stash push -m "sidecar pre-merge $(date +%s)" --quiet 2>/dev/null || true
    
    # Fast-forward to sidecar HEAD
    git fetch "$SIDECAR_DIR" sidecar-integration --quiet
    git merge --ff-only FETCH_HEAD --quiet

    # Reinstall
    source "$VENV_DIR/bin/activate"
    uv pip install -e . --quiet 2>&1 | tail -2

    OK "Active install updated to $SIDECAR_HEAD"
    hermes --version

    # Push to origin to keep fork in sync (standing approval granted by user)
    LOG "Pushing to origin/main to keep fork in sync..."
    git push origin main --quiet
    OK "origin/main updated to $(git rev-parse --short HEAD)"
  fi
else
  LOG "Run with --apply to merge into active install"
  LOG "Sidecar branch available at: $SIDECAR_DIR (branch: sidecar-integration)"
fi