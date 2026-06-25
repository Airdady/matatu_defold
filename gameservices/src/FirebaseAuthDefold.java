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
 * Google sign-in via Firebase Auth.
 *
 *   signIn(webClientId) -> Google account chooser -> Google ID token
 *                       -> Firebase signInWithCredential -> Firebase ID token
 *                       -> native onFirebaseToken(token, error)
 *
 * The Firebase ID token is what the backend (/auth/firebase) verifies with
 * firebase-admin. The native layer polls the stored result (no Lua callback
 * across threads).
 *
 * REQUIRES (provided by the app owner, not buildable here):
 *   - google-services.json in the project so FirebaseApp auto-initialises.
 *   - The OAuth *web* client id (Firebase console -> Auth -> Google provider),
 *     passed in from Lua config as webClientId.
 */
public class FirebaseAuthDefold {
    public static final int RC_SIGN_IN = 9001;

    private final Activity activity;
    private final FirebaseAuth auth;
    private GoogleSignInClient googleClient;

    // Implemented natively in gameservices.cpp.
    public static native void nativeLog(int level, String message);
    public static native void onFirebaseToken(String token, String error);

    public FirebaseAuthDefold(Activity activity) {
        this.activity = activity;
        FirebaseAuth a = null;
        try {
            a = FirebaseAuth.getInstance();
        } catch (Throwable t) {
            nativeLog(1, "FirebaseAuth init failed (is google-services.json present?): " + t.getMessage());
        }
        this.auth = a;
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
            onFirebaseToken(null, "Could not start Google sign-in: " + t.getMessage());
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
                onFirebaseToken(null, "No Google ID token returned");
                return;
            }
            if (auth == null) {
                onFirebaseToken(null, "Firebase not initialised");
                return;
            }
            AuthCredential credential = GoogleAuthProvider.getCredential(googleIdToken, null);
            auth.signInWithCredential(credential).addOnCompleteListener(activity, authTask -> {
                if (authTask.isSuccessful() && auth.getCurrentUser() != null) {
                    auth.getCurrentUser().getIdToken(true).addOnCompleteListener(tokTask -> {
                        if (tokTask.isSuccessful() && tokTask.getResult() != null) {
                            onFirebaseToken(tokTask.getResult().getToken(), null);
                        } else {
                            onFirebaseToken(null, "Failed to fetch Firebase ID token");
                        }
                    });
                } else {
                    String m = authTask.getException() != null ? authTask.getException().getMessage() : "Firebase sign-in failed";
                    onFirebaseToken(null, m);
                }
            });
        } catch (ApiException e) {
            onFirebaseToken(null, "Google sign-in failed (code " + e.getStatusCode() + ")");
        } catch (Throwable t) {
            onFirebaseToken(null, t.getMessage());
        }
    }

    public void signOut() {
        try {
            if (auth != null) auth.signOut();
            if (googleClient != null) googleClient.signOut();
        } catch (Throwable t) {
            nativeLog(2, "signOut: " + t.getMessage());
        }
    }
}
