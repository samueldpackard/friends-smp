#!/usr/bin/env python3
"""Build the "friends-smp-winter" datapack: every land biome in the overworld becomes cold
enough to snow, while keeping its usual grass, leaf and sky colours.

How: for each overworld biome (oceans and rivers left alone, so boats keep working) we copy the
vanilla biome file, set temperature 0.0 (like Snowy Plains) and has_precipitation true (so
deserts, savannas and badlands snow too), and pin grass_color / foliage_color / dry_foliage_color
to what the game would have computed from the old temperature, so nothing turns bluish.

Usage:
  tools/make-winter-datapack.py ~/Library/Application\\ Support/PrismLauncher/libraries/com/mojang/minecraft/26.3/minecraft-26.3-client.jar

Writes pack/world/datapacks/friends-smp-winter/. Then `cd pack && packwiz refresh`.
Re-run after a Minecraft update (biome files change between versions).
"""
import json, struct, sys, zipfile, zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "pack/world/datapacks/friends-smp-winter"
PACK_FORMAT = 121  # data pack format for 26.3 (same as friends-smp-tweaks)
WINTER_TEMPERATURE = 0.0  # snow falls below 0.15
# Water biomes stay as they are: a cold ocean or river freezes over and boats stop working.
KEEP = {"ocean", "deep_ocean", "cold_ocean", "deep_cold_ocean", "lukewarm_ocean",
        "deep_lukewarm_ocean", "warm_ocean", "river",
        # already snowy
        "frozen_ocean", "deep_frozen_ocean", "frozen_river"}


def read_png(data):
    """Minimal decoder for the 8-bit RGB/RGBA colormap PNGs. Returns (width, rows of (r,g,b))."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat = 8, b""
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", chunk[:10])
            assert depth == 8 and ctype in (2, 6), (depth, ctype)
            bpp = 3 if ctype == 2 else 4
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + length
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], (prev[i - bpp] if i >= bpp else 0)
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append([tuple(line[x * bpp:x * bpp + 3]) for x in range(w)])
        prev = line
    return w, rows


def colormap_color(rows, temperature, downfall, default):
    # Same lookup as the game's GrassColor/FoliageColor.get(temperature, downfall).
    t = min(max(temperature, 0.0), 1.0)
    d = min(max(downfall, 0.0), 1.0) * t
    x, y = int((1.0 - t) * 255.0), int((1.0 - d) * 255.0)
    index = (y << 8) | x
    if index >= 256 * 256:
        return default
    r, g, b = rows[y][x]
    return f"#{r:02x}{g:02x}{b:02x}"


def main(jar_path):
    jar = zipfile.ZipFile(jar_path)
    cmap = {n: read_png(jar.read(f"assets/minecraft/textures/colormap/{n}.png"))[1]
            for n in ("grass", "foliage", "dry_foliage")}
    defaults = {"grass": "#ff00ff", "foliage": "#48b518", "dry_foliage": "#a0a69c"}
    overworld = json.loads(jar.read("data/minecraft/tags/worldgen/biome/is_overworld.json"))["values"]

    biome_dir = OUT / "data/minecraft/worldgen/biome"
    if biome_dir.exists():
        for f in biome_dir.glob("*.json"):
            f.unlink()
    biome_dir.mkdir(parents=True, exist_ok=True)

    changed = []
    for entry in overworld:
        name = entry.removeprefix("minecraft:")
        if name in KEEP:
            continue
        biome = json.loads(jar.read(f"data/minecraft/worldgen/biome/{name}.json"))
        t, d = biome["temperature"], biome["downfall"]
        if t < 0.15 and biome["has_precipitation"]:
            continue  # already snows
        effects = biome.setdefault("effects", {})
        for key in ("grass", "foliage", "dry_foliage"):
            if f"{key}_color" not in effects:
                effects[f"{key}_color"] = colormap_color(cmap[key], t, d, defaults[key])
        biome["temperature"] = WINTER_TEMPERATURE
        biome["has_precipitation"] = True
        biome.pop("temperature_modifier", None)
        (biome_dir / f"{name}.json").write_text(json.dumps(biome, indent=2) + "\n")
        changed.append(name)

    (OUT / "pack.mcmeta").write_text(json.dumps({"pack": {
        "description": "Friends SMP winter: snow in every land biome (delete to end winter)",
        "min_format": PACK_FORMAT, "max_format": PACK_FORMAT}}, indent=2) + "\n")
    print(f"Wrote {len(changed)} biomes to {OUT}:\n  " + ", ".join(sorted(changed)))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
