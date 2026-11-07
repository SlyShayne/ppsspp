package io.github.unixepoch.gungnir.core;

import android.view.Surface;

/**
 * The Java face of Gungnir Core's JNI (ext/gungnir-core/android/src/main/cpp/core_jni.c), which
 * binds to this class by name. gungnir-core's own Android library has the same thing in Kotlin
 * (GungnirCore.kt); PPSSPP builds with Java only, so this is its Java twin, method for method.
 *
 * The runtime itself is started, ticked and stopped by PPSSPP's native host
 * (android/jni/GungnirHost.cpp) on the emu thread. Everything here works on that running runtime
 * and is safe from any thread. There's deliberately no tick(): the host ticks while paused too.
 */
public final class GungnirCore {
	static {
		// Already loaded as a dependency of ppsspp_jni; this registers it so JNI can find core_jni.c.
		System.loadLibrary("gungnir_core");
	}

	private GungnirCore() {}

	public static final int TOUCH_DOWN = 0;
	public static final int TOUCH_MOVE = 1;
	public static final int TOUCH_UP = 2;

	public static final int HAPTIC_TAP = 1;
	public static final int HAPTIC_HOLD = 2;
	public static final int HAPTIC_DROP = 3;
	public static final int HAPTIC_REFUSED = 4;
	public static final int HAPTIC_TICK = 5;
	public static final int HAPTIC_HEAVY = 6;

	/** The companion's canvas in pixels (1240 by 1080, the AYN Thor's second screen): touches use these coordinates. */
	public static native int canvasWidth();
	public static native int canvasHeight();

	/** The surface the companion draws into; null detaches it. */
	public static native void setSurface(Surface surface);

	/** One finger, numbered by Android's pointer id. [phase] is TOUCH_DOWN, TOUCH_MOVE or TOUCH_UP. Canvas coordinates. */
	public static native void touchPointer(int pointer, int phase, float x, float y);

	/** Android's "Remove animations": only essential motion plays. */
	public static native void setReducedMotion(boolean reduced);

	/** The player's setting for pack sounds. */
	public static native void setPackSounds(boolean on);
}
