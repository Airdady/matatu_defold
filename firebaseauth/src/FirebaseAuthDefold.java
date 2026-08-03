package com.defold.android.firebaseauth;

import android.app.Activity;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Intent;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;
import com.google.firebase.messaging.FirebaseMessaging;

/**
 * Firebase Cloud Messaging for Defold. PUSH ONLY — there is no sign-in here.
 *
 * Authentication is the device id and, when that is not enough, the phone
 * number; both are plain HTTP against our own backend and neither involves
 * Google or Firebase. Everything that used to sign players in — the Google
 * Sign-In client, FirebaseAuth, the token exchange, the activity result — has
 * been removed, along with the play-services-auth and firebase-auth
 * dependencies behind it.
 *
 * WHAT IS LEFT, AND WHY IT CANNOT ALSO GO
 *
 * FCM is Firebase. A push notification needs a FirebaseApp, and Defold does
 * not apply the Google Services Gradle plugin, so google-services.json never
 * becomes the string resources that would normally create one. This class
 * builds FirebaseOptions by hand instead, and that same initialisation is what
 * fetches the registration token and creates the notification channels.
 *
 * The name is kept deliberately. Renaming the class means renaming the Java
 * package, the JNI signatures in firebaseauth.cpp and the service and receiver
 * entries in AndroidManifest.xml — all in lockstep, none of it verifiable
 * short of a device build, and getting it wrong stops notifications silently.
 * The cost of the name is a comment; the cost of the rename is push.
 */
public class FirebaseAuthDefold {

    private static final String TAG = "MatatuPush";

    private final Activity activity;
    private boolean ready = false;
    private String cachedFcmToken = "";

    // ── Is the player looking at the app right now? ───────────────────────────
    //
    // MatatuFirebaseMessagingService asks this before posting anything to the
    // shade. A push that arrives while the app is open is noise at best: the
    // in-app overlay is already showing that same game request, driven by the
    // WebSocket, so the player gets told twice — once by a banner they can act
    // on and once by a heads-up notification covering it.
    //
    // Static because the messaging service is constructed by the FCM SDK and
    // has no handle on the extension. It is the same process, so a static is
    // exactly the right amount of machinery.
    //
    // Counting STARTED rather than RESUMED activities: resumed goes false for
    // a permission dialog or the notification shade itself being pulled down,
    // and the app is plainly still open in both cases.
    private static int sStartedActivities = 0;
    private static boolean sLifecycleRegistered = false;

    /**
     * True when the app is on screen. False when it is backgrounded, killed,
     * or when nothing has told us either way — the safe default, because a
     * missed notification is worse than a redundant one.
     */
    public static boolean isAppInForeground() {
        return sStartedActivities > 0;
    }

    /** True once the lifecycle hook is installed, so callers know the answer means something. */
    public static boolean isForegroundTrackingActive() {
        return sLifecycleRegistered;
    }

    // Native side. Implemented in firebaseauth.cpp.
    public static native void nativeLog(int level, String message);
    public static native void onFcmTokenReceived(String token);

    public FirebaseAuthDefold(Activity activity) {
        this.activity = activity;
        trackForeground(activity);
    }

    /**
     * Installs the app-wide lifecycle hook that feeds isAppInForeground().
     *
     * Registered once, on the Application, so it survives every activity the
     * engine creates. Failure here is not fatal: the counter simply stays at
     * zero, isAppInForeground() answers false, and notifications behave exactly
     * as they did before this existed.
     */
    private static synchronized void trackForeground(Activity activity) {
        if (sLifecycleRegistered || activity == null) return;
        try {
            android.app.Application app = activity.getApplication();
            if (app == null) return;
            app.registerActivityLifecycleCallbacks(
                    new android.app.Application.ActivityLifecycleCallbacks() {
                @Override public void onActivityStarted(Activity a) { sStartedActivities++; }
                @Override public void onActivityStopped(Activity a) {
                    // Clamped. A stop without a matching start — which happens
                    // if the hook is installed while an activity is already
                    // running — would otherwise drive this negative and leave
                    // the app permanently reported as backgrounded, silently
                    // undoing the whole suppression.
                    if (sStartedActivities > 0) sStartedActivities--;
                }
                @Override public void onActivityCreated(Activity a, android.os.Bundle b) {}
                @Override public void onActivityResumed(Activity a) {}
                @Override public void onActivityPaused(Activity a) {}
                @Override public void onActivitySaveInstanceState(Activity a, android.os.Bundle b) {}
                @Override public void onActivityDestroyed(Activity a) {}
            });
            sLifecycleRegistered = true;
            // The extension is constructed from the activity's own start-up, so
            // by the time we get here it is already started and its
            // onActivityStarted has been and gone. Without this the app reads
            // as backgrounded until the player next switches away and back.
            sStartedActivities = 1;
            Log.i(TAG, "Foreground tracking active - pushes will be suppressed while the app is open");
        } catch (Throwable t) {
            Log.w(TAG, "Could not track foreground state: " + t.getMessage());
        }
    }

