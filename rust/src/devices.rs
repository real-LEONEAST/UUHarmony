// Stable, installation-scoped UI handles. Raw cloud IDs never leave the core.
use super::*;
use std::collections::BTreeMap;

pub(crate) const FRESH_FOR: std::time::Duration = std::time::Duration::from_secs(60);

pub(crate) fn key(c: &Core, dev: &Value) -> Option<String> {
    let id = dev["device_id"].as_str().filter(|s| !s.is_empty() && s.len() <= 1024 && !s.chars().any(char::is_control))?;
    let mut mac = Hmac::<Sha256>::new_from_slice(c.id.client_id.as_bytes()).ok()?;
    mac.update(b"UUHarmony/device-list/v1\0");
    mac.update(id.as_bytes());
    Some(hex::encode(mac.finalize().into_bytes()))
}

pub(crate) fn participant_token(c:&Core, dev:&Value)->Option<String> {
    let entries=dev.get("participants_info")?.as_array()?;if entries.is_empty()||entries.len()>64{return None}
    let mut identities=Vec::new();
    for entry in entries { let client=entry.get("client_id")?.as_str().filter(|v|!v.is_empty()&&v.len()<=1024&&!v.chars().any(char::is_control))?;
        let device=entry.get("device_id")?.as_str().filter(|v|!v.is_empty()&&v.len()<=1024&&!v.chars().any(char::is_control))?;
        let kind=entry.get("user_join_type")?.as_i64()?;identities.push(format!("{}:{}:{}:{}:{}",client.len(),client,device.len(),device,kind)); }
    identities.sort();let mut mac=Hmac::<Sha256>::new_from_slice(c.id.client_id.as_bytes()).ok()?;mac.update(b"UUHarmony/participants/v1\0");
    for identity in identities {mac.update(&(identity.len() as u64).to_be_bytes());mac.update(identity.as_bytes());}Some(hex::encode(mac.finalize().into_bytes()))
}

pub(crate) fn unique_local_participant<'a>(c:&Core,dev:&'a Value)->Option<&'a str>{
    if c.id.device_id.is_empty(){return None}
    let mut ours=dev["participants_info"].as_array()?.iter().filter(|p| match p["device_id"].as_str().filter(|id|!id.is_empty()){
        Some(id)=>id==c.id.device_id,
        None=>!c.id.client_id.is_empty()&&p["client_id"].as_str()==Some(&c.id.client_id),
    });
    let participant=ours.next()?;
    if ours.next().is_some(){return None}
    participant["client_id"].as_str().filter(|id|!id.is_empty()&&id.len()<=1024&&!id.chars().any(char::is_control))
}

pub(crate) fn project(c: &Core, devices: &[Value]) -> (Vec<Value>, usize) {
    let mut rows: Vec<Value> = Vec::new();
    let mut positions = BTreeMap::<String, usize>::new();
    let mut incomplete = 0;
    for dev in devices {
        let Some(key) = key(c, dev) else { incomplete += 1; continue };
        if let Some(&position) = positions.get(&key) {
            if rows[position]["wallpaperRevision"] != json!(crate::device_wallpaper::source(c,dev).map(|s|s.revision).unwrap_or_default()){rows[position]["wallpaperRevision"]=json!("");rows[position]["wallpaperState"]=json!("source_conflict");}
            // Conflicting duplicate participant reports are not authoritative.
            rows[position]["participants"] = Value::Null;rows[position]["participantToken"] = Value::Null;
            // An exact duplicate ID is one registration. Conflicting reports stay unknown.
            if rows[position]["fields"]["status"] != dev["status"] || rows[position]["fields"]["platform"] != dev["platform"] {
                rows[position]["fields"]["status"] = json!("UNKNOWN");
            }
            if rows[position]["fields"]["platform"] != dev["platform"] {
                if let Some(fields)=rows[position]["fields"].as_object_mut(){fields.remove("platform");}
            }
            continue;
        }
        let mut fields = serde_json::Map::new();
        for k in ["alias", "name", "device_name", "platform", "os", "device_type", "type", "online", "is_online", "status", "availability"] {
            if let Some(x) = dev.get(k) {
                if x.is_number() || x.is_boolean() || x.as_str().is_some_and(|s| s.len() <= 512 && !s.chars().any(char::is_control)) {
                    fields.insert(k.into(), x.clone());
                }
            }
        }
        let own=dev["device_id"].as_str()==Some(c.id.device_id.as_str());
        let previous_mobile=!c.id.previous_mobile_device_id.is_empty()&&dev["device_id"].as_str()==Some(c.id.previous_mobile_device_id.as_str());
        if (own&&c.local_kind()==Some("mobile"))||previous_mobile{fields.insert("localMobile".into(),json!(true));}
        if own{if let Some(kind)=c.device_profile["deviceType"].as_str(){fields.insert("localDeviceType".into(),json!(kind));}}
        if previous_mobile{fields.insert("previousMobile".into(),json!(true));}
        if dev["participants_info"].as_array().is_some_and(|entries|entries.len()==1)&&unique_local_participant(c,dev).is_some(){
            fields.insert("localControllerOnly".into(),json!(true));
        }
        // Official Android MyDevice.participants_info is a list of current participants.
        // Only project bounded display aliases; retain raw identities in the core.
        let participants = dev.get("participants_info").and_then(Value::as_array).filter(|a| a.len() <= 64).and_then(|a| {
            let mut names = Vec::new();
            for item in a {
                let obj = item.as_object()?;
                let alias = match obj.get("alias") {
                    Some(Value::String(v)) if v.len() <= 512 && !v.chars().any(char::is_control) => v.trim().to_owned(),
                    None | Some(Value::Null) => String::new(),
                    _ => return None,
                };
                names.push(alias);
            }
            Some(names)
        });
        positions.insert(key.clone(), rows.len());
        rows.push(json!({"key":key, "current":dev["device_id"].as_str()==Some(&c.id.device_id), "fields":fields,"participants":participants,"participantToken":participant_token(c,dev),"wallpaperRevision":crate::device_wallpaper::source(c,dev).map(|s|s.revision).unwrap_or_default(),"wallpaperState":crate::device_wallpaper::metadata_state(c,dev)}));
    }
    (rows, incomplete)
}

