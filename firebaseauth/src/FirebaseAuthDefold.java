package com.defold.android.firebaseauth;

import android.app.Activity;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;

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

/**
 * Firebase Authentication for Defold.
 *
 * WHY FIREBASE IS INITIALISED BY HAND
 *
 * The normal Android setup drops a google-services.json into the app and lets
 * the com.google.gms.google-services Gradle plugin turn it into string
 * resources. Defold builds native extensions without applying that plugin, so
 * that path does not exist here. FirebaseOptions built in code is the supported
 * alternative and needs the same four values, which come from game.project's
 * [firebase] section — see firebaseauth.cpp.
 *
 * WHY LEGACY GoogleSignIn RATHER THAN CREDENTIAL MANAGER
 *
 * GoogleSignIn is deprecated in favour of androidx.credentials. It is used here
 * anyway, deliberately: it resolves through startActivityForResult, and the
 * activity-result hook is plumbing this project's extensions already have and
 * already use. Credential Manager needs an executor, a cancellation signal and
 * a separate no-credentials-available branch, none of which is hard but all of
 * which is untestable from a build machine with no device attached.
 *
 * When it does need replacing: everything outside getSignInIntent /
 * handleSignInResult stays as it is. The Firebase half takes a Google ID token
 * and does not care where it came from.
 *
 * THREADING
 *
 * Every Firebase and Play Services call here is asynchronous and lands on a
 * thread that is not Lua's. Nothing in this file touches Lua — results go out
 * through the native callbacks below, and firebaseauth.cpp queues them for the
 * next frame on the main thread. Calling into Lua from a listener thread is how
 * a crash arrives with a stack that names none of the code that caused it.
 */
public class FirebaseAuthDefold {

    // Any value not already claimed by another extension. GameServices uses
    // 7001 for its in-app update flow, and a collision would route this
    // extension's results into that one's handler.
    public static final int RC_SIGN_IN = 7011;

    private final Activity activity;
    private GoogleSignInClient googleClient;
    private FirebaseAuth auth;
    private boolean ready = false;

    // Native side. Implemented in firebaseauth.cpp.
    public static native void nativeLog(int level, String message);
    public static native void onAuthSuccess(String idToken, String uid, String email, String name, String photo);
    public static native void onAuthFailure(String code, String message);

    public FirebaseAuthDefold(Activity activity) {
        this.activity = activity;
    }

