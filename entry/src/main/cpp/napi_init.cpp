#include "napi/native_api.h"
#include "hilog/log.h"
#include "libtailscale_go.h"
#include <string>
#include <vector>

namespace {
using AsyncStringFunction = char* (*)();

struct AsyncStringWork {
    napi_env env;
    napi_async_work work;
    napi_deferred deferred;
    AsyncStringFunction function;
    std::string result;
    bool succeeded;
};

enum class AsyncInputOperation {
    NetworkChanged,
    FrpStart,
    FrpProfileStart,
    FrpProfileStop,
    CoexistenceSetInboundTCPPorts,
    CoexistenceSetInboundTCPPolicy,
    ClashRepairConfig,
    SetExitNode,
    SetNetworkSetting,
    PeerConnectivity,
    SunshineProbe,
    MediaServiceProbe,
    TaildropSend,
    TaildropReceive,
    TaildriveList,
    TaildriveStat,
    TaildriveMutate,
    TaildriveDownload,
    TaildriveManualDownload,
    TaildriveUpload
};

struct AsyncInputWork {
    napi_async_work work;
    napi_deferred deferred;
    AsyncInputOperation operation;
    std::string input;
    bool enabled;
    std::string result;
    bool succeeded;
};

void ExecuteAsyncString(napi_env env, void* data)
{
    (void)env;
    auto* work = static_cast<AsyncStringWork*>(data);
    char* message = work->function();
    if (message == nullptr) {
        work->succeeded = false;
        return;
    }
    work->result.assign(message);
    TSFreeString(message);
    work->succeeded = true;
}

void CompleteAsyncString(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<AsyncStringWork*>(data);
    napi_value value = nullptr;
    if (status == napi_ok && work->succeeded &&
        napi_create_string_utf8(env, work->result.c_str(), NAPI_AUTO_LENGTH, &value) == napi_ok) {
        napi_resolve_deferred(env, work->deferred, value);
    } else {
        napi_value message = nullptr;
        napi_value error = nullptr;
        napi_create_string_utf8(env, "Native backend operation failed", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, work->deferred, error);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value CreateAsyncStringPromise(
    napi_env env, AsyncStringFunction function, const char* resourceName)
{
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create native backend promise");
        return nullptr;
    }
    auto* work = new AsyncStringWork{env, nullptr, deferred, function, "", false};
    napi_value resource = nullptr;
    if (napi_create_string_utf8(env, resourceName, NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, ExecuteAsyncString, CompleteAsyncString, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) {
            napi_delete_async_work(env, work->work);
        }
        delete work;
        napi_throw_error(env, nullptr, "Failed to queue native backend operation");
        return nullptr;
    }
    return promise;
}

void ExecuteAsyncInput(napi_env env, void* data)
{
    (void)env;
    auto* work = static_cast<AsyncInputWork*>(data);
    char* message = nullptr;
    if (work->operation == AsyncInputOperation::FrpStart) {
        message = TSFrpStart(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::FrpProfileStart) {
        message = TSFrpProfileStart(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::FrpProfileStop) {
        message = TSFrpProfileStop(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::CoexistenceSetInboundTCPPorts) {
        message = TSCoexistenceSetInboundTCPPorts(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::CoexistenceSetInboundTCPPolicy) {
        message = TSCoexistenceSetInboundTCPPolicy(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::ClashRepairConfig) {
        message = TSClashRepairConfig(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::NetworkChanged) {
        message = TSBackendNetworkChanged(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::SetExitNode) {
        message = TSBackendSetExitNode(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::SetNetworkSetting) {
        message = TSBackendSetNetworkSetting(const_cast<char*>(work->input.c_str()), work->enabled ? 1 : 0);
    } else if (work->operation == AsyncInputOperation::PeerConnectivity) {
        message = TSBackendPeerConnectivity(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::SunshineProbe) {
        message = TSBackendSunshineProbe(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::MediaServiceProbe) {
        message = TSBackendMediaServiceProbe(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::TaildropSend) {
        message = TSBackendTaildropSend(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::TaildropReceive) {
        message = TSBackendTaildropReceive(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::TaildriveList) {
        message = TSBackendTaildriveList(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::TaildriveStat) {
        message = TSBackendTaildriveStat(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::TaildriveMutate) {
        message = TSBackendTaildriveMutate(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::TaildriveDownload) {
        message = TSBackendTaildriveDownload(const_cast<char*>(work->input.c_str()));
    } else if (work->operation == AsyncInputOperation::TaildriveManualDownload) {
        message = TSBackendTaildriveManualDownload(const_cast<char*>(work->input.c_str()));
    } else {
        message = TSBackendTaildriveUpload(const_cast<char*>(work->input.c_str()));
    }
    if (message == nullptr) {
        work->succeeded = false;
        return;
    }
    work->result.assign(message);
    TSFreeString(message);
    work->succeeded = true;
}

void CompleteAsyncInput(napi_env env, napi_status status, void* data)
{
    auto* work = static_cast<AsyncInputWork*>(data);
    napi_value value = nullptr;
    if (status == napi_ok && work->succeeded &&
        napi_create_string_utf8(env, work->result.c_str(), NAPI_AUTO_LENGTH, &value) == napi_ok) {
        napi_resolve_deferred(env, work->deferred, value);
    } else {
        napi_value message = nullptr;
        napi_value error = nullptr;
        napi_create_string_utf8(env, "Native backend update failed", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, work->deferred, error);
    }
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value CreateAsyncInputPromise(
    napi_env env, AsyncInputOperation operation, const std::string& input, bool enabled, const char* resourceName)
{
    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create native backend update promise");
        return nullptr;
    }
    auto* work = new AsyncInputWork{nullptr, deferred, operation, input, enabled, "", false};
    napi_value resource = nullptr;
    if (napi_create_string_utf8(env, resourceName, NAPI_AUTO_LENGTH, &resource) != napi_ok ||
        napi_create_async_work(env, nullptr, resource, ExecuteAsyncInput, CompleteAsyncInput, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work != nullptr) {
            napi_delete_async_work(env, work->work);
        }
        delete work;
        napi_throw_error(env, nullptr, "Failed to queue native backend update");
        return nullptr;
    }
    return promise;
}

napi_value BackendSetExitNodeAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendSetExitNodeAsync requires one selection");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Exit-node selection must be a string");
        return nullptr;
    }
    std::vector<char> selection(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], selection.data(), selection.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the exit-node selection");
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::SetExitNode, selection.data(), false, "TailscaleBackendSetExitNode");
}

napi_value BackendSetNetworkSettingAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
        napi_throw_type_error(env, nullptr, "backendSetNetworkSettingAsync requires a key and boolean value");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Network setting key must be a string");
        return nullptr;
    }
    std::vector<char> key(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], key.data(), key.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the network setting key");
        return nullptr;
    }
    bool enabled = false;
    if (napi_get_value_bool(env, args[1], &enabled) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Network setting value must be a boolean");
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::SetNetworkSetting, key.data(), enabled, "TailscaleBackendSetNetworkSetting");
}

napi_value BackendPeerConnectivityAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendPeerConnectivityAsync requires one peer key");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Peer key must be a string");
        return nullptr;
    }
    std::vector<char> key(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], key.data(), key.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the peer key");
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::PeerConnectivity, key.data(), false, "TailscaleBackendPeerConnectivity");
}

napi_value BackendNetworkChangedAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    size_t length = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1 ||
        napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok || length > 64) {
        napi_throw_type_error(env, nullptr, "backendNetworkChangedAsync requires an interface name");
        return nullptr;
    }
    std::vector<char> name(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], name.data(), name.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the interface name");
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::NetworkChanged, name.data(), false, "TailscaleBackendNetworkChanged");
}

napi_value BackendSunshineProbeAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendSunshineProbeAsync requires one peer key");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Peer key must be a string");
        return nullptr;
    }
    std::vector<char> key(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], key.data(), key.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the peer key");
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::SunshineProbe, key.data(), false, "TailscaleBackendSunshineProbe");
}

napi_value BackendMediaServiceProbeAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendMediaServiceProbeAsync requires one peer key");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Peer key must be a string");
        return nullptr;
    }
    std::vector<char> key(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], key.data(), key.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the peer key");
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::MediaServiceProbe, key.data(), false, "TailscaleBackendMediaServiceProbe");
}

napi_value BackendTaildropSendAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendTaildropSendAsync requires one request");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Taildrop request must be a string");
        return nullptr;
    }
    std::vector<char> request(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], request.data(), request.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the Taildrop request");
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::TaildropSend, request.data(), false, "TailscaleBackendTaildropSend");
}

napi_value BackendTaildropReceiveAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendTaildropReceiveAsync requires one request");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Taildrop receive request must be a string");
        return nullptr;
    }
    std::vector<char> request(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], request.data(), request.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the Taildrop receive request");
        return nullptr;
    }
    return CreateAsyncInputPromise(
        env, AsyncInputOperation::TaildropReceive, request.data(), false, "TailscaleBackendTaildropReceive");
}

napi_value BackendTaildropCancelAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendTaildropCancel, "TailscaleBackendTaildropCancel");
}

napi_value BackendTaildriveRequestAsync(
    napi_env env, napi_callback_info info, AsyncInputOperation operation,
    const char* argumentError, const char* readError, const char* resourceName)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, argumentError);
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Taildrive request must be a string");
        return nullptr;
    }
    if (operation == AsyncInputOperation::FrpStart && length > 262144) {
        napi_throw_range_error(env, nullptr, "FRP configuration exceeds 256 KiB");
        return nullptr;
    }
    if (operation == AsyncInputOperation::FrpProfileStart && length > 1048576) {
        napi_throw_range_error(env, nullptr, "FRP profile request exceeds 1 MiB");
        return nullptr;
    }
    if (operation == AsyncInputOperation::FrpProfileStop && length > 100) {
        napi_throw_range_error(env, nullptr, "FRP profileId exceeds 100 bytes");
        return nullptr;
    }
    if ((operation == AsyncInputOperation::CoexistenceSetInboundTCPPorts ||
        operation == AsyncInputOperation::CoexistenceSetInboundTCPPolicy) && length > 256) {
        napi_throw_range_error(env, nullptr, "Inbound TCP port list exceeds 256 bytes");
        return nullptr;
    }
    if (operation == AsyncInputOperation::ClashRepairConfig && length > 2097152) {
        napi_throw_range_error(env, nullptr, "Clash configuration exceeds 2 MiB");
        return nullptr;
    }
    std::vector<char> request(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], request.data(), request.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, readError);
        return nullptr;
    }
    return CreateAsyncInputPromise(env, operation, request.data(), false, resourceName);
}

