// Firebase Authentication & Cloud Messaging — the Lua side.

#include <dmsdk/sdk.h>

#if defined(DM_PLATFORM_ANDROID)

#include <dmsdk/dlib/android.h>
#include <dmsdk/graphics/graphics_native.h>
#include <string.h>
#include <stdlib.h>

static jobject g_AuthObj = NULL;
static jclass  g_AuthClass = NULL;
static char*   g_CachedFcmToken = NULL;


// The FCM token arrives on its OWN schedule, and that is the whole problem this
// solves. FirebaseMessaging.getToken() is asynchronous and typically lands well
// after the app has booted, identified and gone quiet — so anything that reads
// the cached token at a fixed moment (as IDENTIFY did) reads an empty string on
// most cold starts and never learns otherwise.
//
// A separate listener, kept for the life of the app rather than consumed like
// the one-shot sign-in callback, because a token can also ROTATE: a reinstall,
// a restore to a new handset, or a data clear issues a new one, and pushes to
// the old one silently go nowhere.
static dmScript::LuaCallbackInfo* g_FcmCallback = NULL;
static char*        g_PendingFcmToken = NULL;
static dmMutex::HMutex g_FcmMutex = 0;

static char* Dup(JNIEnv* env, jstring s)
{
    if (s == NULL) return strdup("");
    const char* c = env->GetStringUTFChars(s, 0);
    char* out = strdup(c ? c : "");
    env->ReleaseStringUTFChars(s, c);
    return out;
}

// ── JNI callbacks (called from Java, on Java's threads) ────────────────────

extern "C" JNIEXPORT void JNICALL Java_com_defold_android_firebaseauth_FirebaseAuthDefold_nativeLog(
        JNIEnv* env, jclass clazz, jint level, jstring message)
{
    const char* msg = env->GetStringUTFChars(message, 0);
    
    if (level == 1) {
        dmLogError("FirebaseAuth [JAVA ERROR]: %s", msg);
    } else if (level == 2) {
        dmLogWarning("FirebaseAuth [JAVA WARN]: %s", msg);
    } else {
        dmLogInfo("FirebaseAuth [JAVA INFO]: %s", msg);
    }
    
    env->ReleaseStringUTFChars(message, msg);
}

extern "C" JNIEXPORT void JNICALL Java_com_defold_android_firebaseauth_FirebaseAuthDefold_onFcmTokenReceived(
        JNIEnv* env, jclass clazz, jstring token)
{
    if (g_CachedFcmToken) {
        free(g_CachedFcmToken);
        g_CachedFcmToken = NULL;
    }
    g_CachedFcmToken = Dup(env, token);
    dmLogInfo("FirebaseAuth [FCM]: Registration token received natively");

    // Queue it for Lua as well. Caching alone was the bug: the token was held
    // in C++ where nothing could learn it had arrived, so the one place that
    // read it had already read "" and moved on.
    {
        DM_MUTEX_SCOPED_LOCK(g_FcmMutex);
        if (g_PendingFcmToken) free(g_PendingFcmToken);
        g_PendingFcmToken = strdup(g_CachedFcmToken ? g_CachedFcmToken : "");
    }
}

// ── Lua API ────────────────────────────────────────────────────────────────

static void CallJavaVoid(const char* method)
{
    if (g_AuthObj == NULL) { dmLogError("FirebaseAuth: %s before init", method); return; }
    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();
    env->CallVoidMethod(g_AuthObj, env->GetMethodID(g_AuthClass, method, "()V"));
}

static int GetFcmToken(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 1);
    if (g_AuthObj != NULL)
    {
        dmAndroid::ThreadAttacher attacher;
        JNIEnv* env = attacher.GetEnv();
        jmethodID m = env->GetMethodID(g_AuthClass, "getFcmToken", "()Ljava/lang/String;");
        jstring jtok = (jstring)env->CallObjectMethod(g_AuthObj, m);
        const char* ctok = jtok ? env->GetStringUTFChars(jtok, 0) : "";
        lua_pushstring(L, ctok ? ctok : "");
        if (jtok) env->ReleaseStringUTFChars(jtok, ctok);
        return 1;
    }
    lua_pushstring(L, g_CachedFcmToken ? g_CachedFcmToken : "");
    return 1;
}

