package com.defold.android.gameservices;

import android.app.Activity;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import androidx.annotation.NonNull;

import com.onesignal.OneSignal;
import com.onesignal.debug.LogLevel; 
import com.onesignal.notifications.INotificationClickEvent;
import com.onesignal.notifications.INotificationClickListener;
import com.onesignal.notifications.INotificationWillDisplayEvent;
import com.onesignal.notifications.INotificationLifecycleListener;

import org.json.JSONObject;

public class OneSignalDefold {
    private static final String ONE_SIGNAL_APP_ID = "1e295b7f-4155-404d-8d2f-3e5dc337b866";
    public static final String URGENT_CHANNEL_ID = "7360b7b0-2622-4ddd-9279-95c5a321c673";
    
    private boolean isInitialized = false;
    private Activity activity;

    public static native void onNotificationAction(String actionId, String dataJson);
    public static native void nativeLog(int level, String message); // Bridge

    public OneSignalDefold(Activity activity) {
        this.activity = activity;
    }

    public void init() {
        createUrgentChannel(activity);

        new Thread(() -> {
            try {
                nativeLog(0, "OneSignal Subsystem Starting Initialization thread...");
                OneSignal.getDebug().setLogLevel(LogLevel.WARN);
                OneSignal.initWithContext(activity, ONE_SIGNAL_APP_ID);

                OneSignal.getNotifications().addForegroundLifecycleListener(new GameNotificationDisplayListener());
                OneSignal.getNotifications().addClickListener(new GameNotificationClickListener());

                isInitialized = true;
                nativeLog(0, "OneSignal Initialized successfully. Handshake completed.");
            } catch (Exception | NoClassDefFoundError e) {
                nativeLog(1, "OneSignal Failed to mount! Hook dropped: " + e.getMessage());
                isInitialized = false;
            }
        }).start();
    }

    public void setExternalUserId(String externalId) {
        if (!isInitialized) {
            nativeLog(2, "Skipped tag verification: OneSignal not verified yet.");
            return;
        }
        try {
            if (externalId != null && !externalId.isEmpty()) {
                 OneSignal.login(externalId);
                 nativeLog(0, "OneSignal tracking established for mapping ID: " + externalId);
            }
        } catch (Exception e) {
            nativeLog(1, "Failed to send tracking registration: " + e.getMessage());
        }
    }

    public void logout() {
        if (isInitialized) {
            try {
                OneSignal.logout();
                nativeLog(0, "OneSignal external tracking reference detached.");
            } catch (Exception e) {
                nativeLog(1, "Logout dispatch error: " + e.getMessage());
            }
        }
    }

    private class GameNotificationDisplayListener implements INotificationLifecycleListener {
        // OneSignal only invokes onWillDisplay while the app is in the
        // foreground — a backgrounded/closed app never reaches this
        // listener at all, so the OS shows the system banner normally in
        // that case. Suppressing unconditionally here means push
        // notifications never show as a system banner while the app is
        // already open (the in-app UI already surfaces whatever the
        // notification would have said), and still show normally the
        // moment the app is backgrounded. Previously this only suppressed
        // GAME_REQUEST-typed notifications, leaving every other push type
        // (season reminders, promotions, etc.) banner-ing over the active
        // app.
        @Override
        public void onWillDisplay(@NonNull INotificationWillDisplayEvent event) {
            event.preventDefault();
        }
    }

    private class GameNotificationClickListener implements INotificationClickListener {
        @Override
        public void onClick(@NonNull INotificationClickEvent event) {
            String actionId = event.getResult().getActionId();
            if (actionId == null || actionId.isEmpty()) actionId = "opened_normal";
            
            JSONObject additionalData = event.getNotification().getAdditionalData();
            final String finalActionId = actionId;
            final String dataString = (additionalData != null) ? additionalData.toString() : "{}";

            new Handler(Looper.getMainLooper()).post(() -> {
                onNotificationAction(finalActionId, dataString);
            });
        }
    }

    private void createUrgentChannel(Context context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                NotificationManager nm = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
                if (nm != null && nm.getNotificationChannel(URGENT_CHANNEL_ID) == null) {
                    NotificationChannel channel = new NotificationChannel(URGENT_CHANNEL_ID, "Game Invites", NotificationManager.IMPORTANCE_HIGH);
                    nm.createNotificationChannel(channel);
                }
            } catch (Exception e) {
                nativeLog(1, "Notification channel mapping broke: " + e.getMessage());
            }
        }
    }
}