use super::{core, cstring, peer, session, Core};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::ffi::{c_char, CStr};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

#[derive(Default)]
pub(crate) struct BoundDesktop {
    device_key: String,
    account_device: String,
    generation: u64,
    expected_config: Option<[u8; 32]>,
    peer_started: bool,
    expected_answer: Option<([u8; 32], String)>,
    binding: Option<String>,
}

fn account_device(c: &Core, device_key: &str) -> Option<String> {
    if !c.logged() || c.account.user_id.is_empty() || c.id.client_id.is_empty() {
        return None;
    }
    let mut hash = Sha256::new();
    hash.update(b"UUHarmony/WindowsUnlock/1");
    for part in [&c.account.user_id[..], &c.id.client_id, device_key] {
        hash.update((part.len() as u64).to_be_bytes());
        hash.update(part.as_bytes());
    }
    Some(hex::encode(hash.finalize()))
}

// Validate this session's DTLS fingerprint against its own signaling answer.
// It is not a persistent device ID: stock UU creates a new certificate on reconnect.
fn peer_certificate(sdp: &str) -> Option<String> {
    let mut pin: Option<String> = None;
    for attribute in sdp.lines().filter_map(|line| line.strip_prefix("a=fingerprint:")) {
        let mut parts = attribute.split_ascii_whitespace();
        if !parts.next()?.eq_ignore_ascii_case("sha-256") { continue; }
        let encoded = parts.next()?;
        if parts.next().is_some() { return None; }
        let bytes: Vec<_> = encoded.split(':').collect();
        if bytes.len() != 32 || !bytes.iter().all(|b| b.len() == 2 && b.bytes().all(|c| c.is_ascii_hexdigit())) {
            return None;
        }
        let normalized = bytes.concat().to_ascii_lowercase();
        if pin.as_ref().is_some_and(|known| known != &normalized) { return None; }
        pin = Some(normalized);
    }
    pin
}

impl BoundDesktop {
    pub fn for_device(c: &Core, key: &str) -> Self {
        let Some(scope) = account_device(c, key) else { return Self::default() };
        Self { device_key: key.to_owned(), account_device: scope,
               generation: NEXT_GENERATION.fetch_add(1, Ordering::Relaxed), ..Self::default() }
    }
    pub fn observe_signal(&mut self, reply: &Value) {
        if self.generation == 0 { return; }
        if let Some(config) = reply.get("peerConfig").filter(|v| v.is_object()) {
            self.expected_config = Some(Sha256::digest(config.to_string().as_bytes()).into());
        }
        let event = &reply["peerEvent"];
        if self.peer_started && self.binding.is_none() && event["type"] == "answer" {
            self.expected_answer = event["sdp"].as_str().and_then(|sdp|
                Some((Sha256::digest(sdp.as_bytes()).into(), peer_certificate(sdp)?)));
        }
    }
    pub fn peer_start(&mut self, config: &Value) {
        let config_hash: [u8; 32] = Sha256::digest(config.to_string().as_bytes()).into();
        if self.expected_config.take() == Some(config_hash) && !self.peer_started {
            self.peer_started = true;
        } else { *self = Self::default(); }
    }
    pub fn peer_answer(&mut self, sdp: &str) {
        if self.binding.is_some() { return; }
        let Some((expected, cert)) = self.expected_answer.take() else { *self = Self::default(); return };
        let actual: [u8; 32] = Sha256::digest(sdp.as_bytes()).into();
        if self.peer_started && expected == actual && peer::bind_unlock(self.generation, &self.account_device) {
            self.binding = Some(format!("{}.{}", self.account_device, cert));
        } else { *self = Self::default(); }
    }
    pub fn current(&self, c: &Core) -> Option<(&str, u64)> {
        let bound = self.binding.as_deref()?;
        if account_device(c, &self.device_key).as_ref() != Some(&self.account_device)
            || !c.devices.iter().any(|d| d["key"].as_str() == Some(&self.device_key) && d["fields"]["platform"] == 1)
            || !peer::unlock_ready(self.generation) { return None; }
        Some((bound, self.generation))
    }
    pub fn owns_current(&self,c:&Core,key:&str)->bool {
        self.device_key==key && self.current(c).is_some()
    }
}

#[no_mangle]
pub unsafe extern "C" fn s5_unlock_binding(out: *mut c_char, capacity: usize, generation: *mut u64) -> i32 {
    if out.is_null() || generation.is_null() || capacity < 130 { return 1; }
    *out = 0;
    *generation = 0;
    let core = core().lock().unwrap();
    let Some((binding, current)) = session::unlock_context(&core) else { return 1 };
    binding.as_ptr().copy_to_nonoverlapping(out.cast(), binding.len());
    *out.add(binding.len()) = 0;
    *generation = current;
    0
}

unsafe fn matches(c: &Core, binding: *const c_char, generation: u64) -> bool {
    !binding.is_null() && generation != 0 && session::unlock_context(c).is_some_and(|(current, rev)|
        rev == generation && current.as_bytes() == CStr::from_ptr(binding).to_bytes())
}

#[no_mangle]
pub unsafe extern "C" fn s5_unlock_validate(binding: *const c_char, generation: u64) -> i32 {
    i32::from(!matches(&core().lock().unwrap(), binding, generation))
}

#[no_mangle]
pub unsafe extern "C" fn s5_unlock_permitted(binding: *const c_char, generation: u64) -> i32 {
    let core = core().lock().unwrap();
    i32::from(!matches(&core, binding, generation) || !peer::unlock_permitted(generation))
}

#[no_mangle]
pub unsafe extern "C" fn s5_unlock_observed_unlocked(binding: *const c_char, generation: u64) -> i32 {
    let core = core().lock().unwrap();
    i32::from(!matches(&core, binding, generation) || !peer::unlock_observed_unlocked(generation))
}

#[no_mangle]
pub unsafe extern "C" fn s5_unlock_send(binding: *const c_char, generation: u64, password: *const u8, len: usize) -> *mut c_char {
    let core = core().lock().unwrap();
    let result = if password.is_null() || len == 0 || len > 4096 || !matches(&core, binding, generation) {
        json!({"sent":false, "error":"unlock_context_changed"})
    } else {
        // Keep native session dispatch serialized through final delivery. No target or
        // plaintext credential travels through the generic bridge or its JSON logs.
        peer::unlock_send(generation, std::slice::from_raw_parts(password, len))
    };
    cstring(result.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pin_requires_one_unambiguous_sha256_certificate() {
        let pin = vec!["AA"; 32].join(":");
        let line = format!("a=fingerprint:sha-256 {pin}\r\n");
        assert_eq!(peer_certificate(&line.repeat(2)), Some("aa".repeat(32)));
        assert_eq!(peer_certificate(&(line.clone() + &line.replace("AA", "BB"))), None);
        assert_eq!(peer_certificate(&line.replace("sha-256", "sha-1")), None);
        assert_eq!(peer_certificate(&line.replace("AA:", "A:")), None);
    }
    #[test]
    fn enrollment_scope_isolated_across_users_and_devices() {
        let mut c = Core::default();
        c.account.token = "synthetic".into();
        c.id.client_id = "installation".into();
        assert!(account_device(&c,"device").is_none());
        c.account.user_id = "user".into();
        let a = account_device(&c, "device").unwrap();
        assert_ne!(account_device(&c, "second").unwrap(), a);
        c.account.user_id = "second".into();
        assert_ne!(account_device(&c, "device").unwrap(), a);
    }
}
