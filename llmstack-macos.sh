#!/bin/bash
#
# llmstack-macos.sh
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
# License: public domain / CC0. Share and modify freely.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="3.0"

# Date the bundled model catalogue was last curated by hand.
# Bump this whenever the DEFAULT_CATALOG below is revised.
CATALOG_DATE="2026-07-23"

# Staleness thresholds, in days.
CATALOG_WARN_DAYS=90
CATALOG_STALE_DAYS=180

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

ACTUAL_USER="$(whoami)"

log()   { printf '\n==> %s\n' "$1"; }
warn()  { printf '\nWARNING: %s\n' "$1" >&2; }
error() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

confirm() {
  local reply
  printf '\n%s [y/N]: ' "$1"
  read -r reply
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ===========================================================================
# MODEL CATALOGUE
# ===========================================================================
# Written to $CATALOG on first run if that file does not exist. It is never
# overwritten afterwards, so local edits survive upgrades of this script.
#
# Data line format, pipe separated:
#   MIN_RAM_GB | TAG | SIZE_GB | ARCH | ROLE | VERIFIED | NOTES
#
#   MIN_RAM_GB  smallest machine this entry is sensible on
#   TAG         exact ollama pull tag
#   SIZE_GB     on-disk / in-memory size of the quantised weights
#   ARCH        moe or dense
#   ROLE        daily, coding, vision or light
#   VERIFIED    yes if the tag was confirmed against the Ollama registry
#   NOTES       free text, no pipe characters

write_default_catalog() {
  mkdir -p "$CONFIG_DIR"
  cat > "$CATALOG" <<CATALOG_EOF
# ===========================================================================
# Model catalogue for llmstack-macos.sh
# ===========================================================================
#
# Last-Updated: ${CATALOG_DATE}
#
# Local model releases move quickly. Treat this file as a starting point,
# not an authority, and revise it as new models appear. When you do, update
# the Last-Updated line above; the script reads it and will tell you how
# stale the file has become.
#
# Sizing rule used by the script
# -----------------------------------------------------------------------
# Roughly 70 percent of unified memory is usable for model weights. The
# remainder goes to macOS, the inference engine, the KV cache and anything
# else running. The script computes that budget and picks the largest entry
# that fits.
#
# Why architecture matters on Apple Silicon
# -----------------------------------------------------------------------
# Token generation is limited by memory bandwidth, not compute. A dense
# model touches every parameter for every token. A mixture-of-experts model
# activates only a fraction, so it generates far faster while still needing
# the full weight set resident in memory. On bandwidth-constrained chips,
# base-tier parts especially, prefer MoE.
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

# --- Daily drivers ---------------------------------------------------------
48|qwen3.6:35b-a3b|24|moe|daily|yes|35B total with about 3B active per token. Fast on Apple Silicon.
32|qwen3.6:35b-a3b|24|moe|daily|yes|Fits with limited headroom for long context.
16|gemma4:26b-a4b|16|moe|daily|no|Smaller MoE alternative. Verify the tag before relying on it.
8|qwen3.6:8b|5|dense|light|no|Small dense model for constrained machines.

# --- Coding ----------------------------------------------------------------
48|qwen3.6:27b|20|dense|coding|no|Dense model aimed at code. Verify the tag.
32|qwen3.6:14b|9|dense|coding|no|Lighter coding option.

# --- Large dense, high memory only ----------------------------------------
96|llama3.3:70b|43|dense|daily|no|Dense 70B. Slow on anything below Max tier. Verify the tag.

# --- Vision ----------------------------------------------------------------
32|gemma4:26b-a4b|16|moe|vision|no|Multimodal. Verify the tag.
CATALOG_EOF
}

ensure_catalog() {
  if [ ! -f "$CATALOG" ]; then
    log "Writing the default model catalogue to $CATALOG"
    write_default_catalog
  fi
}

# Echo the catalogue's Last-Updated date, or empty if unreadable.
catalog_date() {
  [ -f "$CATALOG" ] || return 0
  grep -m1 '^# Last-Updated:' "$CATALOG" 2>/dev/null | awk '{print $3}'
}

# Echo the catalogue age in whole days, or empty if it cannot be computed.
catalog_age_days() {
  local d cat_epoch now_epoch
  d="$(catalog_date)"
  [ -n "$d" ] || return 0
  cat_epoch="$(date -j -f "%Y-%m-%d" "$d" "+%s" 2>/dev/null)" || return 0
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
# SYSTEM DETECTION
# ===========================================================================
# Sets: SYS_CHIP SYS_TIER SYS_RAM_GB SYS_USABLE_GB SYS_DISK_FREE_GB SYS_CORES
detect_system() {
  SYS_CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
  SYS_CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo '?')"

  local mem_bytes
  mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  SYS_RAM_GB=$(( mem_bytes / 1024 / 1024 / 1024 ))

  # About 70 percent of unified memory is usable for weights.
  SYS_USABLE_GB=$(( SYS_RAM_GB * 70 / 100 ))

  SYS_DISK_FREE_GB="$(df -g "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
  [ -n "$SYS_DISK_FREE_GB" ] || SYS_DISK_FREE_GB=0

  case "$SYS_CHIP" in
    *Ultra*) SYS_TIER="Ultra" ;;
    *Max*)   SYS_TIER="Max" ;;
    *Pro*)   SYS_TIER="Pro" ;;
    *Apple*) SYS_TIER="Base" ;;
    *)       SYS_TIER="Unknown" ;;
  esac
}

