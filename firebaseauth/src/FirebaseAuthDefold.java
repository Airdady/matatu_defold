package com.defold.android.firebaseauth;

import android.app.Activity;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Intent;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import com.google.android.gms.auth.api.signin.GoogleSignIn;
import com.google.android.gms.auth.api.signin.GoogleSignInAccount;
import com.google.android.gms.auth.api.signin.GoogleSignInClient;
import com.google.android.gms.auth.api.signin.GoogleSignInOptions;
import com.google.android.gms.common.api.ApiException;
import com.google.android.gms.tasks.Task;

import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;
import com.google.firebase.auth.AuthCredential;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.auth.FirebaseUser;
import com.google.firebase.auth.GetTokenResult;
import com.google.firebase.auth.GoogleAuthProvider;
import com.google.firebase.messaging.FirebaseMessaging;

/**
 * Firebase Authentication & Firebase Cloud Messaging for Defold.
 */
public class FirebaseAuthDefold {

    private static final String TAG = "FirebaseAuth";

    public static final int RC_SIGN_IN = 7011;

    private final Activity activity;
    private GoogleSignInClient googleClient;
    private FirebaseAuth auth;
    private boolean ready = false;
    private String cachedFcmToken = "";

    // Native side. Implemented in firebaseauth.cpp.
    public static native void nativeLog(int level, String message);
    public static native void onAuthSuccess(String idToken, String uid, String email, String name, String photo);
    public static native void onAuthFailure(String code, String message);
    public static native void onFcmTokenReceived(String token);

    public FirebaseAuthDefold(Activity activity) {
        this.activity = activity;
    }

    /**
     * Builds the Firebase app, the Google sign-in client, and sets up FCM channels.
     */
    public boolean init(String apiKey, String appId, String projectId, String webClientId) {
        try {
            String pkg = activity != null ? activity.getPackageName() : "unknown";
            Log.i(TAG, "init: package=" + pkg + ", projectId=" + projectId + ", webClientId=" + webClientId + ", appId=" + appId);

            if (isBlank(apiKey))      { nativeLog(1, "firebase.api_key is not set in game.project"); return false; }
            if (isBlank(appId))       { nativeLog(1, "firebase.app_id is not set in game.project"); return false; }
            if (isBlank(projectId))   { nativeLog(1, "firebase.project_id is not set in game.project"); return false; }
            if (isBlank(webClientId)) { nativeLog(1, "firebase.web_client_id is not set in game.project"); return false; }

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

            auth = FirebaseAuth.getInstance(app);

            GoogleSignInOptions gso = new GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
                    .requestIdToken(webClientId)
                    .requestEmail()
                    .build();
            googleClient = GoogleSignIn.getClient(activity, gso);

            createNotificationChannels();
            fetchFcmToken();

            ready = true;
            Log.i(TAG, "init: ready for package " + pkg + ", project " + projectId);
            nativeLog(0, "FirebaseAuth & FCM ready (project " + projectId + ", pkg " + pkg + ")");
            return true;
        } catch (Exception | NoClassDefFoundError e) {
            ready = false;
            Log.e(TAG, "init error: " + e.getMessage(), e);
            nativeLog(1, "FirebaseAuth failed to initialise: " + e.getMessage());
            return false;
        }
    }

