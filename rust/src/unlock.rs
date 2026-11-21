// SPDX-License-Identifier: GPL-3.0-only
//! Tracks the secure-desktop reports on a single live peer. The latest host
//! report can change after this connection's automatic login has been disarmed.
use crate::protocol::{decode_wire, WireValue};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SecureDesktopReport { pub locked: bool, pub supported: bool }

/// SecureDesktopState: proto3 bool fields 1 (locked), 5 (unlock support).
/// Omitted bools retain protobuf false semantics; duplicates/type errors fail closed.
pub fn parse_secure_desktop(data: &[u8]) -> Option<SecureDesktopReport> {
    if data.len() > 4096 { return None; }
    let mut locked = None;
    let mut supported = None;
    for field in decode_wire(data).ok()? {
        let slot = match field.number { 1 => &mut locked, 5 => &mut supported, _ => continue };
        if slot.is_some() { return None; }
        let WireValue::Varint(v @ 0..=1) = field.value else { return None; };
        *slot = Some(v == 1);
    }
    Some(SecureDesktopReport { locked: locked.unwrap_or(false), supported: supported.unwrap_or(false) })
}

/// Inspect only the selected protobuf field. An unrelated malformed/JSON packet
/// cannot invalidate a lock report. Once the selected field is identified, an
/// invalid length, type or duplicate is a malformed report rather than absence.
fn selected_body(data: &[u8], selected: u32) -> Result<Option<&[u8]>, ()> {
    let mut offset = 0;
    let mut body = None;
    while offset < data.len() {
        let key = match crate::protocol::varint(data, &mut offset) {
            Ok(key) => key,
            Err(_) => return if body.is_some() { Err(()) } else { Ok(None) },
        };
        let matches = key >> 3 == u64::from(selected);
        let invalid = || if matches || body.is_some() { Err(()) } else { Ok(None) };
        if key >> 3 == 0 || key >> 3 > 0x1fff_ffff { return invalid(); }
        let value = match key & 7 {
            0 => crate::protocol::varint(data, &mut offset).map(|_| None),
            1 => crate::protocol::take(data, &mut offset, 8).map(|_| None),
            2 => crate::protocol::varint(data, &mut offset).and_then(|length| {
                let length = usize::try_from(length).map_err(|_| crate::protocol::WireError::Truncated)?;
                crate::protocol::take(data, &mut offset, length).map(Some)
            }),
            5 => crate::protocol::take(data, &mut offset, 4).map(|_| None),
            _ => return invalid(),
        };
        let value = match value { Ok(value) => value, Err(_) => return invalid() };
        if matches {
            if body.is_some() { return Err(()); }
            body = Some(value.ok_or(())?);
        }
    }
    Ok(body)
}

/// Tracks secure-desktop observations and reserves one submission for this peer.
/// Latest readable state and the first permanent stop reason are independent.
#[derive(Default)]
pub struct UnlockLifecycle {
    closed: bool,
    stop_reason: Option<&'static str>,
    latest: Option<SecureDesktopReport>,
    attempted: bool,
    submitted: u64,
    revoked: bool,
}

impl UnlockLifecycle {
    /// Only the latest valid report on this live peer establishes unlocked.
    /// Permanent attempt stop reasons do not erase subsequent host readback.
    pub fn observed_unlocked(&self) -> bool {
        self.active() && self.latest.is_some_and(|report| !report.locked)
    }
    pub fn permitted(&self) -> bool {
        self.active() && !self.attempted && self.stop_reason.is_none()
            && self.latest == Some(SecureDesktopReport { locked:true, supported:true })
    }
    /// Consume before handing bytes to the transport. Neither a failed send nor
    /// a later lock-state report may authorize a second password submission.
    pub fn reserve(&mut self) -> Result<(), &'static str> {
        if self.attempted { return Err("unlock_already_attempted"); }
        if let Some(reason) = self.stop_reason { return Err(reason); }
        if self.latest != Some(SecureDesktopReport { locked:true, supported:true }) {
            return Err(self.state_reason());
        }
        self.attempted = true;
        Ok(())
    }
    pub fn submitted(&mut self) { self.submitted += 1; }
    pub fn attempted(&self) -> bool { self.attempted }
    pub fn submitted_count(&self) -> u64 { self.submitted }
    fn stop(&mut self, reason: &'static str) {
        self.stop_reason.get_or_insert(reason);
    }

    pub fn active(&self) -> bool { !self.revoked && !self.closed }
    pub fn revoke(&mut self) { self.revoked=true; self.stop("unlock_session_revoked"); }

    pub fn close(&mut self) {
        self.revoke();
        self.closed = true;
        self.latest = None;
    }

    pub fn observe(&mut self, packet: &[u8]) -> Option<Option<SecureDesktopReport>> {
        if self.closed { return None; }
        // CONTROL also carries JSON input/heartbeat data. JSON is never a
        // SystemStateChange envelope, including strings containing wire bytes.
        // An object starts with 0x7b, which is also an invalid group tag for
        // protobuf field 15. Validate it as JSON without allocating its values.
        if packet.iter().find(|b| !b.is_ascii_whitespace()) == Some(&b'{')
            && serde_json::from_slice::<serde::de::IgnoredAny>(packet).is_ok()
        {
            return None;
        }
        let parsed = selected_body(packet, 15).and_then(|change| {
            let Some(change) = change else { return Ok(None); };
            selected_body(change, 1)
        });
        let report = match parsed {
            Ok(None) => return None,
            Ok(Some(data)) => parse_secure_desktop(data),
            Err(()) => None,
        };
        self.latest = report;
        match report {
            None => self.stop("unlock_invalid_state"),
            Some(report) if !report.locked => self.stop("unlock_already_unlocked"),
            Some(report) if !report.supported => self.stop("unlock_unsupported"),
            Some(_) => (),
        }
        Some(report)
    }

    pub fn state_reason(&self) -> &'static str {
        match self.latest {
            None => "unlock_state_unknown",
            Some(report) if !report.locked => "unlock_not_locked",
            Some(report) if !report.supported => "unlock_unsupported",
            Some(_) => "unlock_verified_target_and_credential_channel_required",
        }
    }

    pub fn stop_reason(&self) -> Option<&'static str> { self.stop_reason }

    pub fn reason(&self) -> &'static str {
        self.stop_reason.unwrap_or_else(|| self.state_reason())
    }
}

