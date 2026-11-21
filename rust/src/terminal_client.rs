// SPDX-License-Identifier: GPL-3.0-only
//! TERM client. OPEN responses have no request ID: serialize them and quarantine on uncertainty.
use serde_json::{json, Value};
use base64::{Engine,engine::general_purpose::STANDARD};
use std::{
    collections::{BTreeMap, BTreeSet},
    time::{Duration, Instant},
};

const LIMIT: usize = 64 * 1024;
const WAIT: Duration = Duration::from_secs(15);

fn frame(kind: u8, id: u32, data: &[u8]) -> Vec<u8> {
    let mut b = b"TERM\x01".to_vec();
    b.extend([kind, 0, 0]);
    b.extend(id.to_le_bytes());
    b.extend((data.len() as u32).to_le_bytes());
    b.extend(data);
    b
}

#[derive(Default)]
struct Session {
    output: Vec<u8>,
    raw_v2: crate::terminal_raw_read::RawOutput,
    output_start: u64,
    output_end: u64,
    output_epoch: u64,
    phase: u8,
    attached: bool,
    name: String,
    token: u32,
    created: Option<u64>,
    listed: bool,
}

struct Opening {
    target: Option<u32>,
    at: Instant,
}

struct Pending {
    at: Instant,
}

#[derive(Default)]
pub struct TerminalClient {
    buffer: Vec<u8>,
    sessions: BTreeMap<u32, Session>,
    selected: Option<u32>,
    opening: Option<Opening>,
    open_quarantined: bool,
    list_pending: Option<Instant>,
    list_quarantined: bool,
    next_token: u32,
    kills: BTreeMap<u32, Pending>,
    kill_quarantined: BTreeSet<u32>,
    revision: u64,
    list_state: &'static str,
    kill_state: &'static str,
    kill_target: Option<u32>,
    last_error: &'static str,
}

impl TerminalClient {
    fn id(e: &Value) -> Option<u32> {
        e["session"].as_u64().and_then(|n| u32::try_from(n).ok())
    }

