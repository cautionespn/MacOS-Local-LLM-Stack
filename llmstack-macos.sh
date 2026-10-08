#!/bin/bash
#
# llmstack-macos.sh  v3.6.3
#
# A self-contained, private LLM stack for macOS on Apple Silicon.
#
#   Ollama       local inference engine
#   Open WebUI   web front-end
#   SearXNG      private metasearch, for web-search in Open WebUI
#   Draw Things  image and video generation (optional)
#
# Ollama and Open WebUI are installed as privilege-dropped system
# LaunchDaemons, so they start at boot on a headless machine with nobody
# logged in and without enabling auto-login.
#
# Run  ./llmstack-macos.sh --help  for full documentation.
#
# License: GNU General Public License v3.0. See the LICENSE file in
# https://github.com/cautionespn/MacOS-Local-LLM-Stack for the full text.
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="3.6.3"
CATALOG_DATE="2026-09-30"
# The script version in which the built-in catalogue rows last changed.
# Written into every built-in catalogue; --sync-models offers to replace a
# live catalogue whose marker is missing or older. Bump it only when the
# rows in write_default_catalog change.
CATALOG_GENERATION="3.4.0"
CATALOG_WARN_DAYS=90
CATALOG_STALE_DAYS=180

# Dense-model speed gate. Token generation reads every weight of a dense
# model per token, so tok/s ~= bandwidth / model size. Real runs reach
# roughly 65 percent of the theoretical figure. A dense entry is only
# recommended when it would still generate at DENSE_MIN_TPS or better.
DENSE_MIN_TPS=8
DENSE_EFFICIENCY_PCT=65

# ---------------------------------------------------------------------------
# Paths and defaults
# ---------------------------------------------------------------------------
CONFIG_DIR="$HOME/.config/llmstack"
CONFIG_FILE="$CONFIG_DIR/config"
CATALOG="$CONFIG_DIR/models.catalog"
SECRET_FILE="$CONFIG_DIR/openwebui-secret"
VENV_DIR="$HOME/openwebui-venv"
DATA_DIR="$HOME/.local/share/open-webui/data"
OLLAMA_MODELS_DIR="$HOME/.ollama/models"
SEARXNG_DIR="$HOME/.searxng"
SEARXNG_SETTINGS="$SEARXNG_DIR/settings.yml"
OLLAMA_PLIST="/Library/LaunchDaemons/com.local.ollama.plist"
OPENWEBUI_PLIST="/Library/LaunchDaemons/com.local.openwebui.plist"
OLLAMA_LABEL="com.local.ollama"
OPENWEBUI_LABEL="com.local.openwebui"
PYTHON_FORMULA="python@3.11"
PYTHON_BIN="/opt/homebrew/opt/python@3.11/bin/python3.11"
DRAWTHINGS_APP="/Applications/Draw Things.app"
DRAWTHINGS_ID="6444050820"
SEARXNG_IMAGE="ghcr.io/searxng/searxng:latest"
ZSHRC="$HOME/.zshrc"
ALIAS_START_MARKER="### LLM Stack Control (llmstack-macos.sh) ###"
ALIAS_END_MARKER="### End LLM Stack Control ###"

LEGACY_START_MARKERS=(
  "### LLM Stack Control (auto-generated) ###"
  "# --- Local LLM stack control ---"
  "# ============================================================"
)

# Defaults, overridable by flags or by an existing config file.
SEARXNG_MODE="local"
SEARXNG_HOST_PORT="8888"
SEARXNG_CONTAINER_PORT="8080"
SEARXNG_URL="http://127.0.0.1:${SEARXNG_HOST_PORT}"
WEBUI_PORT="8080"
WEBUI_BIND="0.0.0.0"
SKIP_DRAWTHINGS="no"
SKIP_MODEL="no"
FORCE_MODEL=""
DISCOVER="no"
ACTUAL_USER="$(id -un)"

# ---------------------------------------------------------------------------
# Color support (auto-detected; safe to pipe to non-terminals)
# ---------------------------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  C_BOLD="$(tput bold)"
  C_RED="$(tput setaf 1)"
  C_YELLOW="$(tput setaf 3)"
  C_GREEN="$(tput setaf 2)"
  C_RESET="$(tput sgr0)"
else
  C_BOLD="" C_RED="" C_YELLOW="" C_GREEN="" C_RESET=""
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()   { printf '\n%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$1"; }
warn()  { printf '\n%sWARNING:%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
error() { printf '\n%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }
ok()    { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }

confirm() {
  local reply
  printf '\n%s [y/N]: ' "$1"
  read -r reply
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
# validate_port PORT [WHERE]: WHERE names a source other than the command line.
validate_port() {
  local p="$1" where="${2:-}"
  if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
    error "Invalid port: '$p' (must be 1–65535)${where:+ ($where)}"
  fi
}

# Check whether a TCP port is in use. If it is, echo the process name and
# PID of the holder so the caller can report it, and return 0. If the port
# is free, return 1 without printing anything.
port_in_use() {
  local port="$1"
  local holder
  holder="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1, $2}' | head -1)"
  [ -n "$holder" ] || return 1
  echo "$holder"
  return 0
}

# ---------------------------------------------------------------------------
# Error trap — report partial state on unexpected exit
# ---------------------------------------------------------------------------
INSTALL_STARTED="no"
on_error() {
  local rc=$?
  if [ "$INSTALL_STARTED" = "yes" ] && [ "$rc" -ne 0 ]; then
    printf '\n%s\n' "${C_RED}==========================================================${C_RESET}"
    printf '%sThe script exited with an error (code %d).%s\n' "${C_RED}" "$rc" "${C_RESET}"
    printf '%sPartial state may remain. Re-running is safe (the script is idempotent).%s\n' "${C_RED}" "${C_RESET}"
    printf '%sIf the error is not obvious, check the logs:%s\n' "${C_RED}" "${C_RESET}"
    printf '  Ollama:     %s/.ollama/ollama.daemon.err.log\n' "$HOME"
    printf '  Open WebUI: %s/openwebui.err.log\n' "$DATA_DIR"
    printf '%s==========================================================%s\n' "${C_RED}" "${C_RESET}"
  fi
}
trap on_error EXIT

# ---------------------------------------------------------------------------
# .zshrc block management
# ---------------------------------------------------------------------------
ZSHRC_BACKED_UP="no"

backup_zshrc() {
  [ -f "$ZSHRC" ] || return 0
  [ "$ZSHRC_BACKED_UP" = "yes" ] && return 0
  local dest
  dest="${ZSHRC}.backup-$(date +%Y%m%d-%H%M%S)"
  cp "$ZSHRC" "$dest"
  ZSHRC_BACKED_UP="yes"
  log "Backed up .zshrc to $dest"
}

remove_zshrc_range() {
  local start="$1" end="$2" tmp
  [ -f "$ZSHRC" ] || return 0
  grep -qF "$start" "$ZSHRC" || return 0
  if ! grep -qF "$end" "$ZSHRC"; then
    warn "Found a shell block starting with:"
    echo "      $start"
    echo "    but no matching end marker. Removing it automatically would"
    echo "    mean guessing where it ends, so it is being left alone."
    echo ""
    echo "    Delete it by hand from $ZSHRC, then re-run this script."
    echo "    Leaving it in place will collide with the new definitions."
    return 1
  fi
  backup_zshrc
  tmp="$(mktemp)"
  awk -v s="$start" -v e="$end" '
    index($0, s) { skip = 1 }
    !skip        { print }
    skip && index($0, e) { skip = 0 }
  ' "$ZSHRC" > "$tmp"
  mv "$tmp" "$ZSHRC"
  log "Removed an existing shell block: $start"
  return 0
}

purge_zshrc_blocks() {
  local rc=0 marker
  remove_zshrc_range "$ALIAS_START_MARKER" "$ALIAS_END_MARKER" || rc=1
  for marker in "${LEGACY_START_MARKERS[@]}"; do
    remove_zshrc_range "$marker" "$ALIAS_END_MARKER" || rc=1
  done
  return "$rc"
}

check_stray_llm_defs() {
  [ -f "$ZSHRC" ] || return 0
  if grep -qE '^[[:space:]]*alias[[:space:]]+llm(stop|start|status|upgrade)=' "$ZSHRC"; then
    warn "Found llm* ALIAS definitions in .zshrc outside any marked block."
    echo "    The current stack defines these as functions. zsh expands a"
    echo "    live alias while parsing a function of the same name, which"
    echo "    fails with 'defining function based on alias'."
    echo ""
    echo "    Remove these lines from $ZSHRC before starting a new shell:"
    grep -nE '^[[:space:]]*alias[[:space:]]+llm(stop|start|status|upgrade)=' "$ZSHRC" \
      | sed 's/^/      /'
  fi
}

# ===========================================================================
# MODEL CATALOGUE
# ===========================================================================
# Model tags verified against https://ollama.com/library on 2026-09-30.
# SIZE_GB is the download size of that exact tag, which is not always a
# q4 quantization; it may be a decimal.
write_default_catalog() {
  mkdir -p "$CONFIG_DIR"
  cat > "$CATALOG" <<CATALOG_EOF
# ===========================================================================
# Model catalogue for llmstack-macos.sh
# ===========================================================================
#
# Last-Updated: ${CATALOG_DATE}
# Catalogue-Generation: ${CATALOG_GENERATION}
#
# Last-Updated is when a person last reviewed this file; the script grades
# staleness from it. Catalogue-Generation records which built-in catalogue
# this file descends from; --sync-models offers to replace the file when
# the script ships a newer generation. If you maintain your own catalogue,
# keep the Catalogue-Generation line current to stop that offer.
#
# Local model releases move quickly. Treat this file as a starting point,
# not an authority, and revise it as new models appear. When you do, update
# the Last-Updated line above; the script reads it and will tell you how
# stale the file has become.
#
# Selection rule used by the script
# -----------------------------------------------------------------------
# Within each role, the largest entry that passes all three gates wins:
#   1. SIZE_GB fits the budget, about 70 percent of unified memory. The
#      rest goes to macOS, the inference engine and the KV cache.
#   2. The machine has at least MIN_RAM_GB of memory.
#   3. Dense entries only: the chip's memory bandwidth can generate at
#      ${DENSE_MIN_TPS} tok/s or better. MoE entries are exempt.
# Because the largest passing entry wins, keep size tracking quality within
# a role, and do not list several quantizations of the same model.
#
# Why architecture matters on Apple Silicon
# -----------------------------------------------------------------------
# Token generation is limited by memory bandwidth, not compute. A dense
# model reads every parameter for every token. A mixture-of-experts model
# reads only its active experts, so it generates far faster while still
# needing the full weight set resident in memory. Gate 3 is what keeps
# large dense models off chips too slow to drive them.
#
# The VERIFIED column
# -----------------------------------------------------------------------
# yes  the tag was confirmed to exist in the Ollama registry
# no   the tag is plausible but unconfirmed and may fail to pull
#
# Check current tags at https://ollama.com/library and correct this file.
#
# Format: MIN_RAM_GB|TAG|SIZE_GB|ARCH|ROLE|VERIFIED|NOTES
# ===========================================================================
# --- Light (fallback for the smallest machines) ----------------------------
4|granite4.2:3b|2.2|dense|light|yes|IBM Granite 4.2 3B. Tiny and fast, with a thinking mode. The floor: fits machines under 8 GB, such as VMs.
# --- Daily drivers ---------------------------------------------------------
8|qwen3.5:4b|3.4|dense|daily|yes|Qwen 3.5 4B. Strongest general model under 5 GB. Text and image input.
16|gemma4:12b|7.6|dense|daily|yes|Google Gemma 4 12B. Strong all-rounder for 16 GB machines. Multimodal.
24|gemma4:26b-a4b-it-qat|16|moe|daily|yes|Gemma 4 26B MoE, about 4B active, QAT build. The strong MoE that fits a 24 GB budget.
32|qwen3.6:35b-a3b|23|moe|daily|yes|Qwen 3.6 35B MoE, 3B active. Fast on every chip tier. Multimodal. Needs 36 GB or more.
# --- Reasoning -------------------------------------------------------------
8|qwen3.5:4b|3.4|dense|reasoning|yes|Qwen 3.5 4B with its thinking mode.
16|gemma4:12b|7.6|dense|reasoning|yes|Gemma 4 12B. Strong maths and reasoning for its size.
24|gemma4:26b-a4b-it-qat|16|moe|reasoning|yes|Gemma 4 26B MoE. Reasoning on chips too slow for a dense 27B.
32|qwen3.8:27b|18|dense|reasoning|yes|Qwen 3.8 27B. Top small open model on independent indexes. Dense, so it needs M4 Pro-class bandwidth or better. Uses many tokens.
# --- Coding ----------------------------------------------------------------
8|qwen3.5:4b|3.4|dense|coding|yes|Qwen 3.5 4B. Best coding option under 5 GB.
16|qwen3.5:9b|6.6|dense|coding|yes|Qwen 3.5 9B. Stronger agentic coding than Gemma 4 12B.
24|devstral-small-2:24b|15|dense|coding|yes|Mistral Devstral Small 2 24B. Strong agentic coding. Dense, so it needs Pro-class bandwidth.
32|qwen3.6:35b-a3b-coding|23|moe|coding|yes|Qwen 3.6 35B MoE with its coding sampling preset. Same weights as the daily tag.
# --- Vision ----------------------------------------------------------------
8|qwen3.5:4b|3.4|dense|vision|yes|Qwen 3.5 4B. Image input on the smallest machines.
16|gemma4:12b|7.6|dense|vision|yes|Gemma 4 12B. Image input.
24|gemma4:26b-a4b-it-qat|16|moe|vision|yes|Gemma 4 26B MoE. Image input.
32|qwen3.6:35b-a3b|23|moe|vision|yes|Qwen 3.6 35B MoE. Leads Gemma 4 26B on vision evals.
CATALOG_EOF
}

ensure_catalog() {
  if [ ! -f "$CATALOG" ]; then
    log "Writing the default model catalogue to $CATALOG"
    write_default_catalog
  fi
}

# These lookups feed $(...) assignments, and under `set -o pipefail` a grep
# that matches nothing fails the whole pipeline, which `set -e` then turns
# into a silent exit. "Not found" is a normal answer here, so they always
# succeed and print nothing instead.
catalog_date() {
  [ -f "$CATALOG" ] || return 0
  grep -m1 '^# Last-Updated:' "$CATALOG" 2>/dev/null | awk '{print $3}' || true
}

catalog_generation() {
  [ -f "$CATALOG" ] || return 0
  grep -m1 '^# Catalogue-Generation:' "$CATALOG" 2>/dev/null | awk '{print $3}' || true
}

# True if dotted version $1 is older than $2 (e.g. 3.3.0 < 3.4.0).
_version_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); k = (n > m) ? n : m
    for (i = 1; i <= k; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 1 }'
}

# True when the live catalogue does not descend from the current built-in
# generation: its marker is missing or older.
catalog_predates_builtin() {
  local gen; gen="$(catalog_generation)"
  [ -z "$gen" ] || _version_lt "$gen" "$CATALOG_GENERATION"
}

# Portable date-to-epoch: tries macOS date -j first, then GNU date -d.
# Works on macOS (for real use) and on Linux (for CI testing).
catalog_age_days() {
  local d cat_epoch now_epoch
  d="$(catalog_date)"
  [ -n "$d" ] || return 0
  # macOS: date -j -f "<format>" "<input>" "+%s"
  # Linux:  date -d "<input>" "+%s"
  cat_epoch="$(date -j -f "%Y-%m-%d" "$d" "+%s" 2>/dev/null)" || \
    cat_epoch="$(date -d "$d" "+%s" 2>/dev/null)" || return 0
  now_epoch="$(date "+%s")"
  echo $(( (now_epoch - cat_epoch) / 86400 ))
}

report_catalog_age() {
  local d age
  d="$(catalog_date)"
  age="$(catalog_age_days)"
  if [ -z "$d" ]; then
    warn "The catalogue has no readable 'Last-Updated:' line."
    echo "    Add one in the form:  # Last-Updated: YYYY-MM-DD"
    return 0
  fi
  if [ -z "$age" ]; then
    warn "Could not parse the catalogue date '$d'. Expected YYYY-MM-DD."
    return 0
  fi
  printf '\nModel catalogue last updated: %s (%s days ago)\n' "$d" "$age"
  if [ "$age" -ge "$CATALOG_STALE_DAYS" ]; then
    printf '\n'
    printf '  This catalogue is over %s days old and is very likely stale.\n' "$CATALOG_STALE_DAYS"
    printf '  Local model releases move fast; better options almost certainly\n'
    printf '  exist now. Review https://ollama.com/library, edit\n'
    printf '  %s, and bump its Last-Updated line.\n' "$CATALOG"
  elif [ "$age" -ge "$CATALOG_WARN_DAYS" ]; then
    printf '\n'
    printf '  Worth a look. Over %s days old, so newer models may be a\n' "$CATALOG_WARN_DAYS"
    printf '  better fit for this machine. See https://ollama.com/library\n'
  else
    printf '  Recent enough. No action needed.\n'
  fi
  printf '\n'
}

# ===========================================================================
# MODEL REGISTRY VALIDATION & CATALOGUE REFRESH  (v3.3.0)
# ===========================================================================
# All registry access uses the Ollama manifest endpoint. Its behaviour was
# confirmed by direct probe: a live tag returns HTTP 200, a non-existent tag
# returns 404, and no auth handshake is required.
#
#   https://registry.ollama.ai/v2/library/<n>/manifests/<tag>
#
# Every function here is FAIL-SOFT: a network error, timeout, or any status
# other than 200/404 is treated as "unknown" and never changes the live
# catalogue. This keeps --update reliable when the registry is unreachable,
# and keeps CI (which has no registry access) green: --check-models and
# --refresh-catalog both exit 0 even when every probe fails.
REGISTRY_BASE="https://registry.ollama.ai/v2/library"
REGISTRY_ACCEPT="application/vnd.docker.distribution.manifest.v2+json"
# Common size tokens probed when looking for newer variants within a family
# already in the catalogue. Each candidate is manifest-confirmed before it is
# ever proposed, so a wrong guess simply 404s and is discarded.
PROBE_SIZES="1.5b 3b 4b 7b 8b 9b 11b 12b 14b 22b 27b 30b 32b 34b 70b 72b"

# Trim leading/trailing whitespace safely. Never use xargs for this: it
# treats quotes specially and mangles NOTES containing apostrophes.
_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Probe one tag. Echoes LIVE, DEAD, or UNKNOWN.
registry_probe() {
  local tag="$1" name ver code
  name="${tag%%:*}"
  ver="${tag##*:}"
  if [ "$name" = "$ver" ]; then echo "UNKNOWN"; return 0; fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -H "Accept: ${REGISTRY_ACCEPT}" \
    "${REGISTRY_BASE}/${name}/manifests/${ver}" 2>/dev/null || echo "000")"
  case "$code" in
    200) echo "LIVE" ;;
    404) echo "DEAD" ;;
    *)   echo "UNKNOWN" ;;
  esac
}