impl Core {
    // Connection authority is the current account's last successful snapshot, not its UI age.
    pub(crate) fn has_device_snapshot(&self) -> bool { self.devices_clock.is_some() }
    pub(crate) fn devices_fresh(&self) -> bool {
        !self.devices_refresh_failed && self.devices_clock.is_some_and(|t| t.elapsed() < FRESH_FOR)
    }
    pub(super) fn clear_device_list(&mut self) {
        self.interrupt_device_removal();
        self.devices.clear();
        self.wallpapers.clear();
        self.devices_updated_ms = 0;
        self.devices_clock = None;
        self.devices_refresh_failed = false;
        self.devices_incomplete = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn core() -> Core { let mut c=Core::default(); c.id.client_id="synthetic-install".into(); c }
    #[test]
    fn ui1_device_handles_survive_reorder_and_hide_raw_ids() {
        let c=core(); let a=json!({"device_id":"synthetic-a","name":"Same","platform":1,"status":"CONNECTED"});
        let b=json!({"device_id":"synthetic-b","name":"Same","platform":1,"status":"DISCONNECTED"});
        let (first,_)=project(&c,&[a.clone(),b.clone()]); let (second,_)=project(&c,&[b,a]);
        assert_eq!(first[0]["key"],second[1]["key"]); assert_ne!(first[0]["key"],first[1]["key"]);
        let text=serde_json::to_string(&first).unwrap(); assert!(!text.contains("synthetic-a")); assert!(!text.contains("device_id")); assert!(!text.contains("index"));
        let mut other=core();other.id.client_id="synthetic-other-install".into();assert_ne!(key(&c,&json!({"device_id":"synthetic-a"})),key(&other,&json!({"device_id":"synthetic-a"})));
    }
    #[test]
    fn ui1_device_duplicates_and_missing_identity_are_safe() {
        let c=core();let a=json!({"device_id":"synthetic-a","status":"CONNECTED","platform":1});
        let (rows,incomplete)=project(&c,&[a.clone(),a,json!({"name":"missing"}),json!({"device_id":"synthetic-a","status":"DISCONNECTED","platform":1})]);
        assert_eq!(rows.len(),1);assert_eq!(incomplete,1);assert_eq!(rows[0]["fields"]["status"],"UNKNOWN");
    }
    #[test]
    fn ui1_device_refresh_failure_preserves_last_success() {
        let mut c=core();c.account.token="synthetic-token".into();c.pending=Some((1,"devices".into()));
        c.response(json!({"op":"response","id":1,"httpStatus":200,"body":json!({"code":0,"data":{"my_binded_devices":[{"device_id":"synthetic-a","status":"CONNECTED","platform":1}]}}).to_string()}));
        let before=c.devices.clone();let timestamp=c.devices_updated_ms;assert!(c.devices_fresh());
        c.pending=Some((2,"devices".into()));c.call(json!({"op":"network_error","id":2}));
        assert_eq!(c.devices,before);assert_eq!(c.devices_updated_ms,timestamp);assert!(!c.devices_fresh());assert!(c.devices_refresh_failed);
        c.devices_refresh_failed=false;c.devices_clock=Some(std::time::Instant::now()-FRESH_FOR);assert!(!c.devices_fresh());
    }
}
