package com.defold.android.firebaseauth;

import android.app.NotificationManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * Handles inline action button clicks from push notifications (e.g. Decline challenge, Dismiss).
 */
public class NotificationActionReceiver extends BroadcastReceiver {

    private static final String TAG = "NotificationAction";

    public static final String ACTION_DECLINE = "com.matatu.champ.ACTION_DECLINE";
    public static final String ACTION_DISMISS = "com.matatu.champ.ACTION_DISMISS";
    public static final String EXTRA_NOTIFICATION_ID = "notification_id";
    public static final String EXTRA_REQUEST_ID = "request_id";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || intent.getAction() == null) return;

        String action = intent.getAction();
        int notificationId = intent.getIntExtra(EXTRA_NOTIFICATION_ID, -1);
        String requestId = intent.getStringExtra(EXTRA_REQUEST_ID);

        Log.i(TAG, "Notification action received: " + action + ", notifId=" + notificationId + ", reqId=" + requestId);

        // Dismiss the notification if ID provided
        if (notificationId != -1) {
            NotificationManager manager = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
            if (manager != null) {
                manager.cancel(notificationId);
            }
        }

        if (ACTION_DECLINE.equals(action)) {
            Log.i(TAG, "Game request declined by user from notification banner: " + requestId);
            // Request declined: notification dismissed cleanly
        }
    }
}