# True if the registry is reachable at all (one cheap probe of a known tag).
registry_reachable() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -H "Accept: ${REGISTRY_ACCEPT}" \
    "${REGISTRY_BASE}/llama3.3/manifests/70b" 2>/dev/null || echo "000")"
  [ "$code" = "200" ] || [ "$code" = "404" ]
}

# Unique family prefixes (text before the colon) from the live catalogue.
catalog_families() {
  [ -f "$CATALOG" ] || return 0
  grep -v '^#' "$CATALOG" | grep -v '^$' \
    | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); split($2,a,":"); print a[1]}' \
    | sort -u || true
}

# All tags currently in the catalogue, one per line, trimmed.
catalog_tags() {
  [ -f "$CATALOG" ] || return 0
  grep -v '^#' "$CATALOG" | grep -v '^$' \
    | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' || true
}

# ---------------------------------------------------------------------------
# Part A: validate every catalogue tag against the registry.
# Reports LIVE/DEAD/UNKNOWN. With argument "fix", rewrites the live catalogue
# in place to correct the VERIFIED column (200 -> yes, 404 -> no), preserving
# every other column, after taking a timestamped backup. UNKNOWN never
# changes anything. Always returns 0 (fail-soft).
# ---------------------------------------------------------------------------
validate_catalog_tags() {
  local fix="${1:-report}"
  ensure_catalog
  if ! registry_reachable; then
    warn "Cannot reach the Ollama registry. Skipping tag validation."
    echo "    The existing catalogue is unchanged; this is not an error."
    return 0
  fi
  local live=0 dead=0 unknown=0 changed=0 tmp
  tmp="$(mktemp)"
  log "Validating catalogue tags against the Ollama registry"
  while IFS= read -r rawline; do
    case "$rawline" in
      '#'*|'') printf '%s\n' "$rawline" >> "$tmp"; continue ;;
    esac
    local ram tag size arch role ver notes status trimtag
    IFS='|' read -r ram tag size arch role ver notes <<< "$rawline"
    trimtag="$(_trim "$tag")"
    status="$(registry_probe "$trimtag")"
    case "$status" in
      LIVE)
        live=$((live+1)); ok "  LIVE  $trimtag"
        if [ "$(_trim "$ver")" != "yes" ]; then ver="yes"; changed=$((changed+1)); fi
        ;;
      DEAD)
        dead=$((dead+1)); warn "  DEAD  $trimtag  (404 — retired or renamed)"
        if [ "$(_trim "$ver")" != "no" ]; then ver="no"; changed=$((changed+1)); fi
        ;;
      *)
        unknown=$((unknown+1)); printf '  ????  %s  (registry unreachable for this tag)\n' "$trimtag"
        ;;
    esac
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
      "$(_trim "$ram")" "$trimtag" "$(_trim "$size")" "$(_trim "$arch")" \
      "$(_trim "$role")" "$(_trim "$ver")" "$(_trim "$notes")" >> "$tmp"
  done < "$CATALOG"
  printf '\nValidation summary: %d live, %d dead, %d unknown.\n' "$live" "$dead" "$unknown"
  if [ "$fix" = "fix" ] && [ "$changed" -gt 0 ]; then
    cp "$CATALOG" "${CATALOG}.backup-$(date +%Y%m%d-%H%M%S)"
    mv "$tmp" "$CATALOG"
    ok "Corrected the VERIFIED column on $changed entries. Backup kept."
  else
    rm -f "$tmp"
    if [ "$dead" -gt 0 ]; then
      echo "Run --refresh-catalog to produce a cleaned proposal you can review."
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Part B-lite: probe common tag patterns within each catalogue family for
# variants not already present. Registry-only; every hit is manifest-
# confirmed. Echoes confirmed new "family:tag" candidates, one per line.
# ---------------------------------------------------------------------------
probe_family_variants() {
  local families existing fam base suffix cand
  families="$(catalog_families)"
  existing="$(catalog_tags)"
  for fam in $families; do
    for base in $PROBE_SIZES; do
      for suffix in "" "-instruct"; do
        cand="${fam}:${base}${suffix}"
        printf '%s\n' "$existing" | grep -qx "$cand" && continue
        if [ "$(registry_probe "$cand")" = "LIVE" ]; then
          printf '%s\n' "$cand"
        fi
      done
    done
  done
}

