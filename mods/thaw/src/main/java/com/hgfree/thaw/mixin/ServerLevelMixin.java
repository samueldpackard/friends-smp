package com.hgfree.thaw.mixin;

import com.hgfree.thaw.Thaw;
import net.minecraft.core.BlockPos;
import net.minecraft.server.level.ServerLevel;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * The game picks one random column per loaded chunk now and then to freeze water and pile up
 * snow (tickPrecipitation). We melt the same column first, one snow layer at a time, if its
 * biome is too warm to snow. A backstop for the chunk-load sweep in {@link Thaw}.
 */
@Mixin(ServerLevel.class)
public abstract class ServerLevelMixin {
	@Inject(method = "tickPrecipitation", at = @At("HEAD"))
	private void thaw$melt(BlockPos randomPos, CallbackInfo ci) {
		Thaw.meltColumn((ServerLevel) (Object) this, randomPos, false);
	}
}
