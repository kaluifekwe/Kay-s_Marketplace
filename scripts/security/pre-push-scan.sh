#!/usr/bin/env bash
# Pre-push security scan, same idea as the KaysPay repo's hook. Scans only what
# is about to be pushed, so it stays fast enough that nobody routes around it.
# Uses Docker for every tool, so nothing else needs installing on Windows.
#
# Skip deliberately (not recommended): git push --no-verify
set -euo pipefail

# Git Bash (MSYS) rewrites a leading /path in arguments into a Windows path
# before it reaches docker.exe, which breaks every -v/--config path below.
# No-op on Linux/macOS.
export MSYS_NO_PATHCONV=1

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Docker Desktop wants a Windows-style path for bind mounts under Git Bash.
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
MOUNT_ROOT="$(winpath "$REPO_ROOT")"

if ! docker info >/dev/null 2>&1; then
  echo "Docker isn't running, so the pre-push security scan can't run."
  echo "Start Docker Desktop, or push with --no-verify if you deliberately want to skip it."
  exit 1
fi

DEFAULT_REF="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/feat/shipbubble-delivery)"

LOCAL_SHAS=()
while read -r local_ref local_sha remote_ref remote_sha; do
  [ -z "${local_sha:-}" ] && continue
  [ "$local_sha" = "0000000000000000000000000000000000000000" ] && continue # deleting a ref
  LOCAL_SHAS+=("$local_sha:$remote_sha")
done

if [ "${#LOCAL_SHAS[@]}" -eq 0 ]; then
  echo "Nothing to scan (no ref updates)."
  exit 0
fi

SG_DIR=""
cleanup() { [ -n "$SG_DIR" ] && rm -rf "$SG_DIR"; docker rm -f "pps-semgrep-$$" "pps-rules-$$" >/dev/null 2>&1 || true; }
trap cleanup EXIT

FAIL=0

for pair in "${LOCAL_SHAS[@]}"; do
  local_sha="${pair%%:*}"
  remote_sha="${pair##*:}"
  if [ -z "$remote_sha" ] || [ "$remote_sha" = "0000000000000000000000000000000000000000" ]; then
    # New branch on the remote: compare against the default branch.
    base_sha="$(git merge-base "$local_sha" "$DEFAULT_REF" 2>/dev/null || echo "${local_sha}~20")"
  else
    base_sha="$remote_sha"
  fi

  CHANGED_FILES="$(git diff --name-only --diff-filter=d "$base_sha" "$local_sha" -- . ':!*.lock' ':!package-lock.json' || true)"
  if [ -z "$CHANGED_FILES" ]; then
    continue
  fi

  echo ""
  echo "== Scanning $(echo "$CHANGED_FILES" | wc -l) changed file(s) between ${base_sha:0:8} and ${local_sha:0:8} =="

  echo ""
  echo "-- Gitleaks (secrets) --"
  if ! docker run --rm -v "$MOUNT_ROOT:/repo" zricethezav/gitleaks:latest detect \
      --source="/repo" --log-opts="${base_sha}..${local_sha}" --no-banner --redact -v; then
    echo "Gitleaks found a likely secret in these commits. Fix it before pushing."
    FAIL=1
  fi

  echo ""
  echo "-- Guard: public web app must not touch the service-role key --"
  if git ls-files web | grep -E '^web/(app|lib|components)/|^web/next.config.js$' \
      | xargs -r grep -nE 'SERVICE_ROLE_KEY|SUPABASE_SERVICE|service_role'; then
    echo "The public web app must never reference the service-role key."
    FAIL=1
  else
    echo "ok"
  fi

  # Only source we own; tests excluded (same list as .semgrepignore, which does
  # not apply to files passed explicitly on the command line).
  SEMGREP_FILES=$(echo "$CHANGED_FILES" \
    | grep -E '^(web/(app|lib|components)/|dispatch-admin/src/|dispatchph_mobile/supabase/functions/).*\.(ts|tsx|js|jsx)$' \
    | grep -vE '\.(test|spec)\.(ts|tsx|js|jsx)$' || true)

  if [ -n "$SEMGREP_FILES" ]; then
    # Semgrep inspects the git repo it is mounted in, which hangs on this huge
    # working tree under Docker-on-Windows. Stage ONLY the changed files (as
    # committed) plus the rules into a small temp dir and scan that instead.
    SG_DIR="$(mktemp -d)"
    mkdir -p "$SG_DIR/.semgrep"
    cp .semgrep/dispatch-rules.yml "$SG_DIR/.semgrep/"
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      mkdir -p "$SG_DIR/$(dirname "$f")"
      git show "${local_sha}:${f}" > "$SG_DIR/$f" 2>/dev/null || true
    done <<< "$SEMGREP_FILES"
    SG_MOUNT="$(winpath "$SG_DIR")"

    echo ""
    echo "-- Semgrep: community security rules (blocking) --"
    SEMGREP_STATUS=0
    # 5-minute cap: a timeout is a warning (CI still runs Semgrep), never a frozen push.
    timeout 300 docker run --rm --name "pps-semgrep-$$" -v "$SG_MOUNT:/src" -w /src semgrep/semgrep:latest \
      semgrep --config=p/security-audit --config=p/javascript --config=p/typescript \
      --metrics=off --disable-version-check --no-git-ignore --error . || SEMGREP_STATUS=$?
    if [ "$SEMGREP_STATUS" -eq 124 ]; then
      echo "Semgrep timed out locally; skipped (CI still runs it)."
    elif [ "$SEMGREP_STATUS" -ne 0 ]; then
      echo "Semgrep found a real finding above. Fix it before pushing."
      FAIL=1
    fi

    echo ""
    echo "-- Semgrep: Dispatch-specific rules (blocking) --"
    RULES_STATUS=0
    timeout 300 docker run --rm --name "pps-rules-$$" -v "$SG_MOUNT:/src" -w /src semgrep/semgrep:latest \
      semgrep --config=.semgrep/dispatch-rules.yml \
      --metrics=off --disable-version-check --no-git-ignore --error . || RULES_STATUS=$?
    if [ "$RULES_STATUS" -eq 124 ]; then
      echo "Dispatch rules timed out locally; skipped (CI still runs them)."
    elif [ "$RULES_STATUS" -ne 0 ]; then
      echo "A Dispatch security rule was violated. Fix it before pushing."
      FAIL=1
    fi
    rm -rf "$SG_DIR"; SG_DIR=""
  else
    echo ""
    echo "-- Semgrep --"
    echo "(no scanned JS/TS files changed, skipped)"
  fi

  if echo "$CHANGED_FILES" | grep -qE '(^|/)(package\.json|pubspec\.yaml)$'; then
    echo ""
    echo "-- OSV-Scanner (dependency CVEs) --"
    # `scan source` is the current subcommand; the old flat form silently
    # ignores --config, which looks like a clean pass. Not always a hard
    # blocker (transitive build tooling): read the output, use judgment.
    if ! docker run --rm -v "$MOUNT_ROOT:/repo" ghcr.io/google/osv-scanner:latest \
        scan source --recursive --config=/repo/.osv-scanner.toml /repo 2>/dev/null; then
      echo "OSV-Scanner found a known-vulnerable dependency. Review before pushing."
    fi
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "Pre-push security scan FAILED. Fix the above, or push with --no-verify (not recommended)."
  exit 1
fi

echo ""
echo "Pre-push security scan passed."
