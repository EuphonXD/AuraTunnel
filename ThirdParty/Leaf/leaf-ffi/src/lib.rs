#![allow(clippy::missing_safety_doc)]
use std::{ffi::c_void, ffi::CStr, os::raw::c_char};

#[repr(C)]
pub struct leaf_packet_t {
    pub data: *const u8,
    pub len: usize,
}

pub type leaf_packet_output_callback_t =
    unsafe extern "C" fn(data: *const u8, len: usize, context: *mut c_void);

/// No error.
pub const ERR_OK: i32 = 0;
/// Config path error.
pub const ERR_CONFIG_PATH: i32 = 1;
/// Config parsing error.
pub const ERR_CONFIG: i32 = 2;
/// IO error.
pub const ERR_IO: i32 = 3;
/// Config file watcher error.
pub const ERR_WATCHER: i32 = 4;
/// Async channel send error.
pub const ERR_ASYNC_CHANNEL_SEND: i32 = 5;
/// Sync channel receive error.
pub const ERR_SYNC_CHANNEL_RECV: i32 = 6;
/// Runtime manager error.
pub const ERR_RUNTIME_MANAGER: i32 = 7;
/// No associated config file.
pub const ERR_NO_CONFIG_FILE: i32 = 8;
/// No data found.
pub const ERR_NO_DATA: i32 = 9;

/// Registers the synchronous callback used for Leaf -> PacketFlow packets.
#[no_mangle]
pub extern "C" fn leaf_set_packet_output_callback(
    callback: Option<leaf_packet_output_callback_t>,
    context: *mut c_void,
) -> bool {
    if let Some(callback) = callback {
        leaf::proxy::tun::packet_bridge::register_output(callback, context);
    } else {
        leaf::proxy::tun::packet_bridge::clear_output();
    }
    true
}

/// Clears the output callback without requiring Swift to pass a nullable
/// function pointer through Clang's importer.
#[no_mangle]
pub extern "C" fn leaf_clear_packet_output_callback() {
    leaf::proxy::tun::packet_bridge::clear_output();
}

/// Submits one system-provided packet batch. Returns the number accepted by
/// Leaf's bounded channel; no unbounded queue or polling is used.
#[no_mangle]
pub unsafe extern "C" fn leaf_input_packets(
    packets: *const leaf_packet_t,
    count: usize,
) -> usize {
    if packets.is_null() || count == 0 || count > 1024 {
        return 0;
    }
    let packets = unsafe { std::slice::from_raw_parts(packets, count) };
    let valid_packets = packets.iter().filter_map(|packet| {
        if packet.data.is_null() || packet.len == 0 || packet.len > 65_535 {
            return None;
        }
        Some(unsafe { std::slice::from_raw_parts(packet.data, packet.len) })
    });
    leaf::proxy::tun::packet_bridge::input_packets(valid_packets)
}

#[no_mangle]
pub extern "C" fn leaf_is_running(rt_id: u16) -> bool {
    leaf::is_running(rt_id)
}

fn to_errno(e: leaf::Error) -> i32 {
    match e {
        leaf::Error::Config(..) => ERR_CONFIG,
        leaf::Error::NoConfigFile => ERR_NO_CONFIG_FILE,
        leaf::Error::Io(..) => ERR_IO,
        #[cfg(feature = "auto-reload")]
        leaf::Error::Watcher(..) => ERR_WATCHER,
        leaf::Error::AsyncChannelSend(..) => ERR_ASYNC_CHANNEL_SEND,
        leaf::Error::SyncChannelRecv(..) => ERR_SYNC_CHANNEL_RECV,
        leaf::Error::RuntimeManager => ERR_RUNTIME_MANAGER,
    }
}

/// Starts leaf with options, on a successful start this function blocks the current
/// thread.
///
/// @note This is not a stable API, parameters will change from time to time.
///
/// @param rt_id A unique ID to associate this leaf instance, this is required when
///              calling subsequent FFI functions, e.g. reload, shutdown.
/// @param config_path The path of the config file, must be a file with suffix .conf
///                    or .json, according to the enabled features.
/// @param auto_reload Enabls auto reloading when config file changes are detected,
///                    takes effect only when the "auto-reload" feature is enabled.
/// @param multi_thread Whether to use a multi-threaded runtime.
/// @param auto_threads Sets the number of runtime worker threads automatically,
///                     takes effect only when multi_thread is true.
/// @param threads Sets the number of runtime worker threads, takes effect when
///                     multi_thread is true, but can be overridden by auto_threads.
/// @param stack_size Sets stack size of the runtime worker threads, takes effect when
///                   multi_thread is true.
/// @return ERR_OK on finish running, any other errors means a startup failure.
#[no_mangle]
#[allow(unused_variables)]
pub unsafe extern "C" fn leaf_run_with_options(
    rt_id: u16,
    config_path: *const c_char,
    auto_reload: bool, // requires this parameter anyway
    multi_thread: bool,
    auto_threads: bool,
    threads: i32,
    stack_size: i32,
) -> i32 {
    if let Ok(config_path) = unsafe { CStr::from_ptr(config_path).to_str() } {
        if let Err(e) = leaf::util::run_with_options(
            rt_id,
            config_path.to_string(),
            #[cfg(feature = "auto-reload")]
            auto_reload,
            multi_thread,
            auto_threads,
            threads as usize,
            stack_size as usize,
        ) {
            return to_errno(e);
        }
        ERR_OK
    } else {
        ERR_CONFIG_PATH
    }
}