bandwidth_note() {
  case "$SYS_TIER" in
    Ultra) echo "Ultra tier. Very high memory bandwidth; dense models are comfortable." ;;
    Max)   echo "Max tier. High memory bandwidth; dense models run well." ;;
    Pro)   echo "Pro tier. Good memory bandwidth; MoE models are fast, dense mid-size models are usable." ;;
    Base)  echo "Base tier. Lower memory bandwidth; strongly prefer MoE models." ;;
    *)     echo "Unrecognised chip. Sizing by memory alone." ;;
  esac
}

# Echo the best catalogue line for a role, or empty if nothing fits.
best_for_role() {
  local role="$1"
  [ -f "$CATALOG" ] || return 0
  awk -F'|' -v budget="$SYS_USABLE_GB" -v ram="$SYS_RAM_GB" -v want="$role" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)
      gsub(/^[ \t]+|[ \t]+$/, "", $5)
      # Two independent gates:
      #   $1 MIN_RAM_GB  the machine class an entry is sensible on. Guards
      #                  against picking a large dense model that merely
      #                  fits but is bandwidth-starved on a lesser chip.
      #   $3 SIZE_GB     must fit the usable weight budget.
      if ($5 == want && ($1 + 0) <= ram && ($3 + 0) <= budget && ($3 + 0) > best) {
        best = $3 + 0
        line = $0
      }
    }
    END { if (line != "") print line }
  ' "$CATALOG"
}

field() { echo "$1" | awk -F'|' -v n="$2" '{gsub(/^[ \t]+|[ \t]+$/, "", $n); print $n}'; }

show_recommendations() {
  detect_system
  ensure_catalog

  cat <<SYSINFO

===========================================================================
  DETECTED SYSTEM
===========================================================================
  Chip:              ${SYS_CHIP}
  Tier:              ${SYS_TIER}
  CPU cores:         ${SYS_CORES}
  Unified memory:    ${SYS_RAM_GB} GB
  Usable for models: ~${SYS_USABLE_GB} GB  (about 70 percent)
  Free disk:         ${SYS_DISK_FREE_GB} GB

  $(bandwidth_note)
===========================================================================

RECOMMENDED MODELS
SYSINFO

  local role line tag size arch verified notes found
  found="no"
  for role in daily coding vision light; do
    line="$(best_for_role "$role")"
    [ -n "$line" ] || continue
    found="yes"
    tag="$(field "$line" 2)"
    size="$(field "$line" 3)"
    arch="$(field "$line" 4)"
    verified="$(field "$line" 6)"
    notes="$(field "$line" 7)"
    printf '\n  %-8s %s\n' "${role}:" "$tag"
    printf '           %s GB, %s' "$size" "$arch"
    if [ "$verified" != "yes" ]; then
      printf '  [tag UNVERIFIED]'
    fi
    printf '\n           %s\n' "$notes"
  done

  if [ "$found" = "no" ]; then
    printf '\n  Nothing in the catalogue fits a %s GB budget.\n' "$SYS_USABLE_GB"
    printf '  Add a smaller entry to %s\n' "$CATALOG"
  fi

  report_catalog_age

  printf 'Catalogue file: %s\n' "$CATALOG"
  printf 'Edit it to change these recommendations.\n\n'
}

# ===========================================================================
# CONFIG FILE
# ===========================================================================
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
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

    --uninstall     Guided teardown. Walks every artifact the script
                    created and asks before removing each one. All
                    destructive prompts default to NO.

    --help          Show this text and exit.

