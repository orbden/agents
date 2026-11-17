#!/usr/bin/env bash
# Local CI: runs the checks of the hosted workflow on this machine and reports
# the result as the commit status `check` on HEAD, which is the context branch
# protection requires. The hosted workflow (.github/workflows/ci.yml) stays
# available as a manual run.
#
# It also keeps one result comment on the branch's open pull request (edited in
# place on every run): each step with its time, the full commit, whether it is
# pushed, how far behind main it is, and the tool versions.
#
# Usage: scripts/ci-local.sh [--no-report]
# Needs: a clean tree (the result belongs to the commit, not the working copy),
# a pushed HEAD and an authenticated `gh` for reporting, Python 3.11+ (tomllib),
# shellcheck, and a Rust toolchain unless OPS_ENGINE points at an engine built
# from the commit pinned in .github/actions/build-engine/action.yml.
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

report=1
[[ "${1:-}" == "--no-report" ]] && report=0

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ci-local: the working tree is not clean; commit or stash first" >&2
  exit 2
fi

sha="$(git rev-parse HEAD)"
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
if [[ $report -eq 1 && -z "$repo" ]]; then
  echo "ci-local: cannot resolve the GitHub repository (gh auth status)" >&2
  exit 2
fi

post() { # state description
  [[ $report -eq 1 ]] || return 0
  gh api "repos/$repo/statuses/$sha" -f state="$1" -f context="check" \
    -f description="$2" >/dev/null
}

python=""
for candidate in python3.15 python3.14 python3.13 python3.12 python3.11 python3; do
  if command -v "$candidate" >/dev/null &&
    "$candidate" -c 'import tomllib' 2>/dev/null; then
    python="$candidate"
    break
  fi
done
if [[ -z "$python" ]]; then
  echo "ci-local: needs Python 3.11+ (tomllib)" >&2
  exit 2
fi
if ! command -v shellcheck >/dev/null; then
  echo "ci-local: shellcheck is not installed" >&2
  exit 2
fi

build_engine() {
  if [[ -n "${OPS_ENGINE:-}" && -x "$OPS_ENGINE" ]]; then
    return 0
  fi
  local pin cache
  pin="$(sed -n 's/^ *ref: \([0-9a-f]\{40\}\).*/\1/p' .github/actions/build-engine/action.yml)"
  if [[ -z "$pin" ]]; then
    echo "ci-local: no engine commit found in .github/actions/build-engine/action.yml" >&2
    return 1
  fi
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/agents-ci-local/operations-engine"
  if [[ ! -d "$cache/.git" ]]; then
    mkdir -p "$cache" &&
      git clone --quiet https://github.com/orbden/operations-engine.git "$cache" || return 1
  fi
  git -C "$cache" cat-file -e "$pin^{commit}" 2>/dev/null ||
    git -C "$cache" fetch --quiet origin || return 1
  git -C "$cache" checkout --quiet --detach "$pin" || return 1
  (cd "$cache" && cargo build --release --locked) || return 1
  export OPS_ENGINE="$cache/target/release/ops-engine"
}

