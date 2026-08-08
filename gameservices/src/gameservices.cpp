#include <dmsdk/sdk.h>

#if defined(DM_PLATFORM_ANDROID)
#include <dmsdk/dlib/android.h>
#include <dmsdk/graphics/graphics_native.h> // Required for dmGraphics::GetNativeAndroidActivity()

static jobject g_InAppUpdateObj = NULL;
static jclass g_InAppUpdateClass = NULL;

// ── UNIVERSAL JNI LOGGING BRIDGE ──────────────────────────────────────────
extern "C" JNIEXPORT void JNICALL Java_com_defold_android_gameservices_InAppUpdateDefold_nativeLog(JNIEnv* env, jclass clazz, jint level, jstring message) {
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

// ── ANDROID ACTIVITY LIFECYCLE ──────────────────────────────────────────────
static void OnActivityResult(JNIEnv* env, jobject activity, int32_t requestCode, int32_t resultCode, void* data) {
    if (requestCode == 7001 && g_InAppUpdateObj != NULL) {
        jmethodID method = env->GetMethodID(g_InAppUpdateClass, "onActivityResult", "(I)V");
        env->CallVoidMethod(g_InAppUpdateObj, method, resultCode);
    }
}

// ── LUA TO JAVA BRIDGES ────────────────────────────────────────────────────
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

// Legacy OneSignal stubs for backwards compatibility if called
static int OneSignalLogin(lua_State* L) {
    return 0;
}
static int OneSignalLogout(lua_State* L) {
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
    
    jobject activity = dmGraphics::GetNativeAndroidActivity();

    dmLogInfo("GameServices: Spawning Native Subsystems...");

    // Instantiating InAppUpdate
    jclass updateCls = dmAndroid::LoadClass(env, "com/defold/android/gameservices/InAppUpdateDefold");
    g_InAppUpdateClass = (jclass)env->NewGlobalRef(updateCls);
    g_InAppUpdateObj = env->NewGlobalRef(env->NewObject(g_InAppUpdateClass, env->GetMethodID(g_InAppUpdateClass, "<init>", "(Landroid/app/Activity;)V"), activity));

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
    return dmExtension::RESULT_OK;
}
#else
static dmExtension::Result InitializeGameServices(dmExtension::Params* params) { return dmExtension::RESULT_OK; }
static dmExtension::Result FinalizeGameServices(dmExtension::Params* params) { return dmExtension::RESULT_OK; }
#endif

DM_DECLARE_EXTENSION(GameServices, "GameServices", NULL, NULL, InitializeGameServices, NULL, NULL, FinalizeGameServices)