OPTIONS
    --searxng-url URL
                    Use an existing SearXNG instance instead of installing
                    one locally. Skips Colima and Docker entirely.
                    Example: --searxng-url http://192.168.1.23:8899

    --searxng-port PORT
                    Host port for the local SearXNG container.
                    Default ${SEARXNG_HOST_PORT}.

    --webui-port PORT
                    Port for Open WebUI. Default ${WEBUI_PORT}.

    --model TAG     Install this model instead of the catalogue's
                    recommendation. Skips the fit check.

    --no-model      Do not download any model. Useful for setting up the
                    services first and choosing a model later.

    --no-drawthings Skip the Draw Things installation.

COMPONENTS
    Homebrew            package manager, installed if missing
    python@3.11         runtime required by Open WebUI
    Ollama              inference engine, Homebrew binary
    Open WebUI          web front-end, pip, in its own virtualenv
    Colima + docker     container runtime, local SearXNG mode only
    SearXNG             private metasearch, local mode only
    Draw Things         image and video generation, from the Mac App Store

LAYOUT
    ~/.config/llmstack/config             installer settings
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
    Roughly 70 percent of unified memory is usable for model weights; the
    rest goes to macOS, the inference engine and the KV cache. The script
    computes that budget and picks the largest catalogue entry that fits.

    Memory bandwidth matters as much as capacity. Token generation is
    bandwidth-bound, so a mixture-of-experts model, which activates only a
    fraction of its parameters per token, generates far faster than a dense
    model of the same size. On base-tier chips this is decisive.

    Catalogue entries carry a VERIFIED flag. Tags marked no are plausible
    but unconfirmed and may fail to pull; the script warns first and, if a
    pull fails, points at https://ollama.com/library rather than aborting.

SHELL INTEGRATION
    Adds a marked block to ~/.zshrc providing:

      llmstatus     health of every component
      llmstart      start the stack
      llmstop       stop the stack and reclaim memory
      llmupgrade    run this script's --update mode

    The block is delimited by markers so --uninstall can remove it
    cleanly. Run 'exec zsh' after installing to load the commands.

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
  local ollama webui searxng colima

  if curl -s -o /dev/null http://127.0.0.1:11434/api/version; then
    ollama="UP"
  else
    ollama="DOWN"
  fi

  if curl -s -o /dev/null "http://127.0.0.1:${WEBUI_PORT}"; then
    webui="UP"
  else
    webui="DOWN"
  fi

  if curl -s -o /dev/null --max-time 5 "${SEARXNG_URL}/search?q=test&format=json"; then
    searxng="UP"
  else
    searxng="DOWN"
  fi

  printf '\n'
  printf 'Ollama      (:11434)   %s\n' "$ollama"
  printf 'Open WebUI  (:%s)    %s\n' "$WEBUI_PORT" "$webui"

  if [ "$SEARXNG_MODE" = "local" ]; then
    if command -v colima >/dev/null 2>&1 && colima status >/dev/null 2>&1; then
      colima="UP"
    else
      colima="DOWN"
    fi
    printf 'Colima      (runtime)  %s\n' "$colima"
    printf 'SearXNG     (local)    %s\n' "$searxng"
    if [ "$colima" = "DOWN" ]; then
      printf '\nColima needs a console login session. After a reboot with\n'
      printf 'nobody logged in at the screen, it and SearXNG stay down while\n'
      printf 'Ollama and Open WebUI come up normally.\n'
    fi
  else
    printf 'SearXNG     (remote)   %s   %s\n' "$searxng" "$SEARXNG_URL"
  fi
  printf '\n'
  exit 0
}