# ---------------------------------------------------------------------------
# Part B-full (optional, --discover): scrape ollama.com/library for family
# names not in the catalogue. FRAGILE (HTML), so wholly fail-soft: any
# failure yields no candidates and a note, never an error. Every scraped
# name is manifest-confirmed before being emitted.
# ---------------------------------------------------------------------------
discover_new_families() {
  local html names fam known
  html="$(curl -s --max-time 15 "https://ollama.com/library" 2>/dev/null || true)"
  if [ -z "$html" ]; then
    warn "Could not fetch the library index; skipping discovery." >&2
    echo "    Proposal is based on validated tags and the family watchlist." >&2
    return 0
  fi
  names="$(printf '%s' "$html" \
    | grep -oE 'href="/library/[a-zA-Z0-9._-]+"' \
    | sed -E 's#href="/library/([^"]+)"#\1#' \
    | sort -u)"
  known="$(catalog_families)"
  for fam in $names; do
    printf '%s\n' "$known" | grep -qx "$fam" && continue
    if [ "$(registry_probe "${fam}:latest")" = "LIVE" ]; then
      printf '%s\n' "$fam"
    fi
  done
}

# ---------------------------------------------------------------------------
# Part B/C core: build models.catalog.proposed next to the live file.
#   - Walks the live file IN ORDER. Comments and blank lines pass through
#     untouched, so section headings keep their rows. (Up to v3.5.0 every
#     comment was hoisted to the top, and each refresh degraded the file.)
#   - Re-validates every data row in place: VERIFIED corrected, judgment
#     columns MIN_RAM/ARCH/ROLE/NOTES preserved, dead tags commented out.
#   - New candidates (family variants; with $1 = "discover", new families)
#     are appended as commented "# REVIEW:" lines, never as live rows, and
#     a candidate already suggested that way is not suggested again.
#   - Leaves Last-Updated alone: that line records human review, which a
#     proposal is not. apply_catalog_proposal stamps it on confirmation.
# Never touches the live catalogue. Returns 0.
# ---------------------------------------------------------------------------
REVIEW_HEADER="# --- Suggested by --refresh-catalog: set every REVIEW field, then delete '# REVIEW: ' ---"
PROPOSAL_BUILT="no"

build_catalog_proposal() {
  local discover="${1:-no}"
  ensure_catalog
  local proposed="${CATALOG}.proposed"
  if ! registry_reachable; then
    warn "Cannot reach the Ollama registry. No proposal was written."
    echo "    Try again when the network can reach registry.ollama.ai."
    return 0
  fi
  log "Building a catalogue proposal (live file is not touched)"
  local tmp; tmp="$(mktemp)"
  local live=0 dead=0 added=0 rawline ram tag size arch role ver notes trimtag status
  while IFS= read -r rawline || [ -n "$rawline" ]; do
    case "$rawline" in
      '#'*|'') printf '%s\n' "$rawline" >> "$tmp"; continue ;;
    esac
    IFS='|' read -r ram tag size arch role ver notes <<< "$rawline"
    trimtag="$(_trim "$tag")"
    status="$(registry_probe "$trimtag")"
    ram="$(_trim "$ram")"; size="$(_trim "$size")"; arch="$(_trim "$arch")"
    role="$(_trim "$role")"; notes="$(_trim "$notes")"
    case "$status" in
      LIVE) live=$((live+1))
        printf '%s|%s|%s|%s|%s|yes|%s\n' "$ram" "$trimtag" "$size" "$arch" "$role" "$notes" >> "$tmp" ;;
      DEAD) dead=$((dead+1))
        printf '# DEAD (404 at registry, review/remove): %s|%s|%s|%s|%s|no|%s\n' \
          "$ram" "$trimtag" "$size" "$arch" "$role" "$notes" >> "$tmp" ;;
      *)  # unknown: pass through unchanged
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$ram" "$trimtag" "$size" "$arch" "$role" "$(_trim "$ver")" "$notes" >> "$tmp" ;;
    esac
  done < "$CATALOG"

  local cands="" fams fam cand
  cands="$(probe_family_variants)"
  if [ "$discover" = "discover" ]; then
    fams="$(discover_new_families)"
    while IFS= read -r fam; do
      [ -n "$fam" ] && cands="${cands}"$'\n'"${fam}:latest"
    done <<< "$fams"
  fi
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    # Suggested by an earlier refresh and not yet acted on: don't repeat it.
    grep -qF "# REVIEW: REVIEW|${cand}|" "$CATALOG" && continue
    grep -qxF "$REVIEW_HEADER" "$tmp" || printf '%s\n' "$REVIEW_HEADER" >> "$tmp"
    printf '# REVIEW: REVIEW|%s|REVIEW|REVIEW|REVIEW|yes|Confirmed in the registry. Set MIN_RAM, SIZE, ARCH, ROLE and NOTES.\n' \
      "$cand" >> "$tmp"
    added=$((added+1))
  done <<< "$cands"

  mv "$tmp" "$proposed"
  PROPOSAL_BUILT="yes"
  printf '\n'
  ok "Wrote proposal: $proposed"
  printf 'Summary: %d live, %d dead, %d new suggestion(s) added as "# REVIEW:" comments.\n' "$live" "$dead" "$added"
  printf '\nSuggestions never become live rows on their own: set every REVIEW\n'
  printf 'field and delete the leading "# REVIEW: " to adopt one.\n'
  printf '\nCompare against the live file:\n'
  printf '  diff "%s" "%s"\n' "$CATALOG" "$proposed"
  printf 'Apply it with --refresh-catalog-apply, or by hand:\n'
  printf '  mv "%s" "%s"\n\n' "$proposed" "$CATALOG"
  return 0
}

# ---------------------------------------------------------------------------
# Part C: apply the proposal over the live catalogue, after backup + confirm.
# Only a proposal built in this run is applied: a leftover .proposed file
# from an earlier run (e.g. when the registry is now unreachable) is not.
# Confirming the diff is a human review, so Last-Updated is stamped here.
# ---------------------------------------------------------------------------
apply_catalog_proposal() {
  local discover="${1:-no}"
  build_catalog_proposal "$discover"
  local proposed="${CATALOG}.proposed"
  if [ "$PROPOSAL_BUILT" != "yes" ] || [ ! -f "$proposed" ]; then
    warn "No new proposal was built, so nothing was applied."
    return 0
  fi
  printf '\n'
  diff "$CATALOG" "$proposed" || true
  printf '\n'
  if confirm "Replace the live catalogue with this proposal?"; then
    cp "$CATALOG" "${CATALOG}.backup-$(date +%Y%m%d-%H%M%S)"
    sed "s/^# Last-Updated:.*/# Last-Updated: $(date +%Y-%m-%d)/" "$proposed" > "${proposed}.dated"
    mv "${proposed}.dated" "$CATALOG"
    rm -f "$proposed"
    ok "Catalogue updated and Last-Updated set to today. Backup kept alongside it."
  else
    log "Left the live catalogue unchanged. Proposal remains at $proposed"
  fi
  return 0
}

# ===========================================================================
# SYSTEM DETECTION
# ===========================================================================
# Works on macOS (real hardware) and on Linux (CI). On Linux the sysctl
# keys don't exist, so the chip reads as unknown and sizing falls back to
# memory alone.
detect_system() {
  SYS_CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
  SYS_CHIP="$(_trim "$SYS_CHIP")"
  SYS_CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo '?')"
  local mem_bytes
  mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  SYS_RAM_GB=$(( mem_bytes / 1024 / 1024 / 1024 ))
  # If sysctl failed (e.g. on Linux CI), default to 8 GB so the budget
  # is non-zero and at least the light-tier entries match.
  [ "$SYS_RAM_GB" -gt 0 ] || SYS_RAM_GB=8
  SYS_USABLE_GB=$(( SYS_RAM_GB * 70 / 100 ))
  # macOS df takes -g (GB). GNU df rejects -g; use -BG there so the value
  # is always whole GB (df -h would give T or M units on some disks).
  if df -g "$HOME" >/dev/null 2>&1; then
    SYS_DISK_FREE_GB="$(df -g "$HOME" | awk 'NR==2 {print $4}')"
  else
    SYS_DISK_FREE_GB="$(df -BG "$HOME" 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4}')"
  fi
  [ -n "$SYS_DISK_FREE_GB" ] || SYS_DISK_FREE_GB=0
  case "$SYS_CHIP" in
    *Ultra*) SYS_TIER="Ultra" ;;
    *Max*)   SYS_TIER="Max" ;;
    *Pro*)   SYS_TIER="Pro" ;;
    *Apple*) SYS_TIER="Base" ;;
    *)       SYS_TIER="Unknown" ;;
  esac
  SYS_BANDWIDTH="$(chip_bandwidth)"
  if [ -n "$SYS_BANDWIDTH" ]; then
    SYS_DENSE_CAP_GB="$(awk -v bw="$SYS_BANDWIDTH" -v eff="$DENSE_EFFICIENCY_PCT" \
      -v tps="$DENSE_MIN_TPS" 'BEGIN { printf "%.1f", bw * eff / 100 / tps }')"
  else
    SYS_DENSE_CAP_GB=""
  fi
}

# GPU core count, used only to split the two M5 Max bins. Empty if ioreg
# is unavailable or reports nothing.
gpu_core_count() {
  ioreg -rc AGXAccelerator 2>/dev/null \
    | awk -F'= ' '/"gpu-core-count"/ { gsub(/[^0-9]/, "", $2); print $2; exit }'
}

# Unified-memory bandwidth in GB/s for the detected chip, from Apple's
# published tech specs (M1 base from Wikipedia; Apple never published it).
# Echoes nothing for a non-Apple host, which disables the dense-speed gate.
# Chips sold in two bandwidth bins under one name are split as follows:
#   M3 Max, M4 Max  total CPU cores: 16 is the faster bin, 14 the slower
#   M5 Max          both bins have 18 CPU cores; split on GPU cores (40 vs
#                   32), else on memory (the 32-GPU bin ships only at 36 GB)
#   M6              identical cores; the 16 GB model is the slower bin
# An Apple chip not in the table (a newer generation) takes the newest known
# generation's slower bin for its tier: never slower than today's chips.
chip_bandwidth() {
  local gpu chip
  # Virtualised Macs (e.g. CI runners) append a suffix such as
  # " (Virtual)" to the brand string; look up the underlying chip.
  chip="${SYS_CHIP%% (*}"
  case "$chip" in
    "Apple M1")        echo 68 ;;
    "Apple M1 Pro")    echo 200 ;;
    "Apple M1 Max")    echo 400 ;;
    "Apple M1 Ultra")  echo 800 ;;
    "Apple M2")        echo 100 ;;
    "Apple M2 Pro")    echo 200 ;;
    "Apple M2 Max")    echo 400 ;;
    "Apple M2 Ultra")  echo 800 ;;
    "Apple M3")        echo 100 ;;
    "Apple M3 Pro")    echo 150 ;;
    "Apple M3 Max")    if [ "$SYS_CORES" = "16" ]; then echo 400; else echo 300; fi ;;
    "Apple M3 Ultra")  echo 819 ;;
    "Apple M4")        echo 120 ;;
    "Apple M4 Pro")    echo 273 ;;
    "Apple M4 Max")    if [ "$SYS_CORES" = "16" ]; then echo 546; else echo 410; fi ;;
    "Apple M5")        echo 153 ;;
    "Apple M5 Pro")    echo 307 ;;
    "Apple M5 Max")
      gpu="$(gpu_core_count)"
      if [ "$gpu" = "40" ]; then echo 614
      elif [ "$gpu" = "32" ]; then echo 460
      elif [ "$SYS_RAM_GB" -ge 48 ]; then echo 614
      else echo 460
      fi ;;
    "Apple M5 Ultra")  echo 1200 ;;
    "Apple M6")        if [ "$SYS_RAM_GB" -le 16 ]; then echo 153; else echo 170; fi ;;
    *)
      case "$SYS_TIER" in
        Ultra) echo 1200 ;;
        Max)   echo 460 ;;
        Pro)   echo 307 ;;
        Base)  echo 153 ;;
        *)     : ;;
      esac ;;
  esac
}

bandwidth_note() {
  case "$SYS_TIER" in
    Ultra) echo "Ultra tier. Very high memory bandwidth; large dense models are comfortable." ;;
    Max)   echo "Max tier. High memory bandwidth; dense models up to the cap below run well." ;;
    Pro)   echo "Pro tier. MoE models are fast; dense models are limited to the cap below." ;;
    Base)  echo "Base tier. Lower memory bandwidth; only small dense models, MoE where it fits." ;;
    *)     echo "Unrecognised chip tier. Sizing by memory alone; no dense-speed cap." ;;
  esac
}

# Prints the detected bandwidth and the resulting dense cap, or says why
# there is none. Shared by --recommend and the install banner.
print_bandwidth_lines() {
  if [ -n "$SYS_BANDWIDTH" ]; then
    printf '  Memory bandwidth:  %s GB/s\n' "$SYS_BANDWIDTH"
    printf '  Dense model cap:   ~%s GB  (keeps dense models at %s tok/s or better)\n' \
      "$SYS_DENSE_CAP_GB" "$DENSE_MIN_TPS"
  else
    printf '  Memory bandwidth:  unknown  (no dense-speed cap applied)\n'
  fi
}

best_for_role() {
  local role="$1"
  [ -f "$CATALOG" ] || return 0
  # Three gates, then the largest survivor wins. Gate 3 (dense speed) is
  # skipped when the chip is unrecognised, so an empty cap means "no cap".
  # OFS="|" so that trimming a field rebuilds $0 with pipes, not spaces;
  # otherwise field() cannot re-split a hand-edited line with padding.
  awk -F'|' -v OFS='|' -v budget="$SYS_USABLE_GB" -v ram="$SYS_RAM_GB" -v want="$role" \
      -v cap="${SYS_DENSE_CAP_GB:-}" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)
      gsub(/^[ \t]+|[ \t]+$/, "", $4)
      gsub(/^[ \t]+|[ \t]+$/, "", $5)
      # Unreviewed rows (e.g. MIN_RAM or SIZE still "REVIEW") are never picked.
      if ($1 !~ /^[0-9.]+$/ || $3 !~ /^[0-9.]+$/) next
      if ($4 == "dense" && cap != "" && ($3 + 0) > (cap + 0)) next
      if ($5 == want && ($1 + 0) <= ram && ($3 + 0) <= budget && ($3 + 0) > best) {
        best = $3 + 0
        line = $0
      }
    }
    END { if (line != "") print line }
  ' "$CATALOG"
}

field() { echo "$1" | awk -F'|' -v n="$2" '{gsub(/^[ \t]+|[ \t]+$/, "", $n); print $n}'; }