/// Starts leaf with a single-threaded runtime, on a successful start this function
/// blocks the current thread.
///
/// @param rt_id A unique ID to associate this leaf instance, this is required when
///              calling subsequent FFI functions, e.g. reload, shutdown.
/// @param config_path The path of the config file, must be a file with suffix .conf
///                    or .json, according to the enabled features.
/// @return ERR_OK on finish running, any other errors means a startup failure.
#[no_mangle]
pub unsafe extern "C" fn leaf_run(rt_id: u16, config_path: *const c_char) -> i32 {
    if let Ok(config_path) = unsafe { CStr::from_ptr(config_path).to_str() } {
        let opts = leaf::StartOptions {
            config: leaf::Config::File(config_path.to_string()),
            #[cfg(feature = "auto-reload")]
            auto_reload: false,
            runtime_opt: leaf::RuntimeOption::SingleThread,
        };
        if let Err(e) = leaf::start(rt_id, opts) {
            return to_errno(e);
        }
        ERR_OK
    } else {
        ERR_CONFIG_PATH
    }
}

#[no_mangle]
pub unsafe extern "C" fn leaf_run_with_config_string(rt_id: u16, config: *const c_char) -> i32 {
    if let Ok(config) = unsafe { CStr::from_ptr(config).to_str() } {
        let opts = leaf::StartOptions {
            config: leaf::Config::Str(config.to_string()),
            #[cfg(feature = "auto-reload")]
            auto_reload: false,
            runtime_opt: leaf::RuntimeOption::SingleThread,
        };
        if let Err(e) = leaf::start(rt_id, opts) {
            return to_errno(e);
        }
        ERR_OK
    } else {
        ERR_CONFIG_PATH
    }
}

/// Parses and converts an in-memory configuration before a runtime is started.
/// This keeps malformed imported nodes from creating a half-started tunnel.
#[no_mangle]
pub unsafe extern "C" fn leaf_test_config_string(config: *const c_char) -> i32 {
    if config.is_null() {
        return ERR_CONFIG_PATH;
    }
    if let Ok(config) = unsafe { CStr::from_ptr(config).to_str() } {
        match leaf::config::from_string(config) {
            Ok(_) => ERR_OK,
            Err(error) => to_errno(leaf::Error::Config(anyhow::anyhow!(error))),
        }
    } else {
        ERR_CONFIG_PATH
    }
}

#[cfg(test)]
mod auratunnel_tests {
    use super::*;
    use std::ffi::CString;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn validates_packet_flow_vmess_websocket_tls_configuration() {
        let config = CString::new(
            r#"{
                "log":{"level":"none"},
                "dns":{"servers":["1.1.1.1"]},
                "inbounds":[{"protocol":"tun","tag":"packet-flow","settings":{"fd":-2,"tun2socks":"lwip","fakeDnsInclude":["*"]}}],
                "outbounds":[
                    {"protocol":"chain","tag":"proxy","settings":{"actors":["proxy-tls","proxy-ws","proxy-core"]}},
                    {"protocol":"tls","tag":"proxy-tls","settings":{"serverName":"example.com","insecure":false,"alpn":["http/1.1"]}},
                    {"protocol":"websocket","tag":"proxy-ws","settings":{"path":"/ws","headers":{"Host":"example.com"}}},
                    {"protocol":"vmess","tag":"proxy-core","settings":{"address":"example.com","port":443,"uuid":"00000000-0000-4000-8000-000000000001","security":"aes-128-gcm"}},
                    {"protocol":"direct","tag":"direct"},
                    {"protocol":"drop","tag":"drop"}
                ],
                "router":{"domainResolve":false,"rules":[
                    {"ip":["10.0.0.0/8","fc00::/7"],"target":"direct"},
                    {"domainSuffix":["cn","baidu.com"],"target":"direct"}
                ]}
            }"#,
        )
        .unwrap();