shellcheck_agents() {
  # find, not globstar: the bash that ships with macOS has no globstar.
  local files=()
  while IFS= read -r file; do files+=("$file"); done < <(find agents -name '*.sh' | sort)
  if [[ ${#files[@]} -eq 0 ]]; then return 0; fi
  echo "ci-local: ShellCheck on ${#files[@]} scripts"
  shellcheck "${files[@]}"
}

registry_builds() {
  local out
  out="$(mktemp)" || return 1
  # build_registry.py writes registry.json in the repository; restore it after.
  "$python" scripts/build_registry.py ci "$sha" &&
    "$python" -m json.tool registry.json >"$out"
  local status=$?
  rm -f "$out"
  git checkout -- registry.json 2>/dev/null || rm -f registry.json
  return $status
}

unit_counts() {
  awk '/^Ran [0-9]+ tests?/{n=$2} /^OK|^FAILED/{r=$0} END{printf "%s tests, %s", n, r}' "$log"
}
shellcheck_count() { printf '%s scripts' "$(find agents -name '*.sh' | wc -l | tr -d ' ')"; }

base_branch=main
versions="$("$python" --version), $(shellcheck --version | sed -n 's/^version: /shellcheck /p')"

post pending "running locally"
failed=0
# ── Result reporting (same in every repository) ───────────────────────────────
rows=()
failure_tail=""
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# step NAME SUMMARY_FN CMD...: runs CMD with its output shown and kept, adds a
# table row with the time and, on success, what SUMMARY_FN prints about the
# output (for example how many tests ran). A failing step keeps the last lines
# of its output for the comment.
step() {
  local name="$1" summary="$2"
  shift 2
  local started=$SECONDS rc=0
  "$@" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  local took=$((SECONDS - started))
  if [[ $rc -eq 0 ]]; then
    rows+=("| $name | passed | $("$summary") | $took s |")
    echo "ci-local: $name passed"
  else
    rows+=("| $name | **FAILED** | exit $rc | $took s |")
    failure_tail="$(tail -n 25 "$log" | sed 's/\x1b\[[0-9;]*m//g')"
    echo "ci-local: $name FAILED" >&2
  fi
  return $rc
}
none() { :; }

# One comment per pull request, found by its marker and edited in place, so
# repeated runs do not pile up. Never changes the exit code.
# Uses: repo, sha, failed, rows, failure_tail, base_branch, versions (text).
comment() {
  [[ $report -eq 1 ]] || return 0
  local branch pr marker body id verdict behind pushed
  branch="$(git rev-parse --abbrev-ref HEAD)"
  pr="$(gh pr list --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
  [[ -n "$pr" ]] || return 0
  git fetch -q origin "$base_branch" "$branch" 2>/dev/null || true
  behind="$(git rev-list --count "HEAD..origin/$base_branch" 2>/dev/null || echo '?')"
  [[ "$(git rev-parse "origin/$branch" 2>/dev/null)" == "$sha" ]] && pushed=yes || pushed=NO
  verdict=$([[ $failed -eq 0 ]] && echo "all checks passed" || echo "FAILED")
  marker='<!-- ci-local -->'
  body="$marker
**Local checks: $verdict** on commit \`$sha\` ($(date -u +%Y-%m-%dT%H:%MZ))

| Step | Result | Detail | Time |
| --- | --- | --- | --- |
$(printf '%s\n' "${rows[@]}")

| What | Value |
| --- | --- |
| Commit | \`$sha\` on \`$branch\` |
| Tree | clean (the script refuses a dirty tree) |
| Pushed | $pushed (the commit above is the branch head on GitHub) |
| Behind \`$base_branch\` | $behind commit(s) |
| Tools | $versions |
| Host | $(uname -sm) |

Run by \`scripts/ci-local.sh\` on the author's machine; hosted CI is not used. The commit status says the same."
  if [[ -n "$failure_tail" ]]; then
    body="$body

<details><summary>Last output of the failing step</summary>

\`\`\`
$failure_tail
\`\`\`

</details>"
  fi
  id="$(gh api "repos/$repo/issues/$pr/comments" --paginate \
    --jq "[.[] | select(.body | startswith(\"$marker\"))][0].id // empty" 2>/dev/null || true)"
  if [[ -n "$id" ]]; then
    gh api -X PATCH "repos/$repo/issues/comments/$id" -f body="$body" >/dev/null 2>&1 ||
      echo "ci-local: could not update the PR comment" >&2
  else
    gh api "repos/$repo/issues/$pr/comments" -f body="$body" >/dev/null 2>&1 ||
      echo "ci-local: could not post the PR comment" >&2
  fi
}

step "engine build" none build_engine || failed=1
# step runs in a pipeline, so the export inside build_engine did not survive.
[[ -n "${OPS_ENGINE:-}" ]] ||
  export OPS_ENGINE="${XDG_CACHE_HOME:-$HOME/.cache}/agents-ci-local/operations-engine/target/release/ops-engine"
if [[ $failed -eq 0 ]]; then
  step "agent metadata and scripts" none "$python" scripts/check_agents.py || failed=1
  step "unit tests" unit_counts "$python" -m unittest discover tests || failed=1
  step "ShellCheck" shellcheck_count shellcheck_agents || failed=1
  step "registry builds" none registry_builds || failed=1
fi

if [[ $failed -eq 0 ]]; then
  post success "passed locally on $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "ci-local: check passed"
else
  post failure "failed locally"
  echo "ci-local: check FAILED" >&2
fi
comment
exit $failed