# ---------------------------------------------------------------------------
# Shared status logic — single source of truth for show_status AND .zshrc
# ---------------------------------------------------------------------------
# IMPORTANT: The config-source line uses if/then/fi, NOT [ ] && . , because
# under set -e, "[ -f file ] && . file" returns 1 when the file is absent,
# which kills the calling function. if/then/fi always returns 0.
# shellcheck disable=SC2016
STATUS_BODY='
_llmstack_conf() {
  SEARXNG_MODE="local"
  SEARXNG_URL="http://127.0.0.1:8888"
  WEBUI_PORT="8080"
  if [ -f "$HOME/.config/llmstack/config" ]; then
    . "$HOME/.config/llmstack/config"
  fi
}
_llmstack_status() {
  _llmstack_conf
  local ollama webui searxng colima
  if curl -s -o /dev/null --max-time 3 http://127.0.0.1:11434/api/version; then
    ollama="UP"
  else
    ollama="DOWN"
  fi
  if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${WEBUI_PORT}"; then
    webui="UP"
  else
    webui="DOWN"
  fi
  if curl -s -o /dev/null --max-time 5 "${SEARXNG_URL}/search?q=test&format=json"; then
    searxng="UP"
  else
    searxng="DOWN"
  fi
  printf "Ollama      (:11434)   %s\n" "$ollama"
  printf "Open WebUI  (:%s)    %s\n" "$WEBUI_PORT" "$webui"
  if [ "$SEARXNG_MODE" = "local" ]; then
    if colima status >/dev/null 2>&1; then colima="UP"; else colima="DOWN"; fi
    printf "Colima      (runtime)  %s\n" "$colima"
    printf "SearXNG     (local)    %s\n" "$searxng"
    if [ "$colima" = "DOWN" ]; then
      printf "\nColima needs a console login session. After a reboot with\n"
      printf "nobody logged in at the screen, it and SearXNG stay down.\n"
    fi
  else
    printf "SearXNG     (remote)   %s   %s\n" "$searxng" "$SEARXNG_URL"
  fi
}
'

show_recommendations() {
  detect_system
  ensure_catalog
  cat <<'SYSINFO'
===========================================================================
  DETECTED SYSTEM
===========================================================================
SYSINFO
  printf '  Chip:              %s\n' "$SYS_CHIP"
  printf '  Tier:              %s\n' "$SYS_TIER"
  printf '  CPU cores:         %s\n' "$SYS_CORES"
  printf '  Unified memory:    %s GB\n' "$SYS_RAM_GB"
  printf '  Usable for models: ~%s GB  (about 70 percent)\n' "$SYS_USABLE_GB"
  printf '  Free disk:         %s GB\n' "$SYS_DISK_FREE_GB"
  print_bandwidth_lines
  printf '  %s\n' "$(bandwidth_note)"
  cat <<'SYSINFO2'
===========================================================================
RECOMMENDED MODELS
SYSINFO2
  local role line tag size arch verified notes found
  found="no"
  for role in daily reasoning coding vision light; do
    line="$(best_for_role "$role")"
    [ -n "$line" ] || continue
    found="yes"
    tag="$(field "$line" 2)"
    size="$(field "$line" 3)"
    arch="$(field "$line" 4)"
    verified="$(field "$line" 6)"
    notes="$(field "$line" 7)"
    printf '\n  %-12s %s\n' "${role}:" "$tag"
    printf '             %s GB, %s' "$size" "$arch"
    if [ "$verified" != "yes" ]; then
      printf '  [tag UNVERIFIED]'
    fi
    printf '\n             %s\n' "$notes"
  done
  if [ "$found" = "no" ]; then
    printf '\n  Nothing in the catalogue fits a %s GB budget.\n' "$SYS_USABLE_GB"
    printf '  Add a smaller entry to %s\n' "$CATALOG"
  fi
  report_catalog_age
  printf 'Catalogue file: %s\n' "$CATALOG"
  printf 'Edit it to change these recommendations.\n'
  if catalog_predates_builtin; then
    printf '\nYour catalogue predates the generation %s catalogue built into this\n' "$CATALOG_GENERATION"
    printf 'script, so newer models are not considered. --sync-models offers to\n'
    printf 'replace it (with a backup).\n'
  fi
  printf 'To pull these picks and review removal of other installed models:\n'
  printf '  %s --sync-models\n\n' "$SCRIPT_NAME"
}

# ===========================================================================
# CONFIG FILE
# ===========================================================================
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
  fi
}

# Install settings: the saved config first, then options from this command
# line. Before 3.6.2 the install never read the config, so a plain re-run
# reset everything to defaults (a --searxng-url install fell back to local).
resolve_settings() {
  load_config
  [ -z "$CLI_WEBUI_PORT" ] || WEBUI_PORT="$CLI_WEBUI_PORT"
  if [ -n "$CLI_SEARXNG_PORT" ]; then
    SEARXNG_HOST_PORT="$CLI_SEARXNG_PORT"
    SEARXNG_MODE="local"
    SEARXNG_URL="http://127.0.0.1:${SEARXNG_HOST_PORT}"
  fi
  if [ -n "$CLI_SEARXNG_URL" ]; then
    SEARXNG_URL="$CLI_SEARXNG_URL"
    SEARXNG_MODE="remote"
  fi
  # Options were checked when parsed; the config may have been hand-edited.
  validate_port "$WEBUI_PORT" "WEBUI_PORT in $CONFIG_FILE"
  if [ "$SEARXNG_MODE" = "local" ]; then
    validate_port "$SEARXNG_HOST_PORT" "SEARXNG_HOST_PORT in $CONFIG_FILE"
  fi
}

write_config() {
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<CONFIG_EOF
# llmstack-macos.sh configuration
# Written by the installer. Safe to edit; the shell functions read it.
SEARXNG_MODE="${SEARXNG_MODE}"
SEARXNG_URL="${SEARXNG_URL}"
SEARXNG_HOST_PORT="${SEARXNG_HOST_PORT}"
WEBUI_PORT="${WEBUI_PORT}"
WEBUI_BIND="${WEBUI_BIND}"
CONFIG_EOF
}

