<!--
  Generated from 10-macos-spec.md in the maintainer's private meta repository
  (Local-LLM-Stack-Meta) by tools/export_prompt.py. Do not edit here:
  change the spec there and export again.
-->

> **About this file.** This is the complete specification MacOS-Local-LLM-Stack is built
> from: give it to Claude with an empty folder to rebuild the repository,
> or with this repository to change it. It names some companion documents
> (`01-shared-core.md`, `40-ci-and-testing.md`, `50-release-runbook.md`,
> `60-lessons-learned.md`, `80-backlog.md`). Those live in the maintainer's
> private meta repository. The rules they share with this spec are copied
> in below; the rest are the maintainer's working notes.

# 10 — Rebuild spec: MacOS-Local-LLM-Stack (`llmstack-macos.sh` v3.6.3)

**Use this prompt to rebuild the repository from an empty folder, or to change it.**
- Give the whole file to Claude with the instruction: *"Build (or update) the repository described here. Follow it exactly; where it is silent, ask."*
- It is self-contained. The `SHARED` blocks are kept identical to `01-shared-core.md`.
- Pair it with `50-release-runbook.md` to ship, and with `60-lessons-learned.md` to avoid repeating mistakes.

| | |
|---|---|
| Repository | `cautionespn/MacOS-Local-LLM-Stack` (public, GPL v3) |
| Current version | 3.6.3 (2026-10-08), tag `3.6.3` |
| Catalogue generation | 3.4.0 |
| Verified on | deepthought, an M4 Pro with 64 GB (real install, sync, outdated-build check); CI on Ubuntu with simulated hardware; a conditional macOS-runner job |

---

## 1. Objective

The deliverables are:
- a single, shareable shell script that provisions a private, self-hosted LLM stack on macOS;
- a GitHub-style `README.md` documenting it;
- GitHub Actions workflows that lint and test the script and attach it to releases.

## 2. Target environment

- macOS on Apple Silicon (arm64) only. Refuse anything else in preflight, with a clear message.
- zsh is the user shell.
- Assume a fresh OS install with no console login: the machine is administered over SSH.
- Make no assumption about user name or home path. Use `$HOME` and `id -un`, never `whoami`, which is deprecated.
- Nothing specific to the author's network. Anything site-specific is a flag or a config value.

## 3. Deliverables

1. **`llmstack-macos.sh`:** one file, executable, with no companion scripts.
2. **`README.md`:** follows GitHub conventions: a contents list, tables, and fenced blocks with language hints.
3. **`.github/workflows/ci.yml`:** see §14.
4. **`.shellcheckrc`:** the only lint configuration. It disables nothing globally and sets `external-sources=true`. It documents the two inline suppressions: `SC2016` on `STATUS_BODY` and the `brew shellenv` line, and `source=/dev/null` on the config file.
5. **The model catalogue:** generated on first run if absent and never overwritten afterwards.
6. **`.github/workflows/release-asset.yml`:**
   - On `release: published`, and on `workflow_dispatch` with a tag input, it attaches `llmstack-macos.sh` to the release.
   - It refuses if the tag (minus a leading `v`) differs from `SCRIPT_VERSION`.
   - It checks out the tag, runs the version check, runs `bash -n`, then runs `gh release upload <tag> llmstack-macos.sh --clobber`.
   - The tag goes through `env:`, never interpolated into the script.
   - The README's Quick start downloads `releases/latest/download/llmstack-macos.sh`.
7. **`LICENSE`:** GNU GPL v3. The script header and the README say so and point at it.
8. **`PROMPT.md`:** this file, exported with `tools/export_prompt.py` from the meta repo. That tool puts a short preamble in front, saying the files it names (`01-shared-core.md` and the 40–80 documents) live in the maintainer's private meta repo. Never edit `PROMPT.md` by hand; change this spec and export again.

## 4. Stack

| Component | Purpose | How it runs |
|---|---|---|
| Ollama | inference | Homebrew; system LaunchDaemon `com.local.ollama` |
| Open WebUI | web front-end | pip into a Python 3.11 venv (`~/openwebui-venv`); system LaunchDaemon `com.local.openwebui` |
| SearXNG | private web search | Colima + Docker container, or a remote instance (`--searxng-url`) |
| Draw Things | image and video generation (optional) | Mac App Store via `mas`, app id 6444050820; skip with `--no-drawthings` |

Install Homebrew, `python@3.11` and a container runtime only as needed. Prefer pip and a venv over containers for Open WebUI.

## 5. Service management

**System LaunchDaemons.**
- Ollama and Open WebUI are **system LaunchDaemons** in the `system` domain, at `/Library/LaunchDaemons/com.local.{ollama,openwebui}.plist`. They start at boot with no login session.
- Both privilege-drop to the invoking user via `UserName`. They never run as root.
- **Auto-login is never required, suggested or enabled.**
- Validate every generated plist with `plutil -lint` before loading, and fail loudly if one is malformed.
- Set `HOME` explicitly in each daemon's environment.
- After writing each plist, set its owner to `root:wheel` and its mode to `0644` explicitly. `sudo tee` does not guarantee ownership.

**`WEBUI_SECRET_KEY`.**
- It goes in the Open WebUI plist's `EnvironmentVariables`, so it is world-readable (0644).
- Document this trade-off in `--help` and in the README's Security section. It is fine on a single-user Mac. On a multi-user machine, suggest alternatives.
- Generate it as hex with `secrets.token_hex(16)`. Base64 `+` and `=` are silently dropped from plist environments.
- Persist it to `~/.config/llmstack/openwebui-secret` (0600) and reuse it on every run.