    fn target(&self, e: &Value) -> Result<u32, &'static str> {
        let id = Self::id(e).or(self.selected).ok_or("terminal_session_required")?;
        let Some(s) = self.sessions.get(&id) else { return Err("terminal_unknown_session") };
        if e.get("sessionToken").is_some() && e["sessionToken"].as_u64() != Some(u64::from(s.token)) {
            return Err("terminal_session_changed");
        }
        Ok(id)
    }

    pub fn prepare(&mut self, e: &Value) -> Result<Option<Vec<u8>>, &'static str> {
        self.tick();
        if e.as_object().is_none_or(|o| o.keys().any(|k| {
            !["action", "confirmed", "text", "cols", "rows", "session", "sessionToken"].contains(&k.as_str())
        })) {
            return Err("terminal_unrecognized_field");
        }
        match e["action"].as_str() {
            Some("status") => Ok(None),
            Some("list") => {
                if self.opening.is_some() { return Err("terminal_open_pending") }
                if self.list_quarantined { return Err("terminal_list_uncertain_reconnect_required") }
                if self.list_pending.is_some() { return Err("terminal_list_pending") }
                self.list_pending = Some(Instant::now());
                self.list_state = "pending";
                Ok(Some(frame(9, 0, &[])))
            }
            Some("select") => {
                let id = self.target(e)?;
                if self.sessions[&id].phase != 2 { return Err("terminal_session_not_open") }
                self.selected = Some(id);
                if self.kills.is_empty() { self.kill_state = ""; }
                self.revision += 1;
                Ok(None)
            }
            Some("open") | Some("attach") => {
                if e["confirmed"] != true { return Err("terminal_confirmation_required") }
                if self.open_quarantined { return Err("terminal_open_uncertain_reconnect_required") }
                if self.opening.is_some() { return Err("terminal_open_pending") }
                if self.list_pending.is_some() { return Err("terminal_list_pending") }
                if e["action"] == "open" && self.sessions.len() >= 256 { return Err("terminal_session_limit") }
                let target = if e["action"] == "attach" {
                    let id = self.target(e)?;
                    if id == 0 { return Err("terminal_zero_attach_ambiguous") }
                    if self.sessions[&id].phase != 1 || !self.sessions[&id].listed
                        || self.list_pending.is_some() || self.list_quarantined || self.kill_quarantined.contains(&id)
                    { return Err("terminal_session_unavailable") }
                    Some(id)
                } else { None };
                self.opening = Some(Opening { target, at: Instant::now() });
                self.last_error = "";
                if self.kills.is_empty() { self.kill_state = ""; }
                self.revision += 1;
                Ok(Some(frame(1, target.unwrap_or(0), br#"{"cols":80,"rows":24,"option":"none"}"#)))
            }
            Some("write") => {
                let id = self.target(e)?;
                let s = &self.sessions[&id];
                if s.phase != 2 || !s.attached || self.kills.contains_key(&id) || self.kill_quarantined.contains(&id) {
                    return Err("terminal_not_open");
                }
                let text = e["text"].as_str().filter(|s| !s.is_empty() && s.len() <= 8192 && !s.contains('\0'))
                    .ok_or("terminal_input_limit")?;
                Ok(Some(frame(2, id, text.as_bytes())))
            }
            Some("resize") => {
                let id = self.target(e)?;
                let s = &self.sessions[&id];
                if s.phase != 2 || !s.attached || self.kills.contains_key(&id) || self.kill_quarantined.contains(&id) {
                    return Err("terminal_not_open");
                }
                let cols = e["cols"].as_u64().filter(|n| (1..=240).contains(n)).ok_or("terminal_invalid_size")?;
                let rows = e["rows"].as_u64().filter(|n| (1..=100).contains(n)).ok_or("terminal_invalid_size")?;
                Ok(Some(frame(3, id, json!({"cols":cols,"rows":rows}).to_string().as_bytes())))
            }
            Some("detach_selected") => {
                if self.opening.take().is_some(){self.open_quarantined=true;self.last_error="open_cancelled_unknown";}
                let Some(id)=self.selected else{return Ok(None)};
                let Some(s)=self.sessions.get_mut(&id) else{return Ok(None)};
                if !s.attached{return Ok(None)}
                s.attached=false;s.phase=1;s.output.clear();s.output_start=s.output_end;
                self.revision+=1;Ok(Some(frame(16,id,&[])))
            }
            Some("detach") => {
                let id = self.target(e)?;
                if e["sessionToken"].as_u64() != Some(u64::from(self.sessions[&id].token)) { return Err("terminal_session_changed") }
                let s = self.sessions.get_mut(&id).unwrap();
                if !s.attached { return Err("terminal_not_attached") }
                s.attached = false;
                s.phase = 1;
                self.revision += 1;
                Ok(Some(frame(16, id, &[])))
            }
            Some("kill") => {
                if e["confirmed"] != true { return Err("terminal_confirmation_required") }
                let id = self.target(e)?;
                if e["sessionToken"].as_u64() != Some(u64::from(self.sessions[&id].token)) { return Err("terminal_session_changed") }
                if !self.sessions[&id].attached && !self.sessions[&id].listed { return Err("terminal_session_unavailable") }
                if self.kills.contains_key(&id) || self.kill_quarantined.contains(&id) { return Err("terminal_kill_pending_or_uncertain") }
                self.kills.insert(id, Pending { at: Instant::now() });
                self.kill_target = Some(id);
                self.kill_state = "pending";
                self.revision += 1;
                Ok(Some(frame(11, id, json!({"session_id":id}).to_string().as_bytes())))
            }
            // The desktop overlay owns its terminal and closes it on exit.
            Some("close") => {
                if self.opening.take().is_some() {
                    self.open_quarantined = true;
                    self.last_error = "open_cancelled_unknown";
                }
                let Some(id) = Self::id(e).or(self.selected) else { return Ok(None) };
                if let Some(s) = self.sessions.get_mut(&id) {
                    s.phase = 0;
                    s.attached = false;
                    s.output.clear();
                }
                self.revision += 1;
                Ok(Some(frame(4, id, &[])))
            }
            _ => Err("terminal_unsupported_action"),
        }
    }

    pub fn send_failed(&mut self, action: &str, id: Option<u32>) {
        match action {
            "open" | "attach" => {
                self.opening = None;
                self.open_quarantined = true;
                self.last_error = "open_send_uncertain";
            }
            "list" => {
                self.list_pending = None;
                self.list_quarantined = true;
                self.list_state = "unknown";
            }
            "detach" => {
                if let Some(s) = id.and_then(|id| self.sessions.get_mut(&id)) { s.phase = 4; }
            }
            "kill" => {
                if let Some(id) = id.or(self.kill_target) {
                    self.kills.remove(&id);
                    self.kill_quarantined.insert(id);
                    self.kill_target = Some(id);
                    self.kill_state = "unknown";
                }
            }
            _ => {}
        }
        self.revision += 1;
    }

    fn fail_protocol(&mut self) {
        self.buffer.clear();
        self.opening = None;
        self.open_quarantined = true;
        self.last_error = "invalid_frame";
        for s in self.sessions.values_mut() { s.phase = 4; s.attached = false; }
        for id in self.kills.keys() { self.kill_quarantined.insert(*id); }
        self.kills.clear();
        self.revision += 1;
    }

    fn tick(&mut self) {
        if self.opening.as_ref().is_some_and(|p| p.at.elapsed() > WAIT) {
            self.opening = None;
            self.open_quarantined = true;
            self.last_error = "open_timeout_unknown";
            self.revision += 1;
        }
        if self.list_pending.is_some_and(|t| t.elapsed() > WAIT) {
            self.list_pending = None;
            self.list_quarantined = true;
            self.list_state = "timeout";
            self.revision += 1;
        }
        let timed = self.kills.iter().filter_map(|(id, p)| (p.at.elapsed() > WAIT).then_some(*id)).collect::<Vec<_>>();
        for id in timed {
            self.kills.remove(&id);
            self.kill_quarantined.insert(id);
            self.kill_target = Some(id);
            self.kill_state = "unknown";
            self.revision += 1;
        }
    }
    pub fn observe(&mut self, data: &[u8]) {
        self.tick();
        if self.buffer.is_empty() && !(data.starts_with(b"TERM") || b"TERM".starts_with(data)) { return; }
        if self.buffer.len() + data.len() > 2 * 1024 * 1024 { self.fail_protocol(); return; }
        self.buffer.extend(data);
        loop {
            if self.buffer.len() < 16 { return; }
            let b = &self.buffer;
            if &b[..5] != b"TERM\x01" || b[6] != 0 || b[7] != 0 { self.fail_protocol(); return; }
            let kind = b[5];
            let id = u32::from_le_bytes(b[8..12].try_into().unwrap());
            let len = u32::from_le_bytes(b[12..16].try_into().unwrap()) as usize;
            if len > 1024 * 1024 || !(1..=16).contains(&kind) { self.fail_protocol(); return; }
            if b.len() < 16 + len { return; }
            let payload = b[16..16 + len].to_vec();
            self.buffer.drain(..16 + len);
            match kind {
                13 => self.observe_open(id, &payload),
                10 => self.observe_list(id, &payload),
                12 => self.observe_kill(id, &payload),
                5 => {
                    if let Some(s) = self.sessions.get_mut(&id) {
                        if s.phase == 2 && s.attached {
                            s.output_end += payload.len() as u64;
                            s.raw_v2.append(&payload);
                            s.output.extend(payload);
                            if s.output.len() > LIMIT { let n=s.output.len()-LIMIT; s.output.drain(..n); s.output_start += n as u64; }
                            self.revision += 1;
                        }
                    }
                }
                6 => {
                    if let Some(s) = self.sessions.get_mut(&id) {
                        s.phase = 3;
                        s.attached = false;
                        if self.selected == Some(id) { self.selected = None; }
                        self.revision += 1;
                    }
                }
                8 => {
                    let open_error = self.opening.as_ref().is_some_and(|open| id == 0 || open.target == Some(id));
                    if open_error {
                        self.opening = None;
                        self.open_quarantined = true;
                        self.last_error = "open_error_unknown";
                    } else if let Some(s) = self.sessions.get_mut(&id) {
                        s.phase = 4;
                    }
                    self.revision += 1;
                }
                _ => {}
            }
        }
    }

    fn observe_open(&mut self, id: u32, payload: &[u8]) {
        let Some(open) = self.opening.take() else { return };
        let Ok(v) = serde_json::from_slice::<Value>(payload) else {
            self.open_quarantined = true;
            self.last_error = "invalid_open_response";
            return;
        };
        if v["code"].as_i64() != Some(0) {
            self.last_error = "open_rejected";
            self.revision += 1;
            return;
        }
        let body = v["session_id"].as_u64().or_else(|| v["session_id"].as_str().and_then(|s| s.parse().ok()));
        if body.is_some_and(|n| n > u32::MAX as u64) {
            self.open_quarantined = true;
            self.last_error = "invalid_open_id";
            return;
        }
        let actual = if id != 0 { id } else if let Some(n) = body { n as u32 } else { 0 };
        if open.target.is_some_and(|target| actual != target) || open.target.is_none() && self.sessions.contains_key(&actual) {
            self.open_quarantined = true;
            self.last_error = "ambiguous_open_id";
            self.revision += 1;
            return;
        }
        if !self.sessions.contains_key(&actual) {
            if self.sessions.len() >= 256 {
                self.open_quarantined = true;
                self.last_error = "session_limit";
                return;
            }
            self.next_token = self.next_token.saturating_add(1);
            let mut s = Session::default();
            s.token = self.next_token;
            self.sessions.insert(actual, s);
        }
        let s = self.sessions.get_mut(&actual).unwrap();
        if open.target.is_some() { s.output.clear(); s.output_start=0; s.output_end=0; }
        s.output_epoch=s.output_epoch.saturating_add(1);
        s.raw_v2=crate::terminal_raw_read::RawOutput::default();
        s.phase = 2;
        s.attached = true;
        if s.name.is_empty() { s.name = format!("终端 {}", actual); }
        self.selected = Some(actual);
        self.last_error = "";
        self.revision += 1;
    }

    fn observe_list(&mut self, id: u32, payload: &[u8]) {
        if id != 0 || self.list_pending.is_none() { return; }
        self.list_pending = None;
        let Ok(Value::Array(items)) = serde_json::from_slice::<Value>(payload) else {
            self.list_state = "failed";
            return;
        };
        if items.len() > 256 { self.list_state = "failed"; return; }
        let mut ids=BTreeSet::new();
        if items.iter().any(|v|v["session_id"].as_u64().and_then(|n|u32::try_from(n).ok()).is_none_or(|id|!ids.insert(id))){self.list_state="failed";return;}
        for s in self.sessions.values_mut() { s.listed = false; }
        for v in items {
            let Some(sid) = v["session_id"].as_u64().and_then(|n| u32::try_from(n).ok()) else { continue };
            let name = v["name"].as_str().unwrap_or("").chars().take(80).filter(|c| !c.is_control()).collect::<String>();
            if !self.sessions.contains_key(&sid) {
                if self.sessions.len() >= 256 { continue; }
                self.next_token = self.next_token.saturating_add(1);
                let mut s = Session::default();
                s.token = self.next_token;
                self.sessions.insert(sid, s);
            }
            let created = v["created_at_ms"].as_u64().filter(|n| *n > 0);
            let s = self.sessions.get_mut(&sid).unwrap();
            if s.created.is_some() && created.is_some() && s.created != created {
                s.phase = 4;
                s.attached = false;
                self.kills.remove(&sid);
                self.kill_quarantined.insert(sid);
                self.kill_target = Some(sid);
                self.kill_state = "unknown";
                continue;
            }
            if s.created.is_none() { s.created = created; }
            let state = v["state"].as_str().unwrap_or("").to_ascii_lowercase();
            s.listed = !matches!(state.as_str(), "exited" | "stopped" | "closed" | "terminated" | "dead");
            if !s.listed { s.phase = 3; s.attached = false; }
            if !name.is_empty() { s.name = name; }
            if s.phase == 0 && s.listed { s.phase = 1; }
        }
        // A correlated, complete list is authoritative for absence as well as presence.
        // OPEN and LIST cannot overlap, so a newly opened session cannot be mistaken
        // for one that disappeared while an older list response was in flight.
        for (sid, s) in self.sessions.iter_mut() {
            if !ids.contains(sid) { s.phase = 3; s.attached = false; }
        }
        if self.selected.is_some_and(|id| self.sessions.get(&id).is_some_and(|s| s.phase == 3)) { self.selected = None; }
        self.list_state = "confirmed";
        self.revision += 1;
    }

    fn observe_kill(&mut self, id: u32, payload: &[u8]) {
        if self.kills.remove(&id).is_none() { return; }
        let code = serde_json::from_slice::<Value>(payload).ok().and_then(|v| v["code"].as_i64());
        self.kill_target = Some(id);
        if code == Some(0) {
            if let Some(s) = self.sessions.get_mut(&id) { s.phase = 3; s.attached = false; }
            if self.selected == Some(id) { self.selected = None; }
            self.kill_state = "confirmed";
        } else if code.is_some() {
            self.kill_state = "rejected";
        } else {
            self.kill_state = "unknown";
            self.kill_quarantined.insert(id);
        }
        self.revision += 1;
    }

    /// Lossless bounded byte window. No terminal repaint or UTF-8 normalization.
    pub fn read(&mut self,e:&Value)->Result<Value,&'static str>{
        self.tick();
        if e.as_object().is_none_or(|o|o.keys().any(|k|!["action","session","sessionToken","cursor","limit","streamEpoch"].contains(&k.as_str()))){return Err("terminal_unrecognized_field")}
        let id=self.target(e)?;let s=&self.sessions[&id];
        if e["sessionToken"].as_u64()!=Some(u64::from(s.token))||s.phase!=2||!s.attached{return Err("terminal_not_open")}
        let cursor=e["cursor"].as_u64().ok_or("terminal_cursor_required")?;
        if e.get("streamEpoch").is_some()&&e["streamEpoch"].as_u64()!=Some(s.output_epoch){return Err("terminal_output_epoch_changed")}
        if cursor<s.output_start||cursor>s.output_end{return Err("terminal_output_gap")}
        let limit=e["limit"].as_u64().unwrap_or(16384);if !(1..=16384).contains(&limit){return Err("terminal_read_limit")}
        let start=(cursor-s.output_start)as usize;let end=(start+limit as usize).min(s.output.len());
        Ok(json!({"session":id,"sessionToken":s.token,"streamEpoch":s.output_epoch,"cursor":cursor,"nextCursor":cursor+(end-start)as u64,"outputStart":s.output_start,"outputEnd":s.output_end,"base64":STANDARD.encode(&s.output[start..end]),"phase":Self::phase(s.phase)}))
    }
    pub fn read_v2(&mut self,e:&Value)->Result<Value,&'static str>{let id=self.target(e)?;let s=&self.sessions[&id];s.raw_v2.read(e,id,s.token)}
    pub fn snapshot(&mut self) -> Value {
        self.tick();
        let selected = self.selected.and_then(|id| self.sessions.get(&id));
        let phase = if self.opening.is_some() { "opening" } else {
            selected.map(|s| Self::phase(s.phase)).unwrap_or(if self.last_error.is_empty() { "closed" } else { "failed" })
        };
        let sessions = self.sessions.iter().filter(|(_, s)| s.phase != 3).map(|(id, s)| json!({
            "session": id, "sessionToken": s.token, "listed": s.listed, "name": s.name,"createdAt":s.created,
            "phase": Self::phase(s.phase), "attached": s.attached,
            "killPending": self.kills.contains_key(id), "killUncertain": self.kill_quarantined.contains(id)
        })).collect::<Vec<_>>();
        json!({
            "phase": phase, "session": self.selected, "selectedToken": selected.map(|s| s.token),
            "revision": self.revision,"rawStreamEpoch":selected.map(|s|s.raw_v2.epoch()),
            "output": selected.map(|s| String::from_utf8_lossy(&s.output).into_owned()).unwrap_or_default(),
            "sessions": sessions, "opening": self.opening.is_some(), "openQuarantined": self.open_quarantined,
            "errorDetail": self.last_error, "listState": self.list_state,
            "killState": self.kill_state, "killTarget": self.kill_target
        })
    }

    fn phase(phase: u8) -> &'static str {
        match phase { 1 => "available", 2 => "open", 3 => "exited", 4 => "failed", _ => "closed" }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]fn panel_cleanup_detaches_without_close_kill_or_signal(){
        let mut t=TerminalClient::default();t.prepare(&json!({"action":"open","confirmed":true})).unwrap();ack(&mut t,7);
        let packet=t.prepare(&json!({"action":"detach_selected"})).unwrap().unwrap();assert_eq!(packet[5],16);
        assert_eq!(t.snapshot()["sessions"][0]["attached"],false);assert!(t.prepare(&json!({"action":"detach_selected"})).unwrap().is_none());
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();assert!(t.prepare(&json!({"action":"detach_selected"})).unwrap().is_none());assert_eq!(t.snapshot()["openQuarantined"],true);
    }
    #[test]fn raw_bytes_cursor_detects_gap_and_utf8_boundaries(){
        let mut t=TerminalClient::default();t.prepare(&json!({"action":"open","confirmed":true})).unwrap();ack(&mut t,7);
        let raw="中\r\n🙂".as_bytes();for chunk in raw.chunks(2){t.observe(&frame(5,7,chunk));}
        let mut cursor=0;let mut collected=vec![];
        while cursor<raw.len()as u64{let r=t.read(&json!({"action":"read","session":7,"sessionToken":1,"cursor":cursor,"limit":1})).unwrap();collected.extend(STANDARD.decode(r["base64"].as_str().unwrap()).unwrap());cursor=r["nextCursor"].as_u64().unwrap();}
        assert_eq!(collected,raw);assert_eq!(t.read(&json!({"action":"read","session":7,"sessionToken":99,"cursor":0})),Err("terminal_session_changed"));
        assert_eq!(t.read(&json!({"action":"read","session":7,"sessionToken":1,"cursor":0,"streamEpoch":99})),Err("terminal_output_epoch_changed"));
        t.observe(&frame(5,7,&vec![b'x';LIMIT+10]));assert_eq!(t.read(&json!({"action":"read","session":7,"sessionToken":1,"cursor":0})),Err("terminal_output_gap"));
    }
    fn ack(t: &mut TerminalClient, id: u32) {
        t.observe(&frame(13, id, br#"{"code":0}"#));
    }

    #[test]
    fn multiple_sessions_are_isolated_and_kill_is_correlated() {
        let mut t = TerminalClient::default();
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        ack(&mut t, 7);
        t.observe(&frame(5, 7, b"A"));
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        ack(&mut t, 8);
        t.observe(&frame(5, 8, b"B"));
        t.prepare(&json!({"action":"select","session":7})).unwrap();
        assert_eq!(t.snapshot()["output"], "A");
        t.prepare(&json!({"action":"kill","session":7,"sessionToken":1,"confirmed":true})).unwrap();
        t.observe(&frame(12, 8, br#"{"code":0}"#));
        assert_eq!(t.snapshot()["killState"], "pending");
        t.observe(&frame(12, 7, br#"{"code":0}"#));
        assert_eq!(t.snapshot()["killState"], "confirmed");
        assert!(t.prepare(&json!({"action":"write","session":7,"text":"x"})).is_err());
        let p = t.prepare(&json!({"action":"write","session":8,"text":"b"})).unwrap().unwrap();
        assert_eq!(u32::from_le_bytes(p[8..12].try_into().unwrap()), 8);
        t.prepare(&json!({"action":"select","session":8})).unwrap();
        assert_eq!(t.snapshot()["output"], "B");
    }

    #[test]
    fn late_open_is_quarantined_and_zero_never_fabricates_second_session() {
        let mut t = TerminalClient::default();
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        ack(&mut t, 0);
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        ack(&mut t, 0);
        assert_eq!(t.snapshot()["sessions"].as_array().unwrap().len(), 1);
        assert_eq!(t.snapshot()["openQuarantined"], true);
        assert!(t.prepare(&json!({"action":"open","confirmed":true})).is_err());
        let mut t = TerminalClient::default();
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        t.opening.as_mut().unwrap().at = Instant::now() - Duration::from_secs(16);
        assert_eq!(t.snapshot()["openQuarantined"], true);
        ack(&mut t, 9);
        assert!(t.snapshot()["sessions"].as_array().unwrap().is_empty());
    }

    #[test]
    fn list_and_kill_timeouts_cannot_authorize_late_responses() {
        let mut t = TerminalClient::default();
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        ack(&mut t, 7);
        let list = t.prepare(&json!({"action":"list"})).unwrap().unwrap();
        let request = u32::from_le_bytes(list[8..12].try_into().unwrap());
        assert_eq!(request, 0);
        *t.list_pending.as_mut().unwrap() = Instant::now() - Duration::from_secs(16);
        t.snapshot();
        t.observe(&frame(10, request, br#"[{"session_id":9}]"#));
        assert_eq!(t.snapshot()["sessions"].as_array().unwrap().len(), 1);
        assert!(t.prepare(&json!({"action":"list"})).is_err());
        t.prepare(&json!({"action":"kill","session":7,"sessionToken":1,"confirmed":true})).unwrap();
        t.kills.get_mut(&7).unwrap().at = Instant::now() - Duration::from_secs(16);
        t.snapshot();
        t.observe(&frame(12, 7, br#"{"code":0}"#));
        assert_eq!(t.snapshot()["killState"], "unknown");
        assert!(t.prepare(&json!({"action":"kill","session":7,"sessionToken":1,"confirmed":true})).is_err());
    }

    #[test]
    fn zero_session_and_fragmented_output_remain_valid() {
        let mut t = TerminalClient::default();
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        let p = frame(13, 0, br#"{"code":0}"#);
        for c in p.chunks(4) { t.observe(c); }
        assert_eq!(t.snapshot()["session"], 0);
        t.observe(&frame(5, 0, &vec![b'x'; LIMIT + 1]));
        assert_eq!(t.snapshot()["output"].as_str().unwrap().len(), LIMIT);
        assert!(t.prepare(&json!({"action":"write","session":0,"text":"x"})).is_ok());
    }

    #[test]
    fn list_attach_and_reused_identity_are_guarded() {
        let mut t = TerminalClient::default();
        t.prepare(&json!({"action":"list"})).unwrap();
        t.observe(&frame(10, 0, br#"[{"session_id":8,"state":"running","created_at_ms":100}]"#));
        assert_eq!(t.snapshot()["sessions"][0]["phase"], "available");
        assert!(t.prepare(&json!({"action":"kill","session":8,"sessionToken":99,"confirmed":true})).is_err());
        t.prepare(&json!({"action":"attach","session":8,"sessionToken":1,"confirmed":true})).unwrap();
        ack(&mut t, 8);
        assert!(t.prepare(&json!({"action":"write","session":8,"sessionToken":1,"text":"x"})).is_ok());
        t.prepare(&json!({"action":"list"})).unwrap();
        t.observe(&frame(10, 0, br#"[{"session_id":8,"state":"running","created_at_ms":101}]"#));
        assert!(t.prepare(&json!({"action":"write","session":8,"sessionToken":1,"text":"x"})).is_err());
        assert!(t.prepare(&json!({"action":"kill","session":8,"sessionToken":1,"confirmed":true})).is_err());
    }

    #[test]
    fn malformed_kill_response_is_unknown_not_rejected() {
        let mut t = TerminalClient::default();
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        ack(&mut t, 7);
        let p = t.prepare(&json!({"action":"kill","session":7,"sessionToken":1,"confirmed":true})).unwrap().unwrap();
        assert_eq!(&p[16..], br#"{"session_id":7}"#);
        t.observe(&frame(12, 7, b"{}"));
        assert_eq!(t.snapshot()["killState"], "unknown");
        assert!(t.prepare(&json!({"action":"kill","session":7,"sessionToken":1,"confirmed":true})).is_err());
    }

    #[test]
    fn stale_or_exited_list_entry_cannot_attach_and_detach_preserves_other_sessions() {
        let mut t = TerminalClient::default();
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        ack(&mut t, 7);
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        ack(&mut t, 8);
        let packet = t.prepare(&json!({"action":"detach","session":7,"sessionToken":1})).unwrap().unwrap();
        assert_eq!(packet[5], 16);
        assert!(t.prepare(&json!({"action":"write","session":8,"text":"b"})).is_ok());
        t.prepare(&json!({"action":"list"})).unwrap();
        t.observe(&frame(10, 0, br#"[{"session_id":8,"state":"running"}]"#));
        assert!(t.prepare(&json!({"action":"attach","session":7,"sessionToken":1,"confirmed":true})).is_err());
        t.prepare(&json!({"action":"list"})).unwrap();
        t.observe(&frame(10, 0, br#"[{"session_id":7,"state":"exited"},{"session_id":8}]"#));
        assert!(t.prepare(&json!({"action":"attach","session":7,"sessionToken":1,"confirmed":true})).is_err());
        assert!(t.prepare(&json!({"action":"write","session":8,"text":"b"})).is_ok());
    }

    #[test]
    fn attaching_clears_old_output_before_server_replay() {
        let mut t = TerminalClient::default();
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        ack(&mut t, 7);
        t.observe(&frame(5, 7, b"old"));
        t.prepare(&json!({"action":"detach","session":7,"sessionToken":1})).unwrap();
        t.prepare(&json!({"action":"list"})).unwrap();
        t.observe(&frame(10, 0, br#"[{"session_id":7,"state":"detached"}]"#));
        t.prepare(&json!({"action":"attach","session":7,"sessionToken":1,"confirmed":true})).unwrap();
        ack(&mut t, 7);
        t.observe(&frame(5, 7, b"replay"));
        assert_eq!(t.snapshot()["output"], "replay");
    }
    #[test]
    fn session_limit_blocks_new_open_before_a_frame_is_created() {
        let mut t = TerminalClient::default();
        for id in 1..=256 { t.sessions.insert(id, Session::default()); }
        assert_eq!(t.prepare(&json!({"action":"open","confirmed":true})).unwrap_err(), "terminal_session_limit");
        assert!(t.opening.is_none());
        let s = t.sessions.get_mut(&1).unwrap();
        s.phase = 1;
        s.listed = true;
        assert!(t.prepare(&json!({"action":"attach","session":1,"confirmed":true})).is_ok());
    }

    #[test]
    fn attach_without_confirmed_response_id_is_quarantined() {
        let mut t = TerminalClient::default();
        t.prepare(&json!({"action":"list"})).unwrap();
        t.observe(&frame(10, 0, br#"[{"session_id":7}]"#));
        t.prepare(&json!({"action":"attach","session":7,"sessionToken":1,"confirmed":true})).unwrap();
        ack(&mut t, 0);
        assert_eq!(t.snapshot()["openQuarantined"], true);
        assert_eq!(t.snapshot()["sessions"][0]["attached"], false);
        assert!(t.prepare(&json!({"action":"write","session":7,"text":"x"})).is_err());
    }

    #[test]
    fn confirmed_kill_and_exit_remove_only_the_ended_session_from_snapshot() {
        let mut t = TerminalClient::default();
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        ack(&mut t, 7);
        t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        ack(&mut t, 8);
        t.prepare(&json!({"action":"kill","session":7,"sessionToken":1,"confirmed":true})).unwrap();
        t.observe(&frame(12, 7, br#"{"code":0}"#));
        let state = t.snapshot();
        assert_eq!(state["sessions"].as_array().unwrap().len(), 1);
        assert_eq!(state["sessions"][0]["session"], 8);
        assert!(t.prepare(&json!({"action":"write","session":8,"text":"b"})).is_ok());
        t.observe(&frame(6, 8, b"{}"));
        let state = t.snapshot();
        assert!(state["sessions"].as_array().unwrap().is_empty());
        assert!(state["session"].is_null());
    }

    #[test]
    fn rejected_or_unknown_kill_never_removes_session() {
        for response in [br#"{"code":1}"#.as_slice(), b"{}".as_slice()] {
            let mut t = TerminalClient::default();
            t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
            ack(&mut t, 7);
            t.prepare(&json!({"action":"kill","session":7,"sessionToken":1,"confirmed":true})).unwrap();
            t.observe(&frame(12, 7, response));
            assert_eq!(t.snapshot()["sessions"].as_array().unwrap().len(), 1);
        }
    }


    #[test]
    fn confirmed_empty_list_retires_a_closed_pc_window_without_killing_it() {
        let mut t=TerminalClient::default();t.prepare(&json!({"action":"open","confirmed":true})).unwrap();ack(&mut t,7);
        t.prepare(&json!({"action":"list"})).unwrap();t.observe(&frame(10,0,br#"[]"#));
        let state=t.snapshot();assert!(state["sessions"].as_array().unwrap().is_empty());assert!(state["session"].is_null());
        assert!(t.prepare(&json!({"action":"write","session":7,"sessionToken":1,"text":"x"})).is_err());
        assert!(t.prepare(&json!({"action":"kill","session":7,"sessionToken":1,"confirmed":true})).is_err());
    }
    #[test]
    fn list_and_open_are_serialized_so_absence_is_authoritative() {
        let mut t=TerminalClient::default();t.prepare(&json!({"action":"list"})).unwrap();
        assert_eq!(t.prepare(&json!({"action":"open","confirmed":true})),Err("terminal_list_pending"));
        t.observe(&frame(10,0,br#"[]"#));t.prepare(&json!({"action":"open","confirmed":true})).unwrap();
        assert_eq!(t.prepare(&json!({"action":"list"})),Err("terminal_open_pending"));ack(&mut t,7);
        assert_eq!(t.snapshot()["sessions"].as_array().unwrap().len(),1);
    }
    #[test]
    fn malformed_list_does_not_retire_the_known_session() {
        let mut t=TerminalClient::default();t.prepare(&json!({"action":"open","confirmed":true})).unwrap();ack(&mut t,7);
        t.prepare(&json!({"action":"list"})).unwrap();t.observe(&frame(10,0,b"invalid"));
        assert_eq!(t.snapshot()["listState"],"failed");assert_eq!(t.snapshot()["sessions"].as_array().unwrap().len(),1);
    }
}