# ===========================================================================
# HELP
# ===========================================================================
show_help() {
  cat <<HELPTEXT
${SCRIPT_NAME} v${SCRIPT_VERSION}
NAME
    ${SCRIPT_NAME} - install and manage a private, self-hosted LLM stack
    on macOS running on Apple Silicon.
SYNOPSIS
    ./${SCRIPT_NAME} [MODE] [OPTIONS]
DESCRIPTION
    Installs a complete local AI stack: Ollama for inference, Open WebUI as
    the front-end, SearXNG for private web search, and optionally Draw
    Things for image generation. Nothing leaves the machine unless a web
    search is performed.
    Before installing, the script inspects the host's chip, memory and free
    disk, then consults a model catalogue to choose a model that actually
    fits. The catalogue is a plain text file you own and can edit; it
    carries a date, and the script reports how stale it has become.
    The script is idempotent. Re-running it is safe: every step checks
    current state first, and existing data is never overwritten.
MODES
    --install       Install or repair the stack. Default when no mode is
                    given.
    --update        Update Ollama, Open WebUI and, in local mode, the
                    SearXNG container image. Backs up Open WebUI data
                    first, then reports the age of the model catalogue.
                    --upgrade is accepted as a synonym.
    --status        Print the health of every component and exit. Makes no
                    changes.
    --recommend     Print the detected hardware and the models that suit
                    it, then exit. Installs nothing. Useful before
                    committing to a large download.
    --sync-models   Bring installed models in line with the
                    recommendations. Offers to replace a catalogue whose
                    Catalogue-Generation marker is missing or older than
                    the built-in one, asks which missing picks to pull and
                    which installed picks to update (their build is older
                    than the registry's), pulls
                    them, and only then offers each installed model that
                    is not a current pick for removal, one at a time.
                    Every prompt defaults to no. Needs Ollama running.
    --uninstall     Guided teardown. Walks every artifact the script
                    created and asks before removing each one. All
                    destructive prompts default to NO.
    --check-models  Validate every catalogue tag against the Ollama
                    registry and correct the VERIFIED column in place.
                    Read-only network probe; changes only that column.
    --refresh-catalog
                    Write models.catalog.proposed: re-validate every tag in
                    place, comment out dead ones, and suggest newer variants
                    within your existing families as "# REVIEW:" comments,
                    which never become live rows until you edit them in.
                    Never touches the live catalogue or its Last-Updated
                    line. Add --discover to also scan the Ollama library
                    for entirely new model families.
    --refresh-catalog-apply
                    As --refresh-catalog, then replace the live catalogue
                    with the proposal after a backup and confirmation,
                    setting Last-Updated to today. Accepts --discover.
    --version       Print the script version and exit.
    --help          Show this text and exit.
OPTIONS
    --searxng-url URL
                    Use an existing SearXNG instance instead of installing
                    one locally. Skips Colima and Docker entirely.
                    Saved, so later runs keep using it.
                    Example: --searxng-url http://192.168.1.23:8899
    --searxng-port PORT
                    Host port for the local SearXNG container.
                    Default ${SEARXNG_HOST_PORT}. Also switches a remote
                    install back to local SearXNG.
    --webui-port PORT
                    Port for Open WebUI. Default ${WEBUI_PORT}.
    --model TAG     Install this model instead of the catalogue's
                    recommendation. Skips the fit check.
    --no-model      Do not download any model. Useful for setting up the
                    services first and choosing a model later.
    --no-drawthings Skip the Draw Things installation.
    --discover      Only with --refresh-catalog / --refresh-catalog-apply.
                    Additionally scrape the Ollama library for new model
                    families. Fail-soft: if the scrape fails, the proposal
                    still includes validated tags and family variants.
COMPONENTS
    Homebrew            package manager, installed if missing
    python@3.11         runtime required by Open WebUI
    Ollama              inference engine, Homebrew binary
    Open WebUI          web front-end, pip, in its own virtualenv
    Colima + docker     container runtime, local SearXNG mode only
    SearXNG             private metasearch, local mode only
    Draw Things         image and video generation, from the Mac App Store
LAYOUT
    ~/.config/llmstack/config             installer settings; read by every
                                          install, then overridden by options
    ~/.config/llmstack/models.catalog     model catalogue, yours to edit
    ~/.config/llmstack/openwebui-secret   persisted secret key, mode 0600
    ~/openwebui-venv                      Open WebUI virtualenv
    ~/.local/share/open-webui/data        accounts, chats, uploads, settings
    ~/.ollama/models                      downloaded models
    ~/.searxng/settings.yml               SearXNG config, local mode only
    /Library/LaunchDaemons/com.local.ollama.plist
    /Library/LaunchDaemons/com.local.openwebui.plist
NETWORK
    Ollama        127.0.0.1:11434    local only
    Open WebUI    ${WEBUI_BIND}:${WEBUI_PORT}       reachable across the LAN
    SearXNG       ${SEARXNG_URL}
                                     local only when self-hosted
STARTUP BEHAVIOUR AND ITS LIMITS
    Ollama and Open WebUI are installed as SYSTEM LaunchDaemons. They load
    in the system domain at boot, need no console login, and are
    privilege-dropped to the invoking user rather than running as root. A
    headless, SSH-only machine comes back fully after a reboot without
    enabling auto-login.
    SearXNG in local mode cannot do this. macOS container runtimes require
    an active GUI login session: Docker Desktop is a GUI application and
    cannot be launched over SSH, and Colima manages a per-user virtual
    machine and is not supported as a root or system-level daemon.
    So in local mode Colima and SearXNG start in the user domain and will
    not run after a reboot until someone logs in at the console. Ollama and
    Open WebUI will already be up; web search will report DOWN until then.
    If reboot-durable search matters, run SearXNG on a Linux host, where
    Docker is a genuine systemd service, and point this machine at it with
    --searxng-url. That mode installs no container runtime at all.
MODEL SELECTION
    Within each role, the largest catalogue entry that passes three gates
    is recommended:
      1. Its size fits the budget: roughly 70 percent of unified memory.
         The rest goes to macOS, the inference engine and the KV cache.
      2. The machine has at least the entry's MIN_RAM_GB.
      3. Dense entries only: the chip's memory bandwidth can generate at
         ${DENSE_MIN_TPS} tok/s or better. The cap is bandwidth x
         ${DENSE_EFFICIENCY_PCT} percent / ${DENSE_MIN_TPS} tok/s.
    Token generation is bandwidth-bound: a dense model reads every weight
    per token, a mixture-of-experts model only its active experts. Gate 3
    therefore keeps large dense models off chips too slow to drive them,
    while MoE models are exempt. Bandwidth comes from a built-in table of
    Apple's published figures for M1 through M6, including the two bins of
    M3 Max, M4 Max, M5 Max and M6. A newer, unlisted chip is assumed to
    match the newest known generation for its tier. On a non-Apple host the
    gate is off and sizing uses memory alone. --recommend shows the
    detected bandwidth and the resulting dense cap.
    Catalogue entries carry a VERIFIED flag. Tags marked no are plausible
    but unconfirmed and may fail to pull; the script warns first and, if a
    pull fails, points at https://ollama.com/library rather than aborting.
KEEPING THE CATALOGUE CURRENT
    Model tags come and go. Three commands keep the catalogue honest, all
    using the Ollama registry (a live tag returns 200, a missing tag 404):
      --check-models        validate existing tags, fix the VERIFIED column
      --refresh-catalog     write a reviewed proposal (never the live file)
      --refresh-catalog-apply   apply that proposal after backup + confirm
    The catalogue header carries two lines. Last-Updated is when a person
    last reviewed the file; it drives the staleness grading and changes
    only when you edit it or confirm --refresh-catalog-apply.
    Catalogue-Generation records which built-in catalogue the file
    descends from; --sync-models uses it to offer a replacement when this
    script ships newer rows.
    --update runs the validation step automatically. All of these are
    fail-soft: if the registry cannot be reached, they report that and make
    no changes, so they are safe to run offline and in CI.
SHELL INTEGRATION
    Adds a marked block to ~/.zshrc providing:
      llmstatus     health of every component
      llmstart      start the stack
      llmstop       stop the stack and reclaim memory
      llmupgrade    run this script's --update mode
    The block is delimited by markers so --uninstall can remove it
    cleanly. Run 'exec zsh' after installing to load the commands.
SECURITY NOTE
    The Open WebUI secret key is stored in ~/.config/llmstack/openwebui-secret
    (mode 0600) and passed to the daemon via the plist EnvironmentVariables
    dict. System LaunchDaemon plists are readable by all users (0644). If
    this is a concern on a multi-user machine, set WEBUI_SECRET_KEY in the
    environment of the user's shell profile instead and remove it from the
    plist. See the Open WebUI docs for details.
REQUIREMENTS
    macOS on Apple Silicon (arm64)
    An administrator account; sudo is required for system LaunchDaemons
    Xcode Command Line Tools; the Homebrew installer will prompt if absent
    Signed in to the Mac App Store, for the Draw Things step
    Enough free disk for the chosen model, typically 25 to 45 GB
POST-INSTALL
    1. Run 'exec zsh' to load the shell commands.
    2. Open http://\$(hostname).local:${WEBUI_PORT} and create the admin
       account. The first account created becomes the owner, so do this
       before anyone else on the network can.
    3. Enable web search: Admin -> Settings -> Web Search
         Enable:      ON
         Engine:      searxng
         SearXNG URL: ${SEARXNG_URL}
       The URL field only appears once the engine is selected.
    4. If Draw Things was installed, open it and download image models
       from its own model manager.
EXIT STATUS
    0   success
    1   an error occurred; the message describes the failure
EXAMPLES
    ./${SCRIPT_NAME} --recommend
        Inspect the machine and print suitable models. Changes nothing.
    ./${SCRIPT_NAME}
        Install with a locally hosted SearXNG.
    ./${SCRIPT_NAME} --searxng-url http://192.168.1.23:8899
        Install using an existing SearXNG elsewhere on the network, with
        no container runtime on this machine.
    ./${SCRIPT_NAME} --no-model --no-drawthings
        Install just the services, choose a model later.
    ./${SCRIPT_NAME} --update
        Update everything and report how stale the catalogue is.
    ./${SCRIPT_NAME} --uninstall
        Guided removal, confirming each step.
HELPTEXT
  exit 0
}

# ===========================================================================
# STATUS
# ===========================================================================
show_status() {
  load_config
  eval "$STATUS_BODY"
  _llmstack_status
  printf '\n'
  exit 0
}

# ===========================================================================
# UPDATE
# ===========================================================================
do_update() {
  load_config
  ensure_catalog
  local backup_dir
  backup_dir="$HOME/.open-webui.backup-$(date +%Y%m%d-%H%M%S)"
  log "Backing up Open WebUI data to $backup_dir"
  if [ -d "$DATA_DIR" ]; then
    cp -R "$DATA_DIR" "$backup_dir" || error "Backup failed. Aborting the update."
  else
    warn "No data directory at $DATA_DIR; nothing to back up."
  fi
  log "Stopping the stack (sudo required)"
  sudo launchctl bootout "system/${OPENWEBUI_LABEL}" 2>/dev/null || true
  sudo launchctl bootout "system/${OLLAMA_LABEL}" 2>/dev/null || true
  sleep 2
  log "Updating Ollama"
  if ! brew upgrade ollama 2>/dev/null; then
    log "Ollama is already at the latest version, or brew upgrade failed non-fatally."
  fi
  log "Updating Open WebUI"
  if ! "$VENV_DIR/bin/pip" install --upgrade open-webui; then
    warn "The Open WebUI update failed. Data is safe at $backup_dir"
    echo "    Restarting the existing version anyway."
  fi
  if [ "$SEARXNG_MODE" = "local" ]; then
    log "Updating the SearXNG container image"
    if command -v colima >/dev/null 2>&1 && colima status >/dev/null 2>&1; then
      docker pull "$SEARXNG_IMAGE"
      docker rm -f searxng >/dev/null 2>&1 || true
      start_searxng_container
    else
      warn "Colima is not running; skipping the SearXNG update."
    fi
  else
    log "SearXNG is remote at ${SEARXNG_URL}; update it on that host."
  fi
  log "Restarting the stack"
  sudo launchctl bootstrap system "$OLLAMA_PLIST" 2>/dev/null || true
  sudo launchctl bootstrap system "$OPENWEBUI_PLIST" 2>/dev/null || true
  log "Waiting for services"
  for i in $(seq 1 30); do
    if curl -s -o /dev/null --max-time 2 http://127.0.0.1:11434/api/version 2>/dev/null \
       && curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${WEBUI_PORT}" 2>/dev/null; then
      ok "Services are up."
      break
    fi
    sleep 2
    [ "$i" -eq 30 ] && warn "Services not fully up after 60 seconds. Check the logs."
  done
  cat <<UPDATED
===========================================================================
  UPDATE COMPLETE
===========================================================================
  Backup retained at: $backup_dir
UPDATED
  report_catalog_age
  # Part A: validate catalogue tags against the registry and auto-correct
  # the VERIFIED column in place. Fail-soft: a registry outage is a no-op.
  validate_catalog_tags fix
  detect_system
  local line tag
  line="$(best_for_role daily)"
  if [ -n "$line" ]; then
    tag="$(field "$line" 2)"
    printf 'Current recommendation for this machine (%s GB): %s\n' "$SYS_RAM_GB" "$tag"
    if ! ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$tag"; then
      printf 'Not installed. To add it:  ollama pull %s\n' "$tag"
    fi
    printf '\n'
  fi
  printf 'Run llmstatus to confirm everything is back up.\n'
  printf 'Note that Open WebUI needs 30 to 60 seconds before it answers.\n\n'
  exit 0
}

# ===========================================================================
# UNINSTALL
# ===========================================================================
uninstall_stack() {
  load_config
  cat <<BANNER
===========================================================================
  LLM STACK UNINSTALLER
===========================================================================
  Every artifact this script created is offered for removal one at a
  time. All prompts default to NO, so pressing Enter skips a step.
  Never touched:
    Homebrew, python@3.11, mas   shared system dependencies
    Anything you decline below
===========================================================================
BANNER
  if ! confirm "Begin uninstall?"; then
    log "Cancelled. Nothing was changed."
    exit 0
  fi
  log "Step 1: Stop and unload the LaunchDaemons"
  echo "    Stops Ollama and Open WebUI and removes them from launchd."
  echo "    Reversible: re-run this script without --uninstall."
  if confirm "Stop and unload both daemons?"; then
    sudo launchctl bootout "system/${OPENWEBUI_LABEL}" 2>/dev/null || true
    sudo launchctl bootout "system/${OLLAMA_LABEL}" 2>/dev/null || true
    sleep 2
    log "Daemons unloaded."
  else
    warn "Skipped. Later steps may fail while files are still in use."
  fi
  log "Step 2: Remove the LaunchDaemon plist files"
  echo "    $OPENWEBUI_PLIST"
  echo "    $OLLAMA_PLIST"
  echo "    Without these the services will not start at boot."
  if confirm "Delete both plist files?"; then
    sudo rm -f "$OPENWEBUI_PLIST" "$OLLAMA_PLIST"
    log "Plists removed."
  else
    log "Skipped."
  fi
  if [ "$SEARXNG_MODE" = "local" ]; then
    log "Step 3: Remove the SearXNG container"
    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx searxng; then
      echo "    Stops and deletes the 'searxng' container."
      if confirm "Remove the SearXNG container?"; then
        docker rm -f searxng >/dev/null 2>&1 || warn "Could not remove the container."
        log "Container removed."
      else
        log "Skipped."
      fi
    else
      log "No SearXNG container found."
    fi
    log "Step 4: Remove the SearXNG configuration"
    if [ -e "$SEARXNG_DIR" ]; then
      echo "    $SEARXNG_DIR"
      if confirm "Delete the SearXNG configuration directory?"; then
        rm -rf "$SEARXNG_DIR"
        log "Configuration removed."
      else
        log "Skipped."
      fi
    else
      log "No SearXNG configuration."
    fi
    log "Step 5: Stop and remove Colima"
    if command -v colima >/dev/null 2>&1; then
      echo "    Stops the Colima virtual machine, deletes it, and uninstalls"
      echo "    the Homebrew packages colima and docker."
      echo ""
      echo "    Answer N if anything else on this Mac uses containers."
      if confirm "Remove Colima and the docker CLI?"; then
        brew services stop colima 2>/dev/null || true
        colima stop 2>/dev/null || true
        colima delete --force 2>/dev/null || true
        brew uninstall colima docker 2>/dev/null || warn "brew uninstall reported an error."
        log "Colima removed."
      else
        log "Skipped."
      fi
    else
      log "Colima not installed."
    fi
  else
    log "Steps 3 to 5 skipped: SearXNG is remote at ${SEARXNG_URL}"
    echo "    Remove it on that host if you no longer need it."
  fi
  log "Step 6: Remove the Open WebUI virtualenv"
  if [ -d "$VENV_DIR" ]; then
    echo "    $VENV_DIR  ($(du -sh "$VENV_DIR" 2>/dev/null | cut -f1))"
    echo "    Application code only. No accounts or chats."
    if confirm "Delete the virtualenv?"; then
      rm -rf "$VENV_DIR"
      log "Virtualenv removed."
    else
      log "Skipped."
    fi
  else
    log "No virtualenv."
  fi
  log "Step 7: Remove Open WebUI data"
  if [ -d "$DATA_DIR" ]; then
    echo "    $DATA_DIR  ($(du -sh "$DATA_DIR" 2>/dev/null | cut -f1))"
    echo ""
    echo "    *** THIS IS YOUR ACCOUNTS, CHAT HISTORY, UPLOADS AND SETTINGS."
    echo "    *** THIS CANNOT BE UNDONE."
    echo ""
    echo "    Recommended: answer N, back it up yourself, then re-run."
    if confirm "PERMANENTLY delete all Open WebUI data?"; then
      if confirm "Are you certain? This deletes accounts and chat history."; then
        rm -rf "$DATA_DIR"
        log "Data removed."
      else
        log "Skipped on second confirmation."
      fi
    else
      log "Skipped. Data preserved at $DATA_DIR"
    fi
  else
    log "No data directory."
  fi
  log "Step 8: Remove downloaded models"
  if [ -d "$OLLAMA_MODELS_DIR" ]; then
    echo "    $OLLAMA_MODELS_DIR"
    echo "    Sizing this may take a moment..."
    echo "    ($(du -sh "$OLLAMA_MODELS_DIR" 2>/dev/null | cut -f1))"
    echo "    Re-downloading is many GB over the network."
    if confirm "Delete all downloaded models?"; then
      rm -rf "$OLLAMA_MODELS_DIR"
      log "Models removed."
    else
      log "Skipped. Models preserved."
    fi
  else
    log "No model directory."
  fi
  log "Step 9: Uninstall the Ollama package"
  if brew list ollama >/dev/null 2>&1; then
    echo "    Removes the ollama binary via Homebrew."
    echo "    Homebrew itself and python@3.11 are not removed."
    if confirm "brew uninstall ollama?"; then
      brew uninstall ollama || warn "brew uninstall reported an error."
      log "Package removed."
    else
      log "Skipped."
    fi
  else
    log "Ollama not installed via Homebrew."
  fi
  log "Step 10: Remove the shell commands from .zshrc"
  if [ -f "$ZSHRC" ] && grep -qF "$ALIAS_END_MARKER" "$ZSHRC"; then
    echo "    Removes the marked block, including any left by earlier"
    echo "    versions. A timestamped backup of .zshrc is written first."
    if confirm "Remove the block from .zshrc?"; then
      purge_zshrc_blocks || true
      check_stray_llm_defs
      echo "    Run 'exec zsh' for this to take effect. Sourcing .zshrc is"
      echo "    not enough; definitions already in the shell persist until"
      echo "    the shell itself is replaced."
    else
      log "Skipped."
    fi
  else
    log "No removable shell block found."
    check_stray_llm_defs
  fi
  log "Step 11: Remove configuration and the model catalogue"
  if [ -d "$CONFIG_DIR" ]; then
    echo "    $CONFIG_DIR"
    echo "    Holds the settings file, the secret key and the model"
    echo "    catalogue, including any edits you made to it."
    if confirm "Delete the configuration directory?"; then
      rm -rf "$CONFIG_DIR"
      log "Configuration removed."
    else
      log "Skipped."
    fi
  else
    log "No configuration directory."
  fi
  log "Optional: Draw Things"
  if [ -d "$DRAWTHINGS_APP" ]; then
    echo "    $DRAWTHINGS_APP"
    echo "    Independent of the LLM stack. Image models downloaded inside"
    echo "    the app go with it."
    if confirm "Delete Draw Things?"; then
      sudo rm -rf "$DRAWTHINGS_APP"
      log "Draw Things removed."
    else
      log "Skipped."
    fi
  else
    log "Draw Things not installed."
  fi
  log "Optional: old data backups"
  local backups
  backups="$(find "$HOME" -maxdepth 1 -type d -name '.open-webui.backup-*' -print0 2>/dev/null \
    | xargs -0 echo 2>/dev/null || true)"
  if [ -n "$backups" ]; then
    find "$HOME" -maxdepth 1 -type d -name '.open-webui.backup-*' -print0 2>/dev/null \
      | while IFS= read -r -d '' b; do
          echo "    $b  ($(du -sh "$b" 2>/dev/null | cut -f1))"
        done
    if confirm "Delete ALL of the backup directories listed above?"; then
      find "$HOME" -maxdepth 1 -type d -name '.open-webui.backup-*' -print0 2>/dev/null \
        | while IFS= read -r -d '' b; do rm -rf "$b"; done
      log "Backups removed."
    else
      log "Skipped."
    fi
  else
    log "No backup directories found."
  fi
  cat <<SUMMARY
===========================================================================
  UNINSTALL COMPLETE
===========================================================================
  Left in place by design:
    Homebrew, python@3.11, mas   shared dependencies
    Anything you answered N to
  Check what is still running:
    pgrep -lf open-webui
    pgrep -lf "ollama serve"
===========================================================================
SUMMARY
  exit 0
}

# ===========================================================================
# SYNC MODELS
# ===========================================================================
# Brings installed Ollama models in line with the recommendations. Order is
# the safety property: every chosen pull must succeed before anything is
# removed, so a failed or interrupted run never leaves fewer models than it
# started with. Every change needs a yes; every prompt defaults to no.
#
# Prompts read from stdin, so loops that prompt iterate over fd 3 instead;
# a plain `while read ... done <<< list` would feed the list to confirm().

# "name" and "name:latest" are the same model to Ollama.
_model_norm() { case "$1" in *:*) printf '%s' "$1" ;; *) printf '%s:latest' "$1" ;; esac; }