// Register a listener called whenever a token arrives — at boot, and again on
// every rotation. Deliberately NOT the one-shot sign-in callback: this one has
// to survive for the life of the app.
static int SetFcmListener(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 0);
    if (g_FcmCallback) { dmScript::DestroyCallback(g_FcmCallback); g_FcmCallback = NULL; }
    if (!lua_isnil(L, 1)) g_FcmCallback = dmScript::CreateCallback(L, 1);

    // A token that arrived BEFORE the listener was registered must not be lost.
    // The fetch is kicked off at extension init, so on a warm start it can and
    // does beat the game's own boot — and the listener would then wait forever
    // for an event that already happened.
    if (g_FcmCallback && g_CachedFcmToken && g_CachedFcmToken[0] != '\0')
    {
        DM_MUTEX_SCOPED_LOCK(g_FcmMutex);
        if (!g_PendingFcmToken) g_PendingFcmToken = strdup(g_CachedFcmToken);
    }
    return 0;
}

// The notification button the player pressed, if any. Returns action, requestId
// — or nil when the app was opened normally.
//
// Read once: the Java side clears the extra, because Android hands the same
// intent back for the life of the activity and a value left in place would make
// every focus regain look like a fresh press.
static int ConsumePendingAction(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 2);
    if (g_AuthObj == NULL) { lua_pushnil(L); lua_pushnil(L); return 2; }

    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();
    jmethodID m = env->GetMethodID(g_AuthClass, "consumePendingAction", "()Ljava/lang/String;");
    jstring jres = (jstring)env->CallObjectMethod(g_AuthObj, m);
    if (jres == NULL) { lua_pushnil(L); lua_pushnil(L); return 2; }

    const char* c = env->GetStringUTFChars(jres, 0);
    if (c == NULL || c[0] == '\0')
    {
        if (c) env->ReleaseStringUTFChars(jres, c);
        lua_pushnil(L); lua_pushnil(L);
        return 2;
    }

    // "action|requestId" — split on the first separator only, since a request id
    // is opaque and could in principle contain one.
    const char* bar = strchr(c, '|');
    if (bar == NULL)
    {
        lua_pushstring(L, c);
        lua_pushnil(L);
    }
    else
    {
        lua_pushlstring(L, c, (size_t)(bar - c));
        if (bar[1] == '\0') lua_pushnil(L); else lua_pushstring(L, bar + 1);
    }
    env->ReleaseStringUTFChars(jres, c);
    return 2;
}

static int FetchFcmToken(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 0);
    CallJavaVoid("fetchFcmToken");
    return 0;
}

static int IsAvailable(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 1);
    lua_pushboolean(L, g_AuthObj != NULL);
    return 1;
}

static const luaL_reg Module_methods[] =
{
    {"is_available",    IsAvailable},
    {"get_fcm_token",   GetFcmToken},
    {"fetch_fcm_token", FetchFcmToken},
    {"set_fcm_listener", SetFcmListener},
    {"consume_pending_action", ConsumePendingAction},
    {NULL, NULL}
};

// ── draining, on the main thread ───────────────────────────────────────────

static void DeliverFcmToken()
{
    char* token = NULL;
    {
        DM_MUTEX_SCOPED_LOCK(g_FcmMutex);
        if (!g_PendingFcmToken) return;
        token = g_PendingFcmToken;
        g_PendingFcmToken = NULL;
    }

    if (g_FcmCallback && dmScript::IsCallbackValid(g_FcmCallback))
    {
        lua_State* L = dmScript::GetCallbackLuaContext(g_FcmCallback);
        DM_LUA_STACK_CHECK(L, 0);
        if (dmScript::SetupCallback(g_FcmCallback))
        {
            lua_pushstring(L, token);
            if (lua_pcall(L, 2, 0, 0) != 0)
            {
                dmLogError("FirebaseAuth FCM callback error: %s", lua_tostring(L, -1));
                lua_pop(L, 1);
            }
            dmScript::TeardownCallback(g_FcmCallback);
        }
    }
    free(token);
}