**Container runtime limits.**
- macOS container runtimes need a GUI login: Docker Desktop cannot be launched over SSH, and Colima is per-user. So use Colima, never Docker Desktop.
- A local SearXNG does **not** survive a reboot without a console login. Say so plainly in `--help`, the README and `llmstatus`.
- `--searxng-url` delegates search to a Linux host, where Docker is a real systemd service, and installs no runtime.

## 6. Modes and CLI

**Modes:**
- `--install` (default)
- `--update` (alias `--upgrade`)
- `--status`
- `--recommend`
- `--sync-models`
- `--uninstall`
- `--version`
- `--check-models`
- `--refresh-catalog`
- `--refresh-catalog-apply`
- `--help` (also `-h`)

**Options:**
- `--searxng-url URL`
- `--searxng-port PORT` (default 8888)
- `--webui-port PORT` (default 8080)
- `--model TAG`
- `--no-model`
- `--no-drawthings`
- `--discover` (refresh modes only)

**Mode rules.**
- **`--help`** is comprehensive: synopsis, every mode and option, components, file layout, ports, startup behaviour *and its limits*, the security note, requirements, post-install steps, exit status and examples.
- **`--version`** prints `llmstack-macos.sh v3.6.3` and exits 0.
- **`--recommend` and `--status`** are read-only. `--recommend` ends by pointing at `--sync-models`, and notes a catalogue whose generation predates the built-in one.
- **`--uninstall`** confirms **each artifact separately**:
  - Every prompt defaults to no, and bare Enter skips.
  - Destroying user data needs two confirmations.
  - It never removes shared dependencies (Homebrew, Python, `mas`), and the summary says so.
- **`--update`:**
  1. Load the config.
  2. Copy `DATA_DIR` with `cp -R` to `~/.open-webui.backup-YYYYMMDD-HHMMSS`, aborting if the copy fails.
  3. Boot out both daemons and wait 2 s.
  4. `brew upgrade ollama`. If it fails, treat it as non-fatal.
  5. `pip install --upgrade open-webui` in the venv. On failure, warn that the data is safe and carry on.
  6. Local mode with Colima running: `docker pull`, `docker rm -f searxng`, then start the container again. Remote mode: say to update it on that host.
  7. Bootstrap both daemons, whatever happened above.
  8. Wait up to 60 s for both the Ollama API and Open WebUI.
  9. Print `UPDATE COMPLETE` and the backup path. Report the catalogue age and run `--check-models`.
  10. Print the daily pick, adding `ollama pull <tag>` if it isn't installed, then the `llmstatus` hint.
- **Settings precedence.** The install loads `~/.config/llmstack/config` first; options given on the command line then override it. Parse options into `CLI_*` variables (`CLI_SEARXNG_URL`, `CLI_SEARXNG_PORT`, `CLI_WEBUI_PORT`) and apply them in `resolve_settings` after `load_config`, in this order:
  1. `--webui-port` sets `WEBUI_PORT`.
  2. `--searxng-port` sets `SEARXNG_HOST_PORT`, sets `SEARXNG_MODE=local` and `SEARXNG_URL=http://127.0.0.1:<port>`. This is how a remote install returns to local search.
  3. `--searxng-url` sets `SEARXNG_URL` (trailing `/` removed) and `SEARXNG_MODE=remote`, so it wins over `--searxng-port`.
  4. Validate `WEBUI_PORT`, and `SEARXNG_HOST_PORT` in local mode, wherever they came from. A port from the config that is not 1–65535 stops with `Invalid port ... (WEBUI_PORT in ~/.config/llmstack/config)`; options were already checked when parsed.
  The install calls `resolve_settings`, so a plain re-run keeps a remote SearXNG, a non-default port and `WEBUI_BIND`. Status, update and uninstall only `load_config`: they act on what is installed, and these options do not apply to them.
- **Ports.** Validate every port as an integer from 1 to 65535 before installing anything; reject anything else with a clear error. Before installing, check whether `--webui-port`, and `--searxng-port` in local mode, are in use. Warn with the holder's process name and PID from `lsof`. Don't abort.

<!-- SHARED:sync -->
### `--sync-models` (shared contract)

This mode brings installed models in line with the current picks. **The safety property is order: every chosen pull must succeed before anything is removed.** Every change needs a yes, every prompt defaults to no, and bare Enter means no.

1. **Daemon check.** `ollama list` must succeed. Otherwise say "Cannot reach Ollama. Start the stack (llmstart), then re-run. Nothing was changed." and exit 1.
2. **Catalogue lineage.** If the `Catalogue-Generation` marker is missing or older than the built-in generation:
   - Explain that newer models will not appear until the catalogue is replaced.
   - Say that a backup is kept and hand-added rows can be copied back.
   - Say that adding the current marker line stops the offer.
   - Then ask "Back up your catalogue and replace it with the built-in one?"
3. **Picks.** Compute every role's pick and collapse them to one line per unique tag, listing every role it serves. Treat a tag with no `:` as `:latest` everywhere. Show each pick as:

   ```
     <tag padded 30> <size> GB  <arch>  <state>  <roles>
   ```

   The state is one of:
   - `not installed`
   - `current`: the `ollama list` ID equals the first 12 hex characters of the SHA-256 of the manifest the registry serves for the tag.
   - `outdated`: the two differ.
   - `unchecked`: the registry was unreachable or the manifest could not be fetched.

   If no role has a pick, warn "Nothing in the catalogue fits this machine, so there is nothing to sync." and exit 0, before any registry check.

   Otherwise check reachability once. If the registry is unreachable, print "(Registry unreachable: installed picks were not checked for newer builds.)" and carry on.
4. **Choose.** Go through the picks in order:
   - For each `not installed` pick: "Pull <tag> (about <size> GB) for: <roles>?"
   - For each `outdated` pick: "Update <tag> for: <roles>? Your build is older than the registry's (download up to <size> GB)."
