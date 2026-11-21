// SPDX-License-Identifier: GPL-3.0-only
// Local lifetime/storage policy. The fixed upstream does not publish a QR server TTL.
use super::*;
use std::time::Instant;

pub(crate) const MAX_QR_AGE_MS: u64 = 5 * 60 * 1000;
const ASSET_SECRET_LIMIT: usize = 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PendingQr {
    version: u8,
    client_id: String,
    device_id: String,
    qr: String,
    ticket: String,
    last: i64,
    created_ms: u64,
    expires_ms: u64,
}
impl Drop for PendingQr {
    fn drop(&mut self) {
        self.client_id.zeroize(); self.device_id.zeroize();
        self.qr.zeroize(); self.ticket.zeroize();
    }
}

pub(crate) fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis().min(u64::MAX as u128) as u64
}

impl Core {
    pub(super) fn qr_live_at(&self, now: u64) -> bool {
        !self.qr.is_empty() && !self.ticket.is_empty()
            && self.qr_created_ms > 0 && now >= self.qr_created_ms && now < self.qr_expires_ms
            && self.qr_expires_ms.checked_sub(self.qr_created_ms) == Some(MAX_QR_AGE_MS)
            && self.qr_clock.is_some_and(|t| t.elapsed().as_millis() < MAX_QR_AGE_MS as u128)
    }
    pub(super) fn expire_qr_at(&mut self, now: u64) -> bool {
        if self.qr.is_empty() || self.qr_live_at(now) { return false; }
        self.pending = None;
        self.clear_qr();
        self.state = "qr_expired".into();
        self.message = "二维码已超过本地最长保留时间或时钟已变化，请手动刷新二维码".into();
        true
    }
    pub(super) fn accept_qr(&mut self, qr: &str, ticket: &str) {
        self.clear_qr();
        self.qr = qr.into(); self.ticket = ticket.into(); self.last = 1;
        self.qr_created_ms = now_ms();
        self.qr_expires_ms = self.qr_created_ms.saturating_add(MAX_QR_AGE_MS);
        self.qr_clock = Some(Instant::now());
    }
    fn pending_qr_json(&self) -> String {
        if self.logged() || !self.qr_live_at(now_ms()) { return String::new(); }
        let pending = PendingQr {
            version: 1, client_id: self.id.client_id.clone(), device_id: self.id.device_id.clone(),
            qr: self.qr.clone(), ticket: self.ticket.clone(), last: self.last,
            created_ms: self.qr_created_ms, expires_ms: self.qr_expires_ms,
        };
        serde_json::to_string(&pending).unwrap_or_default()
    }
    pub(super) fn pending_qr_export(&self) -> String {
        let mut text = self.pending_qr_json();
        if text.len() > ASSET_SECRET_LIMIT { text.zeroize(); }
        text
    }
    pub(super) fn qr_persistence(&self) -> &'static str {
        let mut text = self.pending_qr_json();
        let result = if text.is_empty() { "none" } else if text.len() <= ASSET_SECRET_LIMIT { "asset" } else { "memory_only" };
        text.zeroize(); result
    }
    // Invalid/expired pending QR is discardable. Identity/account import errors remain fatal.
    pub(super) fn import_pending_qr(&mut self, input: &[u8]) -> i32 {
        self.clear_qr();
        let Ok(p) = serde_json::from_slice::<PendingQr>(input) else { return 2; };
        let now = now_ms();
        if input.len() > ASSET_SECRET_LIMIT || self.logged() || p.version != 1
            || p.client_id != self.id.client_id || p.device_id != self.id.device_id
            || p.client_id.is_empty() || p.device_id.is_empty()
            || p.qr.is_empty() || p.qr.len() >= 4096 || p.qr.contains('\0')
            || p.ticket.is_empty() || p.ticket.len() > 8192 || p.ticket.contains('\0')
            || !matches!(p.last, 1 | 2 | 4) || p.created_ms == 0
            || now < p.created_ms || now >= p.expires_ms
            || p.expires_ms.checked_sub(p.created_ms) != Some(MAX_QR_AGE_MS) { return 2; }
        self.qr = p.qr.clone(); self.ticket = p.ticket.clone(); self.last = p.last;
        self.qr_created_ms = p.created_ms; self.qr_expires_ms = p.expires_ms;
        self.qr_clock = Instant::now().checked_sub(std::time::Duration::from_millis(now - p.created_ms));
        self.suspended = true;
        0
    }
    pub(super) fn suspend_auth(&mut self) -> Value {
        self.interrupt_device_removal();
        self.pending = None;
        self.suspended = true;
        if !self.expire_qr_at(now_ms()) && self.qr_live_at(now_ms()) {
            self.state = "suspended".into();
            self.message = "已暂停网络；切回应用后继续当前二维码授权".into();
        }
        self.reply(None)
    }
    pub(super) fn resume_auth(&mut self) -> Value {
        self.suspended = false;
        if self.expire_qr_at(now_ms()) { return self.reply(None); }
        if self.pending.is_some() { return self.reply(None); }
        if self.qr_live_at(now_ms()) {
            if self.last == 4 {
                self.state = "exchanging".into();
                self.message = "用户已确认，正在继续完成登录".into();
                return self.request("exchange", "/api/v1/login/by_qrcode", Some(json!({"token":self.ticket,"qrcode_jump_url":self.qr})));
            }
            self.state = if self.last == 2 { "scanned" } else { "waiting_scan" }.into();
            self.message = "已恢复当前二维码，正在查询官方授权状态".into();
            return self.poll();
        }
        if self.state == "suspended" { self.state = if self.logged() { "signed_in" } else { "signed_out" }.into(); }
        self.reply(None)
    }
    pub(super) fn export_qr(&mut self, v: &Value) -> Value {
        self.expire_qr_at(now_ms());
        let allowed = !self.suspended && v["confirmed"] == true && self.qr_live_at(now_ms()) && self.last != 4;
        let mut out = self.reply(None);
        out["qrExport"] = json!(if allowed { self.qr.as_str() } else { "" });
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn active() -> Core {
        let mut c = Core::default();
        c.id = Identity { client_id:"synthetic-client".into(), device_id:"synthetic-device".into(), ..Identity::default() };
        c.accept_qr("https://synthetic.invalid/qr", "synthetic-ticket");
        c
    }
    #[test] fn background_preserves_ticket_and_resume_queries_same_code() {
        let mut c = active(); let r = c.poll(); let stale = r["request"]["id"].clone();
        let paused = c.call(json!({"op":"suspend"}));
        assert_eq!(paused["view"]["qr"], ""); assert_eq!(paused["view"]["canResume"], true);
        assert_eq!(c.ticket, "synthetic-ticket"); assert!(c.pending.is_none());
        c.response(json!({"id":stale,"httpStatus":200,"body":json!({"code":0,"data":{"status":4}}).to_string()}));
        assert_eq!(c.last, 1); assert!(!c.logged());
        let resumed = c.call(json!({"op":"resume"}));
        assert!(resumed["request"]["url"].as_str().unwrap().ends_with("/qrcode/login/status"));
        let body: Value = serde_json::from_str(resumed["request"]["body"].as_str().unwrap()).unwrap();
        assert_eq!(body["token"], "synthetic-ticket"); assert_eq!(body["qrcode_jump_url"], c.qr);
        assert!(c.call(json!({"op":"resume"}))["request"].is_null());
    }
    #[test] fn process_restart_restores_scanned_or_confirmed_ticket_without_generate() {
        for status in [2, 4] {
            let mut c = active(); c.last = status; let mut stored = c.pending_qr_export();
            let mut restored = Core::default(); restored.id = Identity {client_id:c.id.client_id.clone(),device_id:c.id.device_id.clone(),..Identity::default()};
            assert_eq!(restored.import_pending_qr(stored.as_bytes()), 0); stored.zeroize();
            let boot = restored.call(json!({"op":"boot"})); assert!(boot["request"].is_null());
            assert_eq!(boot["view"]["canResume"], true);
            let r = restored.call(json!({"op":"resume"}));
            assert_eq!(r["request"]["kind"], if status == 4 { "exchange" } else { "poll" });
        }
    }
    #[test] fn deadline_clock_change_and_mismatched_identity_discard_pending_asset() {
        let mut c = active();
        assert!(c.qr_live_at(c.qr_expires_ms - 1));
        assert!(!c.qr_live_at(c.qr_expires_ms)); assert!(!c.qr_live_at(c.qr_created_ms - 1));
        let mut text = c.pending_qr_export(); let mut other = Core::default();
        assert_eq!(other.import_pending_qr(text.as_bytes()), 2); text.zeroize();
        assert!(c.expire_qr_at(c.qr_expires_ms)); assert!(c.ticket.is_empty()); assert!(c.pending_qr_export().is_empty());
    }
    #[test] fn cancel_logout_server_expiry_and_refresh_erase_ticket() {
        for op in ["cancel", "logout", "begin"] {
            let mut c = active(); c.call(json!({"op":op}));
            assert!(c.ticket.is_empty()); assert!(c.pending_qr_export().is_empty());
        }
        for reply in [json!({"code":1190}), json!({"code":0,"data":{"status":0}}), json!({"code":0,"data":{"status":3}})] {
            let mut c = active(); c.poll(); let id = c.pending.as_ref().unwrap().0;
            let r = c.response(json!({"id":id,"httpStatus":200,"body":reply.to_string()}));
            assert_eq!(r["view"]["state"], "qr_expired"); assert!(r["request"].is_null());
            assert!(c.ticket.is_empty()); assert!(c.pending_qr_export().is_empty());
            let resumed = c.call(json!({"op":"resume"}));
            assert_eq!(resumed["view"]["state"], "qr_expired"); assert!(resumed["request"].is_null());
        }
    }
    #[test] fn export_requires_explicit_foreground_and_pending_asset_is_bounded() {
        let mut c = active(); assert_eq!(c.export_qr(&json!({}))["qrExport"], "");
        assert_eq!(c.export_qr(&json!({"confirmed":true}))["qrExport"], c.qr);
        c.suspend_auth(); assert_eq!(c.export_qr(&json!({"confirmed":true}))["qrExport"], "");
        c.qr = "x".repeat(1200); assert_eq!(c.qr_persistence(), "memory_only"); assert!(c.pending_qr_export().is_empty());
    }
    #[test] fn transport_timeout_preserves_ticket_and_confirmed_exchange_phase() {
        let mut c = active(); c.last = 4; let r = c.resume_auth(); let id = r["request"]["id"].clone();
        c.call(json!({"op":"network_error","id":id,"timeout":true}));
        assert_eq!(c.ticket, "synthetic-ticket");
        assert_eq!(c.resume_auth()["request"]["kind"], "exchange");
    }
}