# True if the newline-separated list $1 contains the exact line $2.
_has_line() { printf '%s\n' "$1" | grep -qxF -- "$2"; }

# True if `ollama show` lists an embedding capability. Fail-soft: an Ollama
# without a Capabilities section simply reports false.
_is_embedding_model() {
  ollama show "$1" 2>/dev/null \
    | awk 'tolower($0) ~ /capabilities/ { f = 1; next } f && /^[[:space:]]*$/ { f = 0 } f' \
    | grep -qi 'embedding'
}

# SHA-256 of a file (macOS shasum, or sha256sum elsewhere).
_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{ print $1 }'
}

# The ID `ollama list` shows for a model is the first 12 hex digits of the
# SHA-256 of its local manifest, and the registry serves that manifest byte
# for byte (both verified on a real install, v3.6.0). So an installed build
# is outdated exactly when its ID differs from the SHA-256 of the manifest
# the registry now serves - one small request, no download.
# Echoes those 12 digits, or nothing if the manifest could not be fetched.
_registry_manifest_id() {
  local t="$1" f
  f="$(mktemp)"
  if curl -s -f --max-time 15 -H "Accept: ${REGISTRY_ACCEPT}" \
       "${REGISTRY_BASE}/${t%%:*}/manifests/${t##*:}" -o "$f" 2>/dev/null && [ -s "$f" ]; then
    _sha256 "$f" | cut -c1-12
  fi
  rm -f "$f"
}

# Why each failed pull failed. Ollama's error does not tell a missing tag
# from a dropped connection, so probe each manifest once: a tag the registry
# serves means the download itself was cut off. On MBP5800 (2026-10-05)
# Zscaler reset every blob download while the manifests loaded, and the old
# message blamed the tags. $1 is a newline-separated list of tags.
_explain_pull_failures() {
  local t why live="" dead="" down=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$(registry_probe "$t")" in
      LIVE) why="download failed (the tag is in the registry)"; live="yes" ;;
      DEAD) why="tag not found in the registry"; dead="yes" ;;
      *)    why="registry unreachable"; down="yes" ;;
    esac
    printf '      %-30s %s\n' "$t" "$why"
  done <<< "$1"
  if [ -n "$live" ]; then
    echo "    The registry has the tag, so the download itself was cut off. A VPN,"
    echo "    proxy or security software between this machine and the registry may"
    echo "    be resetting long downloads. Downloaded parts are kept, so re-running"
    echo "    resumes them."
  fi
  if [ -n "$dead" ]; then echo "    Check the tag at https://ollama.com/library."; fi
  if [ -n "$down" ]; then echo "    The registry did not answer. Check this machine's network, then re-run."; fi
  return 0
}

sync_models() {
  local listing inst="" m gen role line rows="" picks picktags sel="" cands=""
  local tag size arch roles st need sz pulled="" updated="" failed="" removed="" kept=""
  local states="" reachable="no" lid rid kind
  detect_system
  ensure_catalog
  cat <<'SYNCHDR'
===========================================================================
  SYNC MODELS
===========================================================================
  Pulls the recommended models you choose, then offers each installed
  model that is not a current pick for removal. Nothing is removed until
  every chosen pull has succeeded. All prompts default to NO.
===========================================================================
SYNCHDR

  # 1. The daemon must be up: both pull and rm go through it.
  if ! listing="$(ollama list 2>/dev/null)"; then
    error "Cannot reach Ollama. Start the stack (llmstart), then re-run. Nothing was changed."
  fi
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    inst="${inst}$(_model_norm "$m")"$'\n'
  done <<EOF_LIST
$(printf '%s\n' "$listing" | awk 'NR > 1 && NF { print $1 }')
EOF_LIST

  # 2. A catalogue that does not descend from the current built-in one
  # hides newer models from the picks. Judged by the Catalogue-Generation
  # marker, not Last-Updated: that date records review, and refresh tooling
  # before v3.5.1 stamped it on every proposal.
  if catalog_predates_builtin; then
    gen="$(catalog_generation)"
    if [ -z "$gen" ]; then
      printf '\nYour model catalogue has no Catalogue-Generation line, so it predates\n'
      printf 'the generation %s catalogue built into this script, or was built by hand.\n' "$CATALOG_GENERATION"
    else
      printf '\nYour model catalogue is generation %s; this script ships generation %s.\n' "$gen" "$CATALOG_GENERATION"
    fi
    echo "    Picks come from your catalogue, so newer models will not appear"
    echo "    until it is replaced. Replacing it keeps a timestamped backup;"
    echo "    copy any rows you added by hand back from that file afterwards."
    echo "    If you maintain your own catalogue on purpose, answer no and add"
    echo "    this line to it to stop being asked:"
    echo "      # Catalogue-Generation: $CATALOG_GENERATION"
    if confirm "Back up your catalogue and replace it with the built-in one?"; then
      cp "$CATALOG" "${CATALOG}.backup-$(date +%Y%m%d-%H%M%S)"
      write_default_catalog
      ok "Catalogue replaced. Backup kept alongside it."
    else
      log "Keeping your catalogue."
    fi
  fi

  # 3. Current picks, one line per unique tag with every role it serves.
  for role in daily reasoning coding vision light; do
    line="$(best_for_role "$role")"
    [ -n "$line" ] || continue
    rows="${rows}$(_model_norm "$(field "$line" 2)")|$(field "$line" 3)|$(field "$line" 4)|${role}"$'\n'
  done
  picks="$(printf '%s' "$rows" | awk -F'|' '
    NF < 4 { next }
    !($1 in r) { order[++n] = $1; size[$1] = $2; arch[$1] = $3; r[$1] = $4; next }
    { r[$1] = r[$1] ", " $4 }
    END { for (i = 1; i <= n; i++) print order[i] "|" size[order[i]] "|" arch[order[i]] "|" r[order[i]] }')"
  if [ -z "$picks" ]; then
    warn "Nothing in the catalogue fits this machine, so there is nothing to sync."
    echo "    Run --recommend for details."
    exit 0
  fi
  picktags="$(printf '%s\n' "$picks" | cut -d'|' -f1)"

  # An installed pick may be an old build of its tag: compare manifest
  # digests with the registry (one reachability probe first, so an offline
  # machine does not wait out a timeout per pick). Fail-soft: unreachable
  # means "unchecked", never an error.
  if registry_reachable; then reachable="yes"; fi
  printf '\nCurrent picks for this machine (%s GB, %s):\n' "$SYS_RAM_GB" "$SYS_CHIP"
  while IFS='|' read -r tag size arch roles; do
    [ -n "$tag" ] || continue
    if ! _has_line "$inst" "$tag"; then
      st="not installed"
    elif [ "$reachable" != "yes" ]; then
      st="unchecked"
    else
      lid="$(printf '%s\n' "$listing" | awk -v m="$tag" 'NR > 1 { n = $1; if (n !~ /:/) n = n ":latest"; if (n == m) { print $2; exit } }')"
      rid="$(_registry_manifest_id "$tag")"
      if [ -z "$rid" ] || [ -z "$lid" ]; then st="unchecked"
      elif [ "$rid" = "$lid" ]; then st="current"
      else st="outdated"
      fi
    fi
    states="${states}${tag}|${st}"$'\n'
    printf '  %-30s %6s GB  %-5s  %-13s  %s\n' "$tag" "$size" "$arch" "$st" "$roles"
  done <<< "$picks"
  if [ "$reachable" != "yes" ]; then
    printf '  (Registry unreachable: installed picks were not checked for newer builds.)\n'
  fi

  # 4. Choose which missing picks to pull and which outdated ones to update.
  while IFS='|' read -r tag size arch roles <&3; do
    [ -n "$tag" ] || continue
    st="$(printf '%s' "$states" | awk -F'|' -v t="$tag" '$1 == t { print $2; exit }')"
    case "$st" in
      "not installed")
        if confirm "Pull $tag (about $size GB) for: $roles?"; then
          sel="${sel}${tag}|${size}|pull"$'\n'
        fi ;;
      outdated)
        if confirm "Update $tag for: $roles? Your build is older than the registry's (download up to $size GB)."; then
          sel="${sel}${tag}|${size}|update"$'\n'
        fi ;;
    esac
  done 3<<< "$picks"

  # Removal candidates: installed, and not any role's current pick. A pick
  # you declined to pull stays a pick, so it is never offered for removal.
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    _has_line "$picktags" "$m" || cands="${cands}${m}"$'\n'
  done <<< "$inst"

  if [ -z "$sel" ] && [ -z "$cands" ]; then
    printf '\nNothing to do: no pulls or updates chosen and no other models installed.\n\n'
    exit 0
  fi

  # 5. Old and new models coexist until the removals, so check up front.
  if [ -n "$sel" ]; then
    # Updates count at full size: Ollama fetches the new layers before it
    # drops the old ones.
    need="$(printf '%s' "$sel" | awk -F'|' 'NF { s += $2 } END { printf "%d", s + 10.999 }')"
    if awk -v f="$SYS_DISK_FREE_GB" -v w="$need" 'BEGIN { exit !(f + 0 < w + 0) }'; then
      warn "Only ${SYS_DISK_FREE_GB} GB free; the chosen downloads need about ${need} GB including 10 GB headroom."
      echo "    Nothing was changed. To free space first, run --sync-models again,"
      echo "    decline every pull, and answer yes to the removals you want."
      exit 1
    fi
  fi

  # 6. Pull everything chosen before removing anything.
  if [ -n "$sel" ]; then
    trap 'warn "Pull interrupted. Nothing was removed. Re-run to resume the download."; exit 1' INT
    while IFS='|' read -r tag size kind <&3; do
      [ -n "$tag" ] || continue
      log "Pulling $tag (about $size GB). Large downloads take a while."
      if ollama pull "$tag"; then
        if [ "$kind" = "update" ]; then
          updated="${updated}${tag}"$'\n'
        else
          pulled="${pulled}${tag}"$'\n'
        fi
        ok "Pulled $tag"
      else
        failed="${failed}${tag}"$'\n'
        warn "The pull failed for $tag"
      fi
    done 3<<< "$sel"
    trap - INT
    if [ -n "$failed" ]; then
      warn "Some pulls failed, so no models were removed:"
      _explain_pull_failures "$failed"
      exit 1
    fi
  fi

  # 7. Offer each non-pick for removal, one at a time.
  if [ -n "$cands" ]; then
    printf '\n%s installed model(s) are not a current pick. Each is offered\n' "$(printf '%s' "$cands" | grep -c .)"
    printf 'for removal separately; pressing Enter keeps it.\n'
    while IFS= read -r m <&3; do
      [ -n "$m" ] || continue
      sz="$(printf '%s\n' "$listing" | awk -v m="$m" 'NR > 1 { n = $1; if (n !~ /:/) n = n ":latest"; if (n == m) { print $3 " " $4; exit } }')"
      printf '\n  %s  (%s)\n' "$m" "${sz:-size unknown}"
      if _is_embedding_model "$m"; then
        printf '  %sEmbedding model.%s Open WebUI may use it for document search;\n' "$C_YELLOW" "$C_RESET"
        printf '  removing it can break uploads and knowledge collections.\n'
      fi
      if confirm "Remove $m?"; then
        if ollama rm "$m" >/dev/null; then
          removed="${removed}${m}"$'\n'
          ok "Removed $m"
        else
          kept="${kept}${m}"$'\n'
          warn "Could not remove $m"
        fi
      else
        kept="${kept}${m}"$'\n'
      fi
    done 3<<< "$cands"
  fi

  # 8. Summary.
  cat <<'SYNCDONE'

