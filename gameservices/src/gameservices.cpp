#include <dmsdk/sdk.h>

#if defined(DM_PLATFORM_ANDROID)
#include <dmsdk/dlib/android.h>
#include <dmsdk/graphics/graphics_native.h> // Required for dmGraphics::GetNativeAndroidActivity()

static jobject g_InAppUpdateObj = NULL;
static jclass g_InAppUpdateClass = NULL;
static jobject g_OneSignalObj = NULL;
static jclass g_OneSignalClass = NULL;

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

static const luaL_reg Module_methods[] = {
    {"check_update", CheckUpdate},
    {"start_flexible", StartFlexible},
    {"start_immediate", StartImmediate},
    {"complete_update", CompleteUpdate},
    {"onesignal_login", OneSignalLogin},
    {"onesignal_logout", OneSignalLogout},
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
    return dmExtension::RESULT_OK;
}
#else
static dmExtension::Result InitializeGameServices(dmExtension::Params* params) { return dmExtension::RESULT_OK; }
static dmExtension::Result FinalizeGameServices(dmExtension::Params* params) { return dmExtension::RESULT_OK; }
#endif

DM_DECLARE_EXTENSION(GameServices, "GameServices", NULL, NULL, InitializeGameServices, NULL, NULL, FinalizeGameServices)