    /**
     * Builds the Firebase app and the Google sign-in client.
     *
     * Returns rather than throwing on missing configuration, and says exactly
     * which value is missing. A half-configured extension that fails later,
     * inside a sign-in attempt, produces "sign-in failed" and no clue why.
     */
    public boolean init(String apiKey, String appId, String projectId, String webClientId) {
        try {
            if (isBlank(apiKey))      { nativeLog(1, "firebase.api_key is not set in game.project"); return false; }
            if (isBlank(appId))       { nativeLog(1, "firebase.app_id is not set in game.project"); return false; }
            if (isBlank(projectId))   { nativeLog(1, "firebase.project_id is not set in game.project"); return false; }
            if (isBlank(webClientId)) { nativeLog(1, "firebase.web_client_id is not set in game.project"); return false; }

            FirebaseApp app;
            try {
                // Already up. Happens on an activity recreate — a rotation, or
                // the OS rebuilding the task — and initializing twice throws.
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

            // requestIdToken takes the WEB client id, not the Android one.
            // This is the single most common way this setup is got wrong: the
            // Android client id is what the app is registered under, but the
            // token has to be issued for the audience the backend verifies
            // against, and that is the web client.
            GoogleSignInOptions gso = new GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
                    .requestIdToken(webClientId)
                    .requestEmail()
                    .build();
            googleClient = GoogleSignIn.getClient(activity, gso);

            ready = true;
            nativeLog(0, "FirebaseAuth ready (project " + projectId + ")");
            return true;
        } catch (Exception | NoClassDefFoundError e) {
            ready = false;
            nativeLog(1, "FirebaseAuth failed to initialise: " + e.getMessage());
            return false;
        }
    }

    public boolean isSignedIn() {
        return ready && auth != null && auth.getCurrentUser() != null;
    }

    /** Opens the Google account picker. Result arrives via onActivityResult. */
    public void login() {
        if (!guardReady()) return;
        try {
            // Signed out of Google first so the picker actually appears. Without
            // it the client silently reuses the last account, which makes "sign
            // in as somebody else" impossible on a shared phone — and shared
            // phones are the normal case here.
            googleClient.signOut().addOnCompleteListener(activity, t ->
                    activity.startActivityForResult(googleClient.getSignInIntent(), RC_SIGN_IN));
        } catch (Exception e) {
            fail("sign-in-launch-failed", e.getMessage());
        }
    }

    /**
     * Signs in with no UI at all, if this device already has a session.
     *
     * This is the path that runs at every app start. It is not a fast version
     * of login() — it is the reason a returning player never sees a sign-in
     * screen, and it is why login() only ever needs to run once per install.
     */
    public void silentLogin() {
        if (!guardReady()) return;
        try {
            FirebaseUser current = auth.getCurrentUser();
            if (current != null) {
                // Firebase already holds the session. Its own refresh token
                // does the work; Google does not need to be consulted at all.
                emitToken(current, false);
                return;
            }

            googleClient.silentSignIn().addOnCompleteListener(activity, task -> {
                if (!task.isSuccessful()) {
                    Exception e = task.getException();
                    // Expected, not broken: no account on the device, or one
                    // that has never granted consent. The caller offers a
                    // button rather than treating it as an error.
                    fail("no-silent-session", e != null ? e.getMessage() : "no cached Google session");
                    return;
                }
                exchangeWithFirebase(task.getResult(), false);
            });
        } catch (Exception e) {
            fail("silent-sign-in-failed", e.getMessage());
        }
    }

    /** Called from the activity-result hook in firebaseauth.cpp. */
    public void handleSignInResult(Intent data) {
        if (!guardReady()) return;
        try {
            Task<GoogleSignInAccount> task = GoogleSignIn.getSignedInAccountFromIntent(data);
            GoogleSignInAccount account = task.getResult(ApiException.class);
            exchangeWithFirebase(account, true);
        } catch (ApiException e) {
            // getStatusCode is the useful part. 12501 is the player backing
            // out, 7 is the network, 10 is a misconfigured OAuth client — three
            // completely different problems that "sign-in failed" cannot tell
            // apart, and the third one fails for every user of the build.
            fail("google-" + e.getStatusCode(), e.getMessage());
        } catch (Exception e) {
            fail("sign-in-result-failed", e.getMessage());
        }
    }

    public void logout() {
        try {
            if (auth != null) auth.signOut();
            if (googleClient != null) googleClient.signOut();
            nativeLog(0, "FirebaseAuth signed out");
        } catch (Exception e) {
            nativeLog(1, "FirebaseAuth sign-out error: " + e.getMessage());
        }
    }

    /**
     * A fresh ID token for the account already signed in.
     *
     * Firebase ID tokens last an hour. Anything that reauthenticates against
     * the backend after the app has been open a while has to ask for a new one
     * rather than reuse whatever sign-in returned.
     */
    public void refreshToken() {
        if (!guardReady()) return;
        FirebaseUser user = auth.getCurrentUser();
        if (user == null) { fail("not-signed-in", "no Firebase session"); return; }
        emitToken(user, true);
    }

    // ── internals ──────────────────────────────────────────────────────────

    private void exchangeWithFirebase(GoogleSignInAccount account, boolean forceRefresh) {
        if (account == null || isBlank(account.getIdToken())) {
            // A sign-in that "succeeded" without a token means requestIdToken
            // was given a client id Google does not accept for this app. It is
            // silent and total: every user of the build hits it.
            fail("no-id-token", "Google returned no ID token — check firebase.web_client_id");
            return;
        }

        AuthCredential credential = GoogleAuthProvider.getCredential(account.getIdToken(), null);
        auth.signInWithCredential(credential).addOnCompleteListener(activity, task -> {
            if (!task.isSuccessful()) {
                Exception e = task.getException();
                fail("firebase-credential-rejected", e != null ? e.getMessage() : "unknown");
                return;
            }
            FirebaseUser user = auth.getCurrentUser();
            if (user == null) { fail("no-user-after-sign-in", "Firebase returned no user"); return; }
            emitToken(user, forceRefresh);
        });
    }

    /**
     * Fetches the Firebase ID token and hands it out.
     *
     * The token going to the backend is the FIREBASE one, never the Google one
     * that produced it. They look alike and both verify, but only the Firebase
     * token carries the uid the accounts are keyed on — sending Google's would
     * fail verification against the Firebase project and, if it somehow did
     * not, would key accounts on the wrong identity.
     */
    private void emitToken(FirebaseUser user, boolean forceRefresh) {
        user.getIdToken(forceRefresh).addOnCompleteListener(activity, (Task<GetTokenResult> task) -> {
            if (!task.isSuccessful() || task.getResult() == null || isBlank(task.getResult().getToken())) {
                Exception e = task.getException();
                fail("token-fetch-failed", e != null ? e.getMessage() : "no token returned");
                return;
            }
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
        fail("not-initialised", "FirebaseAuth did not initialise — check the [firebase] section of game.project");
        return false;
    }

    private void fail(String code, String message) {
        nativeLog(2, "FirebaseAuth " + code + ": " + message);
        post(() -> onAuthFailure(code, safe(message)));
    }

    // Onto the main looper before crossing into native. The callbacks are
    // queued on the C++ side either way, but keeping the JNI attach on one
    // known thread removes a whole class of intermittent crash.
    private void post(Runnable r) {
        new Handler(Looper.getMainLooper()).post(r);
    }

    private static boolean isBlank(String s) { return s == null || s.trim().isEmpty(); }
    private static String safe(String s) { return s == null ? "" : s; }
}