    /**
     * Builds the Firebase app and sets up the FCM token and channels.
     *
     * webClientId is gone with the sign-in it existed for — it was the OAuth
     * client Google Sign-In requested an id token against, and nothing here
     * requests one any more.
     */
    public boolean init(String apiKey, String appId, String projectId) {
        try {
            String pkg = activity != null ? activity.getPackageName() : "unknown";
            Log.i(TAG, "init: package=" + pkg + ", projectId=" + projectId + ", appId=" + appId);

            if (isBlank(apiKey))    { nativeLog(1, "firebase.api_key is not set in game.project"); return false; }
            if (isBlank(appId))     { nativeLog(1, "firebase.app_id is not set in game.project"); return false; }
            if (isBlank(projectId)) { nativeLog(1, "firebase.project_id is not set in game.project"); return false; }

            FirebaseApp app;
            try {
                app = FirebaseApp.getInstance();
            } catch (IllegalStateException notYet) {
                FirebaseOptions options = new FirebaseOptions.Builder()
                        .setApiKey(apiKey)
                        .setApplicationId(appId)
                        .setProjectId(projectId)
                        .build();
                app = FirebaseApp.initializeApp(activity, options);
            }

            createNotificationChannels();
            fetchFcmToken();

            ready = true;
            // The package name is printed because Firebase keys its Android app
            // registration on it, and a mismatch between this and the package
            // the Firebase project was registered under is invisible with
            // hand-built FirebaseOptions — initialisation succeeds and pushes
            // simply never arrive, with nothing logged either side.
            Log.i(TAG, "init: ready for package " + pkg + ", project " + projectId);
            nativeLog(0, "FCM ready (project " + projectId
                    + ", pkg " + pkg + ", appId " + appId + ")");
            return true;
        } catch (Exception | NoClassDefFoundError e) {
            ready = false;
            Log.e(TAG, "init error: " + e.getMessage(), e);
            nativeLog(1, "Firebase messaging failed to initialise: " + e.getMessage());
            return false;
        }
    }

    private void createNotificationChannels() {
        if (activity != null) {
            MatatuFirebaseMessagingService.ensureNotificationChannels(activity);
        }
    }

    public void fetchFcmToken() {
        try {
            FirebaseMessaging.getInstance().getToken()
                    .addOnCompleteListener(task -> {
                        if (task.isSuccessful() && task.getResult() != null) {
                            cachedFcmToken = task.getResult();
                            Log.i(TAG, "FCM registration token acquired: " + cachedFcmToken);
                            post(() -> onFcmTokenReceived(cachedFcmToken));
                        } else {
                            Log.w(TAG, "Fetching FCM token failed: " + task.getException());
                        }
                    });
        } catch (Exception | NoClassDefFoundError e) {
            Log.w(TAG, "FirebaseMessaging not available: " + e.getMessage());
        }
    }

    public String getFcmToken() {
        return cachedFcmToken != null ? cachedFcmToken : "";
    }

    /**
     * The notification button the player pressed to get here, if any.
     *
     * Returns "action|requestId" (either part may be empty), or "" when the app
     * was opened normally.
     *
     * READ ONCE. The extra is cleared from the intent on the way out, because
     * Android hands the same intent back for the life of the activity — left in
     * place, every focus regain for the rest of the session would look like a
     * fresh Accept press and re-accept a game that finished an hour ago.
     */
    public String consumePendingAction() {
        try {
            if (activity == null) return "";
            Intent intent = activity.getIntent();
            if (intent == null) return "";

            String action = intent.getStringExtra("push_action");
            if (isBlank(action)) return "";

            String requestId = intent.getStringExtra("push_request_id");
            intent.removeExtra("push_action");
            intent.removeExtra("push_request_id");
            activity.setIntent(intent);

            Log.i(TAG, "consumePendingAction: " + action + " (request " + requestId + ")");
            return action + "|" + (requestId == null ? "" : requestId);
        } catch (Exception e) {
            Log.w(TAG, "consumePendingAction failed: " + e.getMessage());
            return "";
        }
    }

    private void post(Runnable r) {
        new Handler(Looper.getMainLooper()).post(r);
    }

    private static boolean isBlank(String s) { return s == null || s.trim().isEmpty(); }
}