===========================================================================
  SYNC COMPLETE
===========================================================================
SYNCDONE
  printf '  Pulled:\n';  if [ -n "$pulled" ];  then printf '%s' "$pulled"  | sed 's/^/    /'; else echo "    (none)"; fi
  printf '  Updated:\n'; if [ -n "$updated" ]; then printf '%s' "$updated" | sed 's/^/    /'; else echo "    (none)"; fi
  printf '  Removed:\n'; if [ -n "$removed" ]; then printf '%s' "$removed" | sed 's/^/    /'; else echo "    (none)"; fi
  printf '  Kept, not a current pick:\n'; if [ -n "$kept" ]; then printf '%s' "$kept" | sed 's/^/    /'; else echo "    (none)"; fi
  if [ -n "$removed" ]; then
    echo ""
    echo "  If a removed model was the default in Open WebUI, choose a new"
    echo "  default there. Existing chats remain readable."
  fi
  echo "==========================================================================="
  echo ""
}

# ===========================================================================
# SEARXNG CONTAINER
# ===========================================================================
start_searxng_container() {
  docker run -d \
    --name searxng \
    --restart unless-stopped \
    -p "127.0.0.1:${SEARXNG_HOST_PORT}:${SEARXNG_CONTAINER_PORT}" \
    -v "${SEARXNG_SETTINGS}:/etc/searxng/settings.yml:ro" \
    -e "SEARXNG_BASE_URL=http://127.0.0.1:${SEARXNG_HOST_PORT}/" \
    --health-cmd "wget --no-verbose --tries=1 --spider http://127.0.0.1:${SEARXNG_CONTAINER_PORT}/healthz || exit 1" \
    --health-interval 30s \
    --health-timeout 5s \
    --health-retries 3 \
    --health-start-period 20s \
    "$SEARXNG_IMAGE" >/dev/null
}

# ===========================================================================
# ARGUMENT PARSING
# ===========================================================================
MODE="install"
CLI_SEARXNG_URL="" CLI_SEARXNG_PORT="" CLI_WEBUI_PORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)      show_help ;;
    --version)     echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"; exit 0 ;;
    --install)      MODE="install" ;;
    --update|--upgrade) MODE="update" ;;
    --status)       MODE="status" ;;
    --recommend)    MODE="recommend" ;;
    --sync-models)  MODE="sync-models" ;;
    --uninstall)    MODE="uninstall" ;;
    --check-models) MODE="check-models" ;;
    --refresh-catalog)       MODE="refresh-catalog" ;;
    --refresh-catalog-apply) MODE="refresh-catalog-apply" ;;
    --discover)     DISCOVER="yes" ;;
    --searxng-url)
      [ $# -ge 2 ] || error "--searxng-url needs a URL"
      CLI_SEARXNG_URL="${2%/}"
      shift ;;
    --searxng-port)
      [ $# -ge 2 ] || error "--searxng-port needs a port number"
      validate_port "$2"
      CLI_SEARXNG_PORT="$2"
      shift ;;
    --webui-port)
      [ $# -ge 2 ] || error "--webui-port needs a port number"
      validate_port "$2"
      CLI_WEBUI_PORT="$2"
      shift ;;
    --model)
      [ $# -ge 2 ] || error "--model needs a tag"
      FORCE_MODEL="$2"
      shift ;;
    --no-model)      SKIP_MODEL="yes" ;;
    --no-drawthings) SKIP_DRAWTHINGS="yes" ;;
    *) error "Unknown argument: $1   (try --help)" ;;
  esac
  shift
done

case "$MODE" in
  status)    show_status ;;
  recommend) show_recommendations; exit 0 ;;
  sync-models) sync_models; exit 0 ;;
  uninstall) uninstall_stack ;;
  update)    do_update ;;
  check-models)          validate_catalog_tags fix; exit 0 ;;
  refresh-catalog)       build_catalog_proposal "$DISCOVER"; exit 0 ;;
  refresh-catalog-apply) apply_catalog_proposal "$DISCOVER"; exit 0 ;;
esac

# ===========================================================================
# INSTALL
# ===========================================================================
INSTALL_STARTED="yes"

log "Preflight"
[ "$(uname -s)" = "Darwin" ] || error "This script targets macOS. Detected: $(uname -s)"
[ "$(uname -m)" = "arm64" ]  || error "This script targets Apple Silicon (arm64). Detected: $(uname -m)"

if ! xcode-select -p >/dev/null 2>&1; then
  warn "Xcode Command Line Tools are not installed."
  echo "    The Homebrew installer will prompt for them. Accept the dialog,"
  echo "    wait for it to finish, then re-run this script."
fi

resolve_settings
detect_system
ensure_catalog

cat <<'DETECTED_HDR'
===========================================================================
  DETECTED SYSTEM
===========================================================================
DETECTED_HDR
printf '  Chip:              %s\n' "$SYS_CHIP"
printf '  Tier:              %s\n' "$SYS_TIER"
printf '  Unified memory:    %s GB\n' "$SYS_RAM_GB"
printf '  Usable for models: ~%s GB\n' "$SYS_USABLE_GB"
printf '  Free disk:         %s GB\n' "$SYS_DISK_FREE_GB"
print_bandwidth_lines
printf '  %s\n' "$(bandwidth_note)"
if [ "$SEARXNG_MODE" = "remote" ]; then
  printf '  Web search:        remote SearXNG at %s\n' "$SEARXNG_URL"
else
  printf '  Web search:        local SearXNG (Colima) on 127.0.0.1:%s\n' "$SEARXNG_HOST_PORT"
fi
printf '  Open WebUI:        port %s, bound to %s\n' "$WEBUI_PORT" "$WEBUI_BIND"
cat <<'DETECTED_FTR'
===========================================================================
DETECTED_FTR

# --- port conflict check ---------------------------------------------------
holder=""
if holder="$(port_in_use "$WEBUI_PORT")"; then
  warn "Port ${WEBUI_PORT} is already in use."
  echo "    Held by: $holder"
  echo "    Free the port, or re-run with --webui-port <other-port>."
fi
if [ "$SEARXNG_MODE" = "local" ]; then
  if holder="$(port_in_use "$SEARXNG_HOST_PORT")"; then
    warn "Port ${SEARXNG_HOST_PORT} is already in use."
    echo "    Held by: $holder"
    echo "    Free the port, or re-run with --searxng-port <other-port>."
  fi
fi

# --- choose a model --------------------------------------------------------
MODEL_TAG=""
MODEL_SIZE=0
MODEL_VERIFIED="yes"
if [ "$SKIP_MODEL" = "yes" ]; then
  log "Skipping the model download (--no-model)."
elif [ -n "$FORCE_MODEL" ]; then
  MODEL_TAG="$FORCE_MODEL"
  MODEL_VERIFIED="unknown"
  log "Using the model given on the command line: $MODEL_TAG"
  echo "    The fit check is skipped for an explicitly chosen model."
else
  REC_LINE="$(best_for_role daily)"
  if [ -z "$REC_LINE" ]; then
    REC_LINE="$(best_for_role light)"
    [ -n "$REC_LINE" ] && log "No daily-tier model fits; falling back to a lighter one."
  fi
  if [ -z "$REC_LINE" ]; then
    warn "No catalogue entry fits a ${SYS_USABLE_GB} GB budget."
    echo "    Add a smaller entry to $CATALOG, or re-run with"
    echo "    --model TAG to choose one yourself, or --no-model to skip."
    SKIP_MODEL="yes"
  else
    MODEL_TAG="$(field "$REC_LINE" 2)"
    MODEL_SIZE="$(field "$REC_LINE" 3)"
    MODEL_VERIFIED="$(field "$REC_LINE" 6)"
    printf '\nRecommended model: %s  (%s GB, %s)\n' \
      "$MODEL_TAG" "$MODEL_SIZE" "$(field "$REC_LINE" 4)"
    printf '  %s\n' "$(field "$REC_LINE" 7)"
    if [ "$MODEL_VERIFIED" != "yes" ]; then
      printf '\n  This tag is marked UNVERIFIED in the catalogue. It may no\n'
      printf '  longer exist. If the pull fails, check\n'
      printf '  https://ollama.com/library and correct %s\n' "$CATALOG"
    fi
    # MODEL_SIZE can be a decimal (e.g. 7.6), which bash arithmetic rejects
    # and which would abort the install under set -e. Compare in awk.
    DISK_WANTED_GB="$(awk -v s="$MODEL_SIZE" 'BEGIN { printf "%d", s + 10.999 }')"
    if awk -v f="$SYS_DISK_FREE_GB" -v w="$DISK_WANTED_GB" 'BEGIN { exit !(f + 0 < w + 0) }'; then
      warn "Only ${SYS_DISK_FREE_GB} GB free; about ${DISK_WANTED_GB} GB is wanted."
      echo "    Free some space, or re-run with --no-model."
    fi
  fi
  report_catalog_age
fi

# Test hook: stop after the plan, before anything is installed. CI uses it
# to check settings precedence. Not documented in --help.
if [ "${LLMSTACK_PLAN_ONLY:-}" = "1" ]; then
  printf '\nPlan only (LLMSTACK_PLAN_ONLY=1); nothing was installed.\n'
  exit 0
fi

log "Requesting sudo up front (needed for system LaunchDaemons)"
sudo -v

# --- Homebrew --------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
  if ! grep -q 'brew shellenv' "$ZSHRC" 2>/dev/null; then
    log "Adding Homebrew to the PATH in .zshrc"
    # shellcheck disable=SC2016
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$ZSHRC"
  fi
else
  log "Homebrew present."
fi

# --- Ollama ----------------------------------------------------------------
if ! brew list ollama >/dev/null 2>&1; then
  log "Installing Ollama"
  brew install ollama
else
  log "Ollama present; checking for updates"
  brew upgrade ollama 2>/dev/null || log "Already at the latest version."
fi

# --- Python ----------------------------------------------------------------
if ! brew list "$PYTHON_FORMULA" >/dev/null 2>&1; then
  log "Installing $PYTHON_FORMULA"
  brew install "$PYTHON_FORMULA"
else
  log "$PYTHON_FORMULA present."
fi

# --- Container runtime, local SearXNG mode only ----------------------------
if [ "$SEARXNG_MODE" = "local" ]; then
  if ! launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
    warn "No console login session detected."
    echo "    Ollama and Open WebUI will install and run correctly."
    echo "    Colima and SearXNG need a session and will not start."
    echo "    Log in at the screen and re-run to finish the SearXNG setup,"
    echo "    or use --searxng-url to point at a remote instance instead."
  fi
  if ! brew list colima >/dev/null 2>&1; then
    log "Installing Colima"
    brew install colima
  else
    log "Colima present."
  fi
  if ! brew list docker >/dev/null 2>&1; then
    log "Installing the docker CLI"
    brew install docker
  else
    log "docker CLI present."
  fi
  if colima status >/dev/null 2>&1; then
    log "Colima already running."
  else
    log "Starting Colima"
    brew services start colima 2>/dev/null || true
    for i in $(seq 1 60); do
      if colima status >/dev/null 2>&1; then break; fi
      sleep 2
      if [ "$i" -eq 60 ]; then
        warn "Colima did not start within 120 seconds."
        echo "    Expected if no console login session exists."
      fi
    done
  fi
