// Firebase Authentication — the Lua side.
//
// Same shape as the GameServices extension next door: a Java class doing the
// real work, a JNI bridge, and a Lua table registered at init.
//
// ONE THING IT DOES THAT GAMESERVICES DOES NOT
//
// It answers back. GameServices' callbacks only log — nothing in the game waits
// on an in-app update. A sign-in result has to reach Lua, and it arrives on a
// Firebase listener thread, which is not the thread Lua runs on.
//
// Touching a lua_State from that thread is undefined behaviour, and the way it
// presents is the worst kind: it works in testing and crashes in the field with
// a stack naming none of the code responsible. So results are pushed onto a
// mutex-guarded queue and drained in UpdateFirebaseAuth, which Defold calls on
// the main thread once a frame. Nothing here calls into Lua from anywhere else.

#include <dmsdk/sdk.h>

#if defined(DM_PLATFORM_ANDROID)

#include <dmsdk/dlib/android.h>
#include <dmsdk/graphics/graphics_native.h>
#include <string.h>
#include <stdlib.h>

static jobject g_AuthObj = NULL;
static jclass  g_AuthClass = NULL;

// The Lua function waiting for the next result. One at a time on purpose:
// sign-in is a modal, user-driven act, and a second attempt while one is open
// is a double tap, not two separate questions. The second replaces the first
// rather than queueing behind it.
static dmScript::LuaCallbackInfo* g_Callback = NULL;

// Must match FirebaseAuthDefold.RC_SIGN_IN.
static const int RC_SIGN_IN = 7011;

struct AuthResult
{
    bool  m_Success;
    char* m_IdToken;
    char* m_Uid;
    char* m_Email;
    char* m_Name;
    char* m_Photo;
    char* m_Code;
    char* m_Message;
};

// Results land here from a Java thread and are drained on the main one.
static dmArray<AuthResult> g_Pending;
static dmMutex::HMutex     g_Mutex = 0;

static char* Dup(JNIEnv* env, jstring s)
{
    if (s == NULL) return strdup("");
    const char* c = env->GetStringUTFChars(s, 0);
    char* out = strdup(c ? c : "");
    env->ReleaseStringUTFChars(s, c);
    return out;
}

static void FreeResult(AuthResult& r)
{
    free(r.m_IdToken); free(r.m_Uid); free(r.m_Email);
    free(r.m_Name); free(r.m_Photo); free(r.m_Code); free(r.m_Message);
    memset(&r, 0, sizeof(AuthResult));
}

static void Enqueue(const AuthResult& r)
{
    DM_MUTEX_SCOPED_LOCK(g_Mutex);
    if (g_Pending.Full()) g_Pending.OffsetCapacity(4);
    g_Pending.Push(r);
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

extern "C" JNIEXPORT void JNICALL Java_com_defold_android_firebaseauth_FirebaseAuthDefold_onAuthSuccess(
        JNIEnv* env, jclass clazz, jstring idToken, jstring uid, jstring email, jstring name, jstring photo)
{
    AuthResult r;
    memset(&r, 0, sizeof(r));
    r.m_Success = true;
    r.m_IdToken = Dup(env, idToken);
    r.m_Uid     = Dup(env, uid);
    r.m_Email   = Dup(env, email);
    r.m_Name    = Dup(env, name);
    r.m_Photo   = Dup(env, photo);
    r.m_Code    = strdup("");
    r.m_Message = strdup("");
    Enqueue(r);
}

extern "C" JNIEXPORT void JNICALL Java_com_defold_android_firebaseauth_FirebaseAuthDefold_onAuthFailure(
        JNIEnv* env, jclass clazz, jstring code, jstring message)
{
    AuthResult r;
    memset(&r, 0, sizeof(r));
    r.m_Success = false;
    r.m_IdToken = strdup("");
    r.m_Uid     = strdup("");
    r.m_Email   = strdup("");
    r.m_Name    = strdup("");
    r.m_Photo   = strdup("");
    r.m_Code    = Dup(env, code);
    r.m_Message = Dup(env, message);
    Enqueue(r);
}

// ── activity result ────────────────────────────────────────────────────────

static void OnActivityResult(JNIEnv* env, jobject activity, int32_t requestCode, int32_t resultCode, void* data)
{
    if (requestCode != RC_SIGN_IN || g_AuthObj == NULL) return;
    jmethodID m = env->GetMethodID(g_AuthClass, "handleSignInResult", "(Landroid/content/Intent;)V");
    env->CallVoidMethod(g_AuthObj, m, (jobject)data);
}

// ── Lua API ────────────────────────────────────────────────────────────────

static void SetCallback(lua_State* L, int index)
{
    if (g_Callback) { dmScript::DestroyCallback(g_Callback); g_Callback = NULL; }
    if (!lua_isnil(L, index)) g_Callback = dmScript::CreateCallback(L, index);
}

static void CallJavaVoid(const char* method)
{
    if (g_AuthObj == NULL) { dmLogError("FirebaseAuth: %s before init", method); return; }
    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();
    env->CallVoidMethod(g_AuthObj, env->GetMethodID(g_AuthClass, method, "()V"));
}

static int Login(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 0);
    SetCallback(L, 1);
    CallJavaVoid("login");
    return 0;
}