napi_value BackendTaildriveListAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::TaildriveList,
        "backendTaildriveListAsync requires one request", "Failed to read the Taildrive list request",
        "TailscaleBackendTaildriveList");
}

napi_value FrpStartAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::FrpStart,
        "frpStartAsync requires one TOML configuration", "Failed to read FRP configuration", "FrpStart");
}

napi_value FrpStopAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSFrpStop, "FrpStop");
}

napi_value FrpStatusAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSFrpStatus, "FrpStatus");
}

napi_value FrpProfileStartAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::FrpProfileStart,
        "frpProfileStartAsync requires one JSON request", "Failed to read FRP profile request",
        "FrpProfileStart");
}

napi_value FrpProfileStopAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::FrpProfileStop,
        "frpProfileStopAsync requires one profileId", "Failed to read FRP profileId", "FrpProfileStop");
}

napi_value FrpProfilesStatusAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSFrpProfilesStatus, "FrpProfilesStatus");
}

napi_value CoexistenceStartAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSCoexistenceStart, "CoexistenceStart");
}

napi_value CoexistenceStopAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSCoexistenceStop, "CoexistenceStop");
}

napi_value CoexistenceStatusAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSCoexistenceStatus, "CoexistenceStatus");
}

napi_value CoexistenceSetInboundTCPPortsAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::CoexistenceSetInboundTCPPorts,
        "coexistenceSetInboundTCPPortsAsync requires one JSON port array",
        "Failed to read inbound TCP port list", "CoexistenceSetInboundTCPPorts");
}

napi_value CoexistenceSetInboundTCPPolicyAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::CoexistenceSetInboundTCPPolicy,
        "coexistenceSetInboundTCPPolicyAsync requires one JSON policy",
        "Failed to read inbound TCP policy", "CoexistenceSetInboundTCPPolicy");
}

napi_value CoexistenceRepairClashConfigAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::ClashRepairConfig,
        "coexistenceRepairClashConfigAsync requires one Clash configuration string",
        "Failed to read Clash configuration", "CoexistenceRepairClashConfig");
}

napi_value BackendTaildriveStatAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::TaildriveStat,
        "backendTaildriveStatAsync requires one request", "Failed to read the Taildrive stat request",
        "TailscaleBackendTaildriveStat");
}

napi_value BackendTaildriveMutateAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::TaildriveMutate,
        "backendTaildriveMutateAsync requires one request", "Failed to read the Taildrive mutation request",
        "TailscaleBackendTaildriveMutate");
}

napi_value BackendTaildriveDownloadAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::TaildriveDownload,
        "backendTaildriveDownloadAsync requires one request", "Failed to read the Taildrive download request",
        "TailscaleBackendTaildriveDownload");
}

napi_value BackendTaildriveUploadAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::TaildriveUpload,
        "backendTaildriveUploadAsync requires one request", "Failed to read the Taildrive upload request",
        "TailscaleBackendTaildriveUpload");
}

napi_value BackendTaildriveManualDownloadAsync(napi_env env, napi_callback_info info)
{
    return BackendTaildriveRequestAsync(env, info, AsyncInputOperation::TaildriveManualDownload,
        "backendTaildriveManualDownloadAsync requires one request",
        "Failed to read the Taildrive manual download request",
        "TailscaleBackendTaildriveManualDownload");
}

napi_value BackendTaildriveTransferSnapshotAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(
        env, TSBackendTaildriveTransferSnapshot, "TailscaleBackendTaildriveTransferSnapshot");
}

napi_value BackendTaildriveCancelAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendTaildriveCancel, "TailscaleBackendTaildriveCancel");
}

napi_value BackendSnapshotAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendSnapshot, "TailscaleBackendSnapshot");
}

napi_value BackendLocalSendRefreshAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(
        env, TSBackendLocalSendRefresh, "TailscaleBackendLocalSendRefresh");
}

napi_value BackendTaildropIncomingSnapshotAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(
        env, TSBackendTaildropIncomingSnapshot, "TailscaleBackendTaildropIncomingSnapshot");
}

napi_value BackendStopAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendStop, "TailscaleBackendStop");
}

napi_value BackendLogoutAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendLogout, "TailscaleBackendLogout");
}

napi_value BackendAuthURLAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendAuthURL, "TailscaleBackendAuthURL");
}

napi_value BackendVpnConfigAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendVPNConfig, "TailscaleBackendVpnConfig");
}

napi_value ProbeEngineAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSProbeEngine, "TailscaleEngineProbe");
}

napi_value BackendPeerProbeAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendPeerProbe, "TailscaleBackendPeerProbe");
}

napi_value BackendMediaProbeSelfTestAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSMediaProbeSelfTest, "MeshArcMediaProbeSelfTest");
}

napi_value Hello(napi_env env, napi_callback_info info)
{
    (void)info;
    OH_LOG_INFO(LOG_APP, "C++ N-API bridge loaded; calling Go runtime");
    char* message = TSHello();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Go bridge returned a null status string");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to convert the Go status to an ArkTS string");
        return nullptr;
    }
    return result;
}

napi_value ProbeEngine(napi_env env, napi_callback_info info)
{
    (void)info;
    OH_LOG_INFO(LOG_APP, "Initializing Tailscale userspace engine probe");
    char* message = TSProbeEngine();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale engine probe returned a null status string");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to convert the Tailscale engine status to an ArkTS string");
        return nullptr;
    }
    return result;
}

