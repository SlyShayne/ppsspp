package org.ppsspp.ppsspp;

import android.annotation.TargetApi;
import android.app.Activity;
import android.app.ActivityOptions;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.KeyEvent;
import android.view.View;

import java.lang.ref.WeakReference;

// The Gungnir companion on the main (top) display while the game runs on a secondary (bottom) one.
// Android doesn't allow a Presentation on the main display, so this is an activity in its own task
// there, started and finished by PpssppActivity through show() and close(). It never runs on its own:
// if Android brings it back after the game is done with it, it finishes right away.
//
// Its window can't take focus (GungnirCompanion.setUpWindow), so the controller stays with the game.
// Any key that reaches it anyway is handed to the game.
//
// A Java version of CompanionActivity from gungnir-core's Android library (CompanionWindow.kt).
public class GungnirCompanionActivity extends Activity {
	private static final String TAG = "PPSSPPGungnir";

	// Main thread only.
	private static boolean wanted = false;
	private static GungnirCompanionActivity current;
	private static WeakReference<Activity> game;

	private View view;

	// Whether show() was called and close() not since.
	static boolean isWanted() {
		return wanted;
	}

	// Shows the companion on display [displayId]. Needs Android 8 (launching on a chosen display).
	@TargetApi(Build.VERSION_CODES.O)
	static void show(Activity from, int displayId) {
		game = new WeakReference<>(from);
		if (wanted) {
			return;
		}
		wanted = true;
		Intent intent = new Intent(from, GungnirCompanionActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
		ActivityOptions options = ActivityOptions.makeBasic().setLaunchDisplayId(displayId);
		try {
			Log.i(TAG, "Gungnir: showing the companion on display " + displayId + " (the game is on another)");
			from.startActivity(intent, options.toBundle());
		} catch (RuntimeException e) {
			Log.w(TAG, "Gungnir: couldn't show the companion on display " + displayId + ": " + e);
			wanted = false;
		}
	}

	static void close() {
		wanted = false;
		game = null;
		GungnirCompanionActivity activity = current;
		current = null;
		if (activity != null) {
			activity.finishAndRemoveTask();
		}
	}

	static void playHaptic(int kind) {
		GungnirCompanionActivity activity = current;
		if (activity != null) {
			GungnirCompanion.playHaptic(activity, activity.view, kind);
		}
	}

	@Override
	protected void onCreate(Bundle savedInstanceState) {
		super.onCreate(savedInstanceState);
		if (!wanted) {
			// Brought back by Android after the game closed it, or started by something else.
			finishAndRemoveTask();
			return;
		}
		current = this;
		GungnirCompanion.setUpWindow(getWindow());
		view = GungnirCompanion.createView(this);
		setContentView(view);
	}

	@Override
	public boolean dispatchKeyEvent(KeyEvent event) {
		Activity target = game != null ? game.get() : null;
		if (target != null && !target.isFinishing() && target.dispatchKeyEvent(event)) {
			return true;
		}
		return super.dispatchKeyEvent(event);
	}

	@Override
	protected void onDestroy() {
		if (current == this) {
			current = null;
		}
		super.onDestroy();
	}
}
