//! Local-only account handoff. No registration, login request or device mutation.
use serde_json::{json, Value};
use std::ffi::CStr;
const ID: [&str; 4] = ["client_id", "system_id", "machine_guid", "device_id"];
const ACCOUNT: [&str; 3] = ["user_id", "token", "csrf"];
fn valid(value: &Value, keys: &[&str]) -> bool {
    value.is_object() && keys.iter().all(|k| value[*k].as_str().is_some_and(|s| !s.is_empty() && s.len() <= 1024))
}
pub(super) fn running() -> bool {
    super::TASK.lock().unwrap().as_ref().is_some_and(|t| !t.is_finished())
}
#[no_mangle]
pub extern "C" fn uu_unified_running() -> bool { running() }
unsafe fn parse(p: *const libc::c_char) -> Option<Value> {
    if p.is_null() { return None; }
    let bytes = CStr::from_ptr(p).to_bytes();
    if bytes.len() > 1024 { return None; }
    serde_json::from_slice(bytes).ok()
}
#[no_mangle]
pub unsafe extern "C" fn uu_unified_bind(account: *const libc::c_char, identity: *const libc::c_char) -> i32 {
    let (Some(account), Some(identity)) = (parse(account), parse(identity)) else { return -1; };
    if !valid(&account, &ACCOUNT) || !valid(&identity, &ID) { return -1; }
    let Ok(old) = crate::config::read_fresh() else { return -2; };
    let mut cfg = old.unwrap_or_else(|| json!({}));
    let same = ACCOUNT.iter().chain(ID.iter()).all(|k| cfg[*k] == account.get(*k).or_else(|| identity.get(*k)).cloned().unwrap_or(Value::Null));
    if running() { return if same { 0 } else { -3 }; }
    if cfg["device_id"].as_str().is_some_and(|s| !s.is_empty()) && cfg["device_id"] != identity["device_id"] {
        let mut previous = json!({});
        for k in ID { if let Some(v) = cfg.get(k) { previous[k] = v.clone(); } }
        cfg["previous_installation_identity"] = previous;
    }
    if cfg["user_id"] != account["user_id"] {
        cfg["assist_allow"] = json!(false);
        if let Some(map) = cfg.as_object_mut() { map.remove("assist_custom_code"); }
    }
    for k in ID { cfg[k] = identity[k].clone(); }
    for k in ACCOUNT { cfg[k] = account[k].clone(); }
    if crate::config::write(&cfg).is_err() { return -2; }
    0
}
#[no_mangle]
pub unsafe extern "C" fn uu_unified_export_slot(slot: u32, out: *mut u8, capacity: usize) -> i32 {
    if out.is_null() || slot > 1 { return -1; }
    let Ok(Some(cfg)) = crate::config::read_fresh() else { return 0; };
    if !valid(&cfg, &ACCOUNT) || !valid(&cfg, &ID) { return 0; }
    export_slot(&cfg, slot, out, capacity)
}
unsafe fn export_slot(cfg: &Value, slot: u32, out: *mut u8, capacity: usize) -> i32 {
    let mut selected = json!({});
    for k in if slot == 0 { &ID[..] } else { &ACCOUNT[..] } { selected[*k] = cfg[*k].clone(); }
    let Ok(mut bytes) = serde_json::to_vec(&selected) else { return -1; };
    if bytes.len() > capacity { bytes.fill(0); return -1; }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len());
    let size = bytes.len() as i32; bytes.fill(0); size
}
fn same_account(stored: &Value, viewer: &Value) -> bool {
    valid(stored, &ACCOUNT) && valid(viewer, &ACCOUNT)
        && ACCOUNT.iter().all(|key| stored[*key] == viewer[*key])
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovery_requires_the_exact_current_viewer_session() {
        let saved=json!({"user_id":"owner","token":"current","csrf":"csrf","device_id":"same-pc"});
        assert!(same_account(&saved,&json!({"user_id":"owner","token":"current","csrf":"csrf"})));
        assert!(!same_account(&saved,&json!({"user_id":"owner","token":"old","csrf":"csrf"})));
        assert!(!same_account(&saved,&json!({"user_id":"other","token":"current","csrf":"csrf"})));
        assert!(!same_account(&saved,&json!({"user_id":"owner","token":"current"})));
    }
}
#[no_mangle]
pub unsafe extern "C" fn uu_unified_recover_viewer_identity(
    viewer: *const libc::c_char, out: *mut u8, capacity: usize,
) -> i32 {
    if out.is_null() { return -1; }
    let Some(viewer) = parse(viewer) else { return -1; };
    let Ok(Some(cfg)) = crate::config::read_fresh() else { return 0; };
    if !valid(&cfg, &ID) || !same_account(&cfg, &viewer) { return 0; }
    export_slot(&cfg, 0, out, capacity)
}
#[no_mangle]
pub extern "C" fn uu_unified_unbind() -> i32 {
    if running() { return -3; }
    let mut cfg = match crate::config::read_fresh() { Ok(Some(cfg)) => cfg, Ok(None) => return 0, Err(_) => return -2 };
    for k in ACCOUNT { cfg[k] = json!(""); }
    cfg["assist_allow"] = json!(false);
    if crate::config::write(&cfg).is_err() { return -2; }
    0
}
