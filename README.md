# Friends SMP — modded Java Minecraft server

- **GitHub repo (public):** https://github.com/samueldpackard/friends-smp
- **Pack URL** (server and launchers read this): https://samueldpackard.github.io/friends-smp/pack.toml

A private, modded **Java Edition** Minecraft server for ~0–15 friends, hosted in the cloud,
costing money only while people are playing. This README is the handoff doc: a new Claude Code
session (or a human) should be able to read it and continue.

## Decisions made (and why)

| Decision | Choice | Why |
|---|---|---|
| Edition | **Java only** (Mac + Windows PCs). No Bedrock/Xbox, no Geyser. | Removes update breakage and lets us use any mod. Geyser could be added later on the gateway if ever needed. |
| Minecraft version | **26.3** (released 2026-09-15) | Latest release; every starter mod supports it. Stay on one version per "season"; don't chase every release. |
| Mod loader | **Fabric** (loader 0.20.1) | Fastest to update, lightweight mods, easiest for Claude to write/port mods. |
| Mod style | **Light / vanilla-plus** | Quality of life, performance, maps, voice chat. No huge content mods for now. |
| Mod distribution | **packwiz** pack in `pack/` | Single source of truth for server *and* clients. Players' launchers auto-update on every launch. |
| Player launcher | **Prism Launcher** + packwiz-installer-bootstrap | Free, Mac + Windows, supports a "pre-launch command" that syncs the pack. |
| Mod source | **Modrinth** preferred over CurseForge | Some CurseForge mods block automated downloads. |
| Hosting | **AWS, on-demand**: small always-on gateway + big VM that runs only while people play | Players can drop in anytime; the server wakes on connect and shuts down when empty. |
| Custom mods | Each in its own GitHub repo, built by GitHub Actions, added to the pack by URL | Claude Code writes/ports them; releases flow into the pack automatically. |

## Repo layout

```
pack/                 packwiz modpack (the mod list). Edit with the packwiz CLI.
  pack.toml           MC version, loader version
  mods/*.pw.toml      one file per mod; `side` = client | server | both
.github/workflows/
  publish-pack.yml    on push to main (pack/**): checks the index is refreshed, publishes pack/ to GitHub Pages
server/
  docker-compose.yml  local test server (same Docker image the cloud will use)
  data/               world + server files (git-ignored)
infra/                (planned) AWS infrastructure as code
README.md             this file
```

## Current mod list (pack v0.1.0)

- **Both sides:** Fabric API, Lithium, FerriteCore, Spark, No Chat Reports, AppleSkin, Jade,
  Xaero's Minimap, Xaero's World Map, Simple Voice Chat (needs UDP port 24454)
- **Server only:** Chunky (world pre-generation), Ledger (block/grief logging) + its deps
  (Fabric Language Kotlin, Placeholder API)
- **Client only:** Sodium, Iris (shaders), Entity Culling, ImmediatelyFast, Mod Menu

Dropped: ScalableLux (alpha-quality on 26.3).

## Common tasks

Tools: packwiz is installed at `~/go/bin/packwiz` (`go install github.com/packwiz/packwiz@latest`);
add `~/go/bin` to your PATH. Docker Desktop must be running.

```bash
# add / remove / update mods (run inside pack/)
packwiz modrinth add <slug>
packwiz remove <slug>
packwiz update --all
packwiz refresh            # always run after hand-editing any .toml

# publish a pack change: commit + push; GitHub Actions republishes in ~1 min
git add -A && git commit -m "Add <mod>" && git push

# run the local test server (inside server/) — installs from the published pack URL
docker compose up -d
# ...or test unpushed pack changes, served from your local pack/ folder:
PACKWIZ_URL=http://pack/pack.toml docker compose --profile local-pack up -d
docker compose logs -f mc      # wait for "Done (...)! For help, type help"
docker attach server-mc-1      # server console; detach with Ctrl-P Ctrl-Q
docker compose down
```

Connect from Minecraft 26.3 (Fabric, with the client mods) to `localhost:25565`.

## Gotchas found so far

- **Apple-silicon Docker + `USE_MEOWICE_FLAGS` crashes the JVM** (Temurin 25 C2 compiler error,
  `barrierSetAssembler_aarch64.cpp`). We use `USE_AIKAR_FLAGS` instead. Re-test MeowIce on the
  cloud VM later only if performance needs it.
- Docker Desktop quits when the Mac sleeps sometimes; `open -a Docker` restarts it.
- GitHub CLI login (`gh`) uses the device-code flow; the token needs the `workflow` scope to push
  `.github/workflows/*` (granted 2026-11-03). If a push is rejected for that: `gh auth refresh -s workflow`.
- Run `packwiz refresh` after editing any `.pw.toml` by hand, or hashes won't match and installs fail.

## Roadmap

1. ✅ **Pack + local test server.** The server boots on 26.3 with all mods (88 including Fabric API modules).
   - [ ] Samuel joins `localhost:25565` from Prism to confirm the client side.
2. ✅ **Publish the pack.** Public repo + GitHub Pages via Actions. The local server installs from
   the public URL and boots with all mods.
3. **Player setup guide.** Prism Launcher + packwiz-installer-bootstrap pre-launch command;
   one page for friends.
4. **Custom mod template.** Fabric mod repo + GitHub Actions release build → `packwiz url add`.
5. **AWS infrastructure** (`infra/`):
   - Gateway: tiny always-on instance (≈$4–6/mo). Listens on 25565; when the main server is off
     and someone connects, it starts the main server and shows "starting, rejoin in ~1 min".
   - Main server: ~16 GB RAM instance, Docker + itzg image with `PACKWIZ_URL`, auto-stops after
     ~15 min empty. World on persistent EBS volume; nightly backups to S3.
   - Whitelist on, Simple Voice Chat UDP 24454 open.
6. **Friend onboarding + first game night.**

## AWS billing (read before step 5)

Do these **before** creating any infrastructure:
1. Create an AWS account with your own email and a credit card. Turn on MFA for the root user,
   then create an IAM user (or IAM Identity Center user) for day-to-day use. Never use root keys.
2. **Billing → Budgets:** create a monthly cost budget (e.g. $30) with email alerts at 50%, 80%,
   100% actual and 100% forecasted.
3. **Billing preferences:** turn on Free Tier usage alerts and Cost Explorer.
4. Expected cost: gateway ≈ $5/mo + main server ≈ $0.15–0.25 per hour played + a few $ for
   disk/backups. Roughly **$15–25/mo** at 40–60 play hours; less in quiet months.
5. Tag every resource with `project=friends-smp` so Cost Explorer can show this project alone.