napi_value BackendStart(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 4) {
        napi_throw_type_error(env, nullptr,
            "backendStart requires state directory, device model, OS version and control server");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "backendStart state directory must be a string");
        return nullptr;
    }
    std::vector<char> stateDir(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], stateDir.data(), stateDir.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the backend state directory");
        return nullptr;
    }
    size_t modelLength = 0;
    if (napi_get_value_string_utf8(env, args[1], nullptr, 0, &modelLength) != napi_ok) {
        napi_throw_type_error(env, nullptr, "backendStart device model must be a string");
        return nullptr;
    }
    std::vector<char> deviceModel(modelLength + 1, '\0');
    if (napi_get_value_string_utf8(env, args[1], deviceModel.data(), deviceModel.size(), &modelLength) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the backend device model");
        return nullptr;
    }
    size_t osVersionLength = 0;
    if (napi_get_value_string_utf8(env, args[2], nullptr, 0, &osVersionLength) != napi_ok) {
        napi_throw_type_error(env, nullptr, "backendStart OS version must be a string");
        return nullptr;
    }
    std::vector<char> osVersion(osVersionLength + 1, '\0');
    if (napi_get_value_string_utf8(env, args[2], osVersion.data(), osVersion.size(), &osVersionLength) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the backend OS version");
        return nullptr;
    }
    size_t controlLength = 0;
    if (napi_get_value_string_utf8(env, args[3], nullptr, 0, &controlLength) != napi_ok) {
        napi_throw_type_error(env, nullptr, "backendStart control server must be a string");
        return nullptr;
    }
    std::vector<char> controlURL(controlLength + 1, '\0');
    if (napi_get_value_string_utf8(env, args[3], controlURL.data(), controlURL.size(), &controlLength) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the backend control server");
        return nullptr;
    }
    OH_LOG_INFO(LOG_APP, "Starting the persistent Tailscale LocalBackend");
    char* message = TSBackendStart(
        stateDir.data(), deviceModel.data(), osVersion.data(), controlURL.data());
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale backend start returned a null status string");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to convert the Tailscale backend start status");
        return nullptr;
    }
    return result;
}

napi_value BackendStop(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendStop();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Backend stop returned a null status");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create backend stop status");
        return nullptr;
    }
    return result;
}

napi_value BackendLogout(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendLogout();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Backend logout returned a null status");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create backend logout status");
        return nullptr;
    }
    return result;
}

napi_value BackendStatus(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendStatus();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale backend status returned a null string");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to convert the Tailscale backend status");
        return nullptr;
    }
    return result;
}

napi_value BackendStatusAsync(napi_env env, napi_callback_info info)
{
    (void)info;
    return CreateAsyncStringPromise(env, TSBackendStatus, "TailscaleBackendStatus");
}

napi_value BackendAuthURL(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendAuthURL();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale login URL is unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer the Tailscale login URL");
        return nullptr;
    }
    return result;
}

napi_value BackendVpnConfig(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendVPNConfig();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale VPN config is unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer the Tailscale VPN config");
        return nullptr;
    }
    return result;
}

napi_value BackendExitNodes(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendExitNodes();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Exit-node choices are unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer exit-node choices");
        return nullptr;
    }
    return result;
}

napi_value BackendPeers(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendPeers();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Peer summaries are unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer peer summaries");
        return nullptr;
    }
    return result;
}

napi_value BackendAccount(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendAccount();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Account summary is unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer the account summary");
        return nullptr;
    }
    return result;
}

napi_value TailscaleVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSTailscaleVersion();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale version is unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer the Tailscale version");
        return nullptr;
    }
    return result;
}

napi_value BackendNetworkSettings(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendNetworkSettings();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Network settings are unavailable");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer network settings");
        return nullptr;
    }
    return result;
}

napi_value BackendSetNetworkSetting(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
        napi_throw_type_error(env, nullptr, "backendSetNetworkSetting requires a key and boolean value");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Network setting key must be a string");
        return nullptr;
    }
    std::vector<char> key(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], key.data(), key.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the network setting key");
        return nullptr;
    }
    bool enabled = false;
    if (napi_get_value_bool(env, args[1], &enabled) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Network setting value must be a boolean");
        return nullptr;
    }
    char* message = TSBackendSetNetworkSetting(key.data(), enabled ? 1 : 0);
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Network setting update returned a null status");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer network setting update status");
        return nullptr;
    }
    return result;
}

napi_value BackendSetExitNode(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "backendSetExitNode requires one selection");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Exit-node selection must be a string");
        return nullptr;
    }
    std::vector<char> selection(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], selection.data(), selection.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the exit-node selection");
        return nullptr;
    }
    char* message = TSBackendSetExitNode(selection.data());
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Exit-node update returned a null status");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer exit-node update status");
        return nullptr;
    }
    return result;
}