5. **Removal candidates** are installed models that are no current pick. Declining a pick's pull never makes it a removal candidate. If nothing is chosen and there are no candidates, say "Nothing to do: ..." and exit 0.
6. **Disk check.** Updates count at full size. If free disk is less than the chosen sizes plus 10 GB:
   - Warn, and say "Nothing was changed. To free space first, run --sync-models again, decline every pull, and answer yes to the removals you want."
   - Exit 1.
7. **Pull** everything chosen. On Ctrl-C during a pull, say "Pull interrupted. Nothing was removed. Re-run to resume the download." and stop: bash traps `INT`; PowerShell, where a stop skips `catch` but runs `finally`, prints it from a `finally` guarded by "not done and no ordinary error". If any pull fails, list the failures, say "no models were removed", and exit 1.

   **Say why each pull failed.** Ollama's own error does not tell a missing tag from a dropped connection, so probe each failed tag's manifest once with the registry check (the same endpoint and timeout) and print it with a reason:
   - 200: `download failed (the tag is in the registry)`
   - 404: `tag not found in the registry`
   - anything else: `registry unreachable`

   Then print one hint for each reason that occurred, in that order:
   - "The registry has the tag, so the download itself was cut off. A VPN, proxy or security software between this machine and the registry may be resetting long downloads. Downloaded parts are kept, so re-running resumes them."
   - "Check the tag at https://ollama.com/library."
   - "The registry did not answer. Check this machine's network, then re-run."

   Never suggest checking the tag when the registry served it (MBP5800, 2026-10-05: Zscaler reset every blob download while the manifests loaded, and the old message blamed the tags).
8. **Remove**, one model at a time:
   - Show the model's name and size.
   - If `ollama show` lists an `embedding` capability, warn that Open WebUI may use it for document search.
   - Ask "Remove <model>?"
9. **Summary.** Print a `SYNC COMPLETE` banner, then the Pulled, Updated, Removed and "Kept, not a current pick" lists, each showing `(none)` when empty. If anything was removed, add a reminder to choose a new default model in Open WebUI.

When stdin is a list of answers, as in tests, loops that prompt must not consume that list. In bash, iterate over fd 3.
<!-- /SHARED:sync -->

<!-- SHARED:registry -->
### Registry checks and catalogue maintenance (shared contract)

**Endpoint.** `https://registry.ollama.ai/v2/library/<name>/manifests/<tag>`, with header `Accept: application/vnd.docker.distribution.manifest.v2+json`.
- 200 means live and 404 means dead; no auth is needed.
- Any other status, a timeout or a network error means **unknown**.

**Fail-soft, always.**
- An unknown never changes the catalogue.
- Every call has a timeout of 8–15 s.
- Reachability is checked once up front by probing `llama3.3:70b`. **Any 200 or 404 counts as reachable**, so the check survives that tag being retired. If the registry is unreachable, the mode reports that and exits 0 with nothing written.
- CI depends on this.

**`--check-models`.**
- Probes every tag and prints a LIVE/DEAD/???? line for each, then a summary.
- **Only if at least one VERIFIED value changes** (200 sets `yes`, 404 sets `no`), it takes a timestamped backup (`models.catalog.backup-YYYYMMDD-HHMMSS`) and rewrites the file.
- Otherwise, if any tag is dead, it points at `--refresh-catalog`.

**`--refresh-catalog`.** Writes `models.catalog.proposed` beside the live file and never touches the live file.
- Walk the live file **in order**. Comments and blank lines pass through untouched, so headings keep their rows.
- A live row is rewritten with `VERIFIED=yes`. MIN_RAM, ARCH, ROLE and NOTES are preserved verbatim; they are human judgment.
- A dead row is commented out **in place**: `# DEAD (404 at registry, review/remove): <row with VERIFIED=no>`.
- An unknown row passes through unchanged.
- Candidates are found by probing `<family>:<size>` and `<family>:<size>-instruct` for each catalogue family. The sizes are 1.5b 3b 4b 7b 8b 9b 11b 12b 14b 22b 27b 30b 32b 34b 70b 72b. Only tags that are live and not already present count.
- With `--discover`, the script also scrapes `https://ollama.com/library` for family names and keeps those whose `:latest` is live. The scrape is fragile HTML, so it is wholly optional and fail-soft.
- Each candidate is appended **only as a comment**: `# REVIEW: REVIEW|<tag>|REVIEW|REVIEW|REVIEW|yes|Confirmed in the registry. Set MIN_RAM, SIZE, ARCH, ROLE and NOTES.`
  - The first one is preceded by `# --- Suggested by --refresh-catalog: set every REVIEW field, then delete '# REVIEW: ' ---`. That header is never repeated.
  - A candidate already present as a `# REVIEW:` line is not suggested again.
- The proposal leaves `Last-Updated` alone.
- Field trimming must not mangle apostrophes. In bash that means parameter expansion, never `xargs`.

**`--refresh-catalog-apply`.**
- Builds a proposal **in this run**. A leftover `.proposed` file from an earlier run is never applied, notably when the registry is now unreachable.
- Shows the diff and asks, defaulting to no.
- On yes: backs up, replaces the live file, sets `Last-Updated` to today, and deletes the proposal.

**`--update`** runs `--check-models` after updating.
<!-- /SHARED:registry -->

### Install flow (in order)