# ===========================================================================
# UPDATE
# ===========================================================================
do_update() {
  load_config
  ensure_catalog

  local backup_dir="$HOME/.open-webui.backup-$(date +%Y%m%d-%H%M%S)"

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
  brew upgrade ollama || echo "Ollama is already at the latest version."

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
  sleep 20

  cat <<UPDATED

===========================================================================
  UPDATE COMPLETE
===========================================================================
  Backup retained at: $backup_dir
UPDATED

  report_catalog_age

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
  if [ -f "$ZSHRC" ] && grep -qF "$ALIAS_START_MARKER" "$ZSHRC"; then
    if grep -qF "$ALIAS_END_MARKER" "$ZSHRC"; then
      echo "    Removes the marked block. A timestamped backup of .zshrc is"
      echo "    written first."
      if confirm "Remove the block from .zshrc?"; then
        cp "$ZSHRC" "${ZSHRC}.backup-$(date +%Y%m%d-%H%M%S)"
        sed -i '' "/$ALIAS_START_MARKER/,/$ALIAS_END_MARKER/d" "$ZSHRC"
        log "Block removed; a .zshrc backup was kept alongside it."
        echo "    Run 'exec zsh' for this to take effect."
      else
        log "Skipped."
      fi
    else
      warn "Found the start marker but no end marker in .zshrc."
      echo "    Removing it automatically would mean guessing where the block"
      echo "    ends, so this step is being skipped. Remove it by hand from"
      echo "    $ZSHRC, starting at the line:"
      echo "      $ALIAS_START_MARKER"
    fi
  else
    log "No shell block found."
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
  backups="$(find "$HOME" -maxdepth 1 -type d -name '.open-webui.backup-*' 2>/dev/null || true)"
  if [ -n "$backups" ]; then
    echo "$backups" | while read -r b; do
      echo "    $b  ($(du -sh "$b" 2>/dev/null | cut -f1))"
    done
    if confirm "Delete ALL of the backup directories listed above?"; then
      echo "$backups" | while read -r b; do rm -rf "$b"; done
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

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)      show_help ;;
    --install)      MODE="install" ;;
    --update|--upgrade) MODE="update" ;;
    --status)       MODE="status" ;;
    --recommend)    MODE="recommend" ;;
    --uninstall)    MODE="uninstall" ;;
    --searxng-url)
      [ $# -ge 2 ] || error "--searxng-url needs a URL"
      SEARXNG_URL="${2%/}"
      SEARXNG_MODE="remote"
      shift ;;
    --searxng-port)
      [ $# -ge 2 ] || error "--searxng-port needs a port number"
      SEARXNG_HOST_PORT="$2"
      SEARXNG_URL="http://127.0.0.1:${SEARXNG_HOST_PORT}"
      shift ;;
    --webui-port)
      [ $# -ge 2 ] || error "--webui-port needs a port number"
      WEBUI_PORT="$2"
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
  uninstall) uninstall_stack ;;
  update)    do_update ;;
esac

# ===========================================================================
# INSTALL
# ===========================================================================

log "Preflight"

[ "$(uname -s)" = "Darwin" ] || error "This script targets macOS. Detected: $(uname -s)"
[ "$(uname -m)" = "arm64" ]  || error "This script targets Apple Silicon (arm64). Detected: $(uname -m)"

if ! xcode-select -p >/dev/null 2>&1; then
  warn "Xcode Command Line Tools are not installed."
  echo "    The Homebrew installer will prompt for them. Accept the dialog,"
  echo "    wait for it to finish, then re-run this script."
fi

detect_system
ensure_catalog

cat <<DETECTED

===========================================================================
  DETECTED SYSTEM
===========================================================================
  Chip:              ${SYS_CHIP}
  Tier:              ${SYS_TIER}
  Unified memory:    ${SYS_RAM_GB} GB
  Usable for models: ~${SYS_USABLE_GB} GB
  Free disk:         ${SYS_DISK_FREE_GB} GB

  $(bandwidth_note)
===========================================================================
DETECTED

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
    # Nothing in the daily tier fits. Fall back to the light tier rather
    # than leaving a low-memory machine with no model at all.
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

    if [ "$SYS_DISK_FREE_GB" -lt $(( MODEL_SIZE + 10 )) ]; then
      warn "Only ${SYS_DISK_FREE_GB} GB free; about $(( MODEL_SIZE + 10 )) GB is wanted."
      echo "    Free some space, or re-run with --no-model."
    fi
  fi
  report_catalog_age
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
  brew upgrade ollama || echo "Already at the latest version."
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
  python3 -c "import secrets; print(secrets.token_hex(16))" > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
else
  log "Reusing the existing secret key."
fi
WEBUI_SECRET_KEY="$(cat "$SECRET_FILE")"

mkdir -p "$DATA_DIR" "$HOME/.ollama"

