// SPDX-License-Identifier: GPL-3.0-only
use super::*;

pub(super) struct DeviceRemoval {
    key: String,
    name: String,
}

fn displayed_name(row: &Value) -> &str {
    ["alias", "name", "device_name"].into_iter()
        .filter_map(|field| row[field].as_str().map(str::trim))
        .find(|name| !name.is_empty())
        .unwrap_or("未命名设备")
}

impl Core {
    pub(super) fn prepare_device_removal(&mut self, value: &Value) -> Value {
        if self.pending.is_some() { return self.reply(None); }
        self.finish_device_removal("unavailable");
        let (Some(key), Some(name)) = (value["deviceKey"].as_str(), value["name"].as_str()) else {
            return self.reply(None);
        };
        if value["confirmed"] != true || !self.logged() || self.suspended || !self.id.registered()
            || !self.devices_fresh()
            || !self.devices.iter().any(|row| row["current"] == false && row["key"] == key
                && displayed_name(&row["fields"]) == name)
        {
            return self.reply(None);
        }
        self.device_removal = Some(DeviceRemoval { key: key.to_owned(), name: name.to_owned() });
        self.device_removal_status = "checking";
        self.request("unbind_preflight", "/api/v1/device/list", None)
    }

    pub(super) fn verify_device_removal_target(&mut self, data: &Value) -> Value {
        let Some(removal) = self.device_removal.as_ref() else { return self.reply(None); };
        let owned = data["my_binded_devices"].as_array().filter(|rows| rows.len() <= 512);
        let valid = self.logged() && self.id.registered() && !data["current_device"]["device_id"]
            .as_str().is_some_and(|id| id != self.id.device_id);
        if !valid || owned.is_none() {
            self.finish_device_removal("unavailable");
            return self.reply(None);
        }
        let mut candidates = owned.unwrap().iter().filter(|row| {
            crate::devices::key(self, row).as_deref() == Some(removal.key.as_str())
        });
        let Some(target) = candidates.next().filter(|_| candidates.next().is_none()) else {
            self.finish_device_removal("changed");
            return self.reply(None);
        };
        let Some(id) = target["device_id"].as_str().filter(|id| {
            *id != self.id.device_id && *id != "." && *id != ".."
        }) else {
            self.finish_device_removal("changed");
            return self.reply(None);
        };
        if displayed_name(target) != removal.name
            || target["participants_info"].as_array().is_some_and(|participants| !participants.is_empty())
        {
            self.finish_device_removal("changed");
            return self.reply(None);
        }
        let segment: String = id.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            (b as char).to_string()
        } else {
            format!("%{b:02X}")
        }).collect();
        self.device_removal_status = "sending";
        self.request("unbind_device", &format!("/api/v1/device/{segment}/unbind"), None)
    }

    pub(super) fn read_back_device_removal(&mut self) -> Value {
        if self.device_removal.is_none() { return self.reply(None); }
        self.device_removal_status = "verifying";
        self.request("devices", "/api/v1/device/list", None)
    }

    pub(super) fn observe_device_removal_list(&mut self) {
        if self.device_removal_status != "verifying" { return; }
        let absent = self.devices_incomplete == 0 && self.device_removal.as_ref().is_some_and(|removal| {
            !self.devices.iter().any(|row| row["key"] == removal.key.as_str())
        });
        self.finish_device_removal(if absent { "removed" } else { "unconfirmed" });
    }

    pub(super) fn finish_device_removal(&mut self, status: &'static str) {
        self.device_removal = None;
        self.device_removal_status = status;
    }

    pub(super) fn interrupt_device_removal(&mut self) {
        if self.device_removal.is_some() { self.finish_device_removal("unconfirmed"); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (Core, Value, Value, Value) {
        let mut core = Core::default();
        core.id = Identity {
            client_id: "local-client".into(), system_id: "system".into(),
            machine_guid: "machine".into(), device_id: "this-pc".into(),
            ..Default::default()
        };
        core.account.user_id = "test-owner".into();
        core.account.token = "test-account".into();
        let local = json!({"device_id":"this-pc","name":"MateBook","platform":1});
        let old = json!({"device_id":"old/pc?","name":"MateBook","platform":1,"participants_info":[]});
        let other = json!({"device_id":"other-pc","name":"MateBook","platform":1});
        let list = vec![local.clone(), old.clone(), other.clone()];
        core.devices = crate::devices::project(&core, &list).0;
        core.devices_clock = Some(std::time::Instant::now());
        (core, local, old, other)
    }

    fn confirm(core: &mut Core, target: &Value) -> Value {
        let key = crate::devices::key(core, target).unwrap();
        core.call(json!({"op":"remove_device","deviceKey":key,"name":"MateBook","confirmed":true}))
    }

    fn reply(core: &mut Core, request: &Value, status: u32, data: Value) -> Value {
        core.call(json!({"op":"response","id":request["request"]["id"],"httpStatus":status,
            "body":json!({"code":0,"data":data}).to_string()}))
    }

    #[test]
    fn removes_only_selected_same_name_entry_after_fresh_readback() {
        let (mut core, local, old, other) = fixture();
        let preflight = confirm(&mut core, &old);
        assert_eq!(preflight["request"]["method"], "GET");
        assert_eq!(preflight["request"]["kind"], "unbind_preflight");
        let unbind = reply(&mut core, &preflight, 200, json!({
            "current_device":local,"my_binded_devices":[local,other,old]
        }));
        assert_eq!(unbind["request"]["method"], "POST");
        assert!(unbind["request"]["url"].as_str().unwrap().ends_with("/old%2Fpc%3F/unbind"));
        assert_eq!(unbind["request"]["body"], "");
        assert_eq!(core.devices.len(), 3);
        let verify = reply(&mut core, &unbind, 200, json!({}));
        assert_eq!(verify["request"]["kind"], "devices");
        let result = reply(&mut core, &verify, 200, json!({"current_device":local,"my_binded_devices":[other,local]}));
        assert_eq!(result["view"]["deviceRemovalStatus"],"removed");
        assert_eq!(core.devices.len(), 2);
        assert_eq!(core.devices.iter().filter(|d| d["current"]==true).count(), 1);
        assert_eq!(core.id.device_id, "this-pc");
        assert!(core.logged());
    }

    #[test]
    fn refuses_self_shared_ambiguous_renamed_and_controlled_devices() {
        let (mut core, local, old, other) = fixture();
        assert!(confirm(&mut core, &local)["request"].is_null());
        let mut renamed = old.clone();
        renamed["name"] = json!("Changed");
        let mut active = old.clone();
        active["participants_info"] = json!([{"name":"controller"}]);
        for mut owned in [vec![local.clone(), other.clone()], vec![local.clone(),old.clone(),old.clone()],
                          vec![local.clone(),renamed], vec![local.clone(),active]] {
            owned.extend([other.clone()]);
            let preflight = confirm(&mut core, &old);
            let blocked = reply(&mut core, &preflight, 200, json!({
                "current_device":local,"my_binded_devices":owned,"others_shared_devices":[old]
            }));
            assert!(blocked["request"].is_null());
            assert_eq!(blocked["view"]["deviceRemovalStatus"], "changed");
        }
    }

    #[test]
    fn timed_out_post_is_only_read_back_and_still_present_is_unconfirmed() {
        let (mut core, local, old, other) = fixture();
        let preflight = confirm(&mut core, &old);
        let unbind = reply(&mut core, &preflight, 200, json!({"current_device":local,"my_binded_devices":[local,old,other]}));
        let verify = core.call(json!({"op":"network_error","id":unbind["request"]["id"],"timeout":true}));
        assert_eq!(verify["request"]["kind"],"devices");
        let result = reply(&mut core, &verify, 200, json!({"my_binded_devices":[old,other,local]}));
        assert_eq!(result["view"]["deviceRemovalStatus"], "unconfirmed");
        assert!(result["request"].is_null());
    }

    #[test]
    fn late_confirmation_cannot_delete_after_app_suspends() {
        let (mut core, local, old, other) = fixture();
        let preflight = confirm(&mut core, &old);
        core.call(json!({"op":"suspend"}));
        let result = reply(&mut core, &preflight, 200, json!({"my_binded_devices":[local,old,other]}));
        assert!(result["request"].is_null());
        assert_eq!(result["view"]["deviceRemovalStatus"], "unconfirmed");
    }
}