/// Official Android 4.45.0 UnlockRemoteSystem.h: SimpleAction15 with the
/// JSON `key` password member, wrapped as Message3 and sent on TEXT.
/// No terminal authentication or ordinary keyboard event participates.
pub fn desktop_packet(seq:u64, password:&[u8]) -> Result<zeroize::Zeroizing<Vec<u8>>, &'static str> {
    let password=std::str::from_utf8(password).map_err(|_|"unlock_invalid_password")?;
    if password.is_empty() || password.len()>1024 || password.contains('\0') { return Err("unlock_invalid_password"); }
    let mut payload=zeroize::Zeroizing::new(Vec::new());
    payload.extend_from_slice(b"{\"key\":");
    serde_json::to_writer(&mut *payload,password).map_err(|_|"unlock_invalid_password")?;
    payload.push(b'}');
    let mut action=zeroize::Zeroizing::new(Vec::new());
    crate::wire::int(1,15,&mut action);
    crate::wire::bytes(2,&payload,&mut action);
    Ok(zeroize::Zeroizing::new(crate::wire::envelope(seq,3,&action)))
}

#[cfg(test)] mod sender_tests {
    use super::*;
    fn report(locked:bool)->Vec<u8>{let mut state=vec![];crate::wire::int(1,locked as u64,&mut state);crate::wire::int(5,1,&mut state);let mut change=vec![];crate::wire::bytes(1,&state,&mut change);crate::wire::envelope(1,15,&change)}
    #[test]fn unlocked_readback_is_latest_valid_live_peer_only(){
        let mut gate=UnlockLifecycle::default();assert!(!gate.observed_unlocked());
        gate.observe(&report(true));gate.reserve().unwrap();gate.observe(&report(false));assert!(gate.observed_unlocked());
        // An unrelated message preserves readback; a malformed selected report clears it.
        gate.observe(b"{\"heartbeat\":true}");assert!(gate.observed_unlocked());
        gate.observe(&crate::wire::envelope(1,15,&[10,2,8,2]));assert!(!gate.observed_unlocked());
        gate.observe(&report(false));assert!(gate.observed_unlocked());gate.revoke();assert!(!gate.observed_unlocked());
        assert!(!UnlockLifecycle::default().observed_unlocked());
    }
    #[test]fn unlocked_and_out_of_order_send_zero(){let mut gate=UnlockLifecycle::default();gate.observe(&report(false));assert!(gate.reserve().is_err());gate.observe(&report(true));assert!(gate.reserve().is_err());assert_eq!(gate.submitted_count(),0);}
    #[test]fn attempts_never_retry_and_new_peer_is_independent(){let mut old=UnlockLifecycle::default();old.observe(&report(true));old.reserve().unwrap();assert!(old.reserve().is_err());old.observe(&report(true));assert!(old.reserve().is_err());let mut new=UnlockLifecycle::default();new.observe(&report(true));new.reserve().unwrap();new.submitted();assert_eq!(new.submitted_count(),1);assert_eq!(old.submitted_count(),0);}
    #[test]fn duplicate_locked_reports_are_idempotent_and_cancellation_never_rearms(){let mut gate=UnlockLifecycle::default();gate.revoke();gate.observe(&report(true));assert!(gate.reserve().is_err());let mut gate=UnlockLifecycle::default();gate.observe(&report(true));gate.observe(&report(true));assert!(gate.permitted());gate.reserve().unwrap();gate.observe(&report(true));assert!(gate.reserve().is_err());gate.close();gate.observe(&report(true));assert!(gate.reserve().is_err());}
    #[test]fn exact_standard_desktop_encoding_and_bounds(){let packet=desktop_packet(1,b"test").unwrap();let mut action=vec![];crate::wire::int(1,15,&mut action);crate::wire::bytes(2,b"{\"key\":\"test\"}",&mut action);assert_eq!(&*packet,&crate::wire::envelope(1,3,&action));for p in [&b""[..],&b"x\0y"[..],&b"\xff"[..]]{assert!(desktop_packet(1,p).is_err());}assert!(desktop_packet(1,&vec![b'x';1025]).is_err());}
}