1. **Preflight.** Darwin and arm64 only. Warn if the Xcode Command Line Tools are missing.
2. **Settings,** then **detection and plan.** Call `resolve_settings`. Detect the hardware and print the `DETECTED SYSTEM` banner. It ends with two settings lines before the closing rule:
   - `  Web search:        local SearXNG (Colima) on 127.0.0.1:<port>`, or `  Web search:        remote SearXNG at <url>`
   - `  Open WebUI:        port <port>, bound to <WEBUI_BIND>`
   Then check ports, choose the model and warn on low disk. There is **no go-ahead prompt and no `--yes`**.
   - **Test hook `LLMSTACK_PLAN_ONLY=1`:** after the plan (model choice and catalogue age), print `Plan only (LLMSTACK_PLAN_ONLY=1); nothing was installed.` and exit 0, before `sudo -v`. CI uses it to test settings precedence. It is not in `--help`.
3. `sudo -v` up front, for the system LaunchDaemons.
4. **Homebrew,** installed if missing. Append `eval "$(/opt/homebrew/bin/brew shellenv)"` to `.zshrc` once. Then `brew install ollama` and `python@3.11`.
5. **Local SearXNG only:**
   - Warn if there is no console session (`launchctl print gui/$UID`).
   - `brew install colima docker`, then `brew services start colima`. Wait up to **120 s** (60 × 2 s) for `colima status`.
6. **Open WebUI.** Create the venv at `~/openwebui-venv` with `python3.11 -m venv` and run `pip install open-webui`. Create or reuse the secret file.
7. **SearXNG.** Write the settings file (removing a stray directory first) and start the container (see below). Wait up to **60 s** (30 × 2 s) for its JSON search.
8. **Ollama plist.** Write, lint, own and bootstrap it. Wait up to **30 s** for `/api/version`; failure is a hard error.
9. **Open WebUI plist,** then **Draw Things** (`mas install 6444050820`, unless `--no-drawthings`).
10. **The model.** Pull it, trapping Ctrl-C. A failed pull is non-fatal and points at the library.
11. **Config.** Write `~/.config/llmstack/config`, then the `.zshrc` block (§8).
12. **Verify.** Wait up to **90 s** (45 × 2 s) for Open WebUI, then print `SETUP COMPLETE` with next steps: `exec zsh`, create the admin account, turn on web search.

### Daemon and container details

**`com.local.ollama`:**
- `ProgramArguments`: `/opt/homebrew/bin/ollama serve`.
- `EnvironmentVariables`: `HOME`, `OLLAMA_MODELS=~/.ollama/models`.
- `RunAtLoad` and `KeepAlive` are true; `UserName` is the invoking user.
- Logs: `~/.ollama/ollama.daemon.log` and `ollama.daemon.err.log`.

**`com.local.openwebui`:**
- `ProgramArguments`: `~/openwebui-venv/bin/open-webui serve --host $WEBUI_BIND --port $WEBUI_PORT`.
- `WEBUI_BIND` defaults to **`0.0.0.0`**. It has no flag but is persisted in the config.
- `EnvironmentVariables`: `HOME`, `DATA_DIR`, `WEBUI_SECRET_KEY`.
- `SoftResourceLimits` and `HardResourceLimits` `NumberOfFiles` are 65536.
- `RunAtLoad` and `KeepAlive` are true.
- Logs: `$DATA_DIR/openwebui.log` and `openwebui.err.log`.
- The EXIT trap prints all four log paths.

**SearXNG container:**
- Name **`searxng`**, which the `llm*` functions and uninstall depend on.
- Image **`ghcr.io/searxng/searxng:latest`**. macOS uses ghcr; Ubuntu and Windows use `docker.io`.
- Options:
  - `-p 127.0.0.1:$SEARXNG_HOST_PORT:8080`
  - `--restart unless-stopped`
  - `-e SEARXNG_BASE_URL=http://127.0.0.1:<port>/`
  - **the single file** `~/.searxng/settings.yml` mounted read-only at `/etc/searxng/settings.yml`
- Health check: `wget -qO- http://127.0.0.1:8080/healthz`, interval 30 s, timeout 5 s, 3 retries, start period 20 s.

### Uninstall steps (in order)

Every step is a separate prompt, defaulting to no:
1. "Begin uninstall?"
2. Boot out the daemons, then delete the plists.
3. The SearXNG container, then `~/.searxng`, then Colima: `brew services stop colima`, `colima stop`, `colima delete --force`, `brew uninstall colima docker`.
4. The venv, then the Open WebUI data (two confirmations), then the models.
5. `brew uninstall ollama`.
6. The `.zshrc` block, with a backup, then `~/.config/llmstack`.
7. Optional: Draw Things, then the `~/.open-webui.backup-*` folders.

The summary says Homebrew, `python@3.11` and `mas` were left in place.

## 7. Hardware detection and sizing (macOS)

**Detection.**
- `sysctl -n machdep.cpu.brand_string` gives the chip. Strip any suffix such as ` (Virtual)` before looking it up.
- `hw.ncpu` gives the cores.
- `hw.memsize` gives RAM, in whole GB. If unreadable, as on Linux CI, use 8.
- Free disk comes from `df -g "$HOME"`, falling back to GNU `df -BG` for CI.
- Tier comes from the brand string: `*Ultra*`, `*Max*` or `*Pro*`; `*Apple*` otherwise means Base; anything else is Unknown.

**The budget** is 70% of unified memory.

**Bandwidth** comes from the per-chip table in Appendix A. The dense cap = bandwidth × 0.65 ÷ 8, to one decimal. Where one chip name has two bandwidth bins:
- **M3 Max and M4 Max:** decided by `hw.ncpu`, 16 for the higher bin and 14 for the lower.
- **M5 Max:** decided by GPU core count from `ioreg` (`"gpu-core-count" = 40` or `32`). Without it, 48 GB of RAM or more means the higher bin.
- **M6:** 16 GB or less means the lower bin.
- **Unrecognised Apple chips:** use the newest known generation's figure for their tier: Ultra 1200, Max 460, Pro 307, Base 153.
- **Non-Apple hosts (CI):** no bandwidth, so no dense cap; sized by memory alone.

