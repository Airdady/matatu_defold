#include <dmsdk/sdk.h>

#if defined(DM_PLATFORM_ANDROID)
#include <dmsdk/dlib/android.h>
#include <dmsdk/dlib/mutex.h>
#include <dmsdk/graphics/graphics_native.h> // Required for dmGraphics::GetNativeAndroidActivity()
#include <string.h>

static jobject g_InAppUpdateObj = NULL;
static jclass g_InAppUpdateClass = NULL;
static jobject g_OneSignalObj = NULL;
static jclass g_OneSignalClass = NULL;
static jobject g_GoogleSignInObj = NULL;
static jclass  g_GoogleSignInClass = NULL;

// Google/Firebase sign-in result: written from a Firebase Task thread, read by
// polling from Lua on the main thread — guarded by a mutex (no Lua cross-thread).
static const int RC_SIGN_IN = 9001;
static dmMutex::HMutex g_SignInMutex = 0;
static int  g_SignInStatus = 0;        // 0 idle, 1 pending, 2 ok, 3 error
static char g_SignInToken[4096] = {0};
static char g_SignInError[512]  = {0};

// ── UNIVERSAL JNI LOGGING BRIDGE ──────────────────────────────────────────
extern "C" JNIEXPORT void JNICALL Java_com_defold_android_gameservices_OneSignalDefold_nativeLog(JNIEnv* env, jclass clazz, jint level, jstring message) {
    const char* msg_str = env->GetStringUTFChars(message, 0);
    if (level == 1) {
        dmLogError("GameServices [JAVA ERROR]: %s", msg_str);
    } else if (level == 2) {
        dmLogWarning("GameServices [JAVA WARN]: %s", msg_str);
    } else {
        dmLogInfo("GameServices [JAVA INFO]: %s", msg_str);
    }
    env->ReleaseStringUTFChars(message, msg_str);
}

extern "C" JNIEXPORT void JNICALL Java_com_defold_android_gameservices_InAppUpdateDefold_nativeLog(JNIEnv* env, jclass clazz, jint level, jstring message) {
    Java_com_defold_android_gameservices_OneSignalDefold_nativeLog(env, clazz, level, message);
}

// ── FIREBASE AUTH JNI BRIDGE ───────────────────────────────────────────────
extern "C" JNIEXPORT void JNICALL Java_com_defold_android_gameservices_GoogleSignInDefold_nativeLog(JNIEnv* env, jclass clazz, jint level, jstring message) {
    Java_com_defold_android_gameservices_OneSignalDefold_nativeLog(env, clazz, level, message);
}

// Sign-in result delivered from the Firebase Task (background thread). Stored
// under the mutex; Lua polls get_sign_in_status() to pick it up.
extern "C" JNIEXPORT void JNICALL Java_com_defold_android_gameservices_GoogleSignInDefold_onGoogleToken(JNIEnv* env, jclass clazz, jstring token, jstring error) {
    dmMutex::ScopedLock lk(g_SignInMutex);
    if (token != NULL) {
        const char* t = env->GetStringUTFChars(token, 0);
        strncpy(g_SignInToken, t, sizeof(g_SignInToken) - 1);
        g_SignInToken[sizeof(g_SignInToken) - 1] = 0;
        env->ReleaseStringUTFChars(token, t);
        g_SignInError[0] = 0;
        g_SignInStatus = 2; // ok
    } else {
        const char* e = error ? env->GetStringUTFChars(error, 0) : NULL;
        strncpy(g_SignInError, e ? e : "Sign-in failed", sizeof(g_SignInError) - 1);
        g_SignInError[sizeof(g_SignInError) - 1] = 0;
        if (error && e) env->ReleaseStringUTFChars(error, e);
        g_SignInToken[0] = 0;
        g_SignInStatus = 3; // error
    }
}

// ── EXISTING SERVICE EVENTS ────────────────────────────────────────────────
extern "C" JNIEXPORT void JNICALL Java_com_defold_android_gameservices_InAppUpdateDefold_onUpdateAvailable(JNIEnv* env, jclass clazz, jboolean available) {
    dmLogInfo("GameServices [Updates]: Update check complete. Available -> %d", available);
}

extern "C" JNIEXPORT void JNICALL Java_com_defold_android_gameservices_InAppUpdateDefold_onUpdateDownloaded(JNIEnv* env, jclass clazz) {
    dmLogInfo("GameServices [Updates]: Flexible Update Download Complete!");
}

extern "C" JNIEXPORT void JNICALL Java_com_defold_android_gameservices_InAppUpdateDefold_onUpdateFailed(JNIEnv* env, jclass clazz, jstring error) {
    const char* str = env->GetStringUTFChars(error, 0);
    dmLogError("GameServices [Updates] Flow Error: %s", str);
    env->ReleaseStringUTFChars(error, str);
}

