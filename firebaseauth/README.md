# firebaseauth

Firebase Authentication and Cloud Messaging, as a Defold native extension.

Built the same way as `gameservices/` next door: a Java class doing the real
work, a JNI bridge, and a Lua table registered at init. `modules/firebase_auth.lua`
wraps it so the rest of the app never has to know whether the extension exists
on this platform — outside Android it does not, and every call answers
"unavailable" rather than erroring, which is what lets the game still run in the
editor.

## Configuration

Four values in `game.project`, under `[firebase]`:

| key | where it comes from in `google-services.json` |
|---|---|
| `project_id` | `project_info.project_id` |
| `api_key` | `client[].api_key[0].current_key` |
| `app_id` | `client[].client_info.mobilesdk_app_id` |
| `web_client_id` | the `client[].oauth_client[]` entry with `client_type: 3` |

> **`game.project` has no comment syntax.** Only `[section]` headers and
> `key = value` lines parse; a `;` or `#` line breaks the build. That is why this
> file exists rather than a comment block in the config.

### Why the values are typed in rather than read from google-services.json

The normal Android setup drops `google-services.json` into the app and lets the
`com.google.gms.google-services` Gradle plugin turn it into string resources.
Defold builds native extensions without applying that plugin, so those generated
resources do not exist here. `FirebaseOptions` is therefore constructed by hand
in `FirebaseAuthDefold.java` from the four values above.

### `web_client_id` is the WEB client, not the Android one

`client_type: 3`. This is the single most common way the setup is got wrong, and
it fails **silently**: `requestIdToken` given a client Google will not issue for
this app returns a "successful" sign-in carrying no token at all, so every log
line says it worked. The extension reports that case as `no-id-token`, which
`firebase_auth.classify()` treats as `broken` — a build problem, not something to
retry.

### `project_id` must match the backend's service account

`admin.auth().verifyIdToken()` verifies a token against the admin SDK's own
project. A server holding a different project's service account rejects **every
login from every user, permanently**, with an `'aud'` claim error that reads like
a problem with the token rather than with which project the server was told to
expect.

The backend prints the project it resolved at startup, so this can be checked
rather than assumed:

```
[FIREBASE] verifying ID tokens for project "matatu-7aba6" (serviceAccountKey.json)
```

and names the mismatch explicitly when one occurs, instead of logging it the same
way as an expired token.

## SHA-1 registration

Google Sign-In needs an OAuth client registered against this app's **package name
AND signing certificate**. Debug and release builds are signed with different
certificates and each needs its own SHA-1 registered in the Firebase console.

When it is missing, sign-in fails with `DEVELOPER_ERROR` (status 10), whose own
message mentions neither packages nor certificates — which is how it gets
mistaken for a transient failure and retried for hours. The extension logs the
explanation, and `classify()` marks it `broken` so the ladder stops rather than
retrying something no retry can fix.

The package name is logged at init for the same reason: Firebase keys its Android
registration on it, and with hand-built `FirebaseOptions` a mismatch is invisible
until every sign-in fails.

```
FirebaseAuth & FCM ready (project matatu-7aba6, pkg com.matatu.champ, appId 1:...)
```

## FCM tokens

`FirebaseMessaging.getToken()` is asynchronous and starts at extension init. It
usually finishes **after** the app has booted, identified and gone quiet — so
anything that reads the cached token at one fixed moment reads an empty string on
most cold starts and never finds out otherwise.

The token is therefore **pushed when it arrives**, not pulled when something wants
it: `firebase_auth.on_fcm_token(fn)` registers a listener that lives for the life
of the app, and `controller.script` forwards to `POST /auth/fcm-token` when one
lands after sign-in. A token that arrives *before* sign-in needs no forwarding —
`ws.identify` reads the cache itself and carries it.

The listener also fires on **rotation**: a token changes on reinstall, on a
restore to a new handset, and when app data is cleared. Pushes to the retired one
fail silently, so a stale token is indistinguishable from a player who turned
notifications off. Every foreground re-asks; an unchanged value is dropped as a
duplicate rather than posted again.

To check the path end to end, the backend logs both halves:

```
[FIREBASE AUTH] 🔑 login attempt device=... NO fcm token (expect a follow-up /auth/fcm-token)
[FIREBASE AUTH] 📲 fcm token stored for user <id>
```

A login with no token is normal exactly once per install. A login with no token
and **no follow-up** means the client is not forwarding it.

### Known gap

Rotation while the app is backgrounded is not noticed until the next foreground.
Closing that properly needs a `FirebaseMessagingService` subclass overriding
`onNewToken`, declared in a merged `AndroidManifest.xml`.

## Threading

Every Firebase and Play Services call lands on a thread that is not Lua's.
Nothing in the Java layer touches Lua; results cross into C++, are queued under a
mutex, and are drained on the main thread once a frame in `UpdateFirebaseAuth`.
Calling into a `lua_State` from a listener thread is undefined behaviour that
works in testing and crashes in the field with a stack naming none of the
responsible code.