`--recommend` prints the chip, tier, memory, bandwidth, a one-line note for the tier, the dense cap, free disk, the picks and the catalogue age. The low-disk warning (free space under the model plus 10 GB) appears only in the install, not in `--recommend`.

<!-- SHARED:catalogue -->
### Model catalogue (shared contract, generation 3.4.0)

**Format.** One plain-text file. Pipe-delimited and hand-editable:
- `#` starts a comment.
- Blank lines are ignored.
- CRLF line endings are accepted on read.
- Files are written with LF.

Each data row is:

```
MIN_RAM_GB|TAG|SIZE_GB|ARCH|ROLE|VERIFIED|NOTES
```

| Column | Meaning |
|---|---|
| `MIN_RAM_GB` | Minimum **system** RAM (machine class). Compared with system RAM even when a GPU sizes the picks. |
| `TAG` | Exact Ollama tag, `name:tag`. Never invent one. |
| `SIZE_GB` | Download size of that exact tag. May be a decimal (`7.6`). |
| `ARCH` | `dense` or `moe`. |
| `ROLE` | `daily`, `reasoning`, `coding`, `vision` or `light`. |
| `VERIFIED` | `yes` only if the tag was confirmed in the Ollama registry; otherwise `no`. |
| `NOTES` | Free text, worded per platform. Never parsed. |

**Number handling.**
- Never feed a catalogue value to integer arithmetic.
- Compare sizes as decimals, culture-invariant: awk in bash, `[double]::Parse` with `InvariantCulture` in PowerShell.
- A row whose `MIN_RAM_GB` or `SIZE_GB` is not numeric (for example still `REVIEW`) is never picked.

**Header lines.**
- **`# Last-Updated: YYYY-MM-DD`** records when a *person* last reviewed the file.
  - Graded: under 90 days is recent; 90 to 180 is worth a look; over 180 is very likely stale.
  - `--recommend` and `--update` report the grade.
  - No tooling changes this line, except a confirmed `--refresh-catalog-apply`, which sets it to today.
- **`# Catalogue-Generation: X.Y.Z`** records which built-in catalogue the file descends from.
  - It is the MacOS-Local-LLM-Stack version in which the built-in rows last changed. That is currently **3.4.0**.
  - It is shared by all three repositories and bumped in all three together, only when the rows change.
  - A missing or older marker means "predates the built-in catalogue". `--recommend` notes it, and `--sync-models` offers a backed-up replacement.
  - Lineage is never judged from `Last-Updated`.

**Lifecycle.**
- The script writes the built-in catalogue on first use if none exists.
- It never overwrites an existing catalogue silently.
- What a read-only mode does when it cannot write differs per platform; each spec says which:
  - macOS: the catalogue is in the user's home, so it can always write.
  - Ubuntu: uses a temporary copy, deleted on exit.
  - Windows: uses the built-in text in memory.

**Selection.** Within each role, the **largest** entry that passes all three gates wins:
1. `SIZE_GB` ≤ the budget.
2. System RAM ≥ `MIN_RAM_GB`.
3. Dense entries only, and only when the platform defines a dense cap:
   - `SIZE_GB` ≤ dense cap.
   - Dense cap (GB) = bandwidth (GB/s) × 0.65 ÷ 8 tok/s.
   - Named constants: `DENSE_EFFICIENCY_PCT=65` (a percentage, divided by 100) and `DENSE_MIN_TPS=8`; on Windows, `$Script:DenseEfficiencyPct` and `$Script:DenseMinTps`.
   - MoE entries are exempt: only their active experts are read per token.

The bandwidth gate is the only MoE preference. Do not hard-prefer MoE: a dense model that passes may be better than any MoE that fits. Within a role, size tracks quality, so never list several quantizations of one model. Roles are shown in this order: daily, reasoning, coding, vision, light. The install pulls the daily pick, or the light pick when no daily pick fits.

**Built-in rows, generation 3.4.0.** These columns are identical on every platform; only NOTES differ.

| MIN_RAM_GB | TAG | SIZE_GB | ARCH | ROLE | VERIFIED |
|---|---|---|---|---|---|
| 4 | granite4.2:3b | 2.2 | dense | light | yes |
| 8 | qwen3.5:4b | 3.4 | dense | daily | yes |
| 16 | gemma4:12b | 7.6 | dense | daily | yes |
| 24 | gemma4:26b-a4b-it-qat | 16 | moe | daily | yes |
| 32 | qwen3.6:35b-a3b | 23 | moe | daily | yes |
| 8 | qwen3.5:4b | 3.4 | dense | reasoning | yes |
| 16 | gemma4:12b | 7.6 | dense | reasoning | yes |
| 24 | gemma4:26b-a4b-it-qat | 16 | moe | reasoning | yes |
| 32 | qwen3.8:27b | 18 | dense | reasoning | yes |
| 8 | qwen3.5:4b | 3.4 | dense | coding | yes |
| 16 | qwen3.5:9b | 6.6 | dense | coding | yes |
| 24 | devstral-small-2:24b | 15 | dense | coding | yes |
| 32 | qwen3.6:35b-a3b-coding | 23 | moe | coding | yes |
| 8 | qwen3.5:4b | 3.4 | dense | vision | yes |
| 16 | gemma4:12b | 7.6 | dense | vision | yes |
| 24 | gemma4:26b-a4b-it-qat | 16 | moe | vision | yes |
| 32 | qwen3.6:35b-a3b | 23 | moe | vision | yes |