static dmExtension::Result UpdateFirebaseAuth(dmExtension::Params* params)
{
    // One thing left to drain. Sign-in results used to arrive here too, on a
    // Firebase listener thread, which is why the queue and its mutex existed:
    // touching a lua_State from that thread works in testing and crashes in
    // the field with a stack naming none of the responsible code. The FCM
    // token arrives the same way and keeps the same treatment; nothing else
    // does, because nothing else comes back any more.
    DeliverFcmToken();
    return dmExtension::RESULT_OK;
}

// ── lifecycle ──────────────────────────────────────────────────────────────

static const char* Cfg(dmConfigFile::HConfig config, const char* key, const char* fallback)
{
    const char* v = dmConfigFile::GetString(config, key, fallback);
    return v ? v : "";
}

static dmExtension::Result InitializeFirebaseAuth(dmExtension::Params* params)
{
    g_FcmMutex = dmMutex::New();

    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();
    jobject activity = dmGraphics::GetNativeAndroidActivity();

    jclass cls = dmAndroid::LoadClass(env, "com/defold/android/firebaseauth/FirebaseAuthDefold");
    g_AuthClass = (jclass)env->NewGlobalRef(cls);
    g_AuthObj = env->NewGlobalRef(env->NewObject(
            g_AuthClass,
            env->GetMethodID(g_AuthClass, "<init>", "(Landroid/app/Activity;)V"),
            activity));

    const char* apiKey    = Cfg(params->m_ConfigFile, "firebase.api_key", "");
    const char* appId     = Cfg(params->m_ConfigFile, "firebase.app_id", "");
    const char* projectId = Cfg(params->m_ConfigFile, "firebase.project_id", "");

    jstring jApiKey  = env->NewStringUTF(apiKey);
    jstring jAppId   = env->NewStringUTF(appId);
    jstring jProject = env->NewStringUTF(projectId);

    jmethodID initMethod = env->GetMethodID(g_AuthClass, "init",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z");
    jboolean ok = env->CallBooleanMethod(g_AuthObj, initMethod, jApiKey, jAppId, jProject);

    env->DeleteLocalRef(jApiKey);
    env->DeleteLocalRef(jAppId);
    env->DeleteLocalRef(jProject);

    if (!ok)
    {
        dmLogError("Matatu push: initialisation failed — check the [firebase] section of game.project");
    }

    luaL_register(params->m_L, "firebaseauth", Module_methods);
    lua_pop(params->m_L, 1);

    dmLogInfo("FirebaseAuth: bound to Lua");
    return dmExtension::RESULT_OK;
}

static dmExtension::Result FinalizeFirebaseAuth(dmExtension::Params* params)
{
    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();

    if (g_FcmCallback) { dmScript::DestroyCallback(g_FcmCallback); g_FcmCallback = NULL; }
    if (g_FcmMutex)
    {
        {
            DM_MUTEX_SCOPED_LOCK(g_FcmMutex);
            if (g_PendingFcmToken) { free(g_PendingFcmToken); g_PendingFcmToken = NULL; }
        }
        dmMutex::Delete(g_FcmMutex);
        g_FcmMutex = 0;
    }
    if (g_CachedFcmToken) { free(g_CachedFcmToken); g_CachedFcmToken = NULL; }
    if (g_AuthObj)   { env->DeleteGlobalRef(g_AuthObj);   g_AuthObj = NULL; }
    if (g_AuthClass) { env->DeleteGlobalRef(g_AuthClass); g_AuthClass = NULL; }
    return dmExtension::RESULT_OK;
}

#else

static dmExtension::Result InitializeFirebaseAuth(dmExtension::Params* params) { return dmExtension::RESULT_OK; }
static dmExtension::Result FinalizeFirebaseAuth(dmExtension::Params* params) { return dmExtension::RESULT_OK; }
static dmExtension::Result UpdateFirebaseAuth(dmExtension::Params* params) { return dmExtension::RESULT_OK; }

#endif

DM_DECLARE_EXTENSION(FirebaseAuth, "FirebaseAuth", NULL, NULL,
                     InitializeFirebaseAuth, UpdateFirebaseAuth, NULL, FinalizeFirebaseAuth)