napi_value BackendPeerProbe(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSBackendPeerProbe();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Peer probe returned a null status");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to create peer probe status");
        return nullptr;
    }
    return result;
}

napi_value BackendRestartWithTun(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 5) {
        napi_throw_type_error(env, nullptr,
            "backendRestartWithTun requires state directory, device model, OS version, control server and TUN descriptor");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "VPN backend state directory must be a string");
        return nullptr;
    }
    std::vector<char> stateDir(length + 1, '\0');
    if (napi_get_value_string_utf8(env, args[0], stateDir.data(), stateDir.size(), &length) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the VPN backend state directory");
        return nullptr;
    }
    size_t modelLength = 0;
    if (napi_get_value_string_utf8(env, args[1], nullptr, 0, &modelLength) != napi_ok) {
        napi_throw_type_error(env, nullptr, "VPN backend device model must be a string");
        return nullptr;
    }
    std::vector<char> deviceModel(modelLength + 1, '\0');
    if (napi_get_value_string_utf8(env, args[1], deviceModel.data(), deviceModel.size(), &modelLength) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the VPN backend device model");
        return nullptr;
    }
    size_t osVersionLength = 0;
    if (napi_get_value_string_utf8(env, args[2], nullptr, 0, &osVersionLength) != napi_ok) {
        napi_throw_type_error(env, nullptr, "VPN backend OS version must be a string");
        return nullptr;
    }
    std::vector<char> osVersion(osVersionLength + 1, '\0');
    if (napi_get_value_string_utf8(env, args[2], osVersion.data(), osVersion.size(), &osVersionLength) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the VPN backend OS version");
        return nullptr;
    }
    size_t controlLength = 0;
    if (napi_get_value_string_utf8(env, args[3], nullptr, 0, &controlLength) != napi_ok) {
        napi_throw_type_error(env, nullptr, "VPN backend control server must be a string");
        return nullptr;
    }
    std::vector<char> controlURL(controlLength + 1, '\0');
    if (napi_get_value_string_utf8(env, args[3], controlURL.data(), controlURL.size(), &controlLength) != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to read the VPN backend control server");
        return nullptr;
    }
    int32_t fd = -1;
    if (napi_get_value_int32(env, args[4], &fd) != napi_ok) {
        napi_throw_type_error(env, nullptr, "VPN TUN descriptor must be an integer");
        return nullptr;
    }
    char* message = TSBackendRestartWithTun(
        stateDir.data(), deviceModel.data(), osVersion.data(), controlURL.data(), fd);
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "VPN backend restart returned a null status");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to transfer the VPN backend restart status");
        return nullptr;
    }
    return result;
}

napi_value ControlProbe(napi_env env, napi_callback_info info)
{
    (void)info;
    char* message = TSControlProbe();
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "Tailscale control probe returned a null string");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to convert the Tailscale control probe status");
        return nullptr;
    }
    return result;
}

