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
            nativeLog(0, "Google Play task response parsed. Update Availability matches: " + available);
            onUpdateAvailable(available);
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
            nativeLog(0, "Local asset compilation caching successfully closed. Package ready.");
            onUpdateDownloaded();
            unregisterListenerSafely();
        } else if (state.installStatus() == InstallStatus.CANCELED || state.installStatus() == InstallStatus.FAILED) {
            nativeLog(2, "Update step ended or dropped: " + state.installStatus());
            unregisterListenerSafely();
        }
    }

    public void onActivityResult(int resultCode) {
        if (resultCode != Activity.RESULT_OK) {
            nativeLog(2, "Active player rejected update dialogue challenge window.");
            unregisterListenerSafely();
            onUpdateFailed("Flow Cancelled or Failed");
        }
    }

    public void unregisterListenerSafely() {
        if (appUpdateManager != null && isMonitorRegistered) {
            appUpdateManager.unregisterListener(this);
            isMonitorRegistered = false;
        }
    }
}