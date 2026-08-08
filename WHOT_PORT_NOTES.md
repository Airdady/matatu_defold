Searched for "classify"
Viewed firebase_auth.lua:65-115
Viewed firebase_auth.lua:1-65
Viewed game.project:1-55
Listed directory be_matatu
Searched for "firebase"
Listed directory firebaseauth
Listed directory src
Viewed FirebaseAuthDefold.java:1-150
Viewed FirebaseAuthDefold.java:150-293
Viewed .env:1-60
Viewed .env:60-116
Viewed serviceAccountKey.json:1-14
Searched for "google-services"
Searched for "431938576253"
Searched for "431938576253"
Searched for "keystore"
Viewed release.sh:70-120
Viewed champion-keystore.pass.txt
Ran command: `keytool -list -v -keystore champion-keystore.jks -storepass Kanyanyama01 -alias upload`
Viewed nap-keystore.pass.txt
Ran command: `keytool -list -v -keystore nap-keystore.jks -storepass Kanyanyama01 -alias upload`
Ran command: `keytool -list -v -keystore ~/.android/debug.keystore -storepass android -alias androiddebugkey`
Viewed whot.pass.txt
Ran command: `keytool -list -v -keystore whot.keystore -storepass matatu -alias matatu_alias`
Ran command: `adb devices`

### Why You Are Getting "SIGN-IN MISCONFIGURED"

When the Google sign-in dialog opens fine on Android but immediately returns **"SIGN-IN MISCONFIGURED"** after selecting an account, Google Play Services is returning status code **10 (`DEVELOPER_ERROR`)** or **12500 (`SIGN_IN_FAILED`)**.

This happens when Google Play Services validates your APK against the Firebase/Google Cloud project (`matatu-7aba6`) and finds an OAuth configuration mismatch.

---

### Root Causes & Checklist

#### 1. Keystore SHA-1 / SHA-256 Fingerprint Mismatch (Most Common)
Google Play Services verifies the certificate fingerprint of the APK installed on your device against the Android App registered in Firebase. If the SHA-1 has not been added under your Android app in Firebase Console, Google rejects the token request with error `10`.

Here are the exact SHA fingerprints for your project keystores:

* **For `com.matatu.champ` (`champion-keystore.jks`):**
  * **SHA-1:** `01:91:F3:04:CC:B0:9E:BC:65:75:F9:92:09:EC:FB:53:A9:AF:C0:BA`
  * **SHA-256:** `96:32:F7:CA:EA:13:78:42:D0:BD:25:B3:D5:0B:7D:FC:1B:D3:0E:CE:AF:89:11:7C:2C:FA:42:E0:37:49:F7:A6`

* **For `com.matatu.nap` (`nap-keystore.jks`):**
  * **SHA-1:** `56:36:F9:1E:16:7E:64:35:65:F4:34:09:13:83:FD:3A:4E:77:7C:98`
  * **SHA-256:** `43:04:B8:A8:A2:F3:EE:1E:95:B4:8A:6D:B4:F8:88:E6:F2:C8:36:5D:57:D6:B8:47:FB:9B:7E:E8:23:FC:B6:87`

* **For `com.matatu.pro` (`whot.keystore`):**
  * **SHA-1:** `E2:BC:73:D8:66:28:DF:80:45:97:C7:E1:BA:B9:B8:20:0F:F7:5A:0B`
  * **SHA-256:** `CE:3D:8F:C2:A8:5D:8E:7F:27:20:8E:3C:C3:8C:D3:79:E8:57:31:51:A7:12:7A:AA:4E:DD:AA:F3:50:52:3B:3F`

* **If downloaded from Google Play Store (Internal / Closed Testing):**
  * Google Play re-signs the APK with Play App Signing.
  * Go to **Google Play Console > Release > Setup > App Integrity (App Signing)**, copy the **App signing key certificate SHA-1**, and add it to Firebase.

---

#### 2. Package Name in Firebase vs `game.project`
* In [`game.project`](file:///Users/mubarakruganda/Documents/defold/game.project#L36):
  ```ini
  [android]
  package = com.matatu.champ
  ```
* In **Firebase Console > Project Settings > Your Android Apps**, ensure an app exists with package name `com.matatu.champ` (and has the SHA-1 fingerprints above added under it).

---

#### 3. Web Client ID Type Mismatch
In [`game.project`](file:///Users/mubarakruganda/Documents/defold/game.project#L44):
```ini
[firebase]
web_client_id = 431938576253-53tdml3h9mrjb1eb6562k56ogqo9gsef.apps.googleusercontent.com
```
* The ID in `web_client_id` **must be the Type: Web Application OAuth 2.0 Client ID** (auto-created by Firebase under Google Cloud Console / Firebase Auth), **not** the Type: Android client ID.

---

#### 4. Google Sign-In Provider in Firebase Console
* In **Firebase Console > Authentication > Sign-in method**:
  * Ensure **Google** is set to **Enabled**.
  * Ensure a **Project support email** is selected.

---

### Step-by-Step Fix

1. Open **[Firebase Console](https://console.firebase.google.com/)** and select project **`matatu-7aba6`**.
2. Go to **Project Settings** (gear icon ⚙️) > **General** > scroll down to **Your apps**.
3. Under your Android app (`com.matatu.champ`):
   - Click **Add fingerprint**.
   - Paste `01:91:F3:04:CC:B0:9E:BC:65:75:F9:92:09:EC:FB:53:A9:AF:C0:BA` (SHA-1).
   - Click **Add fingerprint** again and paste `96:32:F7:CA:EA:13:78:42:D0:BD:25:B3:D5:0B:7D:FC:1B:D3:0E:CE:AF:89:11:7C:2C:FA:42:E0:37:49:F7:A6` (SHA-256).
4. Go to **Authentication > Sign-in method > Google**:
   - Ensure it is enabled.
   - Under **Web SDK configuration**, copy the **Web client ID** and confirm it matches `431938576253-53tdml3h9mrjb1eb6562k56ogqo9gsef.apps.googleusercontent.com`.
5. Re-run or rebuild the app on your device — the sign-in will succeed immediately without misconfiguration errors.