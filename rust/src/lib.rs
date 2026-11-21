mod auth_resume;
mod devices;
mod local_device;
mod migration_diagnostic;
mod privacy_wallpaper;
mod device_wallpaper;
mod advanced_controls;
mod clipboard;
mod clipboard_protocol;
mod clipboard_rich;
mod files;
mod file_protocol;
mod microphone;
mod center;
mod terminal_client;
mod terminal_raw_read;
mod terminal_privacy;
mod unlock;
mod unlock_binding;
mod app_catalog;
mod protocol;
mod input;
mod tablet_wire;
mod wire;
mod nal_policy;
mod orientation;
#[cfg(any(feature="rtp-diagnostics",test))] mod rtp_diagnostics;
#[cfg(any(target_env="ohos",test))] mod media;
mod multistream;
#[cfg(target_env="ohos")] mod capture;
#[cfg(target_env="ohos")] mod connection_info;
// SPDX-License-Identifier: GPL-3.0-only
// Protocol adapted from VallierDev/uu-remote-linux @ 6bf05a6361e58dbeec5846f044d234bed04fcf02.
mod signal;
#[cfg(target_env="ohos")] mod peer;
#[cfg(not(target_env="ohos"))] mod peer {
    pub fn call(_:serde_json::Value)->serde_json::Value {serde_json::json!({"closed":true,"weakReleased":true,"hostProtocolOnly":true})}
    pub fn bind_unlock(_:u64, _:&str)->bool { false }
    pub fn unlock_ready(_:u64)->bool { false }
    pub fn unlock_permitted(_:u64)->bool { false }
    pub fn unlock_observed_unlocked(_:u64)->bool { false }
    pub fn unlock_send(_:u64,_:&[u8])->serde_json::Value { serde_json::json!({"sent":false,"error":"no_active_peer"}) }
}
mod session;
mod device_removal;
// S3c adds only confirmed room join and signaling; no device mutation or host service.
use base64::Engine;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Sha256;
use std::{collections::BTreeMap, ffi::{CStr,CString}, os::raw::c_char, sync::{Mutex,OnceLock}, time::{SystemTime,UNIX_EPOCH}};
use zeroize::Zeroize;
const SIGN_KEY:&str="alWiSzXZTLu3WfFnw13uBru3"; // Public upstream client-wide signing constant, not an account secret.
const BASE:&str="https://api.nrd.nie.163.com";
#[derive(Default,Serialize,Deserialize)]
struct Identity { client_id:String, system_id:String, machine_guid:String, device_id:String, #[serde(default)] reported_name:String, #[serde(default)] reported_name_owner:String, #[serde(default)] manual_name_owners:BTreeMap<String,String>, #[serde(default)] name_migration_version:u32, #[serde(default)] registered_kind:String, #[serde(default)] previous_mobile_device_id:String, #[serde(default)] pending_alias_restore:String, #[serde(default)] pending_alias_owner:String }
#[derive(Default,Serialize,Deserialize)]
struct Account { user_id:String, token:String, csrf:String }
impl Identity {
 fn has_local_ids(&self)->bool{[&self.client_id,&self.system_id,&self.machine_guid].iter().all(|id|!id.is_empty())}
 fn empty(&self)->bool{[&self.client_id,&self.system_id,&self.machine_guid,&self.device_id].iter().all(|id|id.is_empty())}
 fn registered(&self)->bool{self.has_local_ids()&&!self.device_id.is_empty()}
}
impl Drop for Account { fn drop(&mut self){self.user_id.zeroize();self.token.zeroize();self.csrf.zeroize();} }
#[derive(Default)]
struct Core { id:Identity, device_removal:Option<device_removal::DeviceRemoval>, device_removal_status:&'static str, manual_name_status:String, manual_name_pending:Option<(String,String,String)>, name_sync_status:String, name_sync_attempted:bool, name_sync_pending:Option<(String,String,String)>, migration_attempted:bool, migration_alias:Option<String>, migration_alias_owner:String, migration_status:String, migration_diagnostic:String, migration_validation:String, migration_readback:i64, migration_http:i64, migration_api:i64, alias_restore_attempts:u8, device_profile:Value, account:Account, account_label:String, ticket:String, qr:String, last:i64, qr_created_ms:u64, qr_expires_ms:u64, qr_clock:Option<std::time::Instant>, suspended:bool, serial:u64, pending:Option<(u64,String)>, state:String, message:String, devices:Vec<Value>, wallpapers:BTreeMap<String,device_wallpaper::WallpaperSource>, devices_updated_ms:u64, devices_clock:Option<std::time::Instant>, devices_refresh_failed:bool, devices_incomplete:usize, refreshes:u64, last_http:i64, last_code:i64 }
impl Core {
 fn new_uuid()->Result<String,&'static str>{let mut b=[0u8;16]; getrandom::getrandom(&mut b).map_err(|_|"secure_random_failed")?; b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;let s=hex::encode(b);Ok(format!("{}-{}-{}-{}-{}",&s[..8],&s[8..12],&s[12..16],&s[16..20],&s[20..]))}
 fn clear_qr(&mut self){self.qr.zeroize();self.ticket.zeroize();self.last=1;self.qr_created_ms=0;self.qr_expires_ms=0;self.qr_clock=None;}
 fn logged(&self)->bool{!self.account.token.is_empty()}
 fn valid_restored_identity(&self,expected:bool)->bool{
  if expected||self.logged(){return self.id.registered();}
  self.id.empty()||self.id.has_local_ids()
 }
 fn view(&self)->Value { let live=self.qr_live_at(auth_resume::now_ms()); json!({"state":self.state,"message":self.message,"registeredIdentity":self.id.registered(),"nameSyncStatus":self.name_sync_status,"manualNameStatus":self.manual_name_status,"deviceMigration":self.migration_status,"deviceRemovalStatus":self.device_removal_status,"migrationDiagnostic":self.migration_diagnostic,"migrationValidation":self.migration_validation,"migrationReadback":self.migration_readback,"migrationHttp":self.migration_http,"migrationApi":self.migration_api,"loggedIn":self.logged(),"accountLabel":if self.logged(){if self.account_label.is_empty(){"UU账号已登录"}else{&self.account_label}}else{""},"qr":if live&&!self.suspended{self.qr.as_str()}else{""},"devices":self.devices,"wallpaperAccountKey":self.wallpaper_account_key(),"devicesUpdatedAtMs":self.devices_updated_ms,"devicesRefreshFailed":self.devices_refresh_failed,"devicesIncomplete":self.devices_incomplete,"refreshes":self.refreshes,"httpStatus":self.last_http,"apiCode":self.last_code,"pending":self.pending.is_some(),"suspended":self.suspended,"canResume":live&&!self.logged(),"qrExpiresAtMs":if live{self.qr_expires_ms}else{0},"qrPersistence":self.qr_persistence(),"qrExportAllowed":live&&!self.suspended&&self.last!=4,"smsSupported":false,"sameDeviceDeepLinkSupported":false}) }
 fn reply(&self,req:Option<Value>)->Value{json!({"view":self.view(),"request":req})}
 fn error(&mut self,code:&str)->Value{self.pending=None;self.state="error".into();self.message=if code=="unknown_local_device_type"{"无法识别此设备类型，请确认系统设备信息后重试".into()}else{code.into()};self.reply(None)}
 fn validate_pending_alias_owner(&mut self){if !self.id.pending_alias_restore.is_empty()&&(self.id.pending_alias_owner.is_empty()||self.account.user_id.is_empty()||self.id.pending_alias_owner!=self.account.user_id){self.id.pending_alias_restore.clear();self.id.pending_alias_owner.clear();self.migration_status="alias_owner_changed".into();}}
 fn headers(&self,method:&str,path:&str,body:&str)->BTreeMap<String,String>{
  let elapsed=SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
  let ts=if self.local_kind()==Some("mobile"){elapsed.as_millis().to_string()}else{elapsed.as_secs().to_string()};
  let mut h:BTreeMap<String,String>=[("x-param-plat",if self.local_kind()==Some("mobile"){"2"}else{"1"}),("x-param-vn","4.42.0.2770"),("x-param-vc","2770"),("x-param-pkgn","com.netease.gameviewer"),("x-param-chn","gwqd"),("x-param-lang","zh-CN"),("x-param-cnt","CN")].into_iter().map(|(k,v)|(k.into(),v.into())).collect();
  if self.local_kind()==Some("mobile") {
   for (k,v) in [("x-param-vn","4.45.0"),("x-param-vc","445000"),("x-param-pkgn","com.netease.uuremote"),("x-param-chn","nochannel"),("x-param-rel","prod")] {h.insert(k.into(),v.into());}
   if let Some(abi)=self.device_profile["cpu"].as_str().filter(|s|!s.is_empty()&&*s!="Unknown"){h.insert("x-param-abi".into(),abi.into());}
  }
  for (k,v) in [("x-param-client-id",&self.id.client_id),("x-param-system-id",&self.id.system_id),("x-param-device-id",&self.id.device_id),("x-param-user-id",&self.account.user_id)]{if !v.is_empty(){h.insert(k.into(),v.clone());}}
  h.insert("x-param-ts".into(),ts);
  let sig=sign(method,path,&h,body);
  h.insert("X-Param-SIGN".into(),sig);h.insert("Content-Type".into(),"application/json".into());h.insert("Accept".into(),"application/json".into());if self.local_kind()!=Some("mobile"){h.insert("User-Agent".into(),"UURemote/4.42.0 (Windows NT 10.0; Win64; x64)".into());}
  if self.logged(){h.insert("Authorization".into(),format!("Bearer {}",self.account.token));h.insert("Cookie".into(),format!("nrd_access_token={}; nrd_csrf_access_token={}",self.account.token,self.account.csrf));h.insert("X-CSRF-TOKEN".into(),self.account.csrf.clone());} h
 }
 fn request(&mut self,kind:&str,path:&str,body:Option<Value>)->Value{
  let text=body.map(|v|v.to_string()).unwrap_or_default();let method=if matches!(kind,"devices"|"unbind_preflight"){"GET"}else if matches!(kind,"rename_self"|"rename_manual"|"restore_migration_alias"){"PUT"}else{"POST"};self.serial+=1;self.pending=Some((self.serial,kind.into()));
  let r=json!({"id":self.serial,"kind":kind,"url":format!("{BASE}{path}"),"method":method,"headers":self.headers(method,path,&text),"body":text,"timeoutMs":if matches!(kind,"init"|"init_migrate"|"devices"|"unbind_preflight"|"unbind_device"|"rename_self"|"rename_manual"|"restore_migration_alias"){12000}else{60000}});self.reply(Some(r))
 }
 fn generate(&mut self)->Value{self.clear_qr();self.state="loading_qr".into();self.message="正在获取真实二维码".into();self.request("generate","/api/v1/qrcode/gen/login",None)}
 fn poll(&mut self)->Value{if self.suspended{return self.reply(None);}if self.expire_qr_at(auth_resume::now_ms()){return self.reply(None);}if self.qr.is_empty()||self.ticket.is_empty(){return self.error("no_active_qr");}self.request("poll","/api/v1/qrcode/login/status",Some(json!({"token":self.ticket,"qrcode_jump_url":self.qr,"login_status":self.last})))}
 fn call(&mut self,v:Value)->Value{
  if v["op"]=="boot"||v["op"]=="refresh" { self.accept_device_profile(&v["deviceProfile"]); }
  self.expire_qr_at(auth_resume::now_ms());
  match v["op"].as_str().unwrap_or("") {
   "boot"=>{if self.id.client_id.is_empty(){let a=Self::new_uuid();let b=Self::new_uuid();let c=Self::new_uuid();match (a,b,c){(Ok(a),Ok(b),Ok(c))=>self.id=Identity{client_id:a,system_id:b.to_uppercase(),machine_guid:c,..Default::default()},_=>return self.error("secure_random_failed")}}self.state=if self.logged(){"restored"}else if self.qr_live_at(auth_resume::now_ms()){"suspended"}else{"signed_out"}.into();self.message=if self.logged(){"安全存储已恢复，请刷新验证登录状态"}else if self.qr_live_at(auth_resume::now_ms()){"已从系统安全存储恢复待授权二维码，回到前台后继续"}else{"请点击登录，由官方 UU 手机应用扫码并确认"}.into();self.reply(None)},
   "begin"=>{self.suspended=false;if self.logged(){return self.error("already_logged_in");}self.pending=None;self.clear_qr();if self.local_kind().is_none(){return self.error("unknown_local_device_type")};if self.id.device_id.is_empty(){let Some(path)=self.registration_path()else{return self.error("unknown_local_device_type")};self.state="initializing".into();self.message="正在注册此鸿蒙设备".into();self.request("init",path,Some(self.registration_body(None)))}else{self.generate()}},
   "suspend"=>self.suspend_auth(),
   "resume"=>self.resume_auth(),
   "qr_export"=>self.export_qr(&v),
   "poll"=>self.poll(),
   "device_wallpaper"=>self.resolve_wallpaper(&v),
   "refresh"|"manual_name_refresh" if self.device_removal.is_some()=>self.reply(None),
   "refresh"=>{self.suspended=false;self.validate_pending_alias_owner();if self.local_kind().is_none(){return self.error("unknown_local_device_type")};if !self.logged(){return self.error("login_required");}self.state="refreshing".into();self.message="正在获取真实设备列表".into();self.sync_device_name()},
   "manual_name_refresh"=>{self.suspended=false;self.validate_pending_alias_owner();if self.local_kind()!=Some("pc")||!self.logged()||self.pending.is_some(){return self.error("manual_name_unavailable");}self.state="refreshing".into();self.message="正在获取真实设备列表".into();let request=self.sync_device_name();self.name_sync_attempted=true;request},
   "manual_name"=>self.manual_name_request(&v),
   "remove_device"=>self.prepare_device_removal(&v),
   "response"=>self.response(v),
   "network_error"=>{if self.pending.as_ref().map(|p|p.0)!=v["id"].as_u64(){return self.reply(None);}if self.pending.as_ref().is_some_and(|p|p.1=="unbind_device"){return self.read_back_device_removal();}self.interrupt_device_removal();if self.manual_name_pending.is_some()&&self.pending.as_ref().is_some_and(|p|p.1=="rename_manual"||p.1=="devices"){self.manual_name_pending=None;self.manual_name_status="unconfirmed".into();}if self.pending.as_ref().is_some_and(|p|matches!(p.1.as_str(),"init_migrate"|"restore_migration_alias")){if self.pending.as_ref().is_some_and(|p|p.1=="init_migrate"){self.migration_diagnostic=if v["timeout"]==true{"timeout"}else{"network_error"}.into();self.migration_http=0;self.migration_api=-1;}self.migration_status=if self.pending.as_ref().is_some_and(|p|p.1=="init_migrate"){"failed"}else{"alias_restore_failed"}.into();self.migration_alias=None;return self.request("devices","/api/v1/device/list",None)}if self.pending.as_ref().is_some_and(|p|p.1=="rename_self"){self.name_sync_pending=None;self.name_sync_status="network_error".into();return self.request("devices","/api/v1/device/list",None)} if self.pending.as_ref().is_some_and(|p|p.1=="devices"){self.devices_refresh_failed=true;}self.pending=None;self.state="network_error".into();self.message=if v["timeout"].as_bool()==Some(true){"请求超时（不表示二维码或凭据失效）"}else{"网络请求失败，请手动重试"}.into();self.reply(None)},
   "cancel"=>{self.interrupt_device_removal();self.pending=None;self.clear_qr();self.state=if self.logged(){"signed_in"}else{"cancelled"}.into();self.message="已取消请求，网络资源已释放".into();self.reply(None)},
   "logout"=>{self.pending=None;self.manual_name_pending=None;self.manual_name_status.clear();self.id.pending_alias_restore.clear();self.id.pending_alias_owner.clear();self.clear_qr();self.account=Account::default();self.account_label.zeroize();self.clear_device_list();self.state="signed_out".into();self.message="已退出本应用，凭据已从安全存储删除".into();self.reply(None)},
   _=>self.reply(None)
  }
 }
 fn response(&mut self,v:Value)->Value{
  if self.suspended || self.expire_qr_at(auth_resume::now_ms()){return self.reply(None);}
  let Some((rid,kind))=self.pending.take() else{return self.reply(None)};
  if Some(rid)!=v["id"].as_u64(){self.pending=Some((rid,kind));return self.reply(None)}
  if kind=="devices"{self.devices_refresh_failed=true;}
  let status=v["httpStatus"].as_i64().unwrap_or(0);self.last_http=status;
  let Some(raw)=v["body"].as_str().filter(|s|s.len()<=1024*1024)else{if kind=="unbind_device"{return self.read_back_device_removal();}self.interrupt_device_removal();if kind=="init_migrate"{self.migration_diagnostic="invalid_response_size".into();self.migration_http=status;self.migration_api=-1;self.migration_status="failed".into();return self.request("devices","/api/v1/device/list",None)}if self.manual_name_pending.is_some(){self.manual_name_pending=None;self.manual_name_status="unconfirmed".into();}return self.error("invalid_response_size")};
  let Ok(body)=serde_json::from_str::<Value>(raw)else{if kind=="unbind_device"{return self.read_back_device_removal();}self.interrupt_device_removal();if kind=="init_migrate"{self.migration_diagnostic="invalid_json".into();self.migration_http=status;self.migration_api=-1;self.migration_status="failed".into();return self.request("devices","/api/v1/device/list",None)}if self.manual_name_pending.is_some(){self.manual_name_pending=None;self.manual_name_status="unconfirmed".into();}return self.error("invalid_json_response")};let code=body["code"].as_i64().unwrap_or(-1);self.last_code=code;
  if kind=="init_migrate"{self.migration_validation=if status==422{migration_diagnostic::validation_metadata(&body)}else{String::new()};self.migration_http=status;self.migration_api=code;self.migration_diagnostic=if status!=200{"http_error"}else if code!=0{"api_error"}else if !body["data"]["device_id"].as_str().is_some_and(|s|!s.is_empty()){ "missing_device_id" }else{"accepted"}.into();}
  if code==1120 || status==401 {self.manual_name_pending=None;self.manual_name_status="unconfirmed".into();let after_migration=matches!(kind.as_str(),"devices"|"restore_migration_alias")&&matches!(self.migration_status.as_str(),"readback_pending"|"alias_restore_failed");self.account=Account::default();self.account_label.zeroize();self.clear_device_list();self.clear_qr();self.state="expired".into();if after_migration{self.migration_status="needs_relogin".into();self.message="设备类型更新请求已接受，但账号登录已失效，请重新扫码登录后确认设备类型".into();}else{self.message="登录无效或已过期，请重新扫码登录".into();}return self.reply(None)}
  if kind=="unbind_device" {
   if status>=500 || (status==200 && matches!(code,0|-1)) {return self.read_back_device_removal();}
   self.finish_device_removal("rejected");return self.reply(None);
  }
  if kind=="unbind_preflight" {
   if status==200 && code==0 {return self.verify_device_removal_target(&body["data"]);}
   self.finish_device_removal("unavailable");return self.reply(None);
  }
  if code==1190 {self.clear_qr();self.state="qr_expired".into();self.message="二维码已失效，请点击登录刷新".into();return self.reply(None)}
  if kind=="restore_migration_alias" {self.migration_status=if status==200&&code==0{self.id.pending_alias_restore.clear();self.id.pending_alias_owner.clear();"readback_pending"}else{"alias_restore_failed"}.into();self.migration_alias=None;return self.request("devices","/api/v1/device/list",None);}
  if kind=="init_migrate"&&(status!=200||code!=0){self.migration_status="failed".into();self.migration_alias=None;return self.request("devices","/api/v1/device/list",None);}
  if kind=="rename_manual" {if status!=200||code!=0{self.manual_name_pending=None;self.manual_name_status="failed".into();return self.reply(None);}let valid=self.manual_name_pending.as_ref().is_some_and(|(id,owner,_)|id==&self.id.device_id&&!owner.is_empty()&&owner==&self.account.user_id);if !valid{self.manual_name_pending=None;self.manual_name_status="unconfirmed".into();return self.reply(None);}self.manual_name_status="checking".into();return self.request("devices","/api/v1/device/list",None);}
  if kind=="rename_self" {self.name_sync_status=if status==200&&code==0{"accepted"}else{"failed"}.into();if let Some((id,owner,name))=self.name_sync_pending.take(){if status==200&&code==0&&self.id.device_id==id&&!owner.is_empty()&&self.account.user_id==owner{self.id.reported_name=name;self.id.reported_name_owner=owner;self.id.name_migration_version=27;}}return self.request("devices","/api/v1/device/list",None);}
  if status!=200 || code!=0 {self.interrupt_device_removal();if self.manual_name_pending.is_some(){self.manual_name_pending=None;self.manual_name_status="unconfirmed".into();}return self.error(&format!("api_error http={status} code={code}"))}
  let d=&body["data"];
  match kind.as_str(){
   "clear_control"=>{self.state="signed_in".into();self.message="已提交断开请求，正在重新读取状态".into();self.devices_refresh_failed=true;self.reply(None)},
   "init"=>{let Some(id)=d["device_id"].as_str().filter(|s|!s.is_empty())else{return self.error("missing_device_id")};self.id.device_id=id.into();self.id.registered_kind=self.local_kind().unwrap_or("").into();self.id.reported_name=self.device_profile["name"].as_str().unwrap_or("").into();self.id.reported_name_owner.clear();self.generate()},
   "init_migrate"=>{let Some(id)=d["device_id"].as_str().filter(|s|!s.is_empty())else{self.migration_status="failed".into();self.migration_alias=None;return self.request("devices","/api/v1/device/list",None)};self.migration_status="readback_pending".into();let changed=id!=self.id.device_id;if changed{self.id.previous_mobile_device_id=self.id.device_id.clone();}self.id.device_id=id.into();self.id.registered_kind=self.local_kind().unwrap_or("").into();if changed&&!self.account.user_id.is_empty()&&self.migration_alias_owner==self.account.user_id{if let Some(alias)=self.migration_alias.take(){self.id.pending_alias_owner=self.account.user_id.clone();self.id.pending_alias_restore=alias.clone();self.alias_restore_attempts+=1;let escaped=id.bytes().map(|b|if b.is_ascii_alphanumeric()||b"-._~".contains(&b){(b as char).to_string()}else{format!("%{b:02X}")}).collect::<String>();return self.request("restore_migration_alias",&format!("/api/v1/device/{escaped}"),Some(json!({"alias":alias})));}}self.migration_alias=None;self.request("devices","/api/v1/device/list",None)},
   "generate"=>{let Some(url)=d["qrcode_jump_url"].as_str().filter(|s|!s.is_empty()&&s.len()<4096&&!s.contains('\0'))else{return self.error("missing_qr_url")};let Some(t)=d.get("status_query_ticket").or_else(||d.get("token")).and_then(Value::as_str).filter(|s|!s.is_empty()&&s.len()<=8192&&!s.contains('\0'))else{return self.error("missing_status_ticket")};self.accept_qr(url,t);self.state="waiting_scan".into();self.message="请用官方 UU 远程手机应用扫码并确认".into();self.reply(None)},
   "poll"=>{match d["status"].as_i64(){Some(1)|Some(2)=>{self.last=d["status"].as_i64().unwrap();self.state=if self.last==2{"scanned"}else{"waiting_scan"}.into();self.message=if self.last==2{"已扫码，请在官方手机应用确认登录"}else{"等待官方手机应用扫码"}.into();self.reply(None)},Some(0)|Some(3)=>{self.clear_qr();self.state="qr_expired".into();self.message="二维码已失效，请手动刷新二维码后重新扫码".into();self.reply(None)},Some(4)=>{self.last=4;self.state="exchanging".into();self.message="用户已确认，正在完成登录".into();self.request("exchange","/api/v1/login/by_qrcode",Some(json!({"token":self.ticket,"qrcode_jump_url":self.qr})))},_=>self.error("unexpected_qr_status")}},
   "exchange"=>{let Some(token)=d["token"].as_str().filter(|s|!s.is_empty())else{return self.error("missing_access_token")};let Some(user)=d["user_id"].as_str().filter(|s|!s.is_empty())else{return self.error("missing_user_id")};let csrf=token.split('.').nth(1).and_then(|p|base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(p.trim_end_matches('=')).ok()).and_then(|b|serde_json::from_slice::<Value>(&b).ok()).and_then(|v|v["csrf"].as_str().map(str::to_owned));let Some(csrf)=csrf.filter(|s|!s.is_empty())else{return self.error("missing_csrf_claim")};self.account=Account{user_id:user.into(),token:token.into(),csrf};self.account_label=d["nickname"].as_str().filter(|s|!s.trim().is_empty()&&s.len()<=96&&!s.chars().any(char::is_control)).unwrap_or("").into();self.clear_qr();self.state="signed_in".into();self.message="登录成功，凭据由系统安全存储保护".into();self.reply(None)},
   "devices"=>{self.validate_pending_alias_owner();let Some(list)=d["my_binded_devices"].as_array()else{self.interrupt_device_removal();return self.error("missing_own_device_list")};if list.len()>512{self.interrupt_device_removal();return self.error("too_many_devices")};let current=d.get("current_device");let current_match=!self.id.device_id.is_empty()&&current.and_then(|v|v["device_id"].as_str())==Some(self.id.device_id.as_str());let list_own_count=list.iter().filter(|v|v["device_id"].as_str()==Some(self.id.device_id.as_str())&&!self.id.device_id.is_empty()).count();let conflict=current_match&&list.iter().any(|v|v["device_id"].as_str()==Some(self.id.device_id.as_str())&&v["platform"]!=current.unwrap()["platform"]);let mut merged=list.clone();if current_match&&(list_own_count==0||conflict){merged.push(current.unwrap().clone());}let devices=&merged;let sources=device_wallpaper::collect(self,devices);let (rows,incomplete)=devices::project(self,devices);if self.local_kind()==Some("mobile")&&self.id.registered_kind=="mobile"{let own=devices.iter().filter(|v|v["device_id"].as_str()==Some(self.id.device_id.as_str())).collect::<Vec<_>>();self.migration_readback=if own.len()==1{own[0]["platform"].as_i64().unwrap_or(-1)}else{-1};if self.migration_readback==2{if self.id.pending_alias_restore.is_empty(){self.migration_status="success".into();}}else{self.migration_status="readback_unconfirmed".into();}}self.wallpapers=sources;self.devices=rows;self.devices_incomplete=incomplete;self.observe_device_removal_list();self.devices_updated_ms=auth_resume::now_ms();self.devices_clock=Some(std::time::Instant::now());self.devices_refresh_failed=false;self.refreshes+=1;self.state="signed_in".into();self.message=format!("已从云端获取 {} 台自有设备（不加载他人共享设备）",self.devices.len());let alias_conflict=current_match&&list.iter().any(|v|v["device_id"].as_str()==Some(self.id.device_id.as_str())&&(v["alias"]!=current.unwrap()["alias"]||((v["alias"].is_null()||v["alias"]=="")&&(v["name"]!=current.unwrap()["name"]||v["device_name"]!=current.unwrap()["device_name"]))));if self.manual_name_pending.is_some(){if alias_conflict{self.manual_name_pending=None;self.manual_name_status="unconfirmed".into();}else{self.manual_name_readback(devices);}}if !alias_conflict{if let Some(request)=self.maybe_sync_device_name(devices){return request;}}else{self.name_sync_status="cloud_row_conflict".into();}if self.local_kind()==Some("mobile")&&!self.id.pending_alias_restore.is_empty()&&self.alias_restore_attempts<2 {if let Some(row)=devices.iter().find(|v|v["device_id"].as_str()==Some(self.id.device_id.as_str())){let current=row["alias"].as_str().unwrap_or("");if current==self.id.pending_alias_restore{self.id.pending_alias_restore.clear();self.id.pending_alias_owner.clear();self.migration_status=if self.migration_readback==2{"success"}else{"readback_unconfirmed"}.into();}else if current.is_empty(){self.alias_restore_attempts+=1;let alias=self.id.pending_alias_restore.clone();let id=self.id.device_id.bytes().map(|b|if b.is_ascii_alphanumeric()||b"-._~".contains(&b){(b as char).to_string()}else{format!("%{b:02X}")}).collect::<String>();return self.request("restore_migration_alias",&format!("/api/v1/device/{id}"),Some(json!({"alias":alias})));}else{self.id.pending_alias_restore.clear();self.id.pending_alias_owner.clear();self.migration_status="alias_changed".into();}}} if self.legacy_mobile_registration_needs_change(devices)&&!self.migration_attempted{self.migration_attempted=true;self.migration_status="pending".into();self.migration_diagnostic="pending".into();self.migration_validation.clear();self.migration_http=0;self.migration_api=-1;self.migration_alias_owner=self.account.user_id.clone();self.migration_alias=if self.account.user_id.is_empty(){None}else{devices.iter().find(|v|v["device_id"].as_str()==Some(self.id.device_id.as_str())).and_then(|v|v["alias"].as_str()).filter(|s|!s.trim().is_empty()&&s.len()<=256&&!s.chars().any(char::is_control)).map(str::to_owned)};let alias=self.migration_alias.clone();return self.request("init_migrate","/api/v1/device/android/init",Some(self.registration_body(alias.as_deref())));}self.reply(None)},
   _=>self.error("unexpected_request_kind")
  }
 }
}
fn sign(method:&str,path:&str,headers:&BTreeMap<String,String>,body:&str)->String{let filtered:BTreeMap<String,String>=headers.iter().filter_map(|(k,v)|{let k=k.to_lowercase();(k.starts_with("x-param-")&&k!="x-param-sign").then(||(k,v.clone()))}).collect();let params=filtered.iter().map(|(k,v)|format!("{k}={v}")).collect::<Vec<_>>().join("&");let mut mac=Hmac::<Sha256>::new_from_slice(SIGN_KEY.as_bytes()).unwrap();mac.update(format!("{}{path}{params}{body}",method.to_uppercase()).as_bytes());hex::encode(mac.finalize().into_bytes())}
static CORE:OnceLock<Mutex<Core>>=OnceLock::new();
fn core()->&'static Mutex<Core>{CORE.get_or_init(||Mutex::new(Core::default()))}
fn cstring(s:String)->*mut c_char{CString::new(s).unwrap().into_raw()}
#[no_mangle] pub unsafe extern "C" fn s3a_call(input:*const c_char)->*mut c_char{if input.is_null(){return cstring("{}".into())}let s=CStr::from_ptr(input).to_bytes();let v=serde_json::from_slice(s).unwrap_or(Value::Null);cstring(session::dispatch(&mut core().lock().unwrap(),v).to_string())}
#[no_mangle] pub extern "C" fn s3a_validate_restore(expected:bool)->bool{core().lock().unwrap().valid_restored_identity(expected)}
#[no_mangle] pub extern "C" fn s3a_export(slot:u32)->*mut c_char{let mut c=core().lock().unwrap();c.expire_qr_at(auth_resume::now_ms());cstring(match slot{0 if c.id.has_local_ids()=>serde_json::to_string(&c.id).unwrap(),1 if c.logged()=>serde_json::to_string(&c.account).unwrap(),2=>c.pending_qr_export(),_=>String::new()})}
#[no_mangle] pub unsafe extern "C" fn s3a_import(slot:u32,input:*const c_char)->i32{if input.is_null(){return 1;}let s=CStr::from_ptr(input).to_bytes();let mut c=core().lock().unwrap();match slot{0=>match serde_json::from_slice::<Identity>(s){Ok(v)=>{c.id=v;0},_=>1},1=>match serde_json::from_slice::<Account>(s){Ok(v) if !v.user_id.is_empty()&&!v.token.is_empty()&&!v.csrf.is_empty()=>{c.account=v;0},_=>1},2=>c.import_pending_qr(s),_=>1}}
#[no_mangle] pub extern "C" fn s3a_clear(){session::cleanup();let mut c=core().lock().unwrap();c.clear_qr();*c=Core::default();}
#[no_mangle] pub unsafe extern "C" fn s3a_free(p:*mut c_char){if !p.is_null(){let mut s=CString::from_raw(p).into_bytes();s.zeroize();}}
#[cfg(test)] mod tests{
 #[test]
 fn existing_session_requires_registered_identity_before_any_request() {
  let mut core = Core::default();
  assert!(core.valid_restored_identity(false));
  assert!(!core.valid_restored_identity(true));
  core.account = Account { user_id: "user".into(), token: "token".into(), csrf: "csrf".into() };
  assert!(!core.valid_restored_identity(false));
  core.id.client_id = "first-client".into();
  core.id.system_id = "first-system".into();
  core.id.machine_guid = "first-installation".into();
  assert!(!core.valid_restored_identity(false));
  core.id.device_id = "first-device".into();
  assert!(core.valid_restored_identity(true));
  let boot = core.call(json!({"op":"boot","deviceProfile":{"name":"Test PC","deviceType":"2in1"}}));
  assert_eq!(boot["view"]["state"], "restored");
  assert!(boot["request"].is_null());
  let request = core.call(json!({"op":"refresh"}));
  assert_eq!(request["request"]["kind"], "devices");
  assert_eq!(request["request"]["headers"]["x-param-client-id"], "first-client");
  assert_eq!(request["request"]["headers"]["x-param-device-id"], "first-device");
 }
 use super::*;
 #[test] fn sign_is_upstream_order_and_exact_empty_body(){let h=BTreeMap::from([("X-PARAM-Z".into(),"z".into()),("x-param-a".into(),"a".into()),("Authorization".into(),"ignored".into())]);let mut m=Hmac::<Sha256>::new_from_slice(SIGN_KEY.as_bytes()).unwrap();m.update(b"POST/api/v1/qrcode/gen/loginx-param-a=a&x-param-z=z");assert_eq!(sign("post","/api/v1/qrcode/gen/login",&h,""),hex::encode(m.finalize().into_bytes()));assert_ne!(sign("post","/api/v1/qrcode/gen/login",&h,""),sign("post","/api/v1/qrcode/gen/login",&h,"{}"));}
 #[test] fn qr_uses_current_ticket_and_cancel_rejects_stale_response(){let mut c=Core::default();c.pending=Some((1,"generate".into()));let r=c.response(json!({"id":1,"httpStatus":200,"body":json!({"code":0,"data":{"qrcode_jump_url":"synthetic-qr","status_query_ticket":"new-ticket","token":"old-ticket"}}).to_string()}));assert_eq!(r["view"]["state"],"waiting_scan");let req=c.poll();assert!(req["request"]["body"].as_str().unwrap().contains("new-ticket"));assert!(!req["request"]["body"].as_str().unwrap().contains("old-ticket"));c.call(json!({"op":"cancel"}));c.response(json!({"id":2,"httpStatus":200,"body":"{\"code\":0,\"data\":{\"status\":4}}"}));assert!(!c.logged());assert!(c.qr.is_empty());assert!(c.pending.is_none());}
 #[test] fn expiration_clears_credentials_and_network_error_preserves_them(){let mut c=Core::default();c.account=Account{token:"synthetic-token".into(),csrf:"synthetic-csrf".into(),user_id:"synthetic-user".into()};c.pending=Some((1,"devices".into()));c.call(json!({"op":"network_error","id":1,"timeout":true}));assert!(c.logged());c.pending=Some((2,"devices".into()));c.response(json!({"id":2,"httpStatus":422,"body":"{\"code\":1120}"}));assert!(!c.logged());assert_eq!(c.state,"expired");}
 #[test] fn device_projection_never_exposes_ids_tokens_or_shared_devices(){let mut c=Core::default();c.pending=Some((7,"devices".into()));let r=c.response(json!({"id":7,"httpStatus":200,"body":json!({"code":0,"data":{"my_binded_devices":[{"device_id":"synthetic-secret-id","name":"test computer","platform":1,"online":true,"token":"not-for-ui"}],"others_shared_devices":[{"name":"other"}]}}).to_string()}));let s=r.to_string();assert!(!s.contains("synthetic-secret-id"));assert!(!s.contains("not-for-ui"));assert!(!s.contains("other"));assert_eq!(c.devices.len(),1);assert_eq!(c.refreshes,1);}
}
