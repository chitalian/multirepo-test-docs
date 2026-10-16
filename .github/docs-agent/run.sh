#!/usr/bin/env bash
# Docs agent: when code changes in a child repo, update the docs in every affected child repo.
# Inputs (env): REPO, BEFORE, AFTER, GH_TOKEN (read/write on child repos), OPENROUTER_API_KEY
set -euo pipefail

CONFIG=.github/docs-agent.yml
SOURCES=.github/mintlify-multirepo.yml
ROOT=$PWD
WORK=$(mktemp -d)
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/stdout}
DOC_FILES='(\.mdx?$|(^|/)docs\.json$|\.(svg|png|jpe?g|gif|webp)$|^\.github/)'

note() { echo "$1"; echo "$1" >> "$SUMMARY"; }

enabled=$(yq ".repos[\"$REPO\"].enabled // false" "$CONFIG")
if [ "$enabled" != "true" ]; then
  note "Docs agent is off for \`$REPO\` in $CONFIG. Skipping."
  exit 0
fi
MODEL=$(yq '.model' "$CONFIG")
MODE=$(yq '.mode // "push"' "$CONFIG")

# Clone every source repo so the agent can fix docs anywhere, not only in the repo that changed
repo_list=""
count=$(yq '.sources | length' "$SOURCES")
for i in $(seq 0 $((count - 1))); do
  repo=$(yq ".sources[$i].repo" "$SOURCES")
  dest=$(yq ".sources[$i].destination" "$SOURCES")
  path=$(yq ".sources[$i].path // \".\"" "$SOURCES")
  git clone -q --filter=blob:none "https://x-access-token:${GH_TOKEN}@github.com/${repo}.git" "$WORK/$dest"
  docs="$dest/$path"; [ "$path" = "." ] && docs="$dest/ (root, *.mdx files)"
  repo_list+="- \`$dest/\` is \`$repo\`. Docs: \`$docs\`, published at \`/$dest/...\` on the site."$'\n'
  [ "$repo" = "$REPO" ] && CHANGED_DIR="$WORK/$dest"
done
[ -n "${CHANGED_DIR:-}" ] || { note "\`$REPO\` isn't in $SOURCES. Skipping."; exit 0; }

cd "$CHANGED_DIR"
if [ -z "$BEFORE" ] || [ "$BEFORE" = "0000000000000000000000000000000000000000" ]; then BEFORE=$(git rev-parse "$AFTER^"); fi
RANGE="${BEFORE:0:7}..${AFTER:0:7}"
code_files=$(git diff --name-only "$BEFORE" "$AFTER" | grep -Ev "$DOC_FILES" || true)
if [ -z "$code_files" ]; then
  note "\`$REPO\` $RANGE only changed docs. Nothing for the agent to do."
  exit 0
fi
commits=$(git log --format='- %h %s' "$BEFORE..$AFTER")
echo "$code_files" | xargs git diff "$BEFORE" "$AFTER" -- > "$WORK/CHANGE.diff"
cd "$WORK"

prompt=$(cat "$ROOT/.github/docs-agent/prompt.md")
prompt=${prompt//'{{REPO}}'/"$REPO"}
prompt=${prompt//'{{RANGE}}'/"$RANGE"}
prompt=${prompt//'{{COMMITS}}'/"$commits"}
prompt=${prompt//'{{REPOS}}'/"$repo_list"}

note "## Docs agent: \`$REPO\` $RANGE"
note ""
note "Code files changed: $(echo $code_files | sed 's/ /, /g')"
note ""

# Claude Code, headless, routed through OpenRouter's Anthropic-compatible endpoint
export ANTHROPIC_BASE_URL=https://openrouter.ai/api
export ANTHROPIC_AUTH_TOKEN=$OPENROUTER_API_KEY
export ANTHROPIC_API_KEY=""
export ANTHROPIC_DEFAULT_HAIKU_MODEL=anthropic/claude-haiku-5.5
result=$(claude -p "$prompt" \
  --model "$MODEL" \
  --permission-mode acceptEdits \
  --allowedTools "Read,Edit,Write,Glob,Grep,Bash(git diff:*),Bash(git log:*),Bash(ls:*)" \
  --max-turns 40)
echo "$result"
{ echo "### Agent summary"; echo; echo "$result"; echo; } >> "$SUMMARY"

# Commit doc changes in each repo the agent touched. Anything outside docs is thrown away.
for dir in "$WORK"/*/; do
  cd "$dir"
  repo=$(git remote get-url origin | sed -E 's#.*github.com/(.*)\.git#\1#')
  { git ls-files -m -o --exclude-standard | grep -Ev "$DOC_FILES" || true; } | while read -r f; do
    git checkout -- "$f" 2>/dev/null || rm -f "$f"
  done
  [ -z "$(git status --porcelain)" ] && continue
  git add -A
  git -c user.name="Docs agent" -c user.email="docs-agent@users.noreply.github.com" \
    commit -q -m "docs: update for ${REPO#*/}@${AFTER:0:7}" -m "Written by the docs agent after: $(git -C "$CHANGED_DIR" log -1 --format=%s "$AFTER")"
  if [ "$MODE" = "pull-request" ]; then
    branch="docs-agent/${REPO#*/}-${AFTER:0:7}"
    git push -q origin "HEAD:refs/heads/$branch"
    url=$(gh pr create -R "$repo" --head "$branch" --title "docs: update for ${REPO#*/}@${AFTER:0:7}" --body "$result")
    note "- \`$repo\`: opened $url"
  else
    git push -q origin HEAD:main
    note "- \`$repo\`: pushed $(git rev-parse --short HEAD) to main ($(git show --stat --format= HEAD | tail -1))"
  fi
done
