# llmstack-macos

A single shell script that turns a Mac into a private, self-hosted AI workstation.

Inference, a web front-end, and private web search — all running locally, all starting automatically at boot, without enabling auto-login.

```bash
./llmstack-macos.sh --recommend   # see what your Mac can run
./llmstack-macos.sh               # install it
```

---

## Contents

- [What it installs](#what-it-installs)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Modes](#modes)
- [Options](#options)
- [How models are chosen](#how-models-are-chosen)
- [The model catalogue](#the-model-catalogue)
- [Keeping the catalogue current](#keeping-the-catalogue-current)
- [Startup behaviour, and one real limitation](#startup-behaviour-and-one-real-limitation)
- [Remote SearXNG](#remote-searxng)
- [Shell commands](#shell-commands)
- [Syncing models](#syncing-models)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [File layout](#file-layout)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Design notes](#design-notes)
- [Changelog](#changelog)
- [License](#license)

---

## What it installs

| Component | Role | Managed as |
|---|---|---|
| [Ollama](https://ollama.com) | Inference engine | System LaunchDaemon |
| [Open WebUI](https://github.com/open-webui/open-webui) | Web front-end | System LaunchDaemon |
| [SearXNG](https://github.com/searxng/searxng) | Private metasearch | Container (optional/remote) |
| [Draw Things](https://drawthings.ai) | Image & video generation | Mac App Store app (optional) |
| Homebrew, Python 3.11 | Dependencies | Installed if missing |
| Colima + docker CLI | Container runtime | Local SearXNG mode only |

Nothing leaves the machine except web searches, and those go through your own SearXNG instance rather than a commercial search API.

---

## Requirements

- **macOS on Apple Silicon** (M1 or later). Intel Macs are not supported.
- An **administrator account** — `sudo` is required to install system LaunchDaemons.
- **Xcode Command Line Tools** — the Homebrew installer prompts for these if missing.
- Signed in to the **Mac App Store**, if you want the Draw Things step.
- **Free disk space** for the model, typically 25–45 GB.

The script checks the first two itself and refuses to run on the wrong architecture rather than failing halfway through.

---

## Quick start

```bash
# Download the latest release
curl -fLO https://github.com/cautionespn/MacOS-Local-LLM-Stack/releases/latest/download/llmstack-macos.sh
chmod +x llmstack-macos.sh

# Inspect the machine first. Installs nothing, downloads nothing.
./llmstack-macos.sh --recommend

# Install.
./llmstack-macos.sh

# Load the shell commands.
exec zsh
```

Then open the URL the script prints — `http://<your-hostname>.local:8080` — and **create the admin account immediately**. Open WebUI grants owner rights to the first account created, so do this before anyone else on your network can.

Finally, turn on web search: **Admin → Settings → Web Search**, set *Enable* to on, choose `searxng` as the engine, and enter the SearXNG URL. The URL field only appears *after* you select the engine.

---

## Modes

| Mode | What it does |
|---|---|
| `--install` | Install or repair. Default when no mode is given. |
| `--update` | Update Ollama, Open WebUI, and the SearXNG image. Backs up data first, then reports how stale the model catalogue has become. `--upgrade` is a synonym. |
| `--status` | Print component health. Changes nothing. |
| `--recommend` | Print detected hardware and suitable models. Installs nothing. |
| `--sync-models` | Pull the recommended models you choose, then offer each other installed model for removal. Interactive; every prompt defaults to no. See [Syncing models](#syncing-models). |
| `--uninstall` | Guided teardown, confirming every step. |
| `--check-models` | Validate every catalogue tag against the Ollama registry and fix the VERIFIED column in place. |
| `--refresh-catalog` | Write `models.catalog.proposed`: tags revalidated in place, plus newer variants in your families as `# REVIEW:` suggestions. Never touches the live file. Add `--discover` to also scan for new families. |
| `--refresh-catalog-apply` | As above, then replace the live catalogue after a backup and confirmation, setting `Last-Updated` to today. Accepts `--discover`. |
| `--version` | Print the script version and exit. |
| `--help` | Full documentation. |

Every mode is safe to re-run. The installer checks state before acting and never overwrites existing data.

---

## Options

```
--searxng-url URL      Use an existing SearXNG instance instead of installing
                       one. Skips Colima and Docker entirely.
--searxng-port PORT    Host port for the local SearXNG container (default 8888).
--webui-port PORT      Port for Open WebUI (default 8080).
--model TAG            Install this model instead of the catalogue's pick.
                       Skips the fit check.
--no-model             Install the services without downloading a model.
--no-drawthings        Skip Draw Things.
--discover             With --refresh-catalog / --refresh-catalog-apply only:
                       also scrape the Ollama library for new model families.
                       Fail-soft — a failed scrape still yields a proposal.
```

**Settings carry over between runs.** The installer reads `~/.config/llmstack/config` first, then applies the options you pass, so a plain re-run keeps your SearXNG URL, ports and bind address. `--searxng-port` switches a remote install back to local SearXNG; `--searxng-url` wins if you pass both. The `DETECTED SYSTEM` summary shows the web-search and Open WebUI settings the run will use.

Ports are validated as integers in the range 1–65535; an invalid value is rejected before anything is installed. The script also checks for port conflicts before installing and warns if the target port is already in use, naming the process that holds it.

Examples:

```bash
# Point at a SearXNG already running on a Linux box
./llmstack-macos.sh --searxng-url http://192.168.1.23:8899

# Services now, model later
./llmstack-macos.sh --no-model --no-drawthings

# Override the recommendation
./llmstack-macos.sh --model qwen3.8:27b
```

---

## How models are chosen

The script reads your chip, memory, memory bandwidth, and free disk. Within each role it then picks the **largest catalogue entry that passes three gates**:

1. **Memory budget** — roughly 70% of unified memory is usable for model weights. The rest goes to macOS, the inference engine, and the KV cache. A 64 GB Mac has about a 44 GB budget.
2. **Machine class** — the machine has at least the entry's `MIN_RAM_GB`.
3. **Dense speed** — *dense* entries only: the chip's memory bandwidth must be able to generate at 8 tok/s or better. MoE entries are exempt.

**Why the third gate exists.** Token generation on Apple Silicon is memory-bandwidth-bound, not compute-bound. A dense model reads every weight for every token, so its speed is roughly bandwidth ÷ model size. *Fitting* and *running well* are different things: a 43 GB dense 70B fits a 64 GB M4 Pro's 44 GB budget, but at 273 GB/s it would generate at reading speed at best. A mixture-of-experts (MoE) model reads only its active experts — `qwen3.6:35b-a3b` has 35B parameters but about 3B active per token — so it stays fast on any chip while still needing all of its weights resident.

The dense cap is `bandwidth × 65% ÷ 8 tok/s` (both constants are at the top of the script). Bandwidth comes from a built-in table of Apple's published figures:

| Chip | Bandwidth | Dense cap |
|---|---|---|
| M1 | 68 GB/s | ~5.5 GB |
| M2, M3 | 100 GB/s | ~8 GB |
| M4 | 120 GB/s | ~10 GB |
| M5; M6 16 GB / 24–32 GB | 153 / 170 GB/s | ~12 / ~14 GB |
| M3 Pro | 150 GB/s | ~12 GB |
| M1 Pro, M2 Pro | 200 GB/s | ~16 GB |
| M4 Pro | 273 GB/s | ~22 GB |
| M5 Pro | 307 GB/s | ~25 GB |
| M3 Max 14-core / 16-core | 300 / 400 GB/s | ~24 / ~32 GB |
| M1 Max, M2 Max | 400 GB/s | ~32 GB |
| M4 Max 14-core / 16-core | 410 / 546 GB/s | ~33 / ~44 GB |
| M5 Max 32-GPU / 40-GPU | 460 / 614 GB/s | ~37 / ~50 GB |
| M1/M2 Ultra, M3 Ultra | 800 / 819 GB/s | ~65 GB |
| M5 Ultra | 1200 GB/s | ~97 GB |

Chips sold in two bandwidth bins under one name are told apart by CPU core count (M3 Max, M4 Max), GPU core count from `ioreg` with memory size as fallback (M5 Max), or memory size (M6). A newer chip not in the table is assumed to match the newest known generation for its tier. On a non-Apple host the gate is off and sizing uses memory alone. `--recommend` prints the detected bandwidth and the resulting cap.

**The largest passing entry wins — there is no blanket "prefer MoE" rule.** The speed gate already removes dense models exactly where bandwidth would make them slow. Beyond that, a dense model can be far better than any MoE that fits: `qwen3.8:27b` (dense) outscores `qwen3.6:35b-a3b` (MoE) by a wide margin on independent indexes, and on an M4 Pro or faster it runs fine.

Roughly what you can expect from the shipped catalogue:

| Machine | Daily | Reasoning | Coding |
|---|---|---|---|
| 8 GB | `qwen3.5:4b` | `qwen3.5:4b` | `qwen3.5:4b` |
| 16 GB | `gemma4:12b` | `gemma4:12b` | `qwen3.5:9b` |
| 24–32 GB | `gemma4:26b-a4b-it-qat` | `gemma4:26b-a4b-it-qat`, or `qwen3.8:27b` on a 32 GB M4 Pro+ | `devstral-small-2:24b` on Pro+; `qwen3.5:9b` on base chips |
| 36 GB+ | `qwen3.6:35b-a3b` | `qwen3.8:27b` on M4 Pro/Max/Ultra or M5 Pro+; `gemma4:26b-a4b-it-qat` on slower chips | `qwen3.6:35b-a3b-coding` |

Machines above 64 GB get the same picks as 36 GB. As of September 2026 no locally runnable model beat these picks in the 25–90 GB range. The larger options found — `qwen3.8-flash-next`, `laguna-s-2.1` — were an experimental preview or needed special builds, so they are left for you to add by hand.

---

## The model catalogue

Recommendations live in a plain text file you own:

```
~/.config/llmstack/models.catalog
```

It's written on first run and **never overwritten afterwards**, so your edits survive script upgrades. Format is pipe-delimited with `#` comments:

```
MIN_RAM_GB | TAG | SIZE_GB | ARCH | ROLE | VERIFIED | NOTES
```

```
32|qwen3.6:35b-a3b|23|moe|daily|yes|Qwen 3.6 35B MoE, 3B active. Fast on every chip tier.
```

### The header lines

```
# Last-Updated: 2026-09-30
# Catalogue-Generation: 3.4.0
```

They answer two different questions.

- **`Last-Updated`** — when a person last reviewed the file. It changes only when you edit it, or when you confirm `--refresh-catalog-apply`. The script grades the file's age from it.
- **`Catalogue-Generation`** — which built-in catalogue the file descends from: the script version in which the built-in rows last changed. `--sync-models` offers to replace your file when this marker is missing or older than the script's. If you maintain your own catalogue, keep the marker current and you won't be asked.

Before v3.5.1 there was only the date, and the refresh tooling stamped it with today's date on every proposal. A catalogue could therefore look brand new while holding a generation-old model list.

The age grading from `Last-Updated`:

| Age | Reported as |
|---|---|
| under 90 days | recent enough, no action |
| 90–180 days | worth a look, newer models may fit better |
| over 180 days | very likely stale, review the library |

**Update the date when you edit the file.** That's the whole mechanism — it exists because local model releases move fast enough that a six-month-old recommendation is usually wrong.

### The VERIFIED column

`yes` means the tag was confirmed to exist in the Ollama registry. `no` means it's plausible but unconfirmed.

The script warns before pulling an unverified tag, and if the pull fails it points you at [ollama.com/library](https://ollama.com/library) and continues rather than aborting — everything else stays installed.

If you add entries yourself, mark them `no` until you've confirmed the tag exists at [ollama.com/library](https://ollama.com/library), or run `--check-models` to have the script check and correct the column for you.

`SIZE_GB` is the download size of that exact tag and may be a decimal (`7.6`). Because the largest passing entry wins, keep size tracking quality within a role, and don't list several quantizations of one model — the heaviest would always win.

### Catalogue contents (v3.4.0)

| Role | Tags, smallest machine first |
|---|---|
| Light | `granite4.2:3b` |
| Daily | `qwen3.5:4b`, `gemma4:12b`, `gemma4:26b-a4b-it-qat` (MoE), `qwen3.6:35b-a3b` (MoE) |
| Reasoning | `qwen3.5:4b`, `gemma4:12b`, `gemma4:26b-a4b-it-qat` (MoE), `qwen3.8:27b` |
| Coding | `qwen3.5:4b`, `qwen3.5:9b`, `devstral-small-2:24b`, `qwen3.6:35b-a3b-coding` (MoE) |
| Vision | `qwen3.5:4b`, `gemma4:12b`, `gemma4:26b-a4b-it-qat` (MoE), `qwen3.6:35b-a3b` (MoE) |

Every tag was checked on [ollama.com/library](https://ollama.com/library) on 2026-09-30, and CI re-checks each against the registry on every push. `qwen3.6:35b-a3b-coding` is the same weights as `qwen3.6:35b-a3b` with a coding sampling preset, so pulling both costs no extra disk.

### Upgrading from an earlier version

Your existing catalogue is never overwritten silently, so after upgrading the script you keep the old model list. The bandwidth gate applies to it immediately, but the new models won't appear until the file is refreshed. The easy way is `--sync-models`: when your catalogue is older than the one built into the script, it offers to back yours up and replace it, then walks you through pulling the new picks.

To do it by hand instead:

```bash
mv ~/.config/llmstack/models.catalog ~/.config/llmstack/models.catalog.pre-3.4
./llmstack-macos.sh --recommend    # writes the current built-in catalogue and shows the picks
```

Either way, copy any rows you added yourself back from the backup afterwards.

### Keeping the catalogue current

Model tags come and go — a tag that pulled last month can vanish when a
family is renamed or reorganised. Three commands keep the catalogue honest,
all built on the Ollama registry manifest endpoint (a live tag returns HTTP
`200`, a missing tag `404`, no auth required):

| Command | What it does |
|---|---|
| `--check-models` | Probes every catalogue tag. Corrects the VERIFIED column in place (`200` → `yes`, `404` → `no`) after backing up the file. Flags dead tags. |
| `--refresh-catalog` | Writes `models.catalog.proposed` alongside the live file — never touching the live one. Walks the file in order, re-validating each row where it stands and commenting out dead ones in place, then suggests newer size variants within your existing families as `# REVIEW:` comments. Review it, then `mv` it into place if you approve. |
| `--refresh-catalog-apply` | Same, but replaces the live catalogue with the proposal after a backup and a confirmation prompt, and sets `Last-Updated` to today — confirming the diff is your review. |

`--update` runs `--check-models` automatically, so a routine update also
corrects the VERIFIED column and warns you about retired tags.

**Discovery.** By default `--refresh-catalog` only looks *within* the model
families already in your catalogue — the reliable path, since it never leaves
the manifest API. Add `--discover` to also scrape `ollama.com/library` for
*new* families you don't yet track. That scrape is the one fragile piece
(HTML changes silently), so it is wholly fail-soft: if it fails, you still get
a proposal built from validated tags and family variants, just without the
newly-discovered families.

**Everything here is fail-soft and offline-safe.** If the registry can't be
reached, each command says so and changes nothing — which is also why they're
safe to run in CI with no network access. Nothing ever reaches the catalogue
without a manifest confirmation, so a broken scrape or a bad guess can't
introduce a tag that doesn't exist.

Every candidate, whether a variant probed within a family or a family found
by discovery, is confirmed against the registry before it appears in the
proposal. It arrives as a comment, with every judgment column marked
`REVIEW`:

```
# REVIEW: REVIEW|qwen3.6:27b|REVIEW|REVIEW|REVIEW|yes|Confirmed in the registry. Set MIN_RAM, SIZE, ARCH, ROLE and NOTES.
```

To adopt one, fill in the fields and delete the leading `# REVIEW: `.
Until you do, it can never be recommended. A suggestion already in your file
is not repeated on the next refresh. Separately, the script never picks any
live row whose `MIN_RAM` or `SIZE` isn't a number, so a half-edited row is
ignored too. The tool finds and confirms; you decide what belongs and how
it's classified.

Before v3.5.1 the refresh tooling moved every comment to the top of the
file, which cut section headings off from their rows. It also added
suggestions as live rows with their judgment fields unset. If your
catalogue has been through a few refreshes, `--sync-models` will offer to
replace it with a clean copy. Your old file is kept as a backup.

---

## Startup behaviour, and one real limitation

**Ollama and Open WebUI survive reboots on a headless machine.** They're installed as *system* LaunchDaemons: they load in launchd's `system` domain at boot, require no console login, and are privilege-dropped via `UserName` so they run as you rather than as root. An SSH-only Mac comes back fully after a power cut, with no auto-login enabled.

**SearXNG in local mode cannot do this.** This is a macOS constraint, not a shortcoming of the script:

- **Docker Desktop** is a GUI application. Launching it over SSH fails — launchd rejects it with `Domain does not support specified action`.
- **Colima** manages a per-user virtual machine and socket, and is [not supported as a root or system-level daemon](https://github.com/abiosoft/colima). Running it as one starts the service but leaves it non-functional.

So in local mode, Colima and SearXNG start in the *user* domain and won't run after a reboot until someone logs in at the console. Ollama and Open WebUI will already be up; web search reports DOWN until then.

`llmstatus` shows Colima as its own line and explains this when it's down, so a dead search doesn't look like a broken container.

**If reboot-durable search matters, don't fight macOS — move SearXNG.** See below.

---

## Remote SearXNG

Run SearXNG on a Linux host, where Docker is a real systemd service that starts at boot with no session, and point this Mac at it:

```bash
./llmstack-macos.sh --searxng-url http://192.168.1.23:8899
```

This mode installs **no container runtime at all** on the Mac — no Colima, no docker CLI. The whole stack then survives reboots cleanly.

The URL is saved, so later runs (including a plain `./llmstack-macos.sh`) keep using it. To go back to a local SearXNG, re-run with `--searxng-port 8888`. (Before v3.6.2 a plain re-run silently switched back to local.)

A minimal Compose definition for the Linux side:

```yaml
services:
  searxng:
    image: ghcr.io/searxng/searxng:latest
    container_name: searxng
    restart: unless-stopped
    ports:
      - "8899:8080"
    volumes:
      - ./settings.yml:/etc/searxng/settings.yml:ro
    environment:
      - SEARXNG_BASE_URL=http://<host-ip>:8899/
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider",
             "http://127.0.0.1:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
```

With `settings.yml`:

```yaml
use_default_settings: true
server:
  secret_key: "generate-with-python3-secrets-token_hex-16"
  limiter: false
  image_proxy: true
search:
  formats:
    - html
    - json
```

The `json` format is **required** — Open WebUI parses results programmatically and gets nothing without it.

---

## Shell commands

Installed into `~/.zshrc` inside a marked block, so the uninstaller can remove them cleanly.

| Command | Does |
|---|---|
| `llmstatus` | Health of every component |
| `llmstart` | Start the stack |
| `llmstop` | Stop everything and reclaim memory |
| `llmupgrade` | Runs the script's `--update` mode |

```
$ llmstatus
Ollama      (:11434)   UP
Open WebUI  (:8080)    UP
SearXNG     (local)    UP
Colima      (runtime)  UP
```

`llmstop` is the point of the whole arrangement: a large model holds tens of gigabytes resident. When you need that memory for something else, stop the stack and start it again later.

Settings are read from `~/.config/llmstack/config` at call time, not baked into `.zshrc` — so changing the SearXNG URL means editing one line in one file.

The block is delimited by start and end markers. Re-running the installer **replaces** it rather than appending a second copy, backing up `.zshrc` first, and it recognises markers written by earlier versions of this tooling.

> **Use `exec zsh`, not `source ~/.zshrc`.** Sourcing cannot clear definitions already resident in a running shell. If an older install defined these as aliases, sourcing the new file mid-session produces `defining function based on alias` followed by a parse error. See [Troubleshooting](#defining-function-based-on-alias-llmstop--parse-error-in-zshrc).

---

## Syncing models

```bash
./llmstack-macos.sh --sync-models
```

`--recommend` tells you what suits the machine; `--sync-models` makes the installed models match it. With Ollama running, it:

1. **Offers to replace an out-of-date catalogue.** If your catalogue's `Catalogue-Generation` marker is missing or older than the script's, it explains why and offers to back it up and replace it. The date line plays no part in this.
2. **Shows the current picks**, each with its roles, size and state:
   - `not installed`
   - `current`: installed, and the same build the registry serves
   - `outdated`: installed, but an older build of that tag
   - `unchecked`: installed, but the registry couldn't be reached
3. **Asks which missing picks to pull and which outdated ones to update**, once per model. A model serving several roles is asked about once.
4. **Checks free disk** against the chosen downloads plus 10 GB of headroom, and stops with nothing changed if it's short.
5. **Pulls everything you chose.** If any pull fails, nothing is removed.
6. **Only then offers each other installed model for removal, one at a time.** Embedding models get an explicit warning, because Open WebUI may use them for document search.

**How "outdated" is detected.** The ID `ollama list` shows is the start of the SHA-256 of the model's local manifest, and the registry serves that manifest byte for byte. If the digest of the registry's current manifest differs from your ID, a newer build has been published under the same tag. Checking takes one small request per pick, with no download. This matters because tags move: a `qwen3.6:35b-a3b` pulled seven weeks earlier had different weights from the one Ollama now serves. It also stopped sharing weights with the `-coding` tag, costing a second 22 GB copy until it was updated.

Every prompt defaults to no, so pressing Enter never downloads or deletes anything. A pick you decline to pull is never offered for removal — it's still a recommendation.

Old and new models coexist until the removal step, so you need room for both. If there isn't room, run it once declining every pull and remove what you don't need, then run it again to pull.

The size shown for each pick is its full download. Tags that share weights (like `qwen3.6:35b-a3b` and `qwen3.6:35b-a3b-coding`) are counted twice by the disk check, though Ollama stores the weights once — the check errs on the side of caution.

If you remove the model Open WebUI uses as its default, choose a new default there. Existing chats remain readable.

---

## Updating

```bash
./llmstack-macos.sh --update
# or just:  llmupgrade
```

In order, it:

1. Backs up Open WebUI data to a timestamped directory
2. Stops both daemons
3. Upgrades Ollama via Homebrew
4. Upgrades Open WebUI via pip
5. Re-pulls and recreates the SearXNG container (local mode only)
6. Restarts everything
7. **Reports the catalogue's age** and whether a better-fitting model now exists for this machine

If the Open WebUI upgrade fails, the script restarts the existing version rather than leaving you with a dead stack, and tells you where the backup is.

If you interrupt a model pull with Ctrl-C, the script reports that the pull was interrupted and can be resumed by re-running — rather than exiting silently with a partial download.

> Backups are never auto-deleted. `--uninstall` offers to clear them; otherwise they accumulate, so prune them yourself occasionally.

---

## Uninstalling

```bash
./llmstack-macos.sh --uninstall
```

Walks every artifact one at a time. **Every prompt defaults to no** — pressing Enter skips the step. Deleting Open WebUI data requires two separate confirmations.

Never touched:

- **Homebrew, Python 3.11, and `mas`** — shared dependencies other software almost certainly uses
- **Remote SearXNG** — not this machine's to remove
- Anything you decline

Colima removal is its own prompt, since another project on the machine may want containers.

---

## File layout

```
~/.config/llmstack/config              installer settings
~/.config/llmstack/models.catalog      model catalogue (yours to edit)
~/.config/llmstack/openwebui-secret    persisted secret key, mode 0600
~/openwebui-venv/                      Open WebUI virtualenv
~/.local/share/open-webui/data/        accounts, chats, uploads, settings
~/.ollama/models/                      downloaded models
~/.searxng/settings.yml                SearXNG config (local mode)
/Library/LaunchDaemons/com.local.ollama.plist
/Library/LaunchDaemons/com.local.openwebui.plist
```

### Ports

| Service | Bind | Reachable from |
|---|---|---|
| Ollama | `127.0.0.1:11434` | this machine only |
| Open WebUI | `0.0.0.0:8080` | the LAN |
| SearXNG | `127.0.0.1:8888` | this machine only |

Open WebUI binds to all interfaces deliberately so phones and laptops can use it. **On a machine that joins untrusted networks, change this:** `--webui-port` doesn't alter the bind address, so set `WEBUI_BIND="127.0.0.1"` in `~/.config/llmstack/config` and re-run the installer, which rewrites the plist and reloads the daemon.

The shell functions read `WEBUI_BIND` from the same file, so they follow the change.

---

## Security

### The Open WebUI secret key

The secret key is stored in `~/.config/llmstack/openwebui-secret` (mode 0600) and passed to the daemon via the `EnvironmentVariables` dict in the system LaunchDaemon plist. System LaunchDaemon plists are readable by all users (mode 0644) — this is standard for macOS system daemons, but it means **any local user can read the secret key from the plist**.

On a single-user Mac this is a non-issue. On a multi-user machine where untrusted accounts exist, consider one of:

- **Set `WEBUI_SECRET_KEY` in the user's shell profile** instead of the plist, and remove the key from the plist's `EnvironmentVariables` dict. The daemon inherits it from the user's environment via `UserName` privilege drop.
- **Move the key to a file the daemon reads at startup**, and remove it from the plist entirely.
- **Restrict plist permissions** with `sudo chmod 640` and a dedicated group, though this can cause launchd to refuse to load the daemon on some macOS versions.

### Plist ownership

The script sets both plist files to `root:wheel` with mode `0644`, matching macOS conventions for system LaunchDaemons.

---

## Troubleshooting

Every item here is a failure that actually occurred during development, with the diagnosis that resolved it.

### `defining function based on alias 'llmstop'` / parse error in `.zshrc`

Older versions of this tooling defined `llmstop` and `llmstart` as **aliases**; current versions define them as **functions**. zsh expands a live alias while parsing a function of the same name, so the definition collapses into garbage and the parse fails.

Two separate causes, and they need different fixes.

**Stale definitions in the running shell.** Sourcing `.zshrc` cannot remove an alias that's already in memory — it persists until the shell is replaced. If the file is correct but the error persists:

```bash
alias llmstop        # prints something? it's stale session state
exec zsh             # replaces the shell; source is not enough
```

**A leftover block on disk.** Check for more than one:

```bash
grep -n 'LLM Stack Control\|alias llmstop\|^llmstop()' ~/.zshrc
```

Current versions of the script detect and remove blocks left by earlier versions, so re-running `--install` resolves this. Definitions found *outside* a marked block can't be removed automatically — the script reports them with line numbers for you to delete.

If nothing turns up in `.zshrc` itself, check what oh-my-zsh loads implicitly. With `ZSH_CUSTOM` unset it defaults to `$ZSH/custom`, and **every `.zsh` file there is sourced at startup**:

```bash
grep -rn "llmstop\|llmstart" ~/.oh-my-zsh/custom/ ~/.zshenv ~/.zprofile ~/.zlogin 2>/dev/null
```

### Open WebUI won't start: `Read-only file system: '/.webui_secret_key'`

Open WebUI is trying to write its session key to the filesystem root because `WEBUI_SECRET_KEY` isn't reaching the process. The script sets it in the daemon's `EnvironmentVariables`. Confirm it arrived:

```bash
sudo launchctl print system/com.local.openwebui | grep -A6 environment
```

If the key is absent, the value probably contained characters `launchctl` mishandled. Use hex only:

```bash
python3 -c "import secrets; print(secrets.token_hex(16))"
```

Base64 keys with `+` and `=` are silently dropped from the plist environment.

### Web search fails with `Too many open files`

macOS's default file-descriptor limit is too low for Open WebUI under search load. Both `SoftResourceLimits` and `HardResourceLimits` must be set to 65536 in the plist — the script does this. Verify:

```bash
sudo launchctl print system/com.local.openwebui | grep -A3 "resource limits"
```

### Your login stopped working after reinstalling

Almost certainly a `DATA_DIR` mismatch, not lost data. Open WebUI defaults to `~/.local/share/open-webui/data`, but an explicitly-set `DATA_DIR` elsewhere makes it create a *fresh, empty* database — your accounts are still in the original one. Find them:

```bash
find "$HOME" -name "webui.db" -exec ls -la {} \;
```

Point the daemon's `DATA_DIR` at the directory containing the *populated* database. Note that `webui.db-wal` must travel with `webui.db` — it holds recent writes not yet checkpointed, so copy the whole directory rather than the `.db` alone.

To check which account exists:

```bash
sqlite3 ~/.local/share/open-webui/data/webui.db "SELECT email FROM auth;"
```

To reset its password:

```bash
htpasswd -nBC 10 "" | tr -d ':\n'     # prompts, prints a bcrypt hash
sqlite3 ~/.local/share/open-webui/data/webui.db << 'EOF'
UPDATE auth SET password='<paste-hash>' WHERE email='<your-email>';
EOF
```

The quoted heredoc matters — it stops the shell from mangling the `$` characters in a bcrypt hash.

### `Bootstrap failed: 125: Domain does not support specified action`

You're in an SSH session and trying to load a *user* agent `gui/$(id -u)/...`). Without a console login there's no GUI domain. Check:

```bash
launchctl print gui/$(id -u) >/dev/null 2>&1 && echo reachable || echo "NOT reachable"
```

This is exactly why the script uses system daemons. If you see this, you're targeting the wrong domain — use `sudo launchctl bootstrap system ...`.

### `Bootstrap failed: 5: Input/output error`

The service is already loaded. `bootout` first, wait, then `bootstrap`:

```bash
sudo launchctl bootout system/com.local.openwebui 2>/dev/null
sleep 2
sudo launchctl bootstrap system /Library/LaunchDaemons/com.local.openwebui.plist
```

### SearXNG container restarts forever

Check whether `settings.yml` became a *directory*:

```bash
ls -ld ~/.searxng/settings.yml
```

Docker creates a directory at any bind-mount path that doesn't exist yet. If a container started before the config file was written, you get a directory that then blocks the file from being created. Remove it and re-run:

```bash
rmdir ~/.searxng/settings.yml
```

The script guards against this, but a manual `docker run` can still trigger it.

### SearXNG starts but nothing answers on the mapped port

The container listens on **8080** internally regardless of any `port:` setting in `settings.yml`. Map `8888:8080`, not `8888:8888`. Confirm with `docker logs searxng` — it prints the port it bound.

### Web search returns results in the browser but not in Open WebUI

SearXNG must offer `json` as a response format, or Open WebUI's programmatic
queries receive nothing. The config the script writes includes it, but a
hand edit can remove it. Check:

```bash
grep 'json' ~/.searxng/settings.yml
```

If absent, add it under `search: formats:`:

```yaml
search:
  formats:
    - html
    - json
```

Then restart the container: `docker restart searxng`

### Port already in use

The script checks for port conflicts before installing and warns if `--webui-port` or `--searxng-port` targets a port already in use, naming the process that holds it. If you encounter this:

```bash
lsof -nP -iTCP:<port> -sTCP:LISTEN   # find what holds it
```

Then re-run with a different port:

```bash
./llmstack-macos.sh --webui-port 3000
```

### `open -a Docker` fails from SSH

Expected — see [the limitation section](#startup-behaviour-and-one-real-limitation). Docker Desktop can't launch into the Aqua session from SSH. Use Colima (which the script installs) or move SearXNG to a Linux host.

### The recommendation is smaller than my memory allows

Probably the dense-speed gate working as intended. `--recommend` prints `Memory bandwidth` and `Dense model cap`. A dense entry larger than the cap is skipped because it would generate slower than 8 tok/s on your chip. You can:

- Pull the larger model anyway: `ollama pull <tag>`, or install with `--model <tag>`, which skips the fit checks.
- Lower `DENSE_MIN_TPS` at the top of the script if slower generation is acceptable to you.

If the bandwidth shown is wrong for your chip, compare `sysctl -n machdep.cpu.brand_string` and `sysctl -n hw.ncpu` against the table in [How models are chosen](#how-models-are-chosen), and open an issue.

### Model pull fails

The tag is probably wrong or retired. Check [ollama.com/library](https://ollama.com/library), then correct `~/.config/llmstack/models.catalog` and bump its `Last-Updated` line. Everything else stays installed; just pull manually:

```bash
ollama pull <correct-tag>
```

If you interrupt a pull with Ctrl-C, re-running the script (or pulling again) resumes from where Ollama left off — partial downloads are not wasted.

### Script exited with an error partway through

v3.1 adds an error trap that fires on unexpected exit during install. If the script fails mid-way, it prints a summary showing:

- The exit code
- Where to find the daemon logs (Ollama and Open WebUI error logs)
- A reminder that re-running is safe (the script is idempotent)

Check the logs, fix the cause, and re-run:

```bash
cat ~/.ollama/ollama.daemon.err.log
cat ~/.local/share/open-webui/data/openwebui.err.log
./llmstack-macos.sh
```

---

## FAQ

**Does anything leave my machine?**

Only web searches, and only through your own SearXNG instance. Model inference is entirely local. No API keys, no telemetry, no per-token billing.

**Can I reach this from my phone?**

Yes. Open WebUI binds to `0.0.0.0`, so `http://<hostname>.local:8080` works from anything on the same network. Don't expose it to the internet without putting authentication in front of it.

**Why is it slow?**

Most likely a dense model on a bandwidth-limited chip. Try an MoE model, or check that you haven't overridden the catalogue with something too large. `--recommend` shows your chip's tier and what suits it.

**Can I run multiple models?**

Yes — `ollama pull` as many as you like and switch in Open WebUI's model picker. Ollama loads and unloads them on demand. Keeping two large models resident simultaneously needs the memory for both, so on tighter machines expect a reload pause when switching.

**Can I add more than one machine?**

Yes. In Open WebUI's **Connections** settings, add each machine's Ollama endpoint. You get their combined model list and can pick which backend serves a given chat.

**Can I pool memory across machines to run a bigger model?**

Technically yes, practically rarely worth it. Splitting a model across machines means every token's activations cross the network — even Thunderbolt bridging is an order of magnitude below on-package memory bandwidth. The result is usually *slower* than the same model on one machine. Only worth it when a model won't fit anywhere else.

**Why not Docker Desktop?**

It's a GUI app that can't be driven headlessly over SSH. Colima is CLI-native and much lighter. Neither can run as a system daemon on macOS.

**Why does it need sudo?**

To write to `/Library/LaunchDaemons/`. That's the only way to get services starting at boot without a login session. The daemons themselves drop privileges via `UserName` and don't run as root.

**Is it safe to re-run?**

Yes. Every step checks state first. Data, models, the secret key, the catalogue and your settings (`~/.config/llmstack/config`) are all preserved.

---

## Design notes

A few choices worth explaining, since they're the ones people tend to want to change first.

**System daemons over user agents, and no auto-login.** The straightforward way to get services running at boot on macOS is to enable auto-login so a user session exists. That means the machine boots to an unlocked desktop — unacceptable for a lot of people. System LaunchDaemons with `UserName` privilege-drop achieve the same durability without it. They're fiddlier to set up, which is much of what this script is for.

**pip over Docker for Open WebUI.** Docker on macOS runs inside a virtual machine. For a service that's just a Python web app, that's overhead with no isolation benefit worth paying for on a single-user machine.

**A catalogue file rather than hardcoded models.** Hardcoded recommendations rot silently. A dated file that the tooling reads and complains about makes the rot visible, and puts the fix in the hands of whoever is running it.

**Three gates on model selection, and no blanket MoE preference.** Checking only "does it fit in memory" recommends dense 70B models to 64 GB machines that will run them at a crawl. A per-chip bandwidth table catches that directly, and works on catalogues users have already customised, because it lives in the script rather than the catalogue data. v3.3 and earlier specified "prefer MoE where both fit"; in practice that would have locked out the best small dense model on machines fast enough to run it, so v3.4.0 lets the speed gate express the MoE preference instead.

**A per-chip bandwidth table rather than per-tier caps.** Bandwidth varies almost 2× within a tier (M3 Pro 150 GB/s vs M4 Pro 273 GB/s), so tier alone is too coarse. The cost is that the table needs a row for each new chip; until it gets one, a new chip is assumed to match the newest known generation for its tier.

**A live registry check in CI rather than a blocklist.** Earlier versions kept a list of "known-fictional" tags. It aged badly: one listed tag, `llama3.3:70b`, was always real, and another, `qwen3.6:35b-a3b`, shipped later and is now in the catalogue. CI now fetches each shipped tag's manifest, and a 404 fails the build.

**Single source of truth for status logic.** The status-checking code that runs in the script's `--status` mode and the `llmstatus` shell function share a single code block (`STATUS_BODY`). This eliminates the copy-paste divergence that affected earlier versions, where the two implementations drifted apart and reported different things.

**Error trap during install.** v3.1 traps unexpected exits during the install phase and prints a summary pointing to the daemon logs. Without it, a mid-install failure exited silently, leaving the user to figure out what happened and where to look.

---

## Changelog

### v3.6.3

- **A failed `--sync-models` pull now says why.** The script checks each failed tag against the Ollama registry. If the registry has the tag, it reports that the download itself was cut off and suggests a VPN, proxy or security software that may be resetting long downloads; downloaded parts are kept, so re-running resumes them. If the tag is missing it points at the Ollama library, and if the registry does not answer it says so. Previously every failure said "Check the tag", even when the tag was fine and a corporate security tool was dropping the connection.
- **`PROMPT.md`** updated from the maintainer's spec.

### v3.6.2

- **Re-runs keep your settings.** The installer now reads `~/.config/llmstack/config` before applying options, as the Ubuntu and Windows installers do. Previously a plain re-run reset everything to defaults and rewrote the config, so an install made with `--searxng-url` silently went back to local SearXNG, and a changed port or `WEBUI_BIND` was lost.
  - `--searxng-port` now also switches a remote install back to local SearXNG; `--searxng-url` wins if both are given.
  - The `DETECTED SYSTEM` summary shows the web-search and Open WebUI settings the run will use.
  - Ports read from the config are validated too, so a hand-edited bad port stops the install with a message naming the file.
- **CI:** seven new checks run the install's plan with a simulated Mac, stopping before anything is installed. They confirm that saved settings survive, options override them, and a bad port in the config is refused. They fail against the v3.6.1 logic. All workflows use `actions/checkout@v5`, as Node 20 is deprecated on runners.
- **`PROMPT.md`** is now the full rebuild specification, exported from the maintainer's spec set. It corrects the old §10.6, which said bootstrap was verified with `launchctl print`; the script uses readiness polls on the services' own endpoints.

### v3.6.1

- **License made consistent.** The repository's `LICENSE` file is GPL v3, but the script header and README said public domain / CC0. Both now state GPL v3 and point to `LICENSE`.
- **Quick start downloads the latest release.** It previously pointed at a placeholder URL. It now uses `releases/latest/download/llmstack-macos.sh`, so it always gets the newest published release rather than unreleased work on `main`.
- **Release workflow.** `.github/workflows/release-asset.yml` attaches `llmstack-macos.sh` to each published release, and refuses if the release tag doesn't match the script's `SCRIPT_VERSION`.
- **CI:** three catalogue-format checks lost the quotes around the offending value in their failure messages, a shell-quoting slip inside the awk programs. Found by actionlint; the checks themselves were unaffected.

### v3.6.0

- **`--sync-models` detects outdated builds.** Each installed pick is compared with the build the registry now serves for its tag. It compares the `ollama list` ID with the SHA-256 of the registry's manifest, which needs one small request and no download. Outdated picks are marked and offered for update (default no).
  - **Updates follow the same safety rules as pulls:** they count toward the disk check, must succeed before any removal, and a failed update blocks all removals.
  - **An unreachable registry doesn't stop the sync.** Installed picks show as `unchecked` and the rest carries on.
- **Found on a real install:** a seven-week-old `qwen3.6:35b-a3b` had different weights from the current tag. Updating it made it share weights with `qwen3.6:35b-a3b-coding` and shrank Ollama's blob store from 62 GB to 40 GB.
- **CI:** the stub `ollama list` now reports IDs derived from the stub registry's manifests, so the sync tests never touch the real registry. New cases cover an update, a failed update, and an unreachable registry. The update check was mutation-tested.

### v3.5.1

- **Fixed: `--sync-models` could miss an out-of-date catalogue.** It judged age by `Last-Updated`, but the refresh tooling stamped that date on every proposal, so a catalogue holding an old model list could look current. Catalogues now carry a `Catalogue-Generation` marker, and sync decides from that. `--recommend` also notes when your catalogue predates the built-in one.
- **Fixed: refresh proposals degraded the catalogue.**
  - Every comment was moved to the top, so section headings were cut off from their rows.
  - Suggestions were added as live rows with their judgment fields unset.
  - `Last-Updated` was set without any review.

  Proposals now keep the file in order, comment out dead rows in place, and add suggestions only as `# REVIEW:` comments, without repeating one already in the file. They leave the date alone; `--refresh-catalog-apply` sets it only when you confirm.
- **Fixed: silent exit on a catalogue without a `Last-Updated` line** (present since v3.3.0). Under `set -o pipefail`, a lookup that found nothing aborted the script with no message; `--recommend` exited 1 with no output. The catalogue lookups now treat "not found" as a normal answer.
- **Fixed: `--refresh-catalog-apply` offline** could offer to apply a leftover proposal from an earlier run. It now applies only a proposal built in the same run.
- **Hardened:** a live row whose `MIN_RAM` or `SIZE` is not a number is never selected.
- **CI:** a stub `curl` impersonates the registry to test proposal structure, de-duplication and date handling. The sync tests now cover a catalogue dated today but with no marker, an older marker, and a current marker. Both new checks were mutation-tested.

### v3.5.0

- **New `--sync-models` mode.** Pulls the recommended models you choose, then offers every installed model that is no longer a pick for removal, one at a time. Pulls always finish before any removal, a failed pull blocks all removals, free disk is checked before anything is downloaded, and every prompt defaults to no. Embedding models are flagged before you remove them. See [Syncing models](#syncing-models).
- **Catalogue upgrade built in.** `--sync-models` detects a live catalogue older than the script's built-in one and offers to back it up and replace it, replacing the manual upgrade steps from v3.4.0.
- **`--recommend` points to `--sync-models`**, and remains read-only.
- **CI:** stub `ollama` and `df` executables test the sync logic with no network. The cases cover pulls and removals matching the answers given, pull-before-remove ordering, failed-pull safety, a stopped daemon, stale-catalogue refresh, and a disk shortfall.

### v3.4.0

- **Per-chip memory-bandwidth gate.** A dense model is recommended only if the chip can generate at 8 tok/s or better. The cap is bandwidth × 65% ÷ 8 tok/s, using Apple's published figures for M1 through M6, including the binned M3 Max, M4 Max, M5 Max and M6. This fixes v3.3.0 recommending `llama3.3:70b` on 64 GB Pro-tier Macs, contrary to its own documentation. It applies to existing, customised catalogues too.
- **"Prefer MoE" replaced by "largest entry passing all gates".** The speed gate removes slow dense models; a blanket MoE preference would have shut out the best small model found, which is dense.
- **Full catalogue refresh** to the current generation: Qwen 3.5 / 3.6 / 3.8, Gemma 4, Granite 4.2 and Devstral Small 2, across light, daily, reasoning, coding and vision roles. Every tag was checked against the Ollama library. Existing catalogues are not overwritten; see [Upgrading from an earlier version](#upgrading-from-an-earlier-version).
- **Fixed: decimal model sizes crashed the install.** The free-disk check used bash integer arithmetic on the catalogue's SIZE column; a size like `7.6` aborted the run under `set -e`. The comparison now uses `awk`.
- **Tidied: free-disk probe off macOS.** The non-macOS fallback used `df -h`, whose units vary (`T`, `M`), so a large or small disk could produce a non-numeric value. It now uses `df -BG`. macOS was never affected.
- **Hardened: padded catalogue lines.** Trimming a field no longer rejoins the line with spaces, which had broken later field lookups on hand-edited lines with spaces around the pipes.
- **CI: live tag guard replaces the "fictional tag" blocklist.** The blocklist banned `llama3.3:70b`, which was always real, and `qwen3.6:35b-a3b`, which has since shipped. CI now fetches every shipped tag's manifest; a 404 fails the build and a registry outage is only a warning.
- **CI: simulated-hardware tests.** Stub `sysctl`/`ioreg` executables impersonate specific chips to test the bandwidth table, both bins of every binned chip, unknown future chips, the speed gate, and representative picks.
- **CI: `.shellcheckrc` added** as the only lint configuration. The five codes CI previously excluded on the command line never fire on the script (checked on shellcheck 0.9, 0.10 and 0.11), so none are disabled globally.
- **Correction:** the v3.1 entry below wrongly lists `llama3.3:70b` as a non-existent tag. It has been a real Ollama tag since December 2024.

### v3.3.0

- **Catalogue self-maintenance against the Ollama registry.** Three new modes keep model tags current without hand-editing:
  - `--check-models` validates every catalogue tag (manifest `200`/`404`) and corrects the VERIFIED column in place after a backup.
  - `--refresh-catalog` writes a reviewable `models.catalog.proposed`: revalidated tags, dead ones commented out, and newer size variants found within your existing families. The live catalogue is never touched.
  - `--refresh-catalog-apply` applies that proposal after a backup and confirmation.
- **`--discover` flag.** Layered onto the refresh modes, it additionally scrapes `ollama.com/library` for new model families. Fail-soft: a failed scrape still yields a proposal from validated tags and family variants.
- **`--update` now auto-validates the catalogue.** The VERIFIED column is corrected and retired tags flagged as part of every routine update.
- **All registry access is fail-soft.** If `registry.ollama.ai` is unreachable, every new command reports it and makes no change — safe offline and in CI. Every proposed candidate is manifest-confirmed before it appears, so a broken scrape or bad guess can never introduce a non-existent tag.

### v3.1.1

- **Port conflict detection now reports the holder.** `port_in_use()` returns the process name and PID, not just true/false. The warning prints "Held by: <process> <PID>" so the user knows what to kill or reconfigure.
- **`do_update` polls for readiness instead of fixed `sleep 20`.** Replaced with a loop that checks both the Ollama API and Open WebUI endpoint with `curl --max-time`, breaking as soon as both respond. No more waiting 20 seconds for services that came up in 3, or reporting success when they haven't started yet.
- **Added troubleshooting entry for missing `json` format.** A user who hand-edits `settings.yml` and removes `json` from `search: formats:` sees empty web search results with no error. The README now documents the diagnosis (`grep 'json' ~/.searxng/settings.yml`) and the fix.

### v3.1

- **Replaced all fictional model tags with real, verified ones.** Previous catalogue used tags like `qwen3.6:35b-a3b`, `gemma4:26b-a4b`, and `llama3.3:70b`, which don't exist in the Ollama registry and would fail to pull. Now uses `qwen2.5:32b-instruct`, `llama3.1:70b`, `mixtral:8x7b`, `llama3.2-vision:11b`, `qwen2.5-coder:*`, and others — all confirmed against [ollama.com/library](https://ollama.com/library).
- **Added `--version` flag.**
- **Port validation.** `--webui-port` and `--searxng-port` now validate the value is an integer in 1–65535 before proceeding.
- **Port conflict detection.** Warns before installing if the target port is already in use.
- **Error trap.** Unexpected exit during install now prints a summary with exit code and log locations, instead of exiting silently.
- **Consolidated status logic.** `show_status()` and the `.zshrc` `llmstatus()` now share a single `STATUS_BODY` code block, eliminating copy-paste divergence.
- **`--max-time` on all `curl` calls.** Status checks can no longer hang indefinitely.
- **`id -un` instead of `whoami`.** Uses the POSIX-recommended replacement for the deprecated `whoami`.
- **`find -print0` / `read -d ''`** in the uninstaller for safe handling of paths with spaces.
- **Plist ownership.** System LaunchDaemon plists now explicitly set to `root:wheel` with mode `0644`.
- **SIGINT trap during model pull.** Ctrl-C during `ollama pull` now prints a clear "interrupted, re-run to resume" message.
- **`WEBUI_BIND` persisted in config.** Changing the bind address no longer breaks the shell functions.
- **Color output** with auto-detection; degrades gracefully to plain text when piped.
- **Security note added to `--help`** documenting the plist secret-key exposure tradeoff.
- **Catalogue date updated** to reflect the revised model list.

### v3.0

- Initial public release.

---

## License

Licensed under the [GNU General Public License v3.0](LICENSE). You may use, study, modify and share it. If you distribute it or a modified version, you must do so under the same license, with the source available. The [LICENSE](LICENSE) file has the full terms.

---

## Acknowledgements

Built on the work of the [Ollama](https://ollama.com), [Open WebUI](https://github.com/open-webui/open-webui), [SearXNG](https://github.com/searxng/searxng), and [Colima](https://github.com/abiosoft/colima) projects. This script only wires them together.