napi_value TunFdProbe(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "tunFdProbe requires one file descriptor");
        return nullptr;
    }
    int32_t fd = -1;
    if (napi_get_value_int32(env, args[0], &fd) != napi_ok) {
        napi_throw_type_error(env, nullptr, "tunFdProbe file descriptor must be an integer");
        return nullptr;
    }
    char* message = TSTunFDProbe(fd);
    if (message == nullptr) {
        napi_throw_error(env, nullptr, "TUN descriptor probe returned a null string");
        return nullptr;
    }
    napi_value result = nullptr;
    napi_status status = napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &result);
    TSFreeString(message);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to convert the TUN descriptor probe status");
        return nullptr;
    }
    return result;
}
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"hello", nullptr, Hello, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"frpStartAsync", nullptr, FrpStartAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"frpStopAsync", nullptr, FrpStopAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"frpStatusAsync", nullptr, FrpStatusAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"frpProfileStartAsync", nullptr, FrpProfileStartAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"frpProfileStopAsync", nullptr, FrpProfileStopAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"frpProfilesStatusAsync", nullptr, FrpProfilesStatusAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coexistenceStartAsync", nullptr, CoexistenceStartAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coexistenceStopAsync", nullptr, CoexistenceStopAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coexistenceStatusAsync", nullptr, CoexistenceStatusAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coexistenceSetInboundTCPPortsAsync", nullptr, CoexistenceSetInboundTCPPortsAsync, nullptr, nullptr,
            nullptr, napi_default, nullptr},
        {"coexistenceSetInboundTCPPolicyAsync", nullptr, CoexistenceSetInboundTCPPolicyAsync, nullptr, nullptr,
            nullptr, napi_default, nullptr},
        {"coexistenceRepairClashConfigAsync", nullptr, CoexistenceRepairClashConfigAsync, nullptr, nullptr,
            nullptr, napi_default, nullptr},
        {"probeEngine", nullptr, ProbeEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeEngineAsync", nullptr, ProbeEngineAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStart", nullptr, BackendStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStop", nullptr, BackendStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendLogout", nullptr, BackendLogout, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStatus", nullptr, BackendStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStatusAsync", nullptr, BackendStatusAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendSnapshot", nullptr, BackendSnapshotAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendLocalSendRefreshAsync", nullptr, BackendLocalSendRefreshAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildropIncomingSnapshot", nullptr, BackendTaildropIncomingSnapshotAsync,
            nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendStopAsync", nullptr, BackendStopAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendLogoutAsync", nullptr, BackendLogoutAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendAuthURLAsync", nullptr, BackendAuthURLAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendVpnConfigAsync", nullptr, BackendVpnConfigAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendAuthURL", nullptr, BackendAuthURL, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendVpnConfig", nullptr, BackendVpnConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendExitNodes", nullptr, BackendExitNodes, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeers", nullptr, BackendPeers, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendAccount", nullptr, BackendAccount, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tailscaleVersion", nullptr, TailscaleVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendNetworkSettings", nullptr, BackendNetworkSettings, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendSetNetworkSetting", nullptr, BackendSetNetworkSetting, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendSetNetworkSettingAsync", nullptr, BackendSetNetworkSettingAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendSetExitNode", nullptr, BackendSetExitNode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendSetExitNodeAsync", nullptr, BackendSetExitNodeAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeerProbe", nullptr, BackendPeerProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendPeerProbeAsync", nullptr, BackendPeerProbeAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendNetworkChangedAsync", nullptr, BackendNetworkChangedAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendPeerConnectivityAsync", nullptr, BackendPeerConnectivityAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendSunshineProbeAsync", nullptr, BackendSunshineProbeAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendMediaServiceProbeAsync", nullptr, BackendMediaServiceProbeAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"mediaProbeSelfTestAsync", nullptr, BackendMediaProbeSelfTestAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildropSendAsync", nullptr, BackendTaildropSendAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildropCancelAsync", nullptr, BackendTaildropCancelAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildropReceiveAsync", nullptr, BackendTaildropReceiveAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildriveListAsync", nullptr, BackendTaildriveListAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildriveStatAsync", nullptr, BackendTaildriveStatAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildriveMutateAsync", nullptr, BackendTaildriveMutateAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildriveDownloadAsync", nullptr, BackendTaildriveDownloadAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildriveManualDownloadAsync", nullptr, BackendTaildriveManualDownloadAsync,
            nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendTaildriveUploadAsync", nullptr, BackendTaildriveUploadAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendTaildriveTransferSnapshotAsync", nullptr, BackendTaildriveTransferSnapshotAsync,
            nullptr, nullptr, nullptr, napi_default, nullptr},
        {"backendTaildriveCancelAsync", nullptr, BackendTaildriveCancelAsync, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"backendRestartWithTun", nullptr, BackendRestartWithTun, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"controlProbe", nullptr, ControlProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"tunFdProbe", nullptr, TunFdProbe, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_status status = napi_define_properties(
        env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "Failed to register the Tailscale OHOS native exports");
    }
    return exports;
}
EXTERN_C_END

static napi_module module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "tailscale_ohos",
    .nm_priv = nullptr,
    .reserved = {0}
};

extern "C" __attribute__((constructor)) void RegisterTailscaleOhosModule()
{
    napi_module_register(&module);
}
