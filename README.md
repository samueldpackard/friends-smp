# Friends SMP — modded Java Minecraft server

- **Server address (players type this):** `35.160.13.72` (gateway's static IP; never changes)
- **GitHub repo (public):** https://github.com/samueldpackard/friends-smp
- **Pack URL** (server and launchers read this): https://samueldpackard.github.io/friends-smp/pack.toml
- **One-click Prism instance** (friends import this): https://samueldpackard.github.io/friends-smp/Friends-SMP.zip
- **Friend guide:** [PLAYERS.md](PLAYERS.md)

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
  publish-pack.yml    on push to main (pack/** or launcher/**): checks the index is refreshed,
                      publishes pack/ + the Prism instance zip to GitHub Pages
launcher/
  build-prism-instance.sh  builds Friends-SMP.zip (MC/Fabric versions read from pack.toml;
                      pre-launch runs packwiz-installer-bootstrap so mods sync every launch)
PLAYERS.md            step-by-step guide for friends
server/
  docker-compose.yml  local test server (same Docker image the cloud will use)
  data/               world + server files (git-ignored)
gateway/              Go source for the always-on wake-on-join proxy (game TCP + voice UDP)
infra/                AWS infrastructure (OpenTofu). deploy.sh builds the gateway + applies.
  files/              server/gateway first-boot scripts, mc.env template, idle-check, backup
tools/mc-knock.py     pretend to join: wakes a sleeping server without opening Minecraft
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

## Running the cloud server

How it works: players connect to the **gateway** (t4g.nano, static IP, always on). If the
**main server** (m8g.xlarge, 4 vCPU / 16 GB, Minecraft gets 12 GB) is running, the gateway
proxies the game (TCP 25565) and voice chat (UDP 24454) to it over the private network. If it's
asleep, the server list shows "asleep - join to wake it up"; a join attempt starts the VM and
tells the player to rejoin in ~1 minute. The main server checks every minute and, after
**15 min with nobody online**, stops Minecraft, backs up to S3, and powers off.

AWS access: account `829135570053`, region `us-west-2` (Oregon). The CLI profile is
`friends-smp` (IAM Identity Center user `samueldpackard`, AdministratorAccess), configured in
`~/.aws/config`. Sessions expire; log in again with the device-code flow:

```bash
aws sso login --profile friends-smp --use-device-code --no-browser   # give Samuel the URL + code
export AWS_PROFILE=friends-smp
```

```bash
# change infra or server settings (whitelist, ops, memory, idle time: infra/variables.tf)
infra/deploy.sh plan        # preview
infra/deploy.sh             # apply (asks to confirm)
# mc.env/scripts live in S3 and are re-read at every server boot, so most setting changes
# take effect next time the server wakes up. Gateway changes: restart its service (below).

# wake the server without Minecraft
tools/mc-knock.py

# server state / start / stop
aws ec2 describe-instances --instance-ids i-0737b6ab11af34f5c --query 'Reservations[0].Instances[0].State.Name'
aws ec2 start-instances --instance-ids i-0737b6ab11af34f5c

# admin shell on a VM (no SSH; needs the Session Manager plugin: brew install --cask session-manager-plugin)
aws ssm start-session --target i-0737b6ab11af34f5c   # main server
aws ssm start-session --target i-08edfcde5c8a0cfc8   # gateway
#   on the server:  journalctl -u minecraft -f        (game log)
#                   sudo docker exec -it mc rcon-cli  (server console: /list, /op, /whitelist ...)
#                   journalctl -t mc-idle -t mc-backup (sleep/backup log)
#   on the gateway: journalctl -u mc-gateway -f ;  sudo systemctl restart mc-gateway

# backups
aws s3 ls s3://friends-smp-829135570053/backups/ --recursive
```

Restoring a backup: stop the server (`sudo systemctl stop minecraft` in an SSM session), clear
`/opt/mc/data/world*`, `aws s3 cp` the backup down, `tar -xzf` it into `/opt/mc/data`, start again.

**OpenTofu state** (`infra/terraform.tfstate`) is only on Samuel's Mac (git-ignored). Don't lose
it; moving it to S3 is a good small follow-up. The world disk has `prevent_destroy`, so
`tofu destroy` refuses to delete it.

## Gotchas found so far

- **Apple-silicon Docker + `USE_MEOWICE_FLAGS` crashes the JVM** (Temurin 25 C2 compiler error,
  `barrierSetAssembler_aarch64.cpp`). We use `USE_AIKAR_FLAGS` instead. Re-test MeowIce on the
  cloud VM later only if performance needs it.
- On first launch Prism shows a setup wizard; a `--import <url>` started before the wizard
  completes pops up afterwards (that's what happened on Samuel's Mac — it worked fine).
- Docker Desktop quits when the Mac sleeps sometimes; `open -a Docker` restarts it.
- GitHub CLI login (`gh`) uses the device-code flow; the token needs the `workflow` scope to push
  `.github/workflows/*` (granted 2026-11-03). If a push is rejected for that: `gh auth refresh -s workflow`.
- New AWS accounts are limited to 5 vCPUs of running instances; we need 6. Raised to 16
  (approved 2026-11-05, Service Quotas `L-1216C47A`).
- Claude Code's auto mode blocks `tofu apply` until Samuel explicitly approves it in chat.
- The built-in Claude browser has no Bitwarden; Samuel approves AWS/GitHub device codes in his
  regular browser.
- Run `packwiz refresh` after editing any `.pw.toml` by hand, or hashes won't match and installs fail.

## Roadmap

1. ✅ **Pack + local test server.** The server boots on 26.3 with all mods (88 including Fabric API modules).
   - ✅ Samuel joined `localhost` from Prism (2026-11-04); voice chat connected.
2. ✅ **Publish the pack.** Public repo + GitHub Pages via Actions. The local server installs from
   the public URL and boots with all mods.
3. ✅ **Player setup.** One-click Prism instance + [PLAYERS.md](PLAYERS.md), tested end-to-end on
   Samuel's Mac (client got the 16 client/both mods; server-only mods correctly excluded).
   - [ ] Test on a Windows PC when a friend is available.
   - ✅ Cloud address in PLAYERS.md. (Optional: pre-fill the server list in the instance zip.)
   - Note: changing the Minecraft/Fabric version in pack.toml updates the zip, but existing
     instances keep their old version. Friends would re-import the zip (worlds live on the server,
     so nothing is lost) — or test whether packwiz-installer updates mmc-pack.json by itself.
4. **Custom mod template.** Fabric mod repo + GitHub Actions release build → `packwiz url add`.
5. ✅ **AWS infrastructure** deployed 2026-11-05 (see "Running the cloud server").
   - [ ] Add friends' Minecraft usernames to `whitelist` in infra/variables.tf, then deploy.
   - [ ] Pre-generate the world with Chunky (`/chunky radius 3000`, `/chunky start`) to cut lag.
   - [ ] Optional: a domain name instead of the raw IP; move tofu state to S3.
6. **Friend onboarding + first game night.**

## AWS billing

Set up 2026-11-05:
- Root login has MFA. Day-to-day/CLI access is the IAM Identity Center user `samueldpackard`.
- Budget **"Friends SMP monthly" = $30**, emails samueldpackard@gmail.com at 85% / 100% actual
  and 100% forecast. It measures usage before credits, so it reflects true cost.
- Free Tier usage alerts on (root email). CloudWatch billing alerts intentionally left off.
- **Credits: $100**, expiring 2027-11-05. AWS may grant up to $100 more for starter activities.
- All resources tagged `project=friends-smp`. To filter Cost Explorer by it, activate the tag
  once under Billing → Cost allocation tags (it appears ~24 h after the first tagged resource).

Expected cost (on-demand, us-west-2): gateway t4g.nano ≈ $3/mo + its public IPv4 ≈ $3.65/mo +
world disk 30 GB ≈ $2.40/mo + gateway disk ≈ $0.65/mo + S3 backups < $1/mo ≈ **$10/mo base**,
plus main server m8g.xlarge **$0.1795/hr** + its IPv4 $0.005/hr + 20 GB root disk ≈ $1.60/mo.
≈ $20/mo at 50 play hours. Data out to players is covered by AWS's 100 GB/mo free allowance.