extern "C" JNIEXPORT void JNICALL Java_com_defold_android_gameservices_OneSignalDefold_onNotificationAction(JNIEnv* env, jclass clazz, jstring actionId, jstring dataJson) {
    const char* act = env->GetStringUTFChars(actionId, 0);
    const char* data = env->GetStringUTFChars(dataJson, 0);
    dmLogInfo("GameServices [OneSignal]: Notification Intercepted! Action: %s, Data: %s", act, data);
    env->ReleaseStringUTFChars(actionId, act);
    env->ReleaseStringUTFChars(dataJson, data);
}

// ── ANDROID ACTIVITY LIFECYCLE ──────────────────────────────────────────────
// Replaced the old structural listener with the modern Defold Function Hook
static void OnActivityResult(JNIEnv* env, jobject activity, int32_t requestCode, int32_t resultCode, void* data) {
    if (requestCode == 7001 && g_InAppUpdateObj != NULL) {
        jmethodID method = env->GetMethodID(g_InAppUpdateClass, "onActivityResult", "(I)V");
        env->CallVoidMethod(g_InAppUpdateObj, method, resultCode);
    }
    if (requestCode == RC_SIGN_IN && g_GoogleSignInObj != NULL) {
        jmethodID method = env->GetMethodID(g_GoogleSignInClass, "handleActivityResult", "(IILandroid/content/Intent;)V");
        env->CallVoidMethod(g_GoogleSignInObj, method, (jint)requestCode, (jint)resultCode, (jobject)data);
    }
}

// ── LUA TO JAVA BRIDGES ────────────────────────────────────────────────────
// Using strict dmAndroid::ThreadAttacher syntax and .GetEnv() accessors
static int CheckUpdate(lua_State* L) {
    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();
    env->CallVoidMethod(g_InAppUpdateObj, env->GetMethodID(g_InAppUpdateClass, "checkForUpdate", "()V"));
    return 0;
}
static int StartFlexible(lua_State* L) {
    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();
    env->CallVoidMethod(g_InAppUpdateObj, env->GetMethodID(g_InAppUpdateClass, "startFlexibleUpdate", "()V"));
    return 0;
}
static int StartImmediate(lua_State* L) {
    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();
    env->CallVoidMethod(g_InAppUpdateObj, env->GetMethodID(g_InAppUpdateClass, "startImmediateUpdate", "()V"));
    return 0;
}
static int CompleteUpdate(lua_State* L) {
    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();
    env->CallVoidMethod(g_InAppUpdateObj, env->GetMethodID(g_InAppUpdateClass, "completeUpdate", "()V"));
    return 0;
}
static int OneSignalLogin(lua_State* L) {
    const char* userId = luaL_checkstring(L, 1);
    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();
    jstring jUserId = env->NewStringUTF(userId);
    env->CallVoidMethod(g_OneSignalObj, env->GetMethodID(g_OneSignalClass, "setExternalUserId", "(Ljava/lang/String;)V"), jUserId);
    env->DeleteLocalRef(jUserId);
    return 0;
}
static int OneSignalLogout(lua_State* L) {
    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();
    env->CallVoidMethod(g_OneSignalObj, env->GetMethodID(g_OneSignalClass, "logout", "()V"));
    return 0;
}

// gameservices.google_sign_in(web_client_id) — launches the Google
// account chooser; the Firebase ID token is delivered asynchronously and read
// back via get_sign_in_status().
static int GoogleSignIn(lua_State* L) {
    const char* webClientId = luaL_checkstring(L, 1);
    {
        dmMutex::ScopedLock lk(g_SignInMutex);
        g_SignInStatus = 1; // pending
        g_SignInToken[0] = 0;
        g_SignInError[0] = 0;
    }
    if (g_GoogleSignInObj == NULL) {
        dmMutex::ScopedLock lk(g_SignInMutex);
        strncpy(g_SignInError, "Google sign-in not available", sizeof(g_SignInError) - 1);
        g_SignInStatus = 3;
        return 0;
    }
    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();
    jstring jId = env->NewStringUTF(webClientId);
    env->CallVoidMethod(g_GoogleSignInObj, env->GetMethodID(g_GoogleSignInClass, "signIn", "(Ljava/lang/String;)V"), jId);
    env->DeleteLocalRef(jId);
    return 0;
}

static int GoogleSignOut(lua_State* L) {
    if (g_GoogleSignInObj != NULL) {
        dmAndroid::ThreadAttacher attacher;
        JNIEnv* env = attacher.GetEnv();
        env->CallVoidMethod(g_GoogleSignInObj, env->GetMethodID(g_GoogleSignInClass, "signOut", "()V"));
    }
    dmMutex::ScopedLock lk(g_SignInMutex);
    g_SignInStatus = 0;
    g_SignInToken[0] = 0;
    g_SignInError[0] = 0;
    return 0;
}

