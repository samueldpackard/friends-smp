#!/usr/bin/env python3
"""Build the Classic Music mod: everyday overworld music plays only C418's original tracks.

The mod has no code. It ships an assets/minecraft/sounds.json that *replaces* the vanilla
definitions of selected music events with a C418-only subset of the same event's tracks
(same volume/weight settings). Places with their own designed soundtrack are left alone.

Usage:  mods/classic-music/build.py <vanilla sounds.json>
        (on the Mac, the vanilla file comes from Prism's asset store; see README)
Writes: pack/mods/classic-music.jar (reproducible: same input -> same bytes)
Re-run after a Minecraft update, then `cd pack && packwiz refresh`.
"""
import json, sys, zipfile
from pathlib import Path

VERSION = "1.1.0"
HERE = Path(__file__).resolve().parent
OUT = HERE.parent.parent / "pack" / "mods" / "classic-music.jar"

# C418's tracks from Minecraft - Volume Alpha / Volume Beta that the game uses as background music.
C418 = {
    # survival overworld (Volume Alpha)
    "clark", "danny", "dry_hands", "haggstrom", "key", "living_mice", "mice_on_venus",
    "minecraft", "oxygene", "subwoofer_lullaby", "sweden", "wet_hands",
    # creative (Volume Beta)
    "aria_math", "biome_fest", "blind_spots", "dreiton", "haunt_muskie", "taswell",
    # title screen (Volume Beta)
    "beginning_2", "floating_trees", "moog_city_2", "mutation",
}

# Music events to make C418-only. Everything NOT listed keeps vanilla music, on purpose:
#   deep_dark, lush_caves, dripstone_caves, sulfur_caves, cherry_grove: designed soundtracks
#   nether.*: biome-specific soundtracks (its C418 tracks already play there too)
#   under_water, end, dragon, credits: already C418
#   music.creative: plays C418's creative tracks plus music.game, which becomes C418-only here
CLASSIC_EVENTS = ["music.game", "music.menu"] + [
    f"music.overworld.{b}" for b in [
        "badlands", "bamboo_jungle", "desert", "flower_forest", "forest", "frozen_peaks",
        "grove", "jagged_peaks", "jungle", "meadow", "old_growth_taiga", "snowy_slopes",
        "sparse_jungle", "stony_peaks", "swamp",
    ]
]


def track(entry):
    name = entry if isinstance(entry, str) else entry["name"]
    return name.rsplit("/", 1)[-1]


def main(vanilla_path):
    vanilla = json.loads(Path(vanilla_path).read_text())
    game_c418 = [e for e in vanilla["music.game"]["sounds"] if track(e) in C418]
    sounds = {}
    for event in CLASSIC_EVENTS:
        if event not in vanilla:
            sys.exit(f"{event} is not in this Minecraft version's sounds.json; update CLASSIC_EVENTS")
        if event.startswith("music.overworld."):
            # Like the old game: every C418 overworld track can play in every everyday biome,
            # with equal chances (not just the subset Mojang later assigned to that biome).
            kept = game_c418
        else:
            kept = [e for e in vanilla[event]["sounds"] if track(e) in C418]
        sounds[event] = {"replace": True, "sounds": kept}
        print(f"{event}: {', '.join(track(e) for e in sounds[event]['sounds'])}")

    mod_json = {
        "schemaVersion": 1,
        "id": "classic_music",
        "version": VERSION,
        "name": "Classic Music",
        "description": "Everyday overworld music plays only C418's original tracks. "
                       "Caves, the Deep Dark, Cherry Groves and the Nether keep their own music.",
        "authors": ["Friends SMP"],
        "license": "MIT",
        "environment": "client",
        "depends": {"fabricloader": "*", "minecraft": "*"},
    }
    files = {
        "fabric.mod.json": json.dumps(mod_json, indent=2),
        "assets/minecraft/sounds.json": json.dumps(sounds, indent=2),
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for name, text in files.items():
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, text + "\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
