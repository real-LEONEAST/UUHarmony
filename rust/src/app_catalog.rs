use crate::file_protocol::{all, blob, nested, text, uint};
use crate::wire::{bytes, envelope, int};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

struct App { name: String, app_key: String, app_id: String, target: String }
#[derive(Default)]
pub struct Catalog {
    sequence: u64,
    pending: Option<(u64, String)>,
    apps: BTreeMap<String, App>,
    phase: &'static str,
    icon: Option<(String, String)>,
}

fn rpc(seq: u64, field: u32, payload: &[u8]) -> Vec<u8> {
    let mut header = Vec::new();
    int(1, seq, &mut header);
    let mut request = nested(1, &header);
    bytes(field, payload, &mut request);
    envelope(seq, 21, &request)
}

fn bounded(row: &[u8], field: u32, max: usize) -> Option<String> {
    let value = text(row, field).ok()?;
    (value.len() <= max && !value.chars().any(char::is_control)).then_some(value)
}

impl Catalog {
    pub fn command(&mut self, action: &str, id: &str) -> Result<Option<Vec<u8>>, &'static str> {
        if action == "status" { return Ok(None); }
        self.sequence += 1;
        let seq = 7_300_000 + self.sequence;
        if action == "scan" {
            if self.pending.as_ref().is_some_and(|(_, id)| id.is_empty()) { return Err("catalog_scan_in_progress"); }
            self.apps.clear();
            self.icon = None;
            self.pending = Some((seq, String::new()));
            self.phase = "scanning";
            return Ok(Some(rpc(seq, 23, &[])));
        }
        let app = self.apps.get(id).ok_or("app_not_in_current_catalog")?;
        if action == "icon" {
            if self.pending.as_ref().is_some_and(|(_, id)| id.is_empty()) { return Err("catalog_scan_in_progress"); }
            self.pending = Some((seq, id.into()));
            self.icon = None;
            return Ok(Some(rpc(seq, 24, &nested(1, app.app_key.as_bytes()))));
        }
        if action != "launch" { return Err("unknown_app_operation"); }
        // Only fields from this peer's current scan. There is no caller-defined path or argument.
        let mut payload = Vec::new();
        for (field, value) in [(1, &app.app_id), (2, &app.name), (3, &app.target), (5, &app.app_key)] {
            if !value.is_empty() { bytes(field, value.as_bytes(), &mut payload); }
        }
        Ok(Some(envelope(seq, 4, &payload)))
    }

    pub fn send_failed(&mut self) { self.pending=None; self.phase="failed"; }

    pub fn observe(&mut self, packet: &[u8]) {
        let Some((seq, id)) = self.pending.as_ref() else { return; };
        if packet.len() > 2 * 1024 * 1024 { return; }
        let Some(reply) = blob(packet, 22) else { return; };
        if blob(reply, 1).map(|h| uint(h, 1)) != Some(*seq) { return; }
        if id.is_empty() {
            let Some(body) = blob(reply, 19) else { return; };
            self.pending = None;
            self.phase = "failed";
            if uint(body, 1) != 0 { return; }
            let Ok(rows) = all(body, 3) else { return; };
            let mut apps = BTreeMap::new();
            for row in rows {
                let Some(key) = bounded(row, 1, 512) else {continue};
                let Some(name) = bounded(row, 2, 512) else {continue};
                let Some(target) = bounded(row, 4, 4096) else {continue};
                let Some(app_id) = bounded(row, 5, 512) else {continue};
                if key.is_empty() || name.trim().is_empty() {continue;}
                let id = hex::encode(Sha256::digest(key.as_bytes()));
                apps.entry(id).or_insert(App { name, app_key:key, app_id, target });
            }
            self.apps = apps;
            self.phase = "ready";
        } else {
            let Some(body) = blob(reply, 20) else { return; };
            let id = id.clone();
            self.pending = None;
            if uint(body, 1) != 0 || self.apps.get(&id).map(|a|a.app_key.as_bytes()) != blob(body,3) {return;}
            if let Some(icon) = blob(body, 4).filter(|b| b.len() <= 128 * 1024) {
                let mime = if icon.starts_with(b"\x89PNG\r\n\x1a\n") { "png" } else if icon.starts_with(&[255,216,255]) { "jpeg" } else {return;};
                self.icon=Some((id,format!("data:image/{mime};base64,{}",STANDARD.encode(icon))));
            }
        }
    }
    pub fn status(&self, list: bool) -> Value {
        let mut v=json!({"phase":self.phase,"pending":self.pending.is_some()});
        if list {
            v["apps"]=Value::Array(self.apps.iter().map(|(id,app)|json!({"id":id,"name":app.name})).collect());
        }
        if let Some((id,data))=&self.icon {v["iconId"]=json!(id);v["icon"]=json!(data);}
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn scan_correlates_and_launch_uses_the_selected_rows_identity() {
        let mut catalog=Catalog::default();
        let packet=catalog.command("scan","").unwrap().unwrap();
        let req=blob(&packet,21).unwrap();
        assert_eq!(blob(req,23),Some([].as_slice()));
        let header=blob(req,1).unwrap();
        let mut row=nested(1,b"key-A"); bytes(2,b"Editor",&mut row); bytes(5,b"app-A",&mut row);
        let mut reply=nested(1,&[8,1]);bytes(19,&nested(3,&row),&mut reply);
        catalog.observe(&envelope(1,22,&reply));assert!(catalog.apps.is_empty());
        let mut reply=nested(1,header);bytes(19,&nested(3,&row),&mut reply);
        catalog.observe(&envelope(1,22,&reply));
        assert!(catalog.command("launch","unknown").is_err());
        let id=catalog.apps.keys().next().unwrap().clone();
        let packet=catalog.command("launch",&id).unwrap().unwrap();
        let launch=blob(&packet,4).unwrap();
        assert_eq!(text(launch,1).unwrap(),"app-A");assert_eq!(text(launch,5).unwrap(),"key-A");
        assert!(blob(launch,4).is_none());
    }
    #[test]
    fn concurrent_scan_and_stale_icon_cannot_replace_pending_scan() {
        let mut c=Catalog::default();
        let scan=c.command("scan", "").unwrap().unwrap();
        assert_eq!(c.command("scan", "").unwrap_err(), "catalog_scan_in_progress");
        let header=blob(blob(&scan,21).unwrap(),1).unwrap();
        let mut row=nested(1,b"key");bytes(2,b"Editor",&mut row);bytes(4,b"target",&mut row);bytes(5,b"id",&mut row);
        let mut reply=nested(1,header);bytes(19,&nested(3,&row),&mut reply);c.observe(&envelope(1,22,&reply));
        let id=c.apps.keys().next().unwrap().clone();
        let icon=c.command("icon",&id).unwrap().unwrap();
        let next=c.command("scan", "").unwrap().unwrap();
        let mut stale=nested(1,blob(blob(&icon,21).unwrap(),1).unwrap());
        let mut body=nested(3,b"key");bytes(4,b"\x89PNG\r\n\x1a\n",&mut body);bytes(20,&body,&mut stale);
        c.observe(&envelope(1,22,&stale));assert!(c.icon.is_none());assert!(c.pending.is_some());
        let mut fresh=nested(1,blob(blob(&next,21).unwrap(),1).unwrap());bytes(19,&[],&mut fresh);
        c.observe(&envelope(1,22,&fresh));assert_eq!(c.phase,"ready");assert!(c.apps.is_empty());
    }

}
