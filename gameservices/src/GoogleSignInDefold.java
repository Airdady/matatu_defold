package com.defold.android.gameservices;

import android.app.Activity;
import android.content.Intent;

import com.google.android.gms.auth.api.signin.GoogleSignIn;
import com.google.android.gms.auth.api.signin.GoogleSignInAccount;
import com.google.android.gms.auth.api.signin.GoogleSignInClient;
import com.google.android.gms.auth.api.signin.GoogleSignInOptions;
import com.google.android.gms.common.api.ApiException;
import com.google.android.gms.tasks.Task;

/**
 * Google sign-in via Google Play Services (no Firebase SDK, no
 * google-services.json).
 *
 *   signIn(webClientId) -> Google account chooser -> Google ID token
 *                       -> native onGoogleToken(token, error)
 *
 * The Google ID token is verified on the backend with google-auth-library
 * (OAuth2Client.verifyIdToken, audience = webClientId). Same account-chooser UX
 * as Firebase, but only depends on play-services-auth so it builds cleanly.
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
            String idToken = account.getIdToken();
            if (idToken == null) {
                onGoogleToken(null, "No Google ID token returned (check the web client id)");
            } else {
                onGoogleToken(idToken, null);
            }
        } catch (ApiException e) {
            onGoogleToken(null, "Google sign-in failed (code " + e.getStatusCode() + ")");
        } catch (Throwable t) {
            onGoogleToken(null, t.getMessage());
        }
    }

    public void signOut() {
        try {
            if (googleClient != null) googleClient.signOut();
        } catch (Throwable t) {
            nativeLog(2, "signOut: " + t.getMessage());
        }
    }
}