The file groups these under comment headings: `# --- Light ...`, `# --- Daily drivers ...`, `# --- Reasoning ...`, `# --- Coding ...` and `# --- Vision ...`. Above them is a header that explains the format, the two header lines, the three gates, why architecture matters, and the VERIFIED column. All tags were verified live against the registry on 2026-09-30 and are re-checked by CI on every push.
<!-- /SHARED:catalogue -->

**macOS NOTES column.** These are the exact row texts, in file order.

```
4|granite4.2:3b|2.2|dense|light|yes|IBM Granite 4.2 3B. Tiny and fast, with a thinking mode. The floor: fits machines under 8 GB, such as VMs.
8|qwen3.5:4b|3.4|dense|daily|yes|Qwen 3.5 4B. Strongest general model under 5 GB. Text and image input.
16|gemma4:12b|7.6|dense|daily|yes|Google Gemma 4 12B. Strong all-rounder for 16 GB machines. Multimodal.
24|gemma4:26b-a4b-it-qat|16|moe|daily|yes|Gemma 4 26B MoE, about 4B active, QAT build. The strong MoE that fits a 24 GB budget.
32|qwen3.6:35b-a3b|23|moe|daily|yes|Qwen 3.6 35B MoE, 3B active. Fast on every chip tier. Multimodal. Needs 36 GB or more.
8|qwen3.5:4b|3.4|dense|reasoning|yes|Qwen 3.5 4B with its thinking mode.
16|gemma4:12b|7.6|dense|reasoning|yes|Gemma 4 12B. Strong maths and reasoning for its size.
24|gemma4:26b-a4b-it-qat|16|moe|reasoning|yes|Gemma 4 26B MoE. Reasoning on chips too slow for a dense 27B.
32|qwen3.8:27b|18|dense|reasoning|yes|Qwen 3.8 27B. Top small open model on independent indexes. Dense, so it needs M4 Pro-class bandwidth or better. Uses many tokens.
8|qwen3.5:4b|3.4|dense|coding|yes|Qwen 3.5 4B. Best coding option under 5 GB.
16|qwen3.5:9b|6.6|dense|coding|yes|Qwen 3.5 9B. Stronger agentic coding than Gemma 4 12B.
24|devstral-small-2:24b|15|dense|coding|yes|Mistral Devstral Small 2 24B. Strong agentic coding. Dense, so it needs Pro-class bandwidth.
32|qwen3.6:35b-a3b-coding|23|moe|coding|yes|Qwen 3.6 35B MoE with its coding sampling preset. Same weights as the daily tag.
8|qwen3.5:4b|3.4|dense|vision|yes|Qwen 3.5 4B. Image input on the smallest machines.
16|gemma4:12b|7.6|dense|vision|yes|Gemma 4 12B. Image input.
24|gemma4:26b-a4b-it-qat|16|moe|vision|yes|Gemma 4 26B MoE. Image input.
32|qwen3.6:35b-a3b|23|moe|vision|yes|Qwen 3.6 35B MoE. Leads Gemma 4 26B on vision evals.
```

Representative picks the tests pin:

| Machine | Expected picks |
|---|---|
| M4 Pro, 64 GB | daily `qwen3.6:35b-a3b`, reasoning `qwen3.8:27b` |
| M3 Pro, 36 GB | reasoning `gemma4:26b-a4b-it-qat` (a dense 27B is too slow at 150 GB/s) |
| M4, 32 GB | daily `gemma4:26b-a4b-it-qat`, coding `qwen3.5:9b` |
| M1, 8 GB | daily `qwen3.5:4b`, light `granite4.2:3b` |
| 7 GB VM (GitHub macOS runner) | light `granite4.2:3b` |

## 8. Files and the shell integration

| Path | Contents |
|---|---|
| `~/.config/llmstack/config` | settings, sourced by the shell functions at call time: `SEARXNG_MODE`, `SEARXNG_URL`, `SEARXNG_HOST_PORT`, `WEBUI_PORT`, `WEBUI_BIND` |
| `~/.config/llmstack/models.catalog` | catalogue |
| `~/.config/llmstack/openwebui-secret` | secret key (0600) |
| `~/openwebui-venv` | Open WebUI venv |
| `~/.local/share/open-webui/data` | `DATA_DIR`, pinned explicitly, plus the Open WebUI logs |
| `~/.ollama/models` | models |
| `~/.searxng/settings.yml` | SearXNG settings (`limiter: false`, formats `html` and `json`) |
| `/Library/LaunchDaemons/com.local.{ollama,openwebui}.plist` | daemons |

**The shell functions in `~/.zshrc`.**
- The block is delimited by `### LLM Stack Control (llmstack-macos.sh) ###` and `### End LLM Stack Control ###`.
- It defines `LLMSTACK_SCRIPT="<absolute path>"`, the `STATUS_BODY` functions, and `llmstop`, `llmstart`, `llmstatus` and `llmupgrade`.
- Replace the block, never append. First remove every block under the current marker and every legacy start marker:
  - `### LLM Stack Control (auto-generated) ###`
  - `# --- Local LLM stack control ---`
  - `# ============================================================`
- Back up `.zshrc` first.
- Match markers literally with `awk index()`, never as a regex.
- Never delete a range whose end can't be found: report it and skip.
- Warn about `alias llm(stop|start|status|upgrade)=` lines found outside any marked block (`check_stray_llm_defs`, which runs before the purge). In zsh, an alias that later became a function breaks parsing.
- Legacy start markers are matched up to the current end marker.
- Tell the user to `exec zsh`, not `source`.

## 9. Platform constraints to handle, not discover

These are covered in §5: no auto-login, Colima only, no local SearXNG across reboots without a login, and `--searxng-url` as the escape hatch.

## 10. Failure modes to pre-empt

Each of these has bitten a real deployment. Handle them in code.

