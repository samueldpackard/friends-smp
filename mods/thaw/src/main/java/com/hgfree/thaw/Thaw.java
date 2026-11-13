package com.hgfree.thaw;

import java.util.ArrayDeque;
import java.util.Map;
import java.util.WeakHashMap;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerChunkEvents;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerTickEvents;
import net.minecraft.core.BlockPos;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.IceBlock;
import net.minecraft.world.level.block.SnowLayerBlock;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.levelgen.Heightmap;

/**
 * Melts snow and ice in overworld biomes that are too warm for snow, in two ways:
 * <ul>
 * <li>Every chunk that loads is swept once: all snow layers and ice on top of its columns go.
 *     This runs a tick after the load (changing blocks inside the load event is unsafe), which
 *     is before the chunk normally reaches any player, so nobody sees leftover snow.</li>
 * <li>{@link com.hgfree.thaw.mixin.ServerLevelMixin} also melts one layer at a time at the
 *     game's own freeze/snow pace, as a backstop for anything the sweep missed.</li>
 * </ul>
 */
public class Thaw implements ModInitializer {
	/** Chunks swept per tick per level, so a restart's burst of loads doesn't cause a lag spike. */
	private static final int CHUNKS_PER_TICK = 32;
	private static final Map<ServerLevel, ArrayDeque<Long>> QUEUES = new WeakHashMap<>();

	@Override
	public void onInitialize() {
		ServerChunkEvents.CHUNK_LOAD.register((level, chunk, generated) -> {
			if (level.dimension() == Level.OVERWORLD) {
				QUEUES.computeIfAbsent(level, l -> new ArrayDeque<>()).add(chunk.getPos().pack());
			}
		});
		ServerTickEvents.END_LEVEL_TICK.register(level -> {
			ArrayDeque<Long> queue = QUEUES.get(level);
			for (int i = 0; queue != null && i < CHUNKS_PER_TICK && !queue.isEmpty(); i++) {
				ChunkPos pos = ChunkPos.unpack(queue.poll());
				if (level.hasChunk(pos.x(), pos.z())) {
					sweepChunk(level, pos);
				}
			}
		});
	}

	private static void sweepChunk(ServerLevel level, ChunkPos chunk) {
		BlockPos.MutableBlockPos column = new BlockPos.MutableBlockPos();
		for (int x = chunk.getMinBlockX(); x <= chunk.getMaxBlockX(); x++) {
			for (int z = chunk.getMinBlockZ(); z <= chunk.getMaxBlockZ(); z++) {
				meltColumn(level, column.set(x, 0, z), true);
			}
		}
	}

	/**
	 * Melts the top of one column if its biome is too warm for snow. {@code all} removes a whole
	 * snow layer stack at once; otherwise one layer goes. Returns nothing: no-op in cold biomes.
	 */
	public static void meltColumn(ServerLevel level, BlockPos anyPosInColumn, boolean all) {
		if (level.dimension() != Level.OVERWORLD) {
			return;
		}
		int seaLevel = level.getSeaLevel();
		BlockPos top = level.getHeightmapPos(Heightmap.Types.MOTION_BLOCKING, anyPosInColumn);
		BlockPos below = top.below();
		Biome biome = level.getBiome(below).value();

		// A 1-layer snow sits at `top` (it doesn't block motion); thicker snow is the block below.
		for (BlockPos pos : new BlockPos[] {top, below}) {
			BlockState state = level.getBlockState(pos);
			if (state.is(Blocks.SNOW)) {
				if (biome.warmEnoughToRain(pos, seaLevel)) {
					int layers = state.getValue(SnowLayerBlock.LAYERS);
					level.setBlockAndUpdate(pos, layers > 1 && !all
							? state.setValue(SnowLayerBlock.LAYERS, layers - 1)
							: Blocks.AIR.defaultBlockState());
				}
				return;
			}
		}

		// Water freezes at `below` (the top block of the column); melt it back the same way.
		BlockState state = level.getBlockState(below);
		if (state.is(Blocks.ICE) && biome.warmEnoughToRain(below, seaLevel)) {
			level.setBlockAndUpdate(below, IceBlock.meltsInto());
		}
	}
}