static int SilentLogin(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 0);
    SetCallback(L, 1);
    CallJavaVoid("silentLogin");
    return 0;
}

static int RefreshToken(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 0);
    SetCallback(L, 1);
    CallJavaVoid("refreshToken");
    return 0;
}

static int Logout(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 0);
    CallJavaVoid("logout");
    return 0;
}

static int IsSignedIn(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 1);
    bool signed_in = false;
    if (g_AuthObj != NULL)
    {
        dmAndroid::ThreadAttacher attacher;
        JNIEnv* env = attacher.GetEnv();
        signed_in = env->CallBooleanMethod(g_AuthObj, env->GetMethodID(g_AuthClass, "isSignedIn", "()Z"));
    }
    lua_pushboolean(L, signed_in);
    return 1;
}

// True on a device where this extension is actually present and initialised.
// Lets Lua branch once at startup instead of pcall-ing every call site.
static int IsAvailable(lua_State* L)
{
    DM_LUA_STACK_CHECK(L, 1);
    lua_pushboolean(L, g_AuthObj != NULL);
    return 1;
}

static const luaL_reg Module_methods[] =
{
    {"login",         Login},
    {"silent_login",  SilentLogin},
    {"refresh_token", RefreshToken},
    {"logout",        Logout},
    {"is_signed_in",  IsSignedIn},
    {"is_available",  IsAvailable},
    {NULL, NULL}
};

// ── draining, on the main thread ───────────────────────────────────────────