        assert_eq!(unsafe { leaf_test_config_string(config.as_ptr()) }, ERR_OK);
    }

    #[test]
    fn starts_and_stops_packet_flow_runtime() {
        const RUNTIME_ID: u16 = 47_11;
        let config = CString::new(
            r#"{
                "log":{"level":"none"},
                "dns":{"servers":["1.1.1.1"]},
                "inbounds":[{"protocol":"tun","tag":"packet-flow","settings":{"fd":-2,"tun2socks":"lwip"}}],
                "outbounds":[{"protocol":"direct","tag":"direct"}],
                "router":{"rules":[]}
            }"#,
        )
        .unwrap();

        let runtime = thread::spawn(move || unsafe {
            leaf_run_with_config_string(RUNTIME_ID, config.as_ptr())
        });
        let mut running = false;
        for _ in 0..100 {
            if leaf_is_running(RUNTIME_ID) {
                running = true;
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        assert!(running, "packet-flow runtime did not become ready");
        assert!(leaf_shutdown(RUNTIME_ID));
        assert_eq!(runtime.join().expect("runtime thread panicked"), ERR_OK);
    }
}

/// Reloads DNS servers, outbounds and routing rules from the config file.
///
/// @param rt_id The ID of the leaf instance to reload.
///
/// @return Returns ERR_OK on success.
#[no_mangle]
pub extern "C" fn leaf_reload(rt_id: u16) -> i32 {
    if let Err(e) = leaf::reload(rt_id) {
        return to_errno(e);
    }
    ERR_OK
}

/// Shuts down leaf.
///
/// @param rt_id The ID of the leaf instance to reload.
///
/// @return Returns true on success, false otherwise.
#[no_mangle]
pub extern "C" fn leaf_shutdown(rt_id: u16) -> bool {
    leaf::shutdown(rt_id)
}

/// Tests the configuration.
///
/// @param config_path The path of the config file, must be a file with suffix .conf
///                    or .json, according to the enabled features.
/// @return Returns ERR_OK on success, i.e no syntax error.
#[no_mangle]
pub unsafe extern "C" fn leaf_test_config(config_path: *const c_char) -> i32 {
    if let Ok(config_path) = unsafe { CStr::from_ptr(config_path).to_str() } {
        if let Err(e) = leaf::test_config(config_path) {
            return to_errno(e);
        }
        ERR_OK
    } else {
        ERR_CONFIG_PATH
    }
}

/// Tests all outbounds connectivity and latency.
///
/// @param config The content of the config file.
/// @param concurrency The maximum number of concurrent tests.
/// @param timeout_sec The timeout in seconds for each test.
/// @param context User-provided context pointer to be passed back to the callback.
/// @param callback The callback function to receive results.
///                 Arguments: tag (string), tcp_latency (ms, -1 if failed), udp_latency (ms, -1 if failed), context.
/// @return Returns ERR_OK on success.
#[no_mangle]
pub unsafe extern "C" fn leaf_test_outbounds(
    config: *const c_char,
    concurrency: u32,
    timeout_sec: u32,
    context: *mut std::ffi::c_void,
    callback: extern "C" fn(*const c_char, i32, i32, *mut std::ffi::c_void),
) -> i32 {
    if let Ok(config_str) = unsafe { CStr::from_ptr(config).to_str() } {
        // Send context safely to the other thread?
        // raw pointers are not Send.
        // But we are blocking on rt.block_on, so we are staying in this function?
        // No, rt.block_on blocks the current thread until the future completes.
        // The callback is called from within the future.
        // Since we block, the context pointer is valid for the duration.
        // However, the future is executed on the runtime.
        // We need to wrap the pointer in a Send wrapper if the runtime is multi-threaded.
        // But here we create a new Runtime `Runtime::new()`, which is multi-threaded by default?
        // Or we can use `current_thread` runtime.
        // leaf::util::test_outbounds is async.

        // Let's use a wrapper struct to make the pointer Send/Sync since we know we are waiting for it.
        struct SendPtr(*mut std::ffi::c_void);
        unsafe impl Send for SendPtr {}
        unsafe impl Sync for SendPtr {}
        let ctx = SendPtr(context);

        let config = match leaf::config::from_string(config_str) {
            Ok(c) => c,
            Err(e) => return to_errno(leaf::Error::Config(anyhow::anyhow!(e))),
        };

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        rt.block_on(async move {
            use futures::StreamExt;
            let timeout = if timeout_sec > 0 {
                Some(std::time::Duration::from_secs(timeout_sec as u64))
            } else {
                None
            };
            if let Ok(mut stream) =
                leaf::util::stream_outbounds_tests(&config, timeout, concurrency as usize).await
            {
                while let Some((tag, (tcp_res, udp_res))) = stream.next().await {
                    let tag_cstring = std::ffi::CString::new(tag.clone()).unwrap();
                    let tcp_latency = match tcp_res {
                        Ok(d) => d.as_millis() as i32,
                        Err(e) => {
                            println!("TCP test failed for {}: {:?}", tag, e);
                            -1
                        }
                    };
                    let udp_latency = match udp_res {
                        Ok(d) => d.as_millis() as i32,
                        Err(e) => {
                            println!("UDP test failed for {}: {:?}", tag, e);
                            -1
                        }
                    };
                    callback(tag_cstring.as_ptr(), tcp_latency, udp_latency, ctx.0);
                }
            } else {
                println!("Failed to start stream_outbounds_tests");
            }
        });
        ERR_OK
    } else {
        ERR_CONFIG_PATH
    }
}