    private void createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity != null) {
            try {
                NotificationManager manager = activity.getSystemService(NotificationManager.class);
                if (manager != null) {
                    NotificationChannel general = new NotificationChannel(
                            "general_channel",
                            "General Notifications",
                            NotificationManager.IMPORTANCE_DEFAULT
                    );
                    NotificationChannel gameRequests = new NotificationChannel(
                            "game_requests",
                            "Game Requests & Invites",
                            NotificationManager.IMPORTANCE_HIGH
                    );
                    manager.createNotificationChannel(general);
                    manager.createNotificationChannel(gameRequests);
                    Log.i(TAG, "Notification channels initialized");
                }
            } catch (Exception e) {
                Log.w(TAG, "Failed to create notification channels: " + e.getMessage());
            }
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

    public boolean isSignedIn() {
        return auth != null && auth.getCurrentUser() != null;
    }

    public void login() {
        if (!guardReady()) return;
        try {
            if (googleClient == null) { fail("no-google-client", "Google client not initialised"); return; }
            Intent intent = googleClient.getSignInIntent();
            Log.i(TAG, "login: launching Google Sign-In intent");
            activity.startActivityForResult(intent, RC_SIGN_IN);
        } catch (Exception e) {
            Log.e(TAG, "login failed: " + e.getMessage(), e);
            fail("intent-failed", e.getMessage());
        }
    }

    public void silentLogin() {
        if (!guardReady()) return;
        try {
            FirebaseUser current = auth.getCurrentUser();
            if (current != null) {
                Log.i(TAG, "silentLogin: existing Firebase user found: " + current.getUid());
                emitToken(current, false);
                return;
            }

            if (googleClient == null) { fail("no-google-client", "Google client not initialised"); return; }
            Log.i(TAG, "silentLogin: attempting Google silentSignIn");
            googleClient.silentSignIn().addOnCompleteListener(activity, task -> {
                if (task.isSuccessful()) {
                    GoogleSignInAccount account = task.getResult();
                    Log.i(TAG, "silentLogin: Google silentSignIn successful for " + account.getEmail());
                    exchangeWithFirebase(account, false);
                } else {
                    Exception e = task.getException();
                    Log.i(TAG, "silentLogin: Google silentSignIn failed/not-signed-in: " + (e != null ? e.getMessage() : "unknown"));
                    fail("silent-sign-in-failed", e != null ? e.getMessage() : "not signed in");
                }
            });
        } catch (Exception e) {
            Log.e(TAG, "silentLogin error: " + e.getMessage(), e);
            fail("silent-login-error", e.getMessage());
        }
    }

    public void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != RC_SIGN_IN) return;
        Log.i(TAG, "onActivityResult: received resultCode=" + resultCode);

        if (resultCode == Activity.RESULT_CANCELED) {
            Log.i(TAG, "onActivityResult: user cancelled sign in (RESULT_CANCELED)");
            fail("cancelled", "User cancelled sign in");
            return;
        }

        if (data == null) {
            Log.e(TAG, "onActivityResult: received null intent data");
            fail("null-intent-data", "Sign in returned no data");
            return;
        }

        handleSignInResult(data);
    }

    private void handleSignInResult(Intent data) {
        if (!guardReady()) return;
        try {
            Log.i(TAG, "handleSignInResult: received intent data");
            Task<GoogleSignInAccount> task = GoogleSignIn.getSignedInAccountFromIntent(data);
            GoogleSignInAccount account = task.getResult(ApiException.class);
            Log.i(TAG, "handleSignInResult: GoogleSignInAccount resolved for " + account.getEmail());
            exchangeWithFirebase(account, true);
        } catch (ApiException e) {
            Log.e(TAG, "handleSignInResult ApiException: code=" + e.getStatusCode() + ", status=" + e.getStatus() + ", message=" + e.getMessage(), e);
            String detail = "google-" + e.getStatusCode();
            String msg = (e.getStatus() != null && e.getStatus().getStatusMessage() != null) ? e.getStatus().getStatusMessage() : (e.getMessage() != null ? e.getMessage() : detail);
            fail(detail, msg);
        } catch (Exception e) {
            Log.e(TAG, "handleSignInResult unexpected exception: " + e.getMessage(), e);
            fail("sign-in-result-failed", e.getMessage());
        }
    }

    public void logout() {
        try {
            if (auth != null) auth.signOut();
            if (googleClient != null) googleClient.signOut();
            Log.i(TAG, "logout: signed out");
            nativeLog(0, "FirebaseAuth signed out");
        } catch (Exception e) {
            Log.e(TAG, "logout error: " + e.getMessage(), e);
            nativeLog(1, "FirebaseAuth sign-out error: " + e.getMessage());
        }
    }

    public void refreshToken() {
        if (!guardReady()) return;
        FirebaseUser user = auth.getCurrentUser();
        if (user == null) { fail("not-signed-in", "no Firebase session"); return; }
        emitToken(user, true);
    }

    // ── internals ──────────────────────────────────────────────────────────

    private void exchangeWithFirebase(GoogleSignInAccount account, boolean forceRefresh) {
        if (account == null || isBlank(account.getIdToken())) {
            Log.e(TAG, "exchangeWithFirebase: Google returned null or blank ID token! Check firebase.web_client_id and SHA-1");
            fail("no-id-token", "Google returned no ID token — check firebase.web_client_id and SHA-1");
            return;
        }

        Log.i(TAG, "exchangeWithFirebase: authenticating with Firebase using Google credential for " + account.getEmail());
        AuthCredential credential = GoogleAuthProvider.getCredential(account.getIdToken(), null);
        auth.signInWithCredential(credential).addOnCompleteListener(activity, task -> {
            if (!task.isSuccessful()) {
                Exception e = task.getException();
                Log.e(TAG, "exchangeWithFirebase: Firebase rejected credential: " + (e != null ? e.getMessage() : "unknown"), e);
                fail("firebase-credential-rejected", e != null ? e.getMessage() : "unknown");
                return;
            }
            FirebaseUser user = auth.getCurrentUser();
            if (user == null) {
                Log.e(TAG, "exchangeWithFirebase: Firebase returned no user after sign in");
                fail("no-user-after-sign-in", "Firebase returned no user");
                return;
            }
            Log.i(TAG, "exchangeWithFirebase: Firebase sign-in successful! uid=" + user.getUid());
            emitToken(user, forceRefresh);
        });
    }

    private void emitToken(FirebaseUser user, boolean forceRefresh) {
        Log.i(TAG, "emitToken: fetching Firebase ID token (forceRefresh=" + forceRefresh + ")...");
        user.getIdToken(forceRefresh).addOnCompleteListener(activity, (Task<GetTokenResult> task) -> {
            if (!task.isSuccessful() || task.getResult() == null || isBlank(task.getResult().getToken())) {
                Exception e = task.getException();
                Log.e(TAG, "emitToken failed: " + (e != null ? e.getMessage() : "null"), e);
                fail("token-fetch-failed", e != null ? e.getMessage() : "no token returned");
                return;
            }
            Log.i(TAG, "emitToken: successfully acquired Firebase token for " + user.getUid());
            post(() -> onAuthSuccess(
                    task.getResult().getToken(),
                    safe(user.getUid()),
                    safe(user.getEmail()),
                    safe(user.getDisplayName()),
                    user.getPhotoUrl() != null ? user.getPhotoUrl().toString() : ""));
        });
    }

    private boolean guardReady() {
        if (ready) return true;
        Log.e(TAG, "guardReady: FirebaseAuth did not initialise — check [firebase] in game.project");
        fail("not-initialised", "FirebaseAuth did not initialise — check the [firebase] section of game.project");
        return false;
    }

    private void fail(String code, String message) {
        Log.e(TAG, "fail: [" + code + "] " + message);
        nativeLog(2, "FirebaseAuth " + code + ": " + message);
        post(() -> onAuthFailure(code, safe(message)));
    }

    private void post(Runnable r) {
        new Handler(Looper.getMainLooper()).post(r);
    }

    private static boolean isBlank(String s) { return s == null || s.trim().isEmpty(); }
    private static String safe(String s) { return s == null ? "" : s; }
}