static void Deliver(const AuthResult& r)
{
    if (g_Callback == NULL) return;
    if (!dmScript::IsCallbackValid(g_Callback)) return;

    lua_State* L = dmScript::GetCallbackLuaContext(g_Callback);
    DM_LUA_STACK_CHECK(L, 0);

    if (!dmScript::SetupCallback(g_Callback)) return;

    lua_newtable(L);
    lua_pushboolean(L, r.m_Success);          lua_setfield(L, -2, "success");
    lua_pushstring(L, r.m_IdToken);           lua_setfield(L, -2, "id_token");
    lua_pushstring(L, r.m_Uid);               lua_setfield(L, -2, "uid");
    lua_pushstring(L, r.m_Email);             lua_setfield(L, -2, "email");
    lua_pushstring(L, r.m_Name);              lua_setfield(L, -2, "name");
    lua_pushstring(L, r.m_Photo);             lua_setfield(L, -2, "photo");
    lua_pushstring(L, r.m_Code);              lua_setfield(L, -2, "code");
    lua_pushstring(L, r.m_Message);           lua_setfield(L, -2, "error");

    if (lua_pcall(L, 2, 0, 0) != 0)
    {
        dmLogError("FirebaseAuth callback error: %s", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    dmScript::TeardownCallback(g_Callback);
}

static dmExtension::Result UpdateFirebaseAuth(dmExtension::Params* params)
{
    // Copied out under the lock and delivered outside it. Holding a mutex
    // across a Lua call invites a deadlock the moment a callback does anything
    // that ends up back in here.
    dmArray<AuthResult> batch;
    {
        DM_MUTEX_SCOPED_LOCK(g_Mutex);
        if (g_Pending.Size() == 0) return dmExtension::RESULT_OK;
        batch.SetCapacity(g_Pending.Size());
        for (uint32_t i = 0; i < g_Pending.Size(); ++i) batch.Push(g_Pending[i]);
        g_Pending.SetSize(0);
    }

    for (uint32_t i = 0; i < batch.Size(); ++i)
    {
        Deliver(batch[i]);
        FreeResult(batch[i]);
    }
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
    g_Mutex = dmMutex::New();
    g_Pending.SetCapacity(4);

    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();
    jobject activity = dmGraphics::GetNativeAndroidActivity();

    jclass cls = dmAndroid::LoadClass(env, "com/defold/android/firebaseauth/FirebaseAuthDefold");
    g_AuthClass = (jclass)env->NewGlobalRef(cls);
    g_AuthObj = env->NewGlobalRef(env->NewObject(
            g_AuthClass,
            env->GetMethodID(g_AuthClass, "<init>", "(Landroid/app/Activity;)V"),
            activity));

    // Straight out of game.project rather than google-services.json. Defold does
    // not apply the Google Services Gradle plugin, so the generated string
    // resources that file normally becomes do not exist in this build.
    const char* apiKey    = Cfg(params->m_ConfigFile, "firebase.api_key", "");
    const char* appId     = Cfg(params->m_ConfigFile, "firebase.app_id", "");
    const char* projectId = Cfg(params->m_ConfigFile, "firebase.project_id", "");
    const char* webClient = Cfg(params->m_ConfigFile, "firebase.web_client_id", "");

    jstring jApiKey  = env->NewStringUTF(apiKey);
    jstring jAppId   = env->NewStringUTF(appId);
    jstring jProject = env->NewStringUTF(projectId);
    jstring jWeb     = env->NewStringUTF(webClient);

    jmethodID initMethod = env->GetMethodID(g_AuthClass, "init",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Z");
    jboolean ok = env->CallBooleanMethod(g_AuthObj, initMethod, jApiKey, jAppId, jProject, jWeb);

    env->DeleteLocalRef(jApiKey);
    env->DeleteLocalRef(jAppId);
    env->DeleteLocalRef(jProject);
    env->DeleteLocalRef(jWeb);

    if (!ok)
    {
        // The object stays, so is_available() reports true and calls return a
        // named failure through the normal path. Dropping it here would make
        // every call silently do nothing instead.
        dmLogError("FirebaseAuth: initialisation failed — check the [firebase] section of game.project");
    }

    dmAndroid::RegisterOnActivityResultListener(OnActivityResult);

    luaL_register(params->m_L, "firebaseauth", Module_methods);
    lua_pop(params->m_L, 1);

    dmLogInfo("FirebaseAuth: bound to Lua");
    return dmExtension::RESULT_OK;
}

static dmExtension::Result FinalizeFirebaseAuth(dmExtension::Params* params)
{
    dmAndroid::ThreadAttacher attacher;
    JNIEnv* env = attacher.GetEnv();

    dmAndroid::UnregisterOnActivityResultListener(OnActivityResult);

    if (g_Callback) { dmScript::DestroyCallback(g_Callback); g_Callback = NULL; }

    if (g_Mutex)
    {
        {
            DM_MUTEX_SCOPED_LOCK(g_Mutex);
            for (uint32_t i = 0; i < g_Pending.Size(); ++i) FreeResult(g_Pending[i]);
            g_Pending.SetSize(0);
        }
        dmMutex::Delete(g_Mutex);
        g_Mutex = 0;
    }

    if (g_AuthObj)   { env->DeleteGlobalRef(g_AuthObj);   g_AuthObj = NULL; }
    if (g_AuthClass) { env->DeleteGlobalRef(g_AuthClass); g_AuthClass = NULL; }
    return dmExtension::RESULT_OK;
}

#else

// Every other platform, including the editor. The extension registers nothing
// at all, so `firebaseauth` is nil in Lua and modules/firebase_auth.lua takes
// its stub path — which is what lets the game still run in the editor.
static dmExtension::Result InitializeFirebaseAuth(dmExtension::Params* params) { return dmExtension::RESULT_OK; }
static dmExtension::Result FinalizeFirebaseAuth(dmExtension::Params* params) { return dmExtension::RESULT_OK; }
static dmExtension::Result UpdateFirebaseAuth(dmExtension::Params* params) { return dmExtension::RESULT_OK; }

#endif

DM_DECLARE_EXTENSION(FirebaseAuth, "FirebaseAuth", NULL, NULL,
                     InitializeFirebaseAuth, UpdateFirebaseAuth, NULL, FinalizeFirebaseAuth)