else
  log "SearXNG is remote at ${SEARXNG_URL}; no container runtime needed."
  if curl -s -o /dev/null --max-time 5 "${SEARXNG_URL}/search?q=test&format=json"; then
    log "Remote SearXNG is reachable."
  else
    warn "Cannot reach ${SEARXNG_URL}."
    echo "    Installation continues; only web search is affected."
  fi
fi

# --- Open WebUI ------------------------------------------------------------
if [ ! -d "$VENV_DIR" ]; then
  log "Creating the Open WebUI virtualenv"
  "$PYTHON_BIN" -m venv "$VENV_DIR"
else
  log "Virtualenv present."
fi
log "Installing or upgrading Open WebUI. This is large and may take several minutes."
"$VENV_DIR/bin/pip" install --upgrade pip >/dev/null 2>&1
"$VENV_DIR/bin/pip" install --upgrade open-webui

# --- secret key ------------------------------------------------------------
mkdir -p "$CONFIG_DIR"
if [ ! -f "$SECRET_FILE" ]; then
  log "Generating a persistent secret key"
  "$PYTHON_BIN" -c "import secrets; print(secrets.token_hex(16))" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
else
  log "Reusing the existing secret key."
fi
WEBUI_SECRET_KEY="$(cat "$SECRET_FILE")"
mkdir -p "$DATA_DIR" "$HOME/.ollama"

# --- SearXNG, local mode ---------------------------------------------------
if [ "$SEARXNG_MODE" = "local" ]; then
  mkdir -p "$SEARXNG_DIR"
  if [ -d "$SEARXNG_SETTINGS" ]; then
    log "Removing a stale settings.yml directory left behind by Docker"
    rmdir "$SEARXNG_SETTINGS" 2>/dev/null || rm -rf "$SEARXNG_SETTINGS"
  fi
  if [ ! -f "$SEARXNG_SETTINGS" ]; then
    log "Writing the SearXNG configuration"
    SEARXNG_SECRET="$("$PYTHON_BIN" -c 'import secrets; print(secrets.token_hex(16))')"
    cat > "$SEARXNG_SETTINGS" <<SEARXNG_YML
use_default_settings: true
server:
  secret_key: "${SEARXNG_SECRET}"
  limiter: false
  image_proxy: true
search:
  formats:
    - html
    - json
SEARXNG_YML
  else
    log "SearXNG configuration already present; keeping it."
  fi
  if colima status >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' | grep -qx searxng; then
      log "SearXNG container exists."
      docker ps --format '{{.Names}}' | grep -qx searxng || docker start searxng >/dev/null
    else
      log "Creating the SearXNG container"
      start_searxng_container
    fi
    log "Waiting for SearXNG on :${SEARXNG_HOST_PORT}"
    for i in $(seq 1 30); do
      if curl -s --max-time 3 "http://127.0.0.1:${SEARXNG_HOST_PORT}/search?q=test&format=json" >/dev/null 2>&1; then
        ok "SearXNG is answering."
        break
      fi
      sleep 2
      [ "$i" -eq 30 ] && warn "No response after 60 seconds. Check: docker logs searxng"
    done
  else
    warn "Colima is not running; skipping container creation."
    echo "    The configuration is written. Re-run once Colima can start."
  fi
fi

# --- Ollama daemon ---------------------------------------------------------
log "Installing the Ollama system LaunchDaemon"
sudo tee "$OLLAMA_PLIST" > /dev/null <<PLIST_OLLAMA
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${OLLAMA_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/ollama</string>
    <string>serve</string>
  </array>
  <key>UserName</key>
  <string>${ACTUAL_USER}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>OLLAMA_MODELS</key>
    <string>${OLLAMA_MODELS_DIR}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${HOME}/.ollama/ollama.daemon.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/.ollama/ollama.daemon.err.log</string>
</dict>
</plist>
PLIST_OLLAMA
sudo chown root:wheel "$OLLAMA_PLIST"
sudo chmod 644 "$OLLAMA_PLIST"
plutil -lint "$OLLAMA_PLIST" >/dev/null || error "The generated Ollama plist is malformed."

log "Loading the Ollama daemon"
sudo launchctl bootout "system/${OLLAMA_LABEL}" 2>/dev/null || true
sleep 2
sudo launchctl bootstrap system "$OLLAMA_PLIST" 2>/dev/null || \
  warn "Bootstrap reported an error; status is verified below."

# --- Open WebUI daemon -----------------------------------------------------
log "Installing the Open WebUI system LaunchDaemon"
sudo tee "$OPENWEBUI_PLIST" > /dev/null <<PLIST_WEBUI
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${OPENWEBUI_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${VENV_DIR}/bin/open-webui</string>
    <string>serve</string>
    <string>--host</string>
    <string>${WEBUI_BIND}</string>
    <string>--port</string>
    <string>${WEBUI_PORT}</string>
  </array>
  <key>UserName</key>
  <string>${ACTUAL_USER}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>DATA_DIR</key>
    <string>${DATA_DIR}</string>
    <key>WEBUI_SECRET_KEY</key>
    <string>${WEBUI_SECRET_KEY}</string>
  </dict>
  <key>SoftResourceLimits</key>
  <dict>
    <key>NumberOfFiles</key>
    <integer>65536</integer>
  </dict>
  <key>HardResourceLimits</key>
  <dict>
    <key>NumberOfFiles</key>
    <integer>65536</integer>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${DATA_DIR}/openwebui.log</string>
  <key>StandardErrorPath</key>
  <string>${DATA_DIR}/openwebui.err.log</string>
</dict>
</plist>
PLIST_WEBUI
sudo chown root:wheel "$OPENWEBUI_PLIST"
sudo chmod 644 "$OPENWEBUI_PLIST"
plutil -lint "$OPENWEBUI_PLIST" >/dev/null || error "The generated Open WebUI plist is malformed."

log "Loading the Open WebUI daemon"
sudo launchctl bootout "system/${OPENWEBUI_LABEL}" 2>/dev/null || true
sleep 2
sudo launchctl bootstrap system "$OPENWEBUI_PLIST" 2>/dev/null || \
  warn "Bootstrap reported an error; status is verified below."

# --- Draw Things -----------------------------------------------------------
if [ "$SKIP_DRAWTHINGS" = "yes" ]; then
  log "Skipping Draw Things (--no-drawthings)."
elif [ -d "$DRAWTHINGS_APP" ]; then
  log "Draw Things already installed."
else
  if ! brew list mas >/dev/null 2>&1; then
    log "Installing mas, the Mac App Store CLI"
    brew install mas
  fi
  log "Installing Draw Things from the App Store"
  if mas install "$DRAWTHINGS_ID"; then
    log "Draw Things installed."
  else
    warn "Could not install Draw Things. Are you signed in to the App Store?"
    echo "    Install it by hand: App Store, 'Draw Things: Offline AI Art'"
  fi
fi

# --- model -----------------------------------------------------------------
if [ "$SKIP_MODEL" != "yes" ] && [ -n "$MODEL_TAG" ]; then
  log "Waiting for the Ollama API on :11434"
  for i in $(seq 1 30); do
    if curl -s --max-time 2 http://127.0.0.1:11434/api/version >/dev/null; then break; fi
    sleep 1
    [ "$i" -eq 30 ] && error "The Ollama API did not respond after 30 seconds."
  done
  if ollama list | awk '{print $1}' | grep -qx "$MODEL_TAG"; then
    log "Model already present: $MODEL_TAG"
  else
    log "Pulling $MODEL_TAG. This is a large download and will take a while."
    trap 'warn "Pull interrupted. Re-run to resume the download."; exit 1' INT
    if ! ollama pull "$MODEL_TAG"; then
      trap - INT
      warn "The pull failed for $MODEL_TAG"
      echo "    The tag may have changed or may never have existed."
      echo "    Browse current tags at https://ollama.com/library, then edit"
      echo "    $CATALOG and re-run, or pull one by hand:"
      echo "      ollama pull MODEL_TAG"
      echo ""
      echo "    Everything else installed correctly."
    else
      trap - INT
      ok "Model pulled: $MODEL_TAG"
    fi
  fi
fi

# --- config ----------------------------------------------------------------
write_config

# --- shell integration -----------------------------------------------------
log "Configuring shell commands"
check_stray_llm_defs
if purge_zshrc_blocks; then
  ZSHRC_SAFE="yes"
else
  ZSHRC_SAFE="no"
fi

if [ "$ZSHRC_SAFE" = "no" ]; then
  warn "Skipping the .zshrc update because an existing block could not be"
  echo "    removed safely. Resolve the note above and re-run to finish."
else
  log "Writing llmstatus, llmstart, llmstop and llmupgrade to .zshrc"
  SCRIPT_ABS="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  {
    printf '\n%s\n' "$ALIAS_START_MARKER"
    printf '# Installed by llmstack-macos.sh. Settings live in\n'
    printf '# ~/.config/llmstack/config and are read at call time.\n'
    printf 'LLMSTACK_SCRIPT="%s"\n' "$SCRIPT_ABS"
    printf '%s\n' "$STATUS_BODY"
    cat <<'ZSH_BODY'
llmstop() {
  _llmstack_conf
  sudo launchctl bootout system/com.local.openwebui 2>/dev/null
  sudo launchctl bootout system/com.local.ollama 2>/dev/null
  if [ "$SEARXNG_MODE" = "local" ]; then
    docker stop searxng >/dev/null 2>&1
    brew services stop colima >/dev/null 2>&1
  fi
  echo "LLM stack stopped."
}
llmstart() {
  _llmstack_conf
  if [ "$SEARXNG_MODE" = "local" ]; then
    brew services start colima >/dev/null 2>&1
    for _i in $(seq 1 30); do
      colima status >/dev/null 2>&1 && break
      sleep 2
    done
    docker start searxng >/dev/null 2>&1
  fi
  sudo launchctl bootstrap system /Library/LaunchDaemons/com.local.ollama.plist 2>/dev/null
  sudo launchctl bootstrap system /Library/LaunchDaemons/com.local.openwebui.plist 2>/dev/null
  echo "LLM stack started. Open WebUI needs 30 to 60 seconds before it answers."
}
llmstatus() { _llmstack_status; }
llmupgrade() {
  if [ -x "$LLMSTACK_SCRIPT" ]; then
    "$LLMSTACK_SCRIPT" --update
  else
    echo "Cannot find llmstack-macos.sh at $LLMSTACK_SCRIPT" >&2
    echo "Run the script's --update mode from wherever you keep it." >&2
    return 1
  fi
}
ZSH_BODY
    printf '%s\n' "$ALIAS_END_MARKER"
  } >> "$ZSHRC"
fi

# --- verify ----------------------------------------------------------------
log "Verifying services"
curl -s -o /dev/null --max-time 5 -w "Ollama:     %{http_code}\n" http://127.0.0.1:11434/api/version || true
log "Waiting for Open WebUI on :${WEBUI_PORT}. First start takes 30 to 60 seconds."
for i in $(seq 1 45); do
  if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${WEBUI_PORT}"; then
    ok "Open WebUI: 200"
    break
  fi
  sleep 2
  [ "$i" -eq 45 ] && warn "Not answering yet. Check ${DATA_DIR}/openwebui.err.log"
done

# Clear the error trap — we're done.
trap - EXIT
INSTALL_STARTED="no"

cat <<DONE
===========================================================================
  SETUP COMPLETE
===========================================================================
  Ollama API:   http://127.0.0.1:11434
  Open WebUI:   http://$(hostname).local:${WEBUI_PORT}
  SearXNG:      ${SEARXNG_URL}
  Next steps:
    1. exec zsh
       Loads llmstatus, llmstart, llmstop and llmupgrade.
       Use exec zsh, not 'source ~/.zshrc'. Sourcing cannot clear
       definitions already present in a running shell, and an alias
       left over from an older install will break the new functions.
    2. Open the Open WebUI address above and create the admin account.
       The first account created becomes the owner, so do this before
       anyone else on the network can.
    3. Turn on web search:
         Admin, Settings, Web Search
           Enable:      ON
           Engine:      searxng
           SearXNG URL: ${SEARXNG_URL}
       The URL field only appears once the engine is selected.
  Model catalogue: ${CATALOG}
    Edit it to change what this script recommends. Bump its
    Last-Updated line when you do; --update reports how old it is.
  Documentation:  ./${SCRIPT_NAME} --help
  Uninstall:      ./${SCRIPT_NAME} --uninstall
===========================================================================
DONE