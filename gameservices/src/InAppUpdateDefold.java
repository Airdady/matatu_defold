package com.defold.android.gameservices;

import android.app.Activity;
import android.content.IntentSender;
import com.google.android.play.core.appupdate.AppUpdateInfo;
import com.google.android.play.core.appupdate.AppUpdateManager;
import com.google.android.play.core.appupdate.AppUpdateManagerFactory;
import com.google.android.play.core.appupdate.AppUpdateOptions;
import com.google.android.play.core.install.InstallState;
import com.google.android.play.core.install.InstallStateUpdatedListener;
import com.google.android.play.core.install.model.AppUpdateType;
import com.google.android.play.core.install.model.InstallStatus;
import com.google.android.play.core.install.model.UpdateAvailability;
import com.google.android.gms.tasks.Task;

public class InAppUpdateDefold implements InstallStateUpdatedListener {
    public static final int UPDATE_REQUEST_CODE = 7001;

    private AppUpdateManager appUpdateManager;
    private AppUpdateInfo appUpdateInfo;
    private boolean isMonitorRegistered = false;
    private Activity activity;

    public static native void onUpdateAvailable(boolean available);
    public static native void onUpdateDownloaded();
    public static native void onUpdateFailed(String error);
    public static native void nativeLog(int level, String message); // Bridge

    public InAppUpdateDefold(Activity activity) {
        this.activity = activity;
        try {
            this.appUpdateManager = AppUpdateManagerFactory.create(activity);
            nativeLog(0, "Google AppUpdateManager instantiated cleanly.");
        } catch (Exception e) {
            nativeLog(1, "Failed to instantiate Play AppUpdateManager: " + e.getMessage());
        }
    }

    public void checkForUpdate() {
        if (activity == null || appUpdateManager == null) return;

        nativeLog(0, "Querying Google Play API for application metadata updates...");
        Task<AppUpdateInfo> appUpdateInfoTask = appUpdateManager.getAppUpdateInfo();
        appUpdateInfoTask.addOnSuccessListener(info -> {
            this.appUpdateInfo = info;
            boolean available = info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE;
            boolean resuming = info.updateAvailability() == UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS;
            nativeLog(0, "Google Play task response parsed. Update Availability matches: " + available);
            onUpdateAvailable(available);

            // Force the player through the update the instant they open the
            // app — no prompt, no skip, no Lua round-trip. IMMEDIATE shows
            // Play's own full-screen blocking UI; if Play won't allow
            // IMMEDIATE for this update (e.g. rollout/eligibility rules),
            // fall back to FLEXIBLE and auto-restart the moment the download
            // finishes (see onStateUpdate) so the player still can't keep
            // playing on the old version.
            if (available) {
                if (info.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE)) {
                    nativeLog(0, "Update available: forcing IMMEDIATE update flow.");
                    startImmediateUpdate();
                } else if (info.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE)) {
                    nativeLog(0, "IMMEDIATE not allowed for this update; forcing FLEXIBLE with auto-restart instead.");
                    startFlexibleUpdate();
                } else {
                    nativeLog(1, "Update available but Play disallows both IMMEDIATE and FLEXIBLE for it.");
                }
            } else if (resuming) {
                // An immediate update was already in progress (app was killed
                // or backgrounded mid-flow) — resume forcing it right away.
                resumeUpdate();
            }
        }).addOnFailureListener(e -> {
            nativeLog(2, "Google Play version collection skipped or rejected: " + e.getMessage());
            onUpdateFailed("Check Failed: " + e.getMessage());
        });
    }

    public void startFlexibleUpdate() { startUpdate(AppUpdateType.FLEXIBLE); }
    public void startImmediateUpdate() { startUpdate(AppUpdateType.IMMEDIATE); }

    private void startUpdate(int type) {
        if (activity == null || appUpdateInfo == null) {
            nativeLog(1, "Execution halted: Missing active validation info block.");
            onUpdateFailed("Initialization or Activity missing");
            return;
        }
        if (type == AppUpdateType.FLEXIBLE && !isMonitorRegistered) {
            appUpdateManager.registerListener(this);
            isMonitorRegistered = true;
        }
        try {
            nativeLog(0, "Handing execution thread over to Google Play OS UI layer...");
            appUpdateManager.startUpdateFlowForResult(appUpdateInfo, activity, AppUpdateOptions.newBuilder(type).build(), UPDATE_REQUEST_CODE);
        } catch (IntentSender.SendIntentException | RuntimeException e) { 
            unregisterListenerSafely();
            nativeLog(1, "Play Store Intent window presentation failed: " + e.getMessage());
            onUpdateFailed("Start Failed: " + e.getMessage());
        }
    }

    public void completeUpdate() {
        if (appUpdateManager != null) {
            nativeLog(0, "Instructing Core context manager to finalize installation and hot-reboot.");
            appUpdateManager.completeUpdate();
        }
    }

    public void resumeUpdate() {
        if (activity == null || appUpdateManager == null) return;
        appUpdateManager.getAppUpdateInfo().addOnSuccessListener(info -> {
            if (info.updateAvailability() == UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS) {
                try {
                    nativeLog(0, "Found incomplete Immediate update sequence. Forcing interface takeover...");
                    appUpdateManager.startUpdateFlowForResult(info, activity, AppUpdateOptions.newBuilder(AppUpdateType.IMMEDIATE).build(), UPDATE_REQUEST_CODE);
                } catch (IntentSender.SendIntentException e) {
                   nativeLog(1, "Failed to bind to active updating handle window context.");
                }
            }
        });
    }

    @Override
    public void onStateUpdate(InstallState state) {
        if (state.installStatus() == InstallStatus.DOWNLOADED) {
            // This listener only ever runs for the FLEXIBLE forced-fallback
            // path (registered solely in startUpdate() for AppUpdateType.FLEXIBLE),
            // so the download finishing means it's time to force the restart
            // immediately — there's no "tap to restart" prompt to wait on.
            nativeLog(0, "Local asset compilation caching successfully closed. Package ready. Forcing restart to install.");
            onUpdateDownloaded();
            unregisterListenerSafely();
            completeUpdate();
        } else if (state.installStatus() == InstallStatus.CANCELED || state.installStatus() == InstallStatus.FAILED) {
            nativeLog(2, "Update step ended or dropped: " + state.installStatus());
            unregisterListenerSafely();
        }
    }

    public void onActivityResult(int resultCode) {
        if (resultCode != Activity.RESULT_OK) {
            nativeLog(2, "Active player rejected/backed out of the forced update flow. Re-triggering.");
            unregisterListenerSafely();
            onUpdateFailed("Flow Cancelled or Failed");
            // Force means force: don't let the player slip past a
            // cancelled/back-pressed update — immediately show it again.
            checkForUpdate();
        }
    }

    public void unregisterListenerSafely() {
        if (appUpdateManager != null && isMonitorRegistered) {
            appUpdateManager.unregisterListener(this);
            isMonitorRegistered = false;
        }
    }
}