# --- SearXNG, local mode ---------------------------------------------------
if [ "$SEARXNG_MODE" = "local" ]; then
  mkdir -p "$SEARXNG_DIR"

  # Docker creates a DIRECTORY at a bind-mount path when the file is absent.
  # Clear that first so the real settings file can be written.
  if [ -d "$SEARXNG_SETTINGS" ]; then
    log "Removing a stale settings.yml directory left behind by Docker"
    rmdir "$SEARXNG_SETTINGS" 2>/dev/null || rm -rf "$SEARXNG_SETTINGS"
  fi

  if [ ! -f "$SEARXNG_SETTINGS" ]; then
    log "Writing the SearXNG configuration"
    SEARXNG_SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
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
      if curl -s "http://127.0.0.1:${SEARXNG_HOST_PORT}/search?q=test&format=json" >/dev/null 2>&1; then
        log "SearXNG is answering."
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
    if curl -s http://127.0.0.1:11434/api/version >/dev/null; then break; fi
    sleep 1
    [ "$i" -eq 30 ] && error "The Ollama API did not respond after 30 seconds."
  done

  if ollama list | awk '{print $1}' | grep -qx "$MODEL_TAG"; then
    log "Model already present: $MODEL_TAG"
  else
    log "Pulling $MODEL_TAG. This is a large download and will take a while."
    if ! ollama pull "$MODEL_TAG"; then
      warn "The pull failed for $MODEL_TAG"
      echo "    The tag may have changed or may never have existed."
      echo "    Browse current tags at https://ollama.com/library, then edit"
      echo "    $CATALOG and re-run, or pull one by hand:"
      echo "      ollama pull MODEL_TAG"
      echo ""
      echo "    Everything else installed correctly."
    fi
  fi
fi

# --- config ----------------------------------------------------------------
write_config

# --- shell integration -----------------------------------------------------
log "Configuring shell commands"
if grep -qF "$ALIAS_START_MARKER" "$ZSHRC" 2>/dev/null; then
  log "Shell commands already present in .zshrc; leaving them alone."
else
  log "Adding llmstatus, llmstart, llmstop and llmupgrade to .zshrc"
  SCRIPT_ABS="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  {
    printf '\n%s\n' "$ALIAS_START_MARKER"
    printf '# Installed by llmstack-macos.sh. Settings live in\n'
    printf '# ~/.config/llmstack/config and are read at call time.\n'
    printf 'LLMSTACK_SCRIPT="%s"\n' "$SCRIPT_ABS"
    cat <<'ZSH_BODY'

_llmstack_conf() {
  SEARXNG_MODE="local"
  SEARXNG_URL="http://127.0.0.1:8888"
  WEBUI_PORT="8080"
  [ -f "$HOME/.config/llmstack/config" ] && . "$HOME/.config/llmstack/config"
}

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

llmstatus() {
  _llmstack_conf
  local ollama webui searxng colima
  if curl -s -o /dev/null http://127.0.0.1:11434/api/version; then
    ollama="UP"
  else
    ollama="DOWN"
  fi
  if curl -s -o /dev/null "http://127.0.0.1:${WEBUI_PORT}"; then
    webui="UP"
  else
    webui="DOWN"
  fi
  if curl -s -o /dev/null --max-time 5 "${SEARXNG_URL}/search?q=test&format=json"; then
    searxng="UP"
  else
    searxng="DOWN"
  fi
  printf 'Ollama      (:11434)   %s\n' "$ollama"
  printf 'Open WebUI  (:%s)    %s\n' "$WEBUI_PORT" "$webui"
  if [ "$SEARXNG_MODE" = "local" ]; then
    if colima status >/dev/null 2>&1; then colima="UP"; else colima="DOWN"; fi
    printf 'Colima      (runtime)  %s\n' "$colima"
    printf 'SearXNG     (local)    %s\n' "$searxng"
    if [ "$colima" = "DOWN" ]; then
      printf '\nColima needs a console login session. After a reboot with\n'
      printf 'nobody logged in at the screen, it and SearXNG stay down.\n'
    fi
  else
    printf 'SearXNG     (remote)   %s   %s\n' "$searxng" "$SEARXNG_URL"
  fi
}

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
curl -s -o /dev/null -w "Ollama:     %{http_code}\n" http://127.0.0.1:11434/api/version || true

log "Waiting for Open WebUI on :${WEBUI_PORT}. First start takes 30 to 60 seconds."
for i in $(seq 1 45); do
  if curl -s -o /dev/null "http://127.0.0.1:${WEBUI_PORT}"; then
    echo "Open WebUI: 200"
    break
  fi
  sleep 2
  [ "$i" -eq 45 ] && warn "Not answering yet. Check ${DATA_DIR}/openwebui.err.log"
done

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