1. The secret key must be hex (see §5).
2. Set `SoftResourceLimits` and `HardResourceLimits` `NumberOfFiles` to 65536 for Open WebUI, or web search dies with `Too many open files`.
3. Pin `DATA_DIR` explicitly and consistently. A mismatch creates an empty database that looks exactly like wiped credentials.
4. Docker creates a **directory** at a bind-mount path that doesn't exist. Detect and remove a stray `settings.yml` directory, and write the file before starting the container.
5. SearXNG listens on 8080 inside the container whatever its config says, so map `host-port:8080`.
6. `launchctl bootstrap` fails with error 5 when the daemon is already loaded. Always `bootout`, `sleep 2`, then `bootstrap`. Treat a bootstrap error as a warning: the curl readiness polls that follow are the real verification. (`PROMPT.md` in the repo still says "verify with `launchctl print`"; the code does not do that.)
7. Report the process and PID holding a busy port.
8. SearXNG needs `json` in `formats`, or Open WebUI gets nothing (a 403).
9. The `.zshrc` block rules in §8.
10. **Install error trap.**
    - Trap `EXIT` during install. On a non-zero exit, print the exit code, the log locations, and that re-running is safe.
    - Clear the trap on success.
11. **Ctrl-C during `ollama pull`.** Trap `INT` to say the pull was interrupted and can be resumed by re-running, then exit 1.
12. **Timeouts.** Every `curl` has `--max-time`: 2–5 s for status calls, 8–15 s for the registry.
13. Persist `WEBUI_BIND` in the config file.
14. **One status implementation.** `STATUS_BODY` is a single string, `eval`'d by `--status` and written verbatim into `.zshrc`. Never copy the logic.
15. Plist ownership (§5).
16. **No silent exits on empty grep.** Under `set -euo pipefail`, a `grep` that matches nothing inside `$(...)` aborts the script silently. Lookup functions end with `|| true` and print nothing on no match. This bit v3.5.0, when a catalogue had no marker line.

## 11. Script quality

- `set -euo pipefail`, and idempotent throughout.
- Readiness checks poll real endpoints; no fixed sleeps except short pauses around `launchctl` transitions.
- Show progress for long operations, and state download sizes up front.
- Never `source` an interactive rc file from the script.
- Colour only when `[ -t 1 ]` and `tput` work.
- `find ... -print0` with `read -r -d ''`.
- Comment *why*.

## 12. Documentation

The README must cover:
- what it installs, requirements and the Quick start (release download URL)
- the modes and options tables
- model selection and why bandwidth matters, with the chip table
- the catalogue and its two header lines
- the reboot limitation and its cause
- remote SearXNG, with a working Compose file for a Linux host
- the shell commands
- updating, uninstalling, file layout and ports
- a **Security** section (plist secret exposure, plist ownership)
- troubleshooting for every item in §10, with a diagnostic command each
- an FAQ, design notes and a **Changelog** by version

## 13. Working style

<!-- SHARED:working-style -->
### Working style (shared)

- State assumptions and design decisions before writing code. Name the options, weigh the trade-offs and justify the choice.
- Push back on risk or unneeded complexity instead of complying silently.
- Verify current facts (package names, image tags, model tags, endpoints, versions) instead of relying on recall. Say which ones were verified and which were not. **Never invent model tags.**
- Say plainly what is and is not verified, in the README too. A path tested only against stubs is not verified on real hardware.
- Deliver complete files, never diffs.
- Lint and test before delivering.
- Comment *why*, not *what*, especially at each workaround.
- Every network call has a timeout. Readiness polls real endpoints instead of sleeping.
- Every prompt defaults to no. Deleting Open WebUI data (accounts and chats) takes two confirmations; every other removal takes one. `--yes` (or `-Yes`) answers only the install's own go-ahead, never a removal, an uninstall, a driver install or a third-party licence.
- Idempotent: re-running is safe and never overwrites user data or the secret key.
<!-- /SHARED:working-style -->

## 14. CI

**Lint job** (Ubuntu):
- `bash -n`
- `shellcheck -x` configured only by `.shellcheckrc`
- shebang `#!/bin/bash`

**CLI test job** (Ubuntu). Everything is stubbed. A runnable reference of the techniques is in `40-ci-and-testing.md`.
- **CLI checks:**
  - `--help` and `-h` exit 0 and mention every mode and `--discover`.
  - `--version` works.
  - Unknown arguments, invalid ports (non-numeric, 0, negative, above 65535) and missing option values all exit 1.
- **`--recommend` and `--status`:**
  - `--recommend` prints `DETECTED SYSTEM`, writes the catalogue, reports its age, never overwrites an existing catalogue, and is idempotent.
  - `--status` shows Ollama, Open WebUI and SearXNG.
- **Catalogue format:** 7 fields per row, valid tags, VERIFIED `yes`/`no`, ARCH `moe`/`dense`, known ROLE, and at least one verified daily driver.
- **Simulated hardware.**
  - Stub `sysctl` (`FAKE_CHIP`, `FAKE_NCPU`, `FAKE_RAM_GB`) and `ioreg` (`FAKE_GPU`) first on `PATH`, with an isolated `HOME` per run.
  - Assert every bin in Appendix A, the future-chip fallback, the speed gate (dense over the cap is skipped, MoE exempt) and the representative picks in §7.
  - A non-Apple host gets no dense cap.
- **Sync** (stub `ollama`, stub `df -g`, stub `curl` registry, answers on stdin, a log of calls):
  - happy path, with pulls before removals
  - a failed pull blocks removals, and the failure names its cause: a live tag (download failed, with the VPN/proxy hint and no "check the tag"), a missing tag, or an unreachable registry
  - the daemon down exits 1 with no calls
  - a missing marker is replaced only on yes, with a backup
  - an older generation is offered and the current one is not
  - an outdated pick is offered for update and a current one is not
  - a failed update blocks removals
  - an unreachable registry marks picks `unchecked`
  - a disk shortfall stops before any pull
