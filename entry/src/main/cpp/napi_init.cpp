// NAPI module "xraybridge": the ArkTS face of libxray.so (golib/).
//
// Loaded only by XrayVpnExtensionAbility. Threading:
//   - start()/stop() run Xray on a libuv worker thread and settle a Promise, so the
//     JS thread stays free while Xray starts — it is needed to answer protect requests.
//   - Xray calls OnProtect() from its own threads for every socket it opens. Each call
//     is queued to the JS protect handler, which runs VpnConnection.protect(fd) and
//     answers with completeProtect(id, ok); the Go thread waits for that answer.
//   - Log lines are queued to the JS log listener without waiting.

#include <napi/native_api.h>
#include <hilog/log.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

extern "C" {
#include "libxray.h"
}

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0xD002F10
#define LOG_TAG "xraybridge"
#define LOGI(fmt, ...) ((void)OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__))
#define LOGW(fmt, ...) ((void)OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__))
#define LOGE(fmt, ...) ((void)OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__))

namespace {

constexpr auto kProtectTimeout = std::chrono::seconds(10);

std::mutex g_tsfnMtx;  // guards both tsfn handles against replacement while in use
napi_threadsafe_function g_logTsfn = nullptr;
napi_threadsafe_function g_protectTsfn = nullptr;

struct ProtectRequest {
    std::mutex mtx;
    std::condition_variable cv;
    bool done = false;
    bool ok = false;
};

std::mutex g_reqMtx;
std::unordered_map<uint32_t, std::shared_ptr<ProtectRequest>> g_requests;
std::atomic<uint32_t> g_nextId{1};

struct ProtectCall {
    uint32_t id;
    int fd;
};

// ---------- helpers ----------

std::string GetString(napi_env env, napi_value v) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) return "";
    std::string s(len, '\0');
    napi_get_value_string_utf8(env, v, s.data(), len + 1, &len);
    return s;
}

napi_value MakeString(napi_env env, const std::string& s) {
    napi_value v = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &v);
    return v;
}

size_t GetArgs(napi_env env, napi_callback_info info, napi_value* args, size_t max) {
    size_t argc = max;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return argc;
}

std::string TakeGoString(char* s) {
    if (s == nullptr) return "";
    std::string out(s);
    XrayFree(s);
    return out;
}

void ReplaceTsfn(napi_env env, napi_value cb, const char* name, napi_threadsafe_function_call_js callJs,
                 napi_threadsafe_function* slot) {
    napi_threadsafe_function fresh = nullptr;
    napi_valuetype type = napi_undefined;
    napi_typeof(env, cb, &type);
    if (type == napi_function) {
        napi_value resourceName = MakeString(env, name);
        // max_queue_size 0: unlimited, so a blocking call never waits on a full queue.
        if (napi_create_threadsafe_function(env, cb, nullptr, resourceName, 0, 1, nullptr, nullptr, nullptr,
                                            callJs, &fresh) == napi_ok) {
            // Do not keep the event loop alive just for these callbacks.
            napi_unref_threadsafe_function(env, fresh);
        } else {
            LOGE("napi_create_threadsafe_function(%{public}s) failed", name);
            fresh = nullptr;
        }
    }
    napi_threadsafe_function old = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_tsfnMtx);
        old = *slot;
        *slot = fresh;
    }
    if (old != nullptr) napi_release_threadsafe_function(old, napi_tsfn_release);
}

void FinishProtect(uint32_t id, bool ok) {
    std::shared_ptr<ProtectRequest> req;
    {
        std::lock_guard<std::mutex> lock(g_reqMtx);
        auto it = g_requests.find(id);
        if (it == g_requests.end()) return;  // already timed out
        req = it->second;
    }
    {
        std::lock_guard<std::mutex> lock(req->mtx);
        req->ok = ok;
        req->done = true;
    }
    req->cv.notify_all();
}

// ---------- callbacks from Go threads ----------

void CallJsLog(napi_env env, napi_value jsCb, void* /*context*/, void* data) {
    auto* line = static_cast<std::string*>(data);
    if (env != nullptr && jsCb != nullptr) {
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        napi_value arg = MakeString(env, *line);
        napi_call_function(env, undefined, jsCb, 1, &arg, nullptr);
    }
    delete line;
}

void CallJsProtect(napi_env env, napi_value jsCb, void* /*context*/, void* data) {
    auto* call = static_cast<ProtectCall*>(data);
    bool called = false;
    if (env != nullptr && jsCb != nullptr) {
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        napi_value req = nullptr;
        napi_create_object(env, &req);
        napi_value id = nullptr;
        napi_value fd = nullptr;
        napi_create_uint32(env, call->id, &id);
        napi_create_int32(env, call->fd, &fd);
        napi_set_named_property(env, req, "id", id);
        napi_set_named_property(env, req, "fd", fd);
        called = napi_call_function(env, undefined, jsCb, 1, &req, nullptr) == napi_ok;
    }
    if (!called) {
        LOGE("protect handler could not be called for fd %{public}d", call->fd);
        FinishProtect(call->id, false);
    }
    delete call;
}

void OnLog(const char* line) {
    LOGI("%{public}s", line);
    std::lock_guard<std::mutex> lock(g_tsfnMtx);
    if (g_logTsfn == nullptr) return;
    auto* copy = new std::string(line);
    if (napi_call_threadsafe_function(g_logTsfn, copy, napi_tsfn_nonblocking) != napi_ok) delete copy;
}

