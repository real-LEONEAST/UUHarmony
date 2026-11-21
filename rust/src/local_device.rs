use super::*;
impl Core {
    pub(crate) fn accept_device_profile(&mut self, profile:&Value) {
        if !profile.is_object() { return; }
        let valid=|s:&str|!s.is_empty()&&s.len()<=256&&!s.chars().any(char::is_control);
        if !profile["name"].as_str().is_some_and(valid){return;}
        let mut accepted=json!({"name":profile["name"]});
        // Missing optional hardware metadata must never discard a real device name.
        for key in ["os","cpu","model","screen","deviceType","brand","manufacturer","product","rom","screenSize"]{
            accepted[key]=json!(profile[key].as_str().filter(|s|valid(s)).unwrap_or("Unknown"));
        }
        accepted["dpi"]=json!(profile["dpi"].as_u64().filter(|v|*v<=10000).unwrap_or(0));
        accepted["nameAuthoritative"]=json!(profile["nameAuthoritative"].as_bool().unwrap_or(true));
        self.device_profile=accepted;
    }
    pub(crate) fn local_kind(&self)->Option<&'static str>{match self.device_profile["deviceType"].as_str(){Some("phone"|"tablet")=>Some("mobile"),Some("2in1"|"pc")=>Some("pc"),_=>None}}
    pub(crate) fn legacy_mobile_registration_needs_change(&mut self, devices: &[Value]) -> bool {
        if self.local_kind() != Some("mobile") || self.id.registered_kind == "mobile" || self.id.device_id.is_empty() {
            return false;
        }
        let mut own = devices.iter().filter(|row| row["device_id"].as_str() == Some(self.id.device_id.as_str()));
        let Some(row) = own.next() else { return false; };
        if own.next().is_some() { return false; }
        match row["platform"].as_i64() {
            Some(2) => {
                self.id.registered_kind = "mobile".into();
                self.migration_readback = 2;
                self.migration_status = "success".into();
                false
            }
            Some(1) => true,
            _ => false,
        }
    }
    pub(crate) fn registration_path(&self)->Option<&'static str>{match self.local_kind(){Some("mobile")=>Some("/api/v1/device/android/init"),Some("pc")=>Some("/api/v1/device/windows/init"),_=>None}}
    pub(crate) fn mobile_registration_profile(&self, alias:Option<&str>)->Value {
        let mut body=json!({"client_id":self.id.client_id,"system_id":self.id.system_id,"install_id":self.id.machine_guid,
          "system_version":self.device_profile["os"],"model":self.device_profile["model"],"abi":self.device_profile["cpu"],
          "resolution":self.device_profile["screen"].as_str().filter(|s|*s!="Unknown").unwrap_or(""),"controllable":false,
          "brand":self.device_profile["brand"].as_str().filter(|s|*s!="Unknown").unwrap_or(""),
          "manufacturer":self.device_profile["manufacturer"].as_str().filter(|s|*s!="Unknown").unwrap_or(""),
          "product":self.device_profile["product"].as_str().filter(|s|*s!="Unknown").unwrap_or(""),
          "rom":self.device_profile["rom"].as_str().filter(|s|*s!="Unknown").unwrap_or(""),
          "screen_size":self.device_profile["screenSize"].as_str().filter(|s|*s!="Unknown").unwrap_or(""),
          "dpi":self.device_profile["dpi"].as_u64().unwrap_or(0),"build_fingerprint":"","gaid":""});
        body["name"]=json!(alias.unwrap_or_else(||self.device_profile["name"].as_str().unwrap_or("鸿蒙设备")));body
    }
    pub(crate) fn registration_body(&self,alias:Option<&str>)->Value{if self.local_kind()==Some("mobile"){self.mobile_registration_profile(alias)}else{self.registration_profile()}}
    pub(crate) fn registration_profile(&self)->Value {
        json!({"name":self.device_profile["name"].as_str().unwrap_or("鸿蒙设备"),
            "client_id":self.id.client_id,"system_id":self.id.system_id,"machine_guid":self.id.machine_guid,
            "os":self.device_profile["os"].as_str().unwrap_or("HarmonyOS"),
            "base_board":self.device_profile["model"].as_str().unwrap_or("Unknown"),
            "cpu":self.device_profile["cpu"].as_str().unwrap_or("Unknown"),"video":["Unknown"],"mac":"","memory":0,
            "screen":self.device_profile["screen"].as_str().unwrap_or("Unknown")})
    }
    pub(crate) fn sync_device_name(&mut self)->Value {
        self.name_sync_attempted=false;
        self.name_sync_status="waiting_list".into();
        self.request("devices","/api/v1/device/list",None)
    }
    fn name_skip(&mut self,status:&str)->Option<Value>{self.name_sync_status=status.into();None}
    pub(crate) fn maybe_sync_device_name(&mut self,devices:&[Value])->Option<Value>{
        if self.name_sync_attempted{return self.name_skip("attempted");}
        if self.local_kind()!=Some("pc"){return self.name_skip("not_pc");}
        if self.id.device_id.is_empty()||self.account.user_id.is_empty(){return self.name_skip("missing_identity");}
        if self.id.manual_name_owners.get(&self.account.user_id)==Some(&self.id.device_id){return self.name_skip("manual_override");}
        if self.device_profile["nameAuthoritative"]==false{return self.name_skip("name_unavailable");}
        let own:Vec<&Value>=devices.iter().filter(|v|v["device_id"].as_str()==Some(self.id.device_id.as_str())).collect();
        if own.len()!=1{return self.name_skip("own_row_not_unique");}
        let alias=match own[0].get("alias"){None|Some(Value::Null)=>"",Some(Value::String(s))=>s.as_str(),_=>return self.name_skip("invalid_alias")};
        let cloud_name=if alias.is_empty(){
            let name=own[0]["name"].as_str().filter(|s|!s.is_empty());
            let device_name=own[0]["device_name"].as_str().filter(|s|!s.is_empty());
            if name.is_some()&&device_name.is_some()&&name!=device_name{return self.name_skip("cloud_name_conflict");}
            name.or(device_name).unwrap_or("")
        }else{alias};
        let name=self.device_profile["name"].as_str().unwrap_or("").to_owned();
        if cloud_name.is_empty(){return self.name_skip("cloud_name_missing");}
        if self.id.reported_name.is_empty(){return self.name_skip("reported_name_missing");}
        if name.is_empty(){return self.name_skip("local_name_missing");}
        // Legacy records have no owner; only an exact old-name match can bind them.
        if self.id.reported_name_owner.is_empty()&&cloud_name==self.id.reported_name{self.id.reported_name_owner=self.account.user_id.clone();}
        if self.id.reported_name_owner!=self.account.user_id{return self.name_skip("owner_mismatch");}
        if cloud_name==name{self.id.reported_name=name;return self.name_skip("already_current");}
        if cloud_name!=self.id.reported_name{return self.name_skip("cloud_name_changed");}
        self.name_sync_attempted=true;
        self.name_sync_status="sending".into();
        self.name_sync_pending=Some((self.id.device_id.clone(),self.account.user_id.clone(),name.clone()));
        let id=self.id.device_id.bytes().map(|b|if b.is_ascii_alphanumeric()||b"-._~".contains(&b){(b as char).to_string()}else{format!("%{b:02X}")}).collect::<String>();
        Some(self.request("rename_self",&format!("/api/v1/device/{id}"),Some(json!({"alias":name}))))
    }
    pub(crate) fn manual_name_request(&mut self,v:&Value)->Value{
        self.manual_name_status.clear();
        let own:Vec<&Value>=self.devices.iter().filter(|d|d["current"]==true).collect();
        if !self.logged()||self.suspended||self.pending.is_some()||self.local_kind()!=Some("pc")||self.account.user_id.is_empty()||self.id.device_id.is_empty()||!self.devices_fresh()||own.len()!=1||own[0]["key"].as_str()!=v["deviceKey"].as_str()||v["deviceKey"].as_str().is_none(){return self.error("manual_name_unavailable");}
        let Some(name)=v["name"].as_str().filter(|s|!s.trim().is_empty()&&s.trim()==*s&&s.chars().count()<=64&&s.len()<=256&&!s.chars().any(char::is_control)).map(str::to_owned)else{return self.error("invalid_manual_name")};
        let owner=self.account.user_id.clone();let id=self.id.device_id.clone();
        // A timed-out PUT may still have succeeded; protect the user's choice before sending.
        let previous=self.id.manual_name_owners.insert(owner.clone(),id.clone());
        if serde_json::to_vec(&self.id).map_or(true,|data|data.len()>1024){if let Some(value)=previous{self.id.manual_name_owners.insert(owner.clone(),value);}else{self.id.manual_name_owners.remove(&owner);}return self.error("manual_name_storage_full");}
        self.manual_name_pending=Some((id.clone(),owner,name.clone()));self.manual_name_status="sending".into();
        let escaped=id.bytes().map(|b|if b.is_ascii_alphanumeric()||b"-._~".contains(&b){(b as char).to_string()}else{format!("%{b:02X}")}).collect::<String>();
        self.request("rename_manual",&format!("/api/v1/device/{escaped}"),Some(json!({"alias":name})))
    }
    pub(crate) fn manual_name_readback(&mut self,devices:&[Value]){
        let Some((id,owner,name))=self.manual_name_pending.take()else{return};
        if id!=self.id.device_id||owner.is_empty()||owner!=self.account.user_id{self.manual_name_status="unconfirmed".into();return;}
        let own:Vec<&Value>=devices.iter().filter(|v|v["device_id"].as_str()==Some(id.as_str())).collect();
        self.manual_name_status=if own.len()==1&&own[0]["alias"].as_str()==Some(name.as_str()){ "success" }else{ "unconfirmed" }.into();
    }
}
#[cfg(test)] mod tests {
    use super::*;
    #[test]
    fn existing_mobile_registration_is_reused_without_init() {
        let mut core=Core::default();
        core.accept_device_profile(&json!({"name":"Test phone","deviceType":"phone"}));
        core.id.device_id="my-registration".into();
        let other=json!({"device_id":"another-registration","platform":1});
        let own=json!({"device_id":"my-registration","platform":2});
        assert!(!core.legacy_mobile_registration_needs_change(&[other.clone()]));
        assert!(!core.legacy_mobile_registration_needs_change(&[own.clone(),own.clone()]));
        assert!(core.id.registered_kind.is_empty());
        assert!(!core.legacy_mobile_registration_needs_change(&[other,own]));
        assert_eq!(core.id.device_id,"my-registration");
        assert_eq!(core.id.registered_kind,"mobile");
    }
    fn profile()->Value{json!({"name":"小许的 MateBook","os":"HarmonyOS 6","cpu":"arm64-v8a","model":"MateBook","screen":"3120x2080","deviceType":"2in1"})}
    fn pc_name_case(alias:&str,owner:&str,user:&str)->(Core,Value) {
        let mut c=Core::default();c.accept_device_profile(&profile());c.id.device_id="own".into();c.id.client_id="client".into();c.id.reported_name="old".into();c.id.reported_name_owner=owner.into();c.account.token="token".into();c.account.user_id=user.into();
        let r=c.call(json!({"op":"refresh"}));assert_eq!(r["request"]["kind"],"devices");
        let list=json!({"code":0,"data":{"current_device":{"device_id":"own","alias":alias,"platform":1},"my_binded_devices":[]}});
        let next=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":list.to_string()}));(c,next)
    }
    #[test] fn pc_name_sync_requires_exact_own_alias_and_account(){
        let (mut c,r)=pc_name_case("old","account","account");assert_eq!(r["request"]["kind"],"rename_self");assert_eq!(c.id.reported_name,"old");assert_eq!(c.id.client_id,"client");
        let next=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":"{\"code\":0}"}));assert_eq!(next["request"]["kind"],"devices");assert_eq!(c.id.reported_name,profile()["name"]);assert_eq!(c.id.reported_name_owner,"account");
        for (alias,owner,user) in [("custom","account","account"),("old","other","account"),("old","account","")] {let (c,r)=pc_name_case(alias,owner,user);assert!(r["request"].is_null());assert_eq!(c.id.reported_name,"old");}
        let (c,r)=pc_name_case("old","","account");assert_eq!(r["request"]["kind"],"rename_self");assert_eq!(c.id.reported_name_owner,"account");
    }
    #[test] fn pc_name_failed_or_late_result_never_claims_success(){
        let (mut c,r)=pc_name_case("old","account","account");let reqid=r["request"]["id"].as_u64().unwrap();let late=c.response(json!({"id":reqid+1,"httpStatus":200,"body":"{\"code\":0}"}));assert!(late["request"].is_null());assert_eq!(c.id.reported_name,"old");let next=c.response(json!({"id":reqid,"httpStatus":503,"body":"{\"code\":1}"}));assert_eq!(next["request"]["kind"],"devices");assert_eq!(c.id.reported_name,"old");
        let (mut c,r)=pc_name_case("old","account","account");c.account.user_id="other".into();c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":"{\"code\":0}"}));assert_eq!(c.id.reported_name,"old");
    }
    #[test] fn pc_name_conflicting_or_missing_own_row_does_not_rename(){
        for data in [json!({"my_binded_devices":[]}),json!({"current_device":{"device_id":"own","alias":"old","platform":1},"my_binded_devices":[{"device_id":"own","alias":"custom","platform":1}]})] {
            let mut c=Core::default();c.accept_device_profile(&profile());c.id.device_id="own".into();c.id.reported_name="old".into();c.id.reported_name_owner="account".into();c.account.user_id="account".into();c.account.token="token".into();let r=c.call(json!({"op":"refresh"}));let done=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":json!({"code":0,"data":data}).to_string()}));assert!(done["request"].is_null());assert_eq!(c.id.reported_name,"old");
        }
    }
    #[test] fn pc_empty_alias_requires_exact_unambiguous_old_cloud_name(){
        for (row,should_rename) in [
            (json!({"alias":"","name":"old"}),true),
            (json!({"device_name":"old"}),true),
            (json!({"alias":null,"name":"old","device_name":"old"}),true),
            (json!({"alias":"","name":"other"}),false),
            (json!({"alias":"","name":"old","device_name":"other"}),false),
            (json!({"alias":"custom","name":"old"}),false),
            (json!({"alias":42,"name":"old"}),false),
            (json!({"alias":""}),false),
        ]{
            let mut c=Core::default();c.accept_device_profile(&profile());c.id.device_id="own".into();c.id.reported_name="old".into();c.id.reported_name_owner="account".into();c.account.user_id="account".into();c.account.token="token".into();let r=c.call(json!({"op":"refresh"}));let mut own=row;own["device_id"]=json!("own");own["platform"]=json!(1);let result=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":json!({"code":0,"data":{"current_device":own,"my_binded_devices":[]}}).to_string()}));assert_eq!(result["request"]["kind"]=="rename_self",should_rename);assert_eq!(c.id.reported_name,"old");
        }
    }
    #[test] fn pc_refresh_samples_profile_and_fallback_never_renames(){
        let mut c=Core::default();c.accept_device_profile(&json!({"name":"old","deviceType":"2in1"}));c.id.device_id="own".into();c.id.reported_name="old".into();c.id.reported_name_owner="account".into();c.account.user_id="account".into();c.account.token="token".into();
        let req=c.call(json!({"op":"refresh","deviceProfile":{"name":"new","nameAuthoritative":false,"deviceType":"2in1"}}));let list=json!({"code":0,"data":{"current_device":{"device_id":"own","alias":"old","platform":1},"my_binded_devices":[]}});let result=c.response(json!({"id":req["request"]["id"],"httpStatus":200,"body":list.to_string()}));assert!(result["request"].is_null());assert_eq!(result["view"]["nameSyncStatus"],"name_unavailable");
        let req=c.call(json!({"op":"refresh","deviceProfile":{"name":"new","nameAuthoritative":true,"deviceType":"2in1"}}));let result=c.response(json!({"id":req["request"]["id"],"httpStatus":200,"body":list.to_string()}));assert_eq!(result["request"]["kind"],"rename_self");assert_eq!(result["view"]["nameSyncStatus"],"sending");
    }
    fn manual_fixture()->(Core,String){
        let mut c=Core::default();c.accept_device_profile(&json!({"name":"old","deviceType":"2in1"}));c.id.device_id="own".into();c.id.client_id="client".into();c.id.reported_name="old".into();c.id.reported_name_owner="account".into();c.account.user_id="account".into();c.account.token="token".into();let request=c.call(json!({"op":"refresh"}));let body=json!({"code":0,"data":{"current_device":{"device_id":"own","alias":"old","platform":1},"my_binded_devices":[{"device_id":"other","alias":"other alias","platform":1}]}});let done=c.response(json!({"id":request["request"]["id"],"httpStatus":200,"body":body.to_string()}));assert!(done["request"].is_null());let key=c.devices.iter().find(|d|d["current"]==true).unwrap()["key"].as_str().unwrap().to_owned();(c,key)
    }
    #[test] fn manual_name_validation_scope_and_verified_readback(){
        let (mut c,key)=manual_fixture();let other=c.devices.iter().find(|d|d["current"]==false).unwrap()["key"].as_str().unwrap().to_owned();
        for value in ["", "  ", "bad\nname"]{let r=c.call(json!({"op":"manual_name","name":value,"deviceKey":key}));assert!(r["request"].is_null());assert!(c.id.manual_name_owners.is_empty());}
        let r=c.call(json!({"op":"manual_name","name":"new","deviceKey":other}));assert!(r["request"].is_null());assert!(c.id.manual_name_owners.is_empty());
        let r=c.call(json!({"op":"manual_name","name":"new","deviceKey":key}));assert_eq!(r["request"]["method"],"PUT");assert!(r["request"]["url"].as_str().unwrap().ends_with("/own"));assert_eq!(c.id.manual_name_owners.get("account").map(String::as_str),Some("own"));
        let list=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":"{\"code\":0}"}));assert_eq!(list["request"]["kind"],"devices");assert_eq!(list["view"]["manualNameStatus"],"checking");
        let body=json!({"code":0,"data":{"current_device":{"device_id":"own","alias":"new","platform":1},"my_binded_devices":[{"device_id":"other","alias":"other alias","platform":1}]}});let done=c.response(json!({"id":list["request"]["id"],"httpStatus":200,"body":body.to_string()}));assert_eq!(done["view"]["manualNameStatus"],"success");assert_eq!(c.devices.iter().find(|v|v["current"]==false).unwrap()["fields"]["alias"],"other alias");
        let invalid=c.call(json!({"op":"manual_name","name":"bad\nname","deviceKey":key}));assert!(invalid["request"].is_null());assert_ne!(invalid["view"]["manualNameStatus"],"success");
        let saved=serde_json::to_string(&c.id).unwrap();let mut restored=Core::default();restored.id=serde_json::from_str(&saved).unwrap();restored.account.user_id="account".into();restored.account.token="token".into();restored.accept_device_profile(&json!({"name":"different-system","deviceType":"2in1"}));let req=restored.call(json!({"op":"refresh"}));let done=restored.response(json!({"id":req["request"]["id"],"httpStatus":200,"body":body.to_string()}));assert!(done["request"].is_null());assert_eq!(done["view"]["nameSyncStatus"],"manual_override");
        c.manual_name_status="success".into();c.id.manual_name_owners.insert("oversized".into(),"x".repeat(1024));let full=c.call(json!({"op":"manual_name","name":"valid","deviceKey":key}));assert!(full["request"].is_null());assert_ne!(full["view"]["manualNameStatus"],"success");
    }
    #[test] fn manual_name_late_owner_and_mismatch_never_report_success(){
        let (mut c,key)=manual_fixture();let request=c.call(json!({"op":"manual_name","name":"new","deviceKey":key}));c.account.user_id="other".into();let done=c.response(json!({"id":request["request"]["id"],"httpStatus":200,"body":"{\"code\":0}"}));assert!(done["request"].is_null());assert_ne!(done["view"]["manualNameStatus"],"success");
        let (mut c,key)=manual_fixture();let request=c.call(json!({"op":"manual_name","name":"new","deviceKey":key}));let list=c.response(json!({"id":request["request"]["id"],"httpStatus":200,"body":"{\"code\":0}"}));let body=json!({"code":0,"data":{"current_device":{"device_id":"own","alias":"old","platform":1},"my_binded_devices":[]}});let done=c.response(json!({"id":list["request"]["id"],"httpStatus":200,"body":body.to_string()}));assert_eq!(done["view"]["manualNameStatus"],"unconfirmed");
        let (mut c,key)=manual_fixture();let request=c.call(json!({"op":"manual_name","name":"new","deviceKey":key}));let list=c.response(json!({"id":request["request"]["id"],"httpStatus":200,"body":"{\"code\":0}"}));c.account.user_id="other".into();let done=c.response(json!({"id":list["request"]["id"],"httpStatus":200,"body":body.to_string()}));assert_ne!(done["view"]["manualNameStatus"],"success");
    }
    #[test] fn manual_override_keeps_both_accounts_and_rejects_full_storage(){let (mut c,key)=manual_fixture();let req=c.call(json!({"op":"manual_name","name":"old","deviceKey":key}));assert!(req["request"].is_object());c.pending=None;c.manual_name_pending=None;c.account.user_id="other".into();let req=c.call(json!({"op":"manual_name","name":"second","deviceKey":key}));assert!(req["request"].is_object());assert_eq!(c.id.manual_name_owners.get("account").map(String::as_str),Some("own"));assert_eq!(c.id.manual_name_owners.get("other").map(String::as_str),Some("own"));c.pending=None;c.account.user_id="account".into();let own=json!([{"device_id":"own","alias":"old","platform":1}]);assert!(c.maybe_sync_device_name(own.as_array().unwrap()).is_none());assert_eq!(c.name_sync_status,"manual_override");}
    #[test] fn mobile_init_is_official_shape_and_unknown_is_not_pc(){
        for kind in ["phone","tablet"] {let mut c=Core::default();c.call(json!({"op":"boot","deviceProfile":{"name":"mobile","deviceType":kind,"os":"HarmonyOS","cpu":"arm64","model":"model","screen":"1200x2000"}}));let r=c.call(json!({"op":"begin"}));assert!(r["request"]["url"].as_str().unwrap().ends_with("/api/v1/device/android/init"));assert_eq!(r["request"]["headers"]["x-param-plat"],"2");let body:Value=serde_json::from_str(r["request"]["body"].as_str().unwrap()).unwrap();assert_eq!(body["controllable"],false);assert!(body.get("client_id").is_some());assert!(body.get("system_id").is_some());assert!(body.get("install_id").is_some());assert!(body.get("machine_guid").is_none());}
        let mut c=Core::default();c.call(json!({"op":"boot","deviceProfile":{"name":"unknown","deviceType":"wearable"}}));assert!(c.call(json!({"op":"begin"}))["request"].is_null());
    }
    #[test] fn migration_uses_own_alias_and_preserves_identity_until_success(){
        let mut c=Core::default();c.accept_device_profile(&json!({"name":"phone","deviceType":"phone"}));c.id.client_id="client".into();c.id.system_id="system".into();c.id.machine_guid="install".into();c.id.device_id="old".into();c.account.token="token".into();c.account.user_id="account".into();
        let r=c.call(json!({"op":"refresh"}));let list=json!({"code":0,"data":{"my_binded_devices":[{"device_id":"old","alias":"my alias","platform":1,"status":"CONNECTED"},{"device_id":"other","alias":"not mine","platform":1}]}});let r=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":list.to_string()}));assert_eq!(r["request"]["kind"],"init_migrate");assert_eq!(c.id.device_id,"old");let body:Value=serde_json::from_str(r["request"]["body"].as_str().unwrap()).unwrap();assert_eq!(body["name"],"my alias");assert_eq!(body["client_id"],"client");assert_eq!(body["system_id"],"system");
        let r=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":"{\"code\":0,\"data\":{\"device_id\":\"new\"}}"}));assert_eq!(c.id.device_id,"new");assert_eq!(c.id.registered_kind,"mobile");assert_eq!(r["request"]["kind"],"restore_migration_alias");assert!(r["request"]["url"].as_str().unwrap().ends_with("/new"));assert_eq!(c.id.client_id,"client");assert_eq!(c.account.token,"token");
    }
    #[test] fn failed_migration_keeps_old_id_and_does_not_retry_during_process(){
        let mut c=Core::default();c.accept_device_profile(&json!({"name":"phone","deviceType":"phone"}));c.id.device_id="old".into();c.account.token="token".into();c.account.user_id="account".into();let r=c.call(json!({"op":"refresh"}));let list=json!({"code":0,"data":{"my_binded_devices":[{"device_id":"old","alias":"alias","platform":1}]}});let r=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":list.to_string()}));let r=c.response(json!({"id":r["request"]["id"],"httpStatus":503,"body":"{\"code\":1}"}));assert_eq!(c.id.device_id,"old");assert_eq!(c.id.registered_kind,"");assert_eq!(r["request"]["kind"],"devices");let r=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":list.to_string()}));assert!(r["request"].is_null());
    }
    fn migration_request()->(Core,Value,Value){
        let mut c=Core::default();c.accept_device_profile(&json!({"name":"phone","deviceType":"phone"}));c.id.client_id="client".into();c.id.system_id="system".into();c.id.device_id="old".into();c.account.token="token".into();c.account.user_id="account".into();let r=c.call(json!({"op":"refresh"}));let list=json!({"code":0,"data":{"my_binded_devices":[{"device_id":"old","alias":"known","platform":1}]}});let r=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":list.to_string()}));(c,r,list)
    }
    #[test] fn migration_late_or_missing_id_never_changes_identity(){
        let (mut c,r,_)=migration_request();let id=r["request"]["id"].as_u64().unwrap();let late=c.response(json!({"id":id+1,"httpStatus":200,"body":json!({"code":0,"data":{"device_id":"wrong"}}).to_string()}));assert!(late["request"].is_null());assert_eq!(c.id.device_id,"old");assert_eq!(c.pending.as_ref().unwrap().0,id);let failed=c.response(json!({"id":id,"httpStatus":200,"body":json!({"code":0,"data":{}}).to_string()}));assert_eq!(c.id.device_id,"old");assert_eq!(c.migration_status,"failed");assert_eq!(failed["request"]["kind"],"devices");
    }
    #[test] fn migration_same_id_marks_success_without_alias_put(){
        let (mut c,r,_)=migration_request();let next=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":json!({"code":0,"data":{"device_id":"old"}}).to_string()}));assert_eq!(c.id.device_id,"old");assert_eq!(c.id.registered_kind,"mobile");assert_eq!(c.migration_status,"readback_pending");assert_eq!(next["request"]["kind"],"devices");assert!(c.id.pending_alias_restore.is_empty());
    }
    #[test] fn alias_restore_success_and_failure_do_not_touch_other_alias(){
        let (mut c,r,_)=migration_request();let put=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":json!({"code":0,"data":{"device_id":"new"}}).to_string()}));assert_eq!(c.id.pending_alias_restore,"known");let r=c.response(json!({"id":put["request"]["id"],"httpStatus":503,"body":json!({"code":1}).to_string()}));assert_eq!(c.id.device_id,"new");assert_eq!(c.id.registered_kind,"mobile");assert_eq!(c.migration_status,"alias_restore_failed");assert_eq!(c.id.pending_alias_restore,"known");
        let list=json!({"code":0,"data":{"my_binded_devices":[{"device_id":"new","alias":"user changed","platform":2},{"device_id":"other","alias":"other name","platform":1}]}});let next=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":list.to_string()}));assert!(next["request"].is_null());assert_eq!(c.migration_status,"alias_changed");assert!(c.id.pending_alias_restore.is_empty());assert_eq!(c.devices.iter().find(|v|v["fields"]["alias"]=="other name").unwrap()["fields"]["alias"],"other name");
        let (mut c,r,_)=migration_request();let put=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":json!({"code":0,"data":{"device_id":"new"}}).to_string()}));let next=c.response(json!({"id":put["request"]["id"],"httpStatus":200,"body":json!({"code":0}).to_string()}));assert_eq!(next["request"]["kind"],"devices");assert!(c.id.pending_alias_restore.is_empty());assert_eq!(c.migration_status,"readback_pending");
    }
    #[test] fn failed_alias_restore_retries_only_if_new_record_has_no_alias(){
        let (mut c,r,_)=migration_request();let put=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":json!({"code":0,"data":{"device_id":"new"}}).to_string()}));let list_req=c.response(json!({"id":put["request"]["id"],"httpStatus":503,"body":json!({"code":1}).to_string()}));let list=json!({"code":0,"data":{"my_binded_devices":[{"device_id":"new","alias":"","platform":2}]}});let retry=c.response(json!({"id":list_req["request"]["id"],"httpStatus":200,"body":list.to_string()}));assert_eq!(retry["request"]["kind"],"restore_migration_alias");let list_req=c.response(json!({"id":retry["request"]["id"],"httpStatus":503,"body":json!({"code":1}).to_string()}));let done=c.response(json!({"id":list_req["request"]["id"],"httpStatus":200,"body":list.to_string()}));assert!(done["request"].is_null());assert_eq!(c.id.pending_alias_restore,"known");assert_eq!(c.migration_status,"alias_restore_failed");
    }
    #[test] fn pending_alias_requires_same_nonempty_account_owner(){
        for (owner,account) in [("old","new"),("","new"),("old","")] {let mut c=Core::default();c.accept_device_profile(&json!({"name":"phone","deviceType":"phone"}));c.id.device_id="new".into();c.id.registered_kind="mobile".into();c.id.pending_alias_restore="old alias".into();c.id.pending_alias_owner=owner.into();c.account.token="token".into();c.account.user_id=account.into();let result=c.call(json!({"op":"refresh"}));assert_eq!(result["request"]["kind"],"devices");assert!(c.id.pending_alias_restore.is_empty());assert!(c.id.pending_alias_owner.is_empty());let list=json!({"code":0,"data":{"my_binded_devices":[{"device_id":"new","alias":"","platform":2}]}});let done=c.response(json!({"id":result["request"]["id"],"httpStatus":200,"body":list.to_string()}));assert!(done["request"].is_null());}
        let (mut c,r,_)=migration_request();c.account.user_id.clear();let next=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":json!({"code":0,"data":{"device_id":"new"}}).to_string()}));assert_eq!(next["request"]["kind"],"devices");assert!(c.id.pending_alias_restore.is_empty());
    }
    #[test] fn migration_diagnostic_survives_subsequent_list_refresh(){
        let (mut c,r,list)=migration_request();let next=c.response(json!({"id":r["request"]["id"],"httpStatus":422,"body":json!({"code":1234,"message":"sensitive diagnostic text"}).to_string()}));assert_eq!(c.migration_diagnostic,"http_error");assert_eq!(c.migration_http,422);assert_eq!(c.migration_api,1234);let view=c.response(json!({"id":next["request"]["id"],"httpStatus":200,"body":list.to_string()}));assert_eq!(view["view"]["migrationDiagnostic"],"http_error");assert_eq!(view["view"]["migrationHttp"],422);assert_eq!(view["view"]["migrationApi"],1234);assert!(!view.to_string().contains("sensitive diagnostic text"));
    }
    #[test] fn migration_invalid_body_and_network_preserve_reason(){
        let (mut c,r,_)=migration_request();let next=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":"not json"}));assert_eq!(next["request"]["kind"],"devices");assert_eq!(c.migration_diagnostic,"invalid_json");
        let (mut c,r,_)=migration_request();let next=c.call(json!({"op":"network_error","id":r["request"]["id"],"timeout":true}));assert_eq!(next["request"]["kind"],"devices");assert_eq!(c.migration_diagnostic,"timeout");
        let (mut c,r,_)=migration_request();let next=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":json!({"code":0,"data":{}}).to_string()}));assert_eq!(next["request"]["kind"],"devices");assert_eq!(c.migration_diagnostic,"missing_device_id");
    }
    #[test] fn readback_reports_raw_server_platform_after_same_or_changed_id(){
      for new_id in ["old","new"] {for platform in [1,2]{let (mut c,r,_)=migration_request();c.migration_alias=None;let list_req=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":json!({"code":0,"data":{"device_id":new_id}}).to_string()}));assert_eq!(c.migration_status,"readback_pending");let list=json!({"code":0,"data":{"my_binded_devices":[{"device_id":new_id,"platform":platform}]}});let done=c.response(json!({"id":list_req["request"]["id"],"httpStatus":200,"body":list.to_string()}));assert_eq!(done["view"]["migrationReadback"],platform);assert_eq!(c.migration_status,if platform==2{"success"}else{"readback_unconfirmed"});}}
    }
    #[test] fn mobile_body_includes_required_real_or_empty_values(){let mut c=Core::default();c.accept_device_profile(&json!({"name":"phone","deviceType":"phone","brand":"brand","manufacturer":"maker","product":"series","rom":"Harmony","screenSize":"6x3","dpi":400}));let b=c.registration_body(None);for k in ["brand","manufacturer","product","rom","screen_size","dpi","build_fingerprint","gaid"]{assert!(b.get(k).is_some(),"{k}");}assert_eq!(b["screen_size"],"6x3");assert_eq!(b["dpi"],400);assert_eq!(b["build_fingerprint"],"");}
    #[test] fn expired_after_accepted_migration_explains_relogin(){let (mut c,r,_)=migration_request();c.migration_alias=None;let next=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":json!({"code":0,"data":{"device_id":"new"}}).to_string()}));let reply=c.response(json!({"id":next["request"]["id"],"httpStatus":400,"body":json!({"code":1120}).to_string()}));assert_eq!(reply["view"]["state"],"expired");assert_eq!(reply["view"]["deviceMigration"],"needs_relogin");assert!(reply["view"]["message"].as_str().unwrap().contains("重新扫码"));assert_eq!(c.id.device_id,"new");assert!(!c.logged());}
    #[test] fn current_device_exact_match_readback_and_conflict(){
        for (current_id,current_platform,bound_platform,expected,rows) in [("new",2,None,2,1),("other",2,None,-1,0),("new",2,Some(2),2,1),("new",2,Some(1),-1,1)]{let mut c=Core::default();c.accept_device_profile(&json!({"name":"phone","deviceType":"phone"}));c.id.client_id="client".into();c.id.device_id="new".into();c.id.registered_kind="mobile".into();c.account.token="token".into();c.account.user_id="account".into();let r=c.call(json!({"op":"refresh"}));let list=if let Some(p)=bound_platform{vec![json!({"device_id":"new","platform":p})]}else{vec![]};let body=json!({"code":0,"data":{"current_device":{"device_id":current_id,"platform":current_platform},"my_binded_devices":list}});let result=c.response(json!({"id":r["request"]["id"],"httpStatus":200,"body":body.to_string()}));assert_eq!(result["view"]["migrationReadback"],expected);assert_eq!(c.devices.len(),rows);assert_eq!(c.migration_status,if expected==2{"success"}else{"readback_unconfirmed"});if bound_platform==Some(1){assert!(c.devices[0]["fields"]["platform"].is_null());}}
    }
    #[test]fn optional_empty_hardware_does_not_discard_system_name(){let mut c=Core::default();c.accept_device_profile(&json!({"name":"我的鸿蒙电脑","os":"HarmonyOS","cpu":"","model":"","screen":""}));assert_eq!(c.registration_profile()["name"],"我的鸿蒙电脑");assert_eq!(c.device_profile["cpu"],"Unknown");}
}