- **Refresh** (stub registry):
  - order is kept and dead rows are commented in place
  - suggestions appear only as `# REVIEW:` and are never duplicated
  - the proposal leaves the date alone
  - apply stamps the date only on yes
  - a leftover proposal is never applied when offline
- **Live tag guard.** Before blackholing the registry, fetch every shipped tag's manifest. A 404 fails the job; anything else warns.
- **Offline safety.** Blackhole `registry.ollama.ai` and `ollama.com` in `/etc/hosts`. Then `--check-models`, `--refresh-catalog` (with and without `--discover`) and `--refresh-catalog-apply` must each exit 0, write no proposal, and leave the catalogue byte-identical.

- **Settings precedence** (stub `uname` printing `Darwin`/`arm64` first on `PATH`, plus the hardware stubs, `LLMSTACK_PLAN_ONLY=1`, isolated `HOME`):
  - no config: the plan shows local SearXNG on 8888 and Open WebUI on 8080;
  - a config with `SEARXNG_MODE="remote"` and a URL: a plain run shows that remote URL (the 3.6.1 bug);
  - that config plus `--searxng-port 9999`: local on 9999;
  - that config plus `--searxng-url http://b:1/`: remote `http://b:1`;
  - a config with `WEBUI_PORT="3000"`: port 3000; adding `--webui-port 3100`: port 3100;
  - a config with `WEBUI_PORT="80800"`: exits 1 naming the config, and installs nothing;
  - each run exits 0 and leaves no `com.local.*` plist, venv or `.zshrc` block behind.

**macOS job** (Apple Silicon runner):
- Runs only on pushes to main or on `workflow_dispatch`, because macOS minutes cost 10×.
- Real detection: chip, memory, disk, tier, bandwidth and at least one pick.
- `--status`, and a valid catalogue.

**CI Pass** is the gate job. It needs `lint` and `test`, not the macOS job.

Every job uses `actions/checkout@v5` (Node 24); v4's Node 20 is deprecated on runners.

CI triggers on pushes and PRs to `main` (and `master`) and on `workflow_dispatch`. Offline-safety checks assert exit 0 for all three modes, no proposal for `--refresh-catalog` (with and without `--discover`), and a byte-identical catalogue.

---

## Appendix A — Memory bandwidth by chip (GB/s)

| Chip | GB/s | | Chip | GB/s |
|---|---|---|---|---|
| M1 | 68 | | M4 | 120 |
| M1 Pro | 200 | | M4 Pro | 273 |
| M1 Max | 400 | | M4 Max (14 cores / 16 cores) | 410 / 546 |
| M1 Ultra | 800 | | M5 | 153 |
| M2 | 100 | | M5 Pro | 307 |
| M2 Pro | 200 | | M5 Max (32 GPU / 40 GPU) | 460 / 614 |
| M2 Max | 400 | | M5 Ultra | 1200 |
| M2 Ultra | 800 | | M6 (16 GB or less / more) | 153 / 170 |
| M3 | 100 | | Unknown Ultra / Max / Pro / Base | 1200 / 460 / 307 / 153 |
| M3 Pro | 150 | | | |
| M3 Max (14 cores / 16 cores) | 300 / 400 | | | |
| M3 Ultra | 819 | | | |

The `--recommend` notes per tier:
- **Ultra:** "Very high memory bandwidth; large dense models are comfortable."
- **Max:** "High memory bandwidth; dense models up to the cap below run well."
- **Pro:** "MoE models are fast; dense models are limited to the cap below."
- **Base:** "Lower memory bandwidth; only small dense models, MoE where it fits."
- **Unknown:** "Sizing by memory alone; no dense-speed cap."

## Appendix B — The shell commands written into `.zshrc`

- **`llmstatus`** runs `_llmstack_status`, from `STATUS_BODY`.
- **`llmstop`:**
  1. `sudo launchctl bootout system/com.local.openwebui`, then the same for `system/com.local.ollama`.
  2. In local mode, also `docker stop searxng` and `brew services stop colima`.
- **`llmstart`:**
  1. In local mode: `brew services start colima`, wait up to 60 s for `colima status`, then `docker start searxng`.
  2. Bootstrap both plists.
  3. Print "Open WebUI needs 30 to 60 seconds".
- **`llmupgrade`** runs `"$LLMSTACK_SCRIPT" --update`, or explains where the script should be.

## Appendix C — Version history

| Version | Change |
|---|---|
| 3.6.3 | `--sync-models` says why each pull failed: it probes the manifest, so a dropped download on a live tag is no longer blamed on the tag (MBP5800, Zscaler) |
| 3.6.2 | The install loads the config before applying options, so re-runs keep settings (backlog 4a); `--searxng-port` returns to local mode; plan shows the web-search and Open WebUI settings; `LLMSTACK_PLAN_ONLY` test hook; `actions/checkout@v5`; `PROMPT.md` exported from this spec |
| 3.6.1 | GPL v3 stated consistently; release-asset workflow; Quick start uses the latest release |
| 3.6.0 | `--sync-models` detects outdated builds by manifest digest and offers updates |
| 3.5.1 | `Catalogue-Generation` marker; refresh proposals keep the file's shape and never apply unreviewed rows; silent-exit fix (§10.16) |
| 3.5.0 | `--sync-models` |
| 3.4.0 | Three gates, per-chip bandwidth table, largest-wins, live tag guard, generation 3.4.0 rows, `.shellcheckrc` |
| 3.3.0 | Registry validation and refresh modes |
| ≤3.1.1 | Original installer: daemons, Colima, SearXNG, Draw Things |