// Returns (status, value): status is "idle" | "pending" | "ok" | "error".
// value is the Firebase ID token when "ok", or the error message when "error".
static int GetSignInStatus(lua_State* L) {
    int status;
    char token[sizeof(g_SignInToken)];
    char err[sizeof(g_SignInError)];
    {
        dmMutex::ScopedLock lk(g_SignInMutex);
        status = g_SignInStatus;
        memcpy(token, g_SignInToken, sizeof(token));
        memcpy(err, g_SignInError, sizeof(err));
    }
    const char* s = "idle";
    if (status == 1) s = "pending";
    else if (status == 2) s = "ok";
    else if (status == 3) s = "error";
    lua_pushstring(L, s);
    lua_pushstring(L, status == 2 ? token : (status == 3 ? err : ""));
    return 2;
}

static const luaL_reg Module_methods[] = {
    {"check_update", CheckUpdate},
    {"start_flexible", StartFlexible},
    {"start_immediate", StartImmediate},
    {"complete_update", CompleteUpdate},
    {"onesignal_login", OneSignalLogin},
    {"onesignal_logout", OneSignalLogout},
    {"google_sign_in", GoogleSignIn},
    {"google_sign_out", GoogleSignOut},
    {"get_sign_in_status", GetSignInStatus},
    {NULL, NULL}
};

static dmExtension::Result InitializeGameServices(dmExtension::Params* params) {
    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();
    
    // Correctly fetch the Java jobject representing the active App Context via Graphics API
    jobject activity = dmGraphics::GetNativeAndroidActivity();

    dmLogInfo("GameServices: Spawning Native Subsystems...");

    // 1. Instantiating InAppUpdate
    jclass updateCls = dmAndroid::LoadClass(env, "com/defold/android/gameservices/InAppUpdateDefold");
    g_InAppUpdateClass = (jclass)env->NewGlobalRef(updateCls);
    g_InAppUpdateObj = env->NewGlobalRef(env->NewObject(g_InAppUpdateClass, env->GetMethodID(g_InAppUpdateClass, "<init>", "(Landroid/app/Activity;)V"), activity));

    // 2. Instantiating and Auto-Initializing OneSignal
    jclass osCls = dmAndroid::LoadClass(env, "com/defold/android/gameservices/OneSignalDefold");
    g_OneSignalClass = (jclass)env->NewGlobalRef(osCls);
    g_OneSignalObj = env->NewGlobalRef(env->NewObject(g_OneSignalClass, env->GetMethodID(g_OneSignalClass, "<init>", "(Landroid/app/Activity;)V"), activity));
    env->CallVoidMethod(g_OneSignalObj, env->GetMethodID(g_OneSignalClass, "init", "()V"));

    // 3. Instantiating Google Sign-In (Play Services)
    g_SignInMutex = dmMutex::New();
    jclass faCls = dmAndroid::LoadClass(env, "com/defold/android/gameservices/GoogleSignInDefold");
    g_GoogleSignInClass = (jclass)env->NewGlobalRef(faCls);
    g_GoogleSignInObj = env->NewGlobalRef(env->NewObject(g_GoogleSignInClass, env->GetMethodID(g_GoogleSignInClass, "<init>", "(Landroid/app/Activity;)V"), activity));

    // Register modern Activity Result Hook
    dmAndroid::RegisterOnActivityResultListener(OnActivityResult);

    luaL_register(params->m_L, "gameservices", Module_methods);
    lua_pop(params->m_L, 1);
    
    dmLogInfo("GameServices: Extension Bound to Lua Layer Successfully.");
    return dmExtension::RESULT_OK;
}

static dmExtension::Result FinalizeGameServices(dmExtension::Params* params) {
    dmAndroid::ThreadAttacher attacher; 
    JNIEnv* env = attacher.GetEnv();
    
    dmAndroid::UnregisterOnActivityResultListener(OnActivityResult);
    
    if(g_InAppUpdateObj) { env->DeleteGlobalRef(g_InAppUpdateObj); g_InAppUpdateObj = NULL; }
    if(g_InAppUpdateClass) { env->DeleteGlobalRef(g_InAppUpdateClass); g_InAppUpdateClass = NULL; }
    if(g_OneSignalObj) { env->DeleteGlobalRef(g_OneSignalObj); g_OneSignalObj = NULL; }
    if(g_OneSignalClass) { env->DeleteGlobalRef(g_OneSignalClass); g_OneSignalClass = NULL; }
    if(g_GoogleSignInObj) { env->DeleteGlobalRef(g_GoogleSignInObj); g_GoogleSignInObj = NULL; }
    if(g_GoogleSignInClass) { env->DeleteGlobalRef(g_GoogleSignInClass); g_GoogleSignInClass = NULL; }
    if(g_SignInMutex) { dmMutex::Delete(g_SignInMutex); g_SignInMutex = 0; }
    return dmExtension::RESULT_OK;
}
#else
static dmExtension::Result InitializeGameServices(dmExtension::Params* params) { return dmExtension::RESULT_OK; }
static dmExtension::Result FinalizeGameServices(dmExtension::Params* params) { return dmExtension::RESULT_OK; }
#endif

DM_DECLARE_EXTENSION(GameServices, "GameServices", NULL, NULL, InitializeGameServices, NULL, NULL, FinalizeGameServices)