int OnProtect(int fd) {
    const uint32_t id = g_nextId.fetch_add(1);
    auto req = std::make_shared<ProtectRequest>();
    {
        std::lock_guard<std::mutex> lock(g_reqMtx);
        g_requests[id] = req;
    }
    bool queued = false;
    {
        std::lock_guard<std::mutex> lock(g_tsfnMtx);
        if (g_protectTsfn != nullptr) {
            auto* call = new ProtectCall{id, fd};
            queued = napi_call_threadsafe_function(g_protectTsfn, call, napi_tsfn_blocking) == napi_ok;
            if (!queued) delete call;
        }
    }
    bool ok = false;
    if (queued) {
        std::unique_lock<std::mutex> lock(req->mtx);
        if (req->cv.wait_for(lock, kProtectTimeout, [&] { return req->done; })) {
            ok = req->ok;
        } else {
            LOGE("protect(fd %{public}d) timed out", fd);
        }
    } else {
        LOGE("no protect handler; refusing fd %{public}d so it cannot loop into the VPN", fd);
    }
    {
        std::lock_guard<std::mutex> lock(g_reqMtx);
        g_requests.erase(id);
    }
    return ok ? 1 : 0;
}

// ---------- start / stop on a worker thread ----------

struct Work {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    bool isStart = true;
    std::string config;
    std::string assetDir;
    int tunFd = -1;
    std::string error;
};

void ExecuteWork(napi_env /*env*/, void* data) {
    auto* w = static_cast<Work*>(data);
    if (w->isStart) {
        w->error = TakeGoString(XrayStart(const_cast<char*>(w->config.c_str()), w->tunFd,
                                          const_cast<char*>(w->assetDir.c_str())));
    } else {
        w->error = TakeGoString(XrayStop());
    }
}

void CompleteWork(napi_env env, napi_status status, void* data) {
    auto* w = static_cast<Work*>(data);
    if (status != napi_ok && w->error.empty()) w->error = "worker cancelled";
    // Resolves with "" on success and the error message otherwise.
    napi_resolve_deferred(env, w->deferred, MakeString(env, w->error));
    napi_delete_async_work(env, w->work);
    delete w;
}

napi_value QueueWork(napi_env env, Work* w, const char* name) {
    napi_value promise = nullptr;
    napi_create_promise(env, &w->deferred, &promise);
    napi_create_async_work(env, nullptr, MakeString(env, name), ExecuteWork, CompleteWork, w, &w->work);
    napi_queue_async_work(env, w->work);
    return promise;
}

// ---------- JS API ----------

// start(configJson: string, tunFd: number, assetDir: string): Promise<string>
napi_value Start(napi_env env, napi_callback_info info) {
    napi_value args[3] = {nullptr, nullptr, nullptr};
    const size_t argc = GetArgs(env, info, args, 3);
    auto* w = new Work();
    if (argc >= 1) w->config = GetString(env, args[0]);
    if (argc >= 2) napi_get_value_int32(env, args[1], &w->tunFd);
    if (argc >= 3) w->assetDir = GetString(env, args[2]);
    return QueueWork(env, w, "xray.start");
}

// stop(): Promise<string>
napi_value Stop(napi_env env, napi_callback_info /*info*/) {
    auto* w = new Work();
    w->isStart = false;
    return QueueWork(env, w, "xray.stop");
}

napi_value Version(napi_env env, napi_callback_info /*info*/) {
    return MakeString(env, TakeGoString(XrayVersion()));
}

napi_value IsRunning(napi_env env, napi_callback_info /*info*/) {
    napi_value v = nullptr;
    napi_get_boolean(env, XrayIsRunning() != 0, &v);
    return v;
}

napi_value SetLogListener(napi_env env, napi_callback_info info) {
    napi_value args[1];
    if (GetArgs(env, info, args, 1) >= 1) ReplaceTsfn(env, args[0], "xray.log", CallJsLog, &g_logTsfn);
    return nullptr;
}

napi_value SetProtectHandler(napi_env env, napi_callback_info info) {
    napi_value args[1];
    if (GetArgs(env, info, args, 1) >= 1) {
        ReplaceTsfn(env, args[0], "xray.protect", CallJsProtect, &g_protectTsfn);
    }
    return nullptr;
}

// completeProtect(id: number, ok: boolean): void
napi_value CompleteProtect(napi_env env, napi_callback_info info) {
    napi_value args[2];
    if (GetArgs(env, info, args, 2) < 2) return nullptr;
    uint32_t id = 0;
    bool ok = false;
    napi_get_value_uint32(env, args[0], &id);
    napi_get_value_bool(env, args[1], &ok);
    FinishProtect(id, ok);
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports) {
    XraySetCallbacks(OnProtect, OnLog);
    napi_property_descriptor desc[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setLogListener", nullptr, SetLogListener, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setProtectHandler", nullptr, SetProtectHandler, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"completeProtect", nullptr, CompleteProtect, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

}  // namespace

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "xraybridge",
    .nm_priv = nullptr,
    .reserved = {nullptr, nullptr, nullptr, nullptr},
};

extern "C" __attribute__((constructor)) void RegisterXrayBridge() {
    napi_module_register(&g_module);
}
