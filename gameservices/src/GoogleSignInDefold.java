package com.defold.android.gameservices;

import android.app.Activity;
import android.content.Intent;

import com.google.android.gms.auth.api.signin.GoogleSignIn;
import com.google.android.gms.auth.api.signin.GoogleSignInAccount;
import com.google.android.gms.auth.api.signin.GoogleSignInClient;
import com.google.android.gms.auth.api.signin.GoogleSignInOptions;
import com.google.android.gms.common.api.ApiException;
import com.google.android.gms.tasks.Task;

import com.google.firebase.auth.AuthCredential;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.auth.GoogleAuthProvider;

/**
 * Google sign-in through Firebase Authentication.
 *
 *   signIn(webClientId) -> Google account chooser -> Google ID token
 *                       -> FirebaseAuth.signInWithCredential -> Firebase ID token
 *                       -> native onGoogleToken(firebaseIdToken, error)
 *
 * The backend verifies the Firebase ID token with firebase-admin
 * (admin.auth().verifyIdToken). FirebaseApp must already be initialised — that
 * is what extension-firebase + google-services.json provide. The Google account
 * picker still comes from play-services-auth.
 *
 * NOTE: firebase-auth requires Android minSdkVersion 23 (see the partial
 * manifests/android/AndroidManifest.xml in this extension).
 */
public class GoogleSignInDefold {
    public static final int RC_SIGN_IN = 9001;

    private final Activity activity;
    private GoogleSignInClient googleClient;

    // Implemented natively in gameservices.cpp.
    public static native void nativeLog(int level, String message);
    public static native void onGoogleToken(String token, String error);

    public GoogleSignInDefold(Activity activity) {
        this.activity = activity;
    }

    /** Start the Google account chooser. webClientId = OAuth web client id. */
    public void signIn(final String webClientId) {
        try {
            GoogleSignInOptions gso = new GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
                    .requestIdToken(webClientId)
                    .requestEmail()
                    .build();
            googleClient = GoogleSignIn.getClient(activity, gso);

            // Sign out first so the chooser always appears (lets users switch accounts).
            googleClient.signOut().addOnCompleteListener(activity, t -> {
                Intent intent = googleClient.getSignInIntent();
                activity.startActivityForResult(intent, RC_SIGN_IN);
            });
        } catch (Throwable t) {
            onGoogleToken(null, "Could not start Google sign-in: " + t.getMessage());
        }
    }

    /** Called from the native onActivityResult hook (main thread). */
    public void handleActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != RC_SIGN_IN) return;
        try {
            Task<GoogleSignInAccount> task = GoogleSignIn.getSignedInAccountFromIntent(data);
            GoogleSignInAccount account = task.getResult(ApiException.class);
            String googleIdToken = account.getIdToken();
            if (googleIdToken == null) {
                onGoogleToken(null, "No Google ID token returned (check the web client id)");
                return;
            }
            // Exchange the Google credential for a Firebase session, then fetch
            // the Firebase ID token the backend verifies.
            final FirebaseAuth auth = FirebaseAuth.getInstance();
            AuthCredential credential = GoogleAuthProvider.getCredential(googleIdToken, null);
            auth.signInWithCredential(credential).addOnCompleteListener(activity, authTask -> {
                if (authTask.isSuccessful() && auth.getCurrentUser() != null) {
                    auth.getCurrentUser().getIdToken(true).addOnCompleteListener(tokTask -> {
                        if (tokTask.isSuccessful() && tokTask.getResult() != null) {
                            onGoogleToken(tokTask.getResult().getToken(), null);
                        } else {
                            onGoogleToken(null, "Failed to fetch Firebase ID token");
                        }
                    });
                } else {
                    String m = authTask.getException() != null ? authTask.getException().getMessage() : "Firebase sign-in failed";
                    onGoogleToken(null, m);
                }
            });
        } catch (ApiException e) {
            onGoogleToken(null, "Google sign-in failed (code " + e.getStatusCode() + ")");
        } catch (Throwable t) {
            onGoogleToken(null, t.getMessage());
        }
    }

    public void signOut() {
        try {
            FirebaseAuth.getInstance().signOut();
            if (googleClient != null) googleClient.signOut();
        } catch (Throwable t) {
            nativeLog(2, "signOut: " + t.getMessage());
        }
    }
}
