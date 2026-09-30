mod media;
pub mod provider;
pub mod session;

use parking_lot::RwLock;
use session::Session;
use std::{
    collections::HashMap,
    ffi::{CStr, CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    slice,
    sync::{
        Arc, LazyLock,
        atomic::{AtomicU64, Ordering},
    },
};

static NEXT: AtomicU64 = AtomicU64::new(1);
static SESSIONS: LazyLock<RwLock<HashMap<u64, Arc<Session>>>> = LazyLock::new(Default::default);
static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("spark-core")
        .build()
        .expect("Spark runtime construction failed")
});
fn sessions() -> &'static RwLock<HashMap<u64, Arc<Session>>> {
    &SESSIONS
}
fn runtime() -> &'static tokio::runtime::Runtime {
    &RUNTIME
}
fn string(value: String) -> *mut c_char {
    CString::new(value.replace('\0', "�"))
        .unwrap_or_default()
        .into_raw()
}
fn result_json(result: Result<(), String>) -> *mut c_char {
    match result {
        Ok(()) => string("{\"ok\":true}".into()),
        Err(message) => string(serde_json::json!({"ok":false,"error":message}).to_string()),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn spark_create() -> u64 {
    catch_unwind(|| {
        let handle = NEXT.fetch_add(1, Ordering::Relaxed);
        sessions()
            .write()
            .insert(handle, Arc::new(Session::new(runtime().handle().clone())));
        handle
    })
    .unwrap_or(0)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn spark_command(handle: u64, json: *const c_char) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        if json.is_null() {
            return result_json(Err("command is required".into()));
        }
        let Ok(raw) = (unsafe { CStr::from_ptr(json) }).to_str() else {
            return result_json(Err("command must be UTF-8".into()));
        };
        let session = sessions().read().get(&handle).cloned();
        result_json(
            session
                .ok_or("stale Spark handle".into())
                .and_then(|s| s.command(raw)),
        )
    }))
    .unwrap_or_else(|_| result_json(Err("internal Spark failure".into())))
}
#[unsafe(no_mangle)]
pub extern "C" fn spark_poll_event(handle: u64) -> *mut c_char {
    catch_unwind(|| {
        sessions()
            .read()
            .get(&handle)
            .and_then(|s| s.poll())
            .map(string)
            .unwrap_or_else(|| string("null".into()))
    })
    .unwrap_or_else(|_| string("null".into()))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn spark_string_free(value: *mut c_char) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !value.is_null() {
            drop(unsafe { CString::from_raw(value) })
        }
    }));
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn spark_push_audio(handle: u64, samples: *const f32, count: usize) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if samples.is_null() || count == 0 || count > 32_000 {
            return;
        }
        if let Some(s) = sessions().read().get(&handle) {
            s.push_audio(unsafe { slice::from_raw_parts(samples, count) })
        }
    }));
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn spark_read_audio(
    handle: u64,
    samples: *mut f32,
    capacity: usize,
) -> usize {
    catch_unwind(AssertUnwindSafe(|| {
        if samples.is_null() || capacity == 0 || capacity > 480_000 {
            return 0;
        }
        sessions().read().get(&handle).map_or(0, |s| {
            s.read_audio(unsafe { slice::from_raw_parts_mut(samples, capacity) })
        })
    }))
    .unwrap_or(0)
}
#[unsafe(no_mangle)]
pub extern "C" fn spark_destroy(handle: u64) {
    let _ = catch_unwind(|| {
        sessions().write().remove(&handle);
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_handles_are_safe() {
        let h = spark_create();
        assert_ne!(h, 0);
        spark_destroy(h);
        spark_destroy(h);
        assert_eq!(unsafe { spark_read_audio(h, std::ptr::null_mut(), 0) }, 0);
        let p = spark_poll_event(h);
        unsafe {
            assert_eq!(CStr::from_ptr(p).to_str().unwrap(), "null");
            spark_string_free(p)
        }
    }
    #[test]
    fn command_string_ownership() {
        let h = spark_create();
        let input = CString::new("{\"type\":\"setMuted\",\"muted\":true}").unwrap();
        let p = unsafe { spark_command(h, input.as_ptr()) };
        unsafe {
            assert_eq!(CStr::from_ptr(p).to_str().unwrap(), "{\"ok\":true}");
            spark_string_free(p)
        }
        spark_destroy(h)
    }
}