/// Runs a health check for an outbound.
///
/// This performs an active health check by sending a PING to healthcheck.leaf
/// and waiting for a PONG response through the specified outbound, testing both
/// TCP and UDP protocols.
///
/// @param rt_id The ID of the leaf instance.
/// @param outbound_tag The tag of the outbound to test.
/// @param timeout_ms Timeout in milliseconds (0 for default 4 seconds).
/// @return Returns ERR_OK if either TCP or UDP health check succeeds, error code otherwise.
#[no_mangle]
pub unsafe extern "C" fn leaf_health_check(
    rt_id: u16,
    outbound_tag: *const c_char,
    timeout_ms: u64,
) -> i32 {
    use std::time::Duration;

    let outbound_tag = if let Ok(tag) = unsafe { CStr::from_ptr(outbound_tag).to_str() } {
        tag.to_string()
    } else {
        return ERR_CONFIG_PATH;
    };

    let manager = leaf::RUNTIME_MANAGER.lock().unwrap().get(&rt_id).cloned();
    let result = if let Some(m) = manager {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let timeout = if timeout_ms == 0 {
            None
        } else {
            Some(Duration::from_millis(timeout_ms))
        };
        rt.block_on(async move { m.health_check_outbound(&outbound_tag, timeout).await })
    } else {
        Err(leaf::Error::RuntimeManager)
    };

    match result {
        Ok((tcp_res, udp_res)) => {
            if tcp_res.is_ok() || udp_res.is_ok() {
                ERR_OK
            } else {
                ERR_IO
            }
        }
        Err(e) => to_errno(e),
    }
}

/// Gets the last active time for an outbound.
///
/// This returns the timestamp of the last successful connection through the outbound.
///
/// @param rt_id The ID of the leaf instance.
/// @param outbound_tag The tag of the outbound.
/// @param timestamp_s Pointer to store the timestamp in seconds since epoch.
/// @return Returns ERR_OK on success, ERR_NO_DATA if no active time found, error code otherwise.
#[no_mangle]
pub unsafe extern "C" fn leaf_get_last_active(
    rt_id: u16,
    outbound_tag: *const c_char,
    timestamp_s: *mut u32,
) -> i32 {
    let outbound_tag = if let Ok(tag) = unsafe { CStr::from_ptr(outbound_tag).to_str() } {
        tag.to_string()
    } else {
        return ERR_CONFIG_PATH;
    };

    let manager = leaf::RUNTIME_MANAGER.lock().unwrap().get(&rt_id).cloned();
    let result = if let Some(m) = manager {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async move { m.get_outbound_last_peer_active(&outbound_tag).await })
    } else {
        return to_errno(leaf::Error::RuntimeManager);
    };

    match result {
        Ok(Some(ts)) => {
            unsafe { *timestamp_s = ts };
            ERR_OK
        }
        Ok(None) => ERR_NO_DATA,
        Err(e) => to_errno(e),
    }
}

/// Gets seconds since last active time for an outbound.
///
/// This returns the number of seconds elapsed since the last successful
/// connection through the specified outbound.
///
/// @param rt_id The ID of the leaf instance.
/// @param outbound_tag The tag of the outbound.
/// @param since_s Pointer to store the seconds since last active.
/// @return Returns ERR_OK on success, ERR_NO_DATA if no active time found, error code otherwise.
#[no_mangle]
pub unsafe extern "C" fn leaf_get_since_last_active(
    rt_id: u16,
    outbound_tag: *const c_char,
    since_s: *mut u32,
) -> i32 {
    let outbound_tag = if let Ok(tag) = unsafe { CStr::from_ptr(outbound_tag).to_str() } {
        tag.to_string()
    } else {
        return ERR_CONFIG_PATH;
    };

    let manager = leaf::RUNTIME_MANAGER.lock().unwrap().get(&rt_id).cloned();
    let result = if let Some(m) = manager {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async move { m.get_outbound_last_peer_active(&outbound_tag).await })
    } else {
        return to_errno(leaf::Error::RuntimeManager);
    };

    match result {
        Ok(Some(ts)) => {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs() as u32)
                .unwrap_or(0);
            let since = now.saturating_sub(ts);
            unsafe { *since_s = since };
            ERR_OK
        }
        Ok(None) => ERR_NO_DATA,
        Err(e) => to_errno(e),
    }
}
