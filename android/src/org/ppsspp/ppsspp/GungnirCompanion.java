package org.ppsspp.ppsspp;

import android.annotation.SuppressLint;
import android.app.Presentation;
import android.content.Context;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.Log;
import android.view.Display;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.FrameLayout;

import io.github.unixepoch.gungnir.core.GungnirCore;

// The Gungnir companion screen (a pack's map, buttons, character stats) on a dual-screen handheld's
// other display. Gungnir Core draws it natively into the surface here; touches go back to it in canvas
// coordinates. PpssppActivity shows it when the native host (android/jni/GungnirHost.cpp) says a pack
// started, and hides it when the pack stops:
// - Game on the main (top) display: this Presentation, on the secondary (bottom) one.
// - Game on a secondary display: GungnirCompanionActivity on the main one, since Android doesn't
//   allow a Presentation on the main display.
//
// A Java version of CompanionPresentation, companionView and CompanionHaptics from gungnir-core's
// Android library (CompanionWindow.kt, CompanionHaptics.kt), since PPSSPP builds with Java only.
public class GungnirCompanion extends Presentation {
	private static final String TAG = "PPSSPPGungnir";

	private View view;

	public GungnirCompanion(Context outerContext, Display display) {
		super(outerContext, display);
	}

	@Override
	protected void onCreate(Bundle savedInstanceState) {
		super.onCreate(savedInstanceState);
		setUpWindow(getWindow());
		view = createView(getContext());
		setContentView(view);
	}

	public void playHaptic(int kind) {
		playHaptic(getContext(), view, kind);
	}

	// ---- shared with GungnirCompanionActivity ----

	// Not focusable, so touching this screen never pulls controller focus away from the game. No system bars.
	@SuppressWarnings("deprecation")
	static void setUpWindow(Window window) {
		if (window == null) {
			return;
		}
		window.addFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE);
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
			WindowManager.LayoutParams attributes = window.getAttributes();
			attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
			window.setAttributes(attributes);
		}
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
			window.setDecorFitsSystemWindows(false);
			// getDecorView creates the decor, which a Presentation doesn't have yet before setContentView.
			WindowInsetsController controller = window.getDecorView().getWindowInsetsController();
			if (controller != null) {
				controller.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
				controller.hide(WindowInsets.Type.systemBars());
			}
		} else {
			window.getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
				| View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
				| View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN);
		}
	}

	// The companion's surface, centred on black, as large as fits with the canvas's shape.
	static View createView(Context context) {
		FrameLayout frame = new FrameLayout(context);
		frame.setBackgroundColor(Color.BLACK);
		frame.addView(new FittedSurfaceView(context), new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
		return frame;
	}

	// A pack's haptic (GungnirCore.HAPTIC_*), as gungnir-core's CompanionHaptics plays it.
	static void playHaptic(Context context, View view, int kind) {
		Vibrator vibrator = (Vibrator) context.getSystemService(Context.VIBRATOR_SERVICE);
		try {
			if (vibrator == null || !vibrator.hasVibrator()) {
				return;
			}
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && kind == GungnirCore.HAPTIC_TICK
				&& vibrator.areAllPrimitivesSupported(VibrationEffect.Composition.PRIMITIVE_TICK)) {
				vibrator.vibrate(VibrationEffect.startComposition().addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK).compose());
			} else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
				int effect;
				switch (kind) {
				case GungnirCore.HAPTIC_HOLD:
				case GungnirCore.HAPTIC_DROP:
					effect = VibrationEffect.EFFECT_CLICK;
					break;
				case GungnirCore.HAPTIC_REFUSED:
					effect = VibrationEffect.EFFECT_DOUBLE_CLICK;
					break;
				case GungnirCore.HAPTIC_HEAVY:
					effect = VibrationEffect.EFFECT_HEAVY_CLICK;
					break;
				default:
					effect = VibrationEffect.EFFECT_TICK;
					break;
				}
				vibrator.vibrate(VibrationEffect.createPredefined(effect));
			} else if (view != null) {
				// Before Android 10 there are no predefined effects.
				view.performHapticFeedback(kind == GungnirCore.HAPTIC_HOLD || kind == GungnirCore.HAPTIC_HEAVY
					? HapticFeedbackConstants.LONG_PRESS : HapticFeedbackConstants.VIRTUAL_KEY);
			}
		} catch (RuntimeException e) {
			Log.w(TAG, "Couldn't play a companion haptic: " + e);
		}
	}

	@SuppressLint("ViewConstructor")
	private static final class FittedSurfaceView extends SurfaceView implements SurfaceHolder.Callback {
		FittedSurfaceView(Context context) {
			super(context);
			getHolder().addCallback(this);
		}

		@Override
		protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
			long availableW = MeasureSpec.getSize(widthMeasureSpec);
			long availableH = MeasureSpec.getSize(heightMeasureSpec);
			long canvasW = GungnirCore.canvasWidth();
			long canvasH = GungnirCore.canvasHeight();
			if (availableW <= 0 || availableH <= 0) {
				setMeasuredDimension(0, 0);
			} else if (availableW * canvasH <= availableH * canvasW) {
				setMeasuredDimension((int) availableW, (int) (availableW * canvasH / canvasW));
			} else {
				setMeasuredDimension((int) (availableH * canvasW / canvasH), (int) availableH);
			}
		}

		@Override
		public void surfaceCreated(SurfaceHolder holder) {
			GungnirCore.setSurface(holder.getSurface());
		}

		@Override
		public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
		}

		@Override
		public void surfaceDestroyed(SurfaceHolder holder) {
			GungnirCore.setSurface(null);
		}

		@SuppressLint("ClickableViewAccessibility")
		@Override
		public boolean onTouchEvent(MotionEvent event) {
			float scaleX = (float) GungnirCore.canvasWidth() / Math.max(getWidth(), 1);
			float scaleY = (float) GungnirCore.canvasHeight() / Math.max(getHeight(), 1);
			switch (event.getActionMasked()) {
			case MotionEvent.ACTION_DOWN:
			case MotionEvent.ACTION_POINTER_DOWN:
				send(event, event.getActionIndex(), GungnirCore.TOUCH_DOWN, scaleX, scaleY);
				break;
			case MotionEvent.ACTION_UP:
			case MotionEvent.ACTION_POINTER_UP:
			case MotionEvent.ACTION_CANCEL:
				send(event, event.getActionIndex(), GungnirCore.TOUCH_UP, scaleX, scaleY);
				break;
			case MotionEvent.ACTION_MOVE:
				for (int i = 0; i < event.getPointerCount(); i++) {
					send(event, i, GungnirCore.TOUCH_MOVE, scaleX, scaleY);
				}
				break;
			default:
				break;
			}
			return true;
		}

		private static void send(MotionEvent event, int index, int phase, float scaleX, float scaleY) {
			GungnirCore.touchPointer(event.getPointerId(index), phase, event.getX(index) * scaleX, event.getY(index) * scaleY);
		}
	}
}
