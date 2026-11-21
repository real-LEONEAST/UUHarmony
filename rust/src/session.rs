// SPDX-License-Identifier: GPL-3.0-only
use super::*;
use crate::signal::SignalCore;
#[derive(Default)]
struct Lab { client_type:Option<u32>,multi_video:bool,decoder_envelope:Option<(u32,u32,u32,u32,u32)>,capture_type:u32, signal:SignalCore, desktop:crate::unlock_binding::BoundDesktop, targets:Vec<Value>, selected:Option<String>, offline:bool, offer_delay:u64, assist_fallback:bool, assist_v2:bool, leave:Option<RoomLeave> }
fn session_client_type(c:&Core)->Result<u32,&'static str>{match c.local_kind(){Some("mobile")=>Ok(2),Some("pc")=>Ok(3),_=>Err("local_device_type_unknown")}}
fn decoder_envelope(v:&Value,multi:bool)->Result<(u32,u32,u32,u32,u32),&'static str>{
 #[cfg(target_env="ohos")] {
  extern "C"{fn s5_video_slot_ready_details(slot:u32,generation:u32,w:*mut u32,h:*mut u32,codec:*mut u32,level:*mut u32,fps:*mut u32)->bool;fn s5_video_ready_details(w:*mut u32,h:*mut u32,codec:*mut u32,level:*mut u32,fps:*mut u32)->bool;}
  let(mut w,mut h,mut codec,mut level,mut fps)=(0,0,0,0,0);
  let ok=if multi{let slot=v["renderSlot"].as_u64().filter(|n|*n==0).ok_or("primary_renderer_required")? as u32;let generation=v["videoGeneration"].as_u64().and_then(|n|u32::try_from(n).ok()).filter(|n|*n>0).ok_or("primary_renderer_required")?;unsafe{s5_video_slot_ready_details(slot,generation,&mut w,&mut h,&mut codec,&mut level,&mut fps)}}else{unsafe{s5_video_ready_details(&mut w,&mut h,&mut codec,&mut level,&mut fps)}};
  if ok&&(2..=8192).contains(&w)&&(2..=8192).contains(&h)&&[1,2].contains(&codec)&&level>0&&level<=255&&(1..=60).contains(&fps){return Ok((w,h,codec,level,fps))}Err("primary_decoder_not_ready")
 }
 #[cfg(not(target_env="ohos"))] {if multi{let _slot=v["renderSlot"].as_u64().filter(|n|*n==0).ok_or("primary_renderer_required")?;let _generation=v["videoGeneration"].as_u64().and_then(|n|u32::try_from(n).ok()).filter(|n|*n>0).ok_or("primary_renderer_required")?;Err("primary_decoder_not_ready")}else{Ok((1280,720,1,31,30))}}
}
// Keep the accepted room's own controller identity independent of device refresh/selection.
// The by-device clear API is deliberately reserved for the explicit disconnect-all action.
struct RoomLeave { device:String, client:String, owner:String, accepted:bool, participant:Option<String> }
impl Drop for RoomLeave { fn drop(&mut self){self.device.zeroize();self.client.zeroize();self.owner.zeroize();if let Some(p)=self.participant.as_mut(){p.zeroize();}} }
impl RoomLeave {
 fn observe_participant(&mut self,c:&Core,devices:&[Value]){
  if !self.accepted||self.client!=c.id.client_id||self.owner!=c.account.user_id{return}
  let mut rows=devices.iter().filter(|d|d["device_id"].as_str()==Some(&self.device));
  let Some(row)=rows.next().filter(|_|rows.next().is_none())else{return};
  if let Some(prior)=self.participant.as_mut(){prior.zeroize();}
  self.participant=crate::devices::unique_local_participant(c,row).map(str::to_owned);
 }
 fn request(&self,c:&Core)->Option<Value>{
  if !self.accepted||!c.logged()||self.owner!=c.account.user_id||self.client!=c.id.client_id||self.device.is_empty()||self.client.is_empty(){return None}
  // Official Android 4.45.0 Le9/C2.invokeSuspend: POST clear/{deviceId}/{clientId}.
  let participant=self.participant.as_deref().unwrap_or(&self.client);
  let path=format!("/api/v1/room/clear/{}/{}",segment(&self.device),segment(participant));
  // This request must not replace Core.pending: account refresh and teardown have independent lifetimes.
  let binding=if self.participant.is_none(){"unobserved"}else if participant==self.client{"confirmed"}else{"registered_device"};
  Some(json!({"id":0,"url":format!("{BASE}{path}"),"headers":c.headers("POST",&path,""),"body":"","timeoutMs":2200,"participantBinding":binding}))
 }
}
static LAB:OnceLock<Mutex<Lab>>=OnceLock::new();
fn lab()->&'static Mutex<Lab>{LAB.get_or_init(||Mutex::new(Lab::default()))}
pub(super) fn unlock_context(c:&Core)->Option<(String,u64)>{
    let l=lab().lock().unwrap();
    if !l.signal.active(){return None}
    l.desktop.current(c).map(|(scope,epoch)|(scope.to_owned(),epoch))
}
fn now(v:&Value)->u64{v["nowMs"].as_u64().unwrap_or(0)}
fn err(s:&str)->Value{json!({"error":s,"actions":[],"signal":{"state":"error","message":s}})}
fn allowed(dev:&Value,own:&str,previous_mobile:&str)->bool{dev["platform"]==1 && dev["status"]=="CONNECTED" && dev["device_id"].as_str().is_some_and(|s|!s.is_empty()&&s!=own&&s!=previous_mobile)}
fn harmony_host(dev:&Value)->bool {
    dev["platform"] == 1 && dev["os"].as_str().is_some_and(|os| {
        let os = os.trim();
        os.eq_ignore_ascii_case("HarmonyOS") || os.to_ascii_lowercase().starts_with("harmonyos ")
    })
}
fn segment(s:&str)->String{s.bytes().map(|b|if b.is_ascii_alphanumeric()||b"-._~".contains(&b){(b as char).to_string()}else{format!("%{b:02X}")}).collect()}
fn join_data(status:u64,b:&Value)->Result<Value,&'static str>{
 if b["code"]==2002{return Err("remote_session_busy")}
 if status==429{return Err("join_rate_limited")}
 if status>=500{return Err("join_service_unavailable")}
 if status!=200{return Err("join_http_rejected")}
 if b["code"]!=0{return Err("join_service_rejected")}
 let d=&b["data"];
 if d["token"].as_str().is_none_or(|s|s.is_empty()||s.len()>8192) || d["signaling_list"].as_array().is_none_or(|a|a.is_empty()||a.len()>8||a.iter().any(|v|v.as_str().is_none_or(|s|!s.starts_with("wss://")||s.len()>4096))) || !d["report_token"].is_string() || !d["report_url"].is_string(){return Err("invalid_join_response")}
 Ok(d.clone())
}
pub fn dispatch(c:&mut Core,v:Value)->Value{
 let op=v["op"].as_str().unwrap_or("");
 if op.starts_with("peer_"){
    match op {
      "peer_start" => {
        let mut l=lab().lock().unwrap();
        if v["filesOnly"]!=true&&v["catalogOnly"]!=true&&v["lockOnly"]!=true&&v["terminalOnly"]!=true&&l.decoder_envelope.is_none(){return err("primary_decoder_not_ready")}
        l.desktop.peer_start(&v["config"]);
        let mut request=v;
        request["decoderCodec"]=json!(l.decoder_envelope.map(|d|d.2).unwrap_or(1));
        request["decoderLevel"]=json!(l.decoder_envelope.map(|d|d.3).unwrap_or(31));
        request["decoderWidth"]=json!(l.decoder_envelope.map(|d|d.0).unwrap_or(1280));
        request["decoderHeight"]=json!(l.decoder_envelope.map(|d|d.1).unwrap_or(720));
        request["decoderFps"]=json!(l.decoder_envelope.map(|d|d.4).unwrap_or(30));
        let result=crate::peer::call(request);
        if !result["offer"].is_string(){l.desktop=Default::default()}
        return result;
      }
      "peer_receive" if v["event"]["type"]=="answer" => {
        let result=crate::peer::call(v.clone());
        let mut l=lab().lock().unwrap();
        if result["answered"]==true && result.get("error").is_none() {
          l.desktop.peer_answer(v["event"]["sdp"].as_str().unwrap_or(""));
        } else {l.desktop=Default::default()}
        return result;
      }
      "peer_close"|"peer_end_media" => lab().lock().unwrap().desktop=Default::default(),
      _=>()
    }
    return crate::peer::call(v)
 }
 let mut l=lab().lock().unwrap();
 if op.starts_with("signal_"){
    let result=l.signal.call(v);
    if l.signal.active(){l.desktop.observe_signal(&result)}else{l.desktop=Default::default()}
    return result
 }
 match op {
  "privacy_wallpaper_request"=>{
   // The one-use selection is consumed by join; use the authenticated active
   // desktop binding for settings made after the connection has been opened.
   if !c.logged()||c.suspended||!l.signal.active()||l.capture_type!=1||!v["deviceKey"].as_str().is_some_and(|key|l.desktop.owns_current(c,key)){return err("owned_desktop_required")}
   let Some(target)=l.targets.iter().find(|d|d["key"]==v["deviceKey"]&&allowed(d,&c.id.device_id,&c.id.previous_mobile_device_id))else{return err("owned_desktop_required")};
   return crate::privacy_wallpaper::request(c,target,&v);
  },
  // Foreground account/list refresh must not steal the request id of an in-flight room join.
  "refresh"|"resume" if c.pending.as_ref().is_some_and(|(_,kind)|kind=="join"||kind=="assist_join")=>c.reply(None),
  "offline_start"=>{l.desktop=Default::default();l.offline=false;l.signal.start(json!({"client_type":3,"token":"synthetic-room","signaling_list":["ws://127.0.0.1:18763"],"ws_connect_timeout_ms":12000}),"synthetic-client","synthetic-viewer-device",now(&v))},
  "offline_pass"=>{l.offline=true;json!({"offlinePassed":true})},
  "clear_device_control"=>{
   if v["confirmed"]!=true||!c.logged()||c.suspended||c.pending.is_some()||!c.devices_fresh()||l.signal.active(){return err("clear_control_unavailable")}
   let Some(key)=v["deviceKey"].as_str() else{return err("invalid_device_identity")};
   let Some(row)=c.devices.iter().find(|d|d["key"]==key&&d["current"]==false) else{return err("device_changed")};
   if row["participantToken"].as_str().is_none_or(|t|t.is_empty()||Some(t)!=v["participantToken"].as_str()){return err("control_session_changed")}
   let Some(dev)=l.targets.iter().find(|d|d["key"]==key&&allowed(d,&c.id.device_id,&c.id.previous_mobile_device_id)) else{return err("device_changed")};
   let path=format!("/api/v1/room/clear/by_device/{}",segment(dev["device_id"].as_str().unwrap()));
   c.devices_refresh_failed=true;let mut result=c.request("clear_control",&path,None);result["request"]["timeoutMs"]=json!(12000);return result;
  },
  "select_device"=>{
   if !c.logged(){return err("authentication_required")}
   if c.pending.is_some(){return err("auth_busy")}
   if !c.has_device_snapshot(){return err("device_list_unavailable")}
   let Some(key)=v["deviceKey"].as_str().filter(|s|s.len()==64&&s.bytes().all(|b|b.is_ascii_hexdigit()))else{return err("invalid_device_identity")};
   let Some(device)=l.targets.iter().find(|d|d["key"]==key&&allowed(d,&c.id.device_id,&c.id.previous_mobile_device_id))else{return err("select_own_online_windows_required")};
   let harmony=harmony_host(device);
   l.selected=Some(key.into());json!({"selectedKey":key,"selectionValid":true,"harmonyHost":harmony})
  },
  "assist_join"=>{
   if v["confirmed"]!=true || !c.logged() || c.pending.is_some(){return err("explicit_assistance_confirmation_required")}
   if let Err(e)=crate::wire::local_display(v["viewerWidth"].as_u64().unwrap_or(0),v["viewerHeight"].as_u64().unwrap_or(0),v["viewerRefresh"].as_u64().unwrap_or(0)){return err(e)}
   let Some(id)=v["connectId"].as_str().filter(|s|!s.trim().is_empty()&&s.len()<=256&&!s.chars().any(char::is_control))else{return err("invalid_assistance_id")};
   let Some(code)=v["connectCode"].as_str().filter(|s|!s.trim().is_empty()&&s.len()<=1024&&!s.chars().any(char::is_control))else{return err("invalid_assistance_code")};
   let legacy=v["legacy"]==true;
   if legacy&&!l.assist_fallback{return err("assistance_fallback_not_authorized")}
   let client_type=match session_client_type(c){Ok(t)=>t,Err(e)=>return err(e)};
   let decoder=match decoder_envelope(&v,v["multiVideo"]==true){Ok(d)=>Some(d),Err(e)=>return err(e)};
   l.client_type=Some(client_type);l.leave=None;l.desktop=Default::default();l.multi_video=v["multiVideo"]==true;l.decoder_envelope=decoder;l.capture_type=1;l.assist_fallback=false;l.assist_v2=!legacy;l.selected=None;l.offer_delay=v["offerDelayMs"].as_u64().unwrap_or(0).min(3000);
   let path=if legacy{"/api/v1/room/join/share/by_code"}else{"/api/v2/room/join/share/by_code"};
   let mut r=c.request("assist_join",path,Some(json!({"connect_id":id,"connect_code":code})));r["request"]["timeoutMs"]=json!(12000);r
  },
  "join"=>{
   // Data-only entry points have no desktop Surface or viewer display yet.
   if v["filesOnly"]!=true&&v["catalogOnly"]!=true&&v["lockOnly"]!=true&&v["terminalOnly"]!=true&&v.get("viewerWidth").is_some(){if let Err(e)=crate::wire::local_display(v["viewerWidth"].as_u64().unwrap_or(0),v["viewerHeight"].as_u64().unwrap_or(0),v["viewerRefresh"].as_u64().unwrap_or(0)){return err(e)}}
   if v["confirmed"]!=true{return err("explicit_device_confirmation_required")}
   if ["filesOnly","catalogOnly","lockOnly","terminalOnly"].iter().filter(|k|v[**k]==true).count()>1{return err("conflicting_session_roles")}
   if !c.logged(){return err("authentication_required")}
   if let Some((_,kind))=&c.pending{return err(if kind=="join"||kind=="assist_join"{"join_request_pending"}else{"auth_busy"})}
   if l.signal.active(){return err("session_already_active")}
   if !c.has_device_snapshot(){return err("device_list_unavailable")}
   let Some(key)=l.selected.as_deref() else{return err("device_selection_required")};
   if v["deviceKey"].as_str()!=Some(key){return err("selection_confirmation_mismatch")}
   let Some(dev)=l.targets.iter().find(|d|d["key"]==key&&allowed(d,&c.id.device_id,&c.id.previous_mobile_device_id))else{return err("device_no_longer_online")};
   let client_type=match session_client_type(c){Ok(t)=>t,Err(e)=>return err(e)};
   let multi=v["multiVideo"]==true&&v["filesOnly"]!=true&&v["lockOnly"]!=true&&v["terminalOnly"]!=true&&v["catalogOnly"]!=true;
   let decoder=if v["filesOnly"]!=true&&v["lockOnly"]!=true&&v["terminalOnly"]!=true&&v["catalogOnly"]!=true{match decoder_envelope(&v,multi){Ok(d)=>Some(d),Err(e)=>return err(e)}}else{None};
   let path=format!("/api/v1/room/join/by_device/{}",segment(dev["device_id"].as_str().unwrap()));
   let leave=RoomLeave{device:dev["device_id"].as_str().unwrap().into(),client:c.id.client_id.clone(),owner:c.account.user_id.clone(),accepted:false,participant:None};
   l.desktop=if v["watch"]==false && v["filesOnly"]!=true && v["catalogOnly"]!=true && v["lockOnly"]!=true&&v["terminalOnly"]!=true {
     crate::unlock_binding::BoundDesktop::for_device(c,key)
   }else{Default::default()};
   l.leave=Some(leave);
   l.client_type=Some(client_type);l.multi_video=multi;l.decoder_envelope=decoder;l.capture_type=if v["filesOnly"]==true||v["lockOnly"]==true{5}else if v["catalogOnly"]==true{7}else if v["terminalOnly"]==true{8}else{1};
   l.offer_delay=v["offerDelayMs"].as_u64().unwrap_or(0).min(3000);
   l.selected=None;let mut r=c.request("join",&path,Some(json!({"force_join":false})));r["request"]["timeoutMs"]=json!(12000);r
  },
  "join_response"=>{
   let kind=c.pending.as_ref().filter(|(id,k)|Some(*id)==v["id"].as_u64()&&["join","assist_join"].contains(&k.as_str())).map(|(_,k)|k.clone());
   let Some(kind)=kind else{return err("stale_join_response")};
   if kind=="assist_join"&&l.assist_v2&&matches!(v["httpStatus"].as_u64(),Some(404|405)){c.pending=None;l.client_type=None;l.assist_fallback=true;return json!({"assistFallback":true})}
   c.pending=None;c.last_http=v["httpStatus"].as_i64().unwrap_or(0);
   let b=serde_json::from_str::<Value>(v["body"].as_str().filter(|s|s.len()<=1048576).unwrap_or("")).unwrap_or(Value::Null);c.last_code=b["code"].as_i64().unwrap_or(-1);
   if c.last_code==1120||c.last_http==401{l.client_type=None;l.leave=None;c.account=Account::default();l.targets.clear();return err("authentication_expired")}
   match join_data(c.last_http as u64,&b){Ok(mut room)=>{if let Some(leave)=l.leave.as_mut(){leave.accepted=true;}room["client_type"]=json!(l.client_type.take());room["multi_video"]=json!(l.multi_video);room["decoder_envelope"]=json!(l.decoder_envelope);room["offer_delay_ms"]=json!(l.offer_delay);room["capture_type"]=json!(if l.capture_type==0{1}else{l.capture_type});let mut out=l.signal.start(room,&c.id.client_id,&c.id.device_id,now(&v));out["joinHttp"]=json!(c.last_http);out["joinCode"]=json!(c.last_code);out["joinPassed"]=json!(true);out},Err(e)=>{l.client_type=None;l.leave=None;l.decoder_envelope=None;let mut out=err(e);out["joinHttp"]=json!(c.last_http);out["joinCode"]=json!(c.last_code);out}}
  },
  "session_cancel"=>{l.client_type=None;l.desktop=Default::default();l.decoder_envelope=None;let leave=l.leave.take().and_then(|room|room.request(c));if c.pending.as_ref().is_some_and(|(_,k)|["join","assist_join"].contains(&k.as_str())){c.pending=None;}l.assist_fallback=false;l.selected=None;let mut result=l.signal.call(json!({"op":"signal_cancel"}));if let Some(request)=leave{result["leaveRequest"]=request;c.devices_refresh_failed=true;}result},
  "response"=>{
   let devices=c.pending.as_ref().is_some_and(|(id,k)|k=="devices"&&Some(*id)==v["id"].as_u64());
   let incoming=if devices{v["body"].as_str().filter(|s|s.len()<=1048576).and_then(|s|serde_json::from_str::<Value>(s).ok()).and_then(|b|b["data"]["my_binded_devices"].as_array().filter(|a|a.len()<=512).cloned()).unwrap_or_default()}else{Vec::new()};
   let revision=c.refreshes;
   let r=c.call(v);
   if devices && c.refreshes>revision {
    if let Some(leave)=l.leave.as_mut(){leave.observe_participant(c,&incoming);}
    l.targets=c.devices.iter().filter_map(|row|{
     let dev=incoming.iter().find(|d|crate::devices::key(c,d).as_deref()==row["key"].as_str())?;
     Some(json!({"key":row["key"],"device_id":dev["device_id"],"platform":row["fields"]["platform"],"status":row["fields"]["status"],"os":row["fields"]["os"]}))
    }).collect();
    if !l.selected.as_ref().is_some_and(|key|l.targets.iter().any(|d|d["key"]==key.as_str()&&allowed(d,&c.id.device_id,&c.id.previous_mobile_device_id))){l.selected=None;}
   } else if devices { l.selected=None; }
   if !c.logged(){l.leave=None;l.desktop=Default::default();l.targets.clear();l.selected=None;}r
  },
  "logout"=>{l.leave=None;l.desktop=Default::default();l.targets.clear();l.selected=None;c.call(v)},
  _=>c.call(v)
 }
}
pub fn cleanup(){let _=crate::peer::call(json!({"op":"peer_close"}));let mut l=lab().lock().unwrap();l.signal.call(json!({"op":"signal_cancel"}));*l=Lab::default();}
// Tests share the production singleton; hold this guard across each complete test scenario.
#[cfg(test)] static TEST_LAB_SCENARIO: Mutex<()> = Mutex::new(());
#[cfg(test)] mod tests {use super::*;
 #[test]fn room_leave_is_own_controller_only_one_use_and_independent_of_auth_pending(){let _scenario=TEST_LAB_SCENARIO.lock().unwrap_or_else(|e|e.into_inner());
  let mut c=Core::default();c.accept_device_profile(&json!({"name":"synthetic","deviceType":"pc"}));c.id.client_id="synthetic/controller".into();c.account.user_id="synthetic-owner".into();c.account.token="synthetic-token".into();
  let mut l=lab().lock().unwrap();*l=Lab::default();
  l.leave=Some(RoomLeave{device:"synthetic/device".into(),client:c.id.client_id.clone(),owner:c.account.user_id.clone(),accepted:true,participant:None});drop(l);
  c.pending=Some((88,"devices".into()));
  let ended=dispatch(&mut c,json!({"op":"session_cancel"}));let req=&ended["leaveRequest"];
  assert_eq!(req["url"],format!("{BASE}/api/v1/room/clear/synthetic%2Fdevice/synthetic%2Fcontroller"));
  assert_eq!(req["timeoutMs"],2200);assert!(req["headers"]["X-Param-SIGN"].is_string());assert!(!req.to_string().contains("clear/by_device"));
  assert_eq!(c.pending,Some((88,"devices".into())));
  assert!(dispatch(&mut c,json!({"op":"session_cancel"}))["leaveRequest"].is_null());
  for (accepted,owner,client) in [(false,"synthetic-owner","synthetic/controller"),(true,"another-account","synthetic/controller"),(true,"synthetic-owner","another-controller")]{
   lab().lock().unwrap().leave=Some(RoomLeave{device:"synthetic-device".into(),client:client.into(),owner:owner.into(),accepted,participant:None});
   assert!(dispatch(&mut c,json!({"op":"session_cancel"}))["leaveRequest"].is_null());
  }
  *lab().lock().unwrap()=Lab::default();
 }
 #[test]
 fn room_leave_resolves_the_cloud_participant_for_only_the_local_registration(){
  let mut c=Core::default();
  c.id.device_id="local-registration".into();
  c.id.client_id="local-installation".into();
  c.account=Account{user_id:"owner".into(),token:"token".into(),csrf:"csrf".into()};
  let mut room=RoomLeave{device:"remote-target".into(),client:c.id.client_id.clone(),owner:c.account.user_id.clone(),accepted:true,participant:None};
  let other=json!({"device_id":"other-registration","client_id":"other-controller"});
  let same=json!({"device_id":"local-registration","client_id":"current-session-route"});
  room.observe_participant(&c,&[json!({"device_id":"remote-target","participants_info":[other.clone(),same.clone()]})]);
  assert_eq!(room.request(&c).unwrap()["url"],format!("{BASE}/api/v1/room/clear/remote-target/current-session-route"));
  room.observe_participant(&c,&[json!({"device_id":"remote-target","participants_info":[other.clone(),same.clone(),same]})]);
  assert_eq!(room.request(&c).unwrap()["url"],format!("{BASE}/api/v1/room/clear/remote-target/local-installation"));
  room.observe_participant(&c,&[json!({"device_id":"remote-target","participants_info":[other]})]);
  assert_eq!(room.request(&c).unwrap()["participantBinding"],"unobserved");
 }
 #[test]fn ui1_selection_tracks_identity_across_refresh_and_rejects_retargeting(){let _scenario=TEST_LAB_SCENARIO.lock().unwrap_or_else(|e|e.into_inner());
  let mut c=Core::default();c.accept_device_profile(&json!({"name":"synthetic","deviceType":"pc"}));c.id.client_id="synthetic-install".into();c.account.token="synthetic-token".into();
  *lab().lock().unwrap()=Lab::default();
  let a=json!({"device_id":"synthetic-a","platform":1,"name":"Same","status":"CONNECTED"});
  let b=json!({"device_id":"synthetic-b","platform":1,"name":"Same","status":"CONNECTED"});
  let load=|c:&mut Core,id:u64,items:Vec<Value>|{c.pending=Some((id,"devices".into()));dispatch(c,json!({"op":"response","id":id,"httpStatus":200,"body":json!({"code":0,"data":{"my_binded_devices":items}}).to_string()}));};
  load(&mut c,1,vec![a.clone(),b.clone()]);let key=crate::devices::key(&c,&a).unwrap();
  assert_eq!(dispatch(&mut c,json!({"op":"select_device","deviceKey":key}))["selectionValid"],true);
  load(&mut c,2,vec![b.clone(),a.clone()]);
  let other=crate::devices::key(&c,&b).unwrap();assert_eq!(dispatch(&mut c,json!({"op":"join","deviceKey":other,"confirmed":true}))["error"],"selection_confirmation_mismatch");
  let join=dispatch(&mut c,json!({"op":"join","deviceKey":key,"confirmed":true}));assert!(join["request"]["url"].as_str().unwrap().ends_with("synthetic-a"));assert_eq!(join["request"]["body"],"{\"force_join\":false}");
  dispatch(&mut c,json!({"op":"session_cancel"}));load(&mut c,3,vec![a.clone(),b.clone()]);dispatch(&mut c,json!({"op":"select_device","deviceKey":key}));load(&mut c,4,vec![b]);
  assert_eq!(dispatch(&mut c,json!({"op":"join","deviceKey":key,"confirmed":true}))["error"],"device_selection_required");
  c.devices_clock=Some(std::time::Instant::now()-crate::devices::FRESH_FOR);assert_eq!(dispatch(&mut c,json!({"op":"select_device","deviceKey":other}))["selectionValid"],true);assert_eq!(dispatch(&mut c,json!({"op":"select_device","deviceKey":key}))["error"],"select_own_online_windows_required");
  assert!(dispatch(&mut c,json!({"op":"select_device","index":1}))["error"].is_string());*lab().lock().unwrap()=Lab::default();
 }
 #[test]fn join_gate_never_forces_and_cancel_rejects_late_room(){let _scenario=TEST_LAB_SCENARIO.lock().unwrap_or_else(|e|e.into_inner());
  let mut c=Core::default();c.accept_device_profile(&json!({"name":"synthetic","deviceType":"pc"}));c.account=Account{token:"synthetic-token".into(),csrf:"synthetic-csrf".into(),user_id:"synthetic-user".into()};c.devices_clock=Some(std::time::Instant::now());
  {let mut l=lab().lock().unwrap();*l=Lab::default();l.targets=vec![json!({"key":"a".repeat(64),"device_id":"synthetic/a","platform":1,"status":"CONNECTED"})];l.selected=Some("a".repeat(64));}
  assert!(dispatch(&mut c,json!({"op":"join","deviceKey":"a".repeat(64),"confirmed":false}))["error"].is_string());
  {lab().lock().unwrap().offline=true;}
  assert!(dispatch(&mut c,json!({"op":"join","deviceKey":"a".repeat(64),"confirmed":false}))["error"].is_string());
  let r=dispatch(&mut c,json!({"op":"join","deviceKey":"a".repeat(64),"confirmed":true}));assert_eq!(r["request"]["body"],"{\"force_join\":false}");assert_eq!(r["request"]["method"],"POST");assert!(r["request"]["url"].as_str().unwrap().ends_with("synthetic%2Fa"));let id=r["request"]["id"].clone();
  dispatch(&mut c,json!({"op":"session_cancel"}));assert!(c.pending.is_none());let late=dispatch(&mut c,json!({"op":"join_response","id":id,"httpStatus":200,"body":"{}"}));assert_eq!(late["error"],"stale_join_response");*lab().lock().unwrap()=Lab::default();
 }
 #[test]fn join_response_requires_https_room_and_required_report_fields(){let mut b=json!({"code":0,"msg":"","data":{"token":"synthetic","signaling_list":["wss://synthetic.invalid"],"report_token":"synthetic","report_url":"https://synthetic.invalid"}});assert!(join_data(200,&b).is_ok());assert!(join_data(503,&b).is_err());b["code"]=json!(2002);assert!(join_data(200,&b).is_err());b["code"]=json!(0);b["data"]["signaling_list"]=json!(["ws://unsafe.invalid"]);assert!(join_data(200,&b).is_err());}
 #[test]fn only_own_online_windows_selection_and_encoded_path(){assert!(allowed(&json!({"device_id":"a","platform":1,"status":"CONNECTED"}),"self",""));for d in [json!({"device_id":"self","platform":1,"status":"CONNECTED"}),json!({"device_id":"a","platform":4,"status":"CONNECTED"}),json!({"device_id":"a","platform":1,"status":"DISCONNECTED"})]{assert!(!allowed(&d,"self",""));}assert!(!allowed(&json!({"device_id":"old","platform":1,"status":"CONNECTED"}),"new","old"));assert_eq!(segment("a/b?c"),"a%2Fb%3Fc");}
 #[test]fn harmony_host_requires_reported_pc_platform_and_os(){
    assert!(harmony_host(&json!({"platform":1,"os":"HarmonyOS"})));
    assert!(harmony_host(&json!({"platform":1,"os":"HarmonyOS 6"})));
    assert!(!harmony_host(&json!({"platform":2,"os":"HarmonyOS"})));
    assert!(!harmony_host(&json!({"platform":1,"name":"HarmonyOS"})));
    assert!(!harmony_host(&json!({"platform":1,"os":"Windows 11"})));
 }
}

#[cfg(test)] mod assistance_tests {
 use super::*;
 #[test] fn assistance_confirmation_fallback_and_cancel_are_scoped(){let _scenario=TEST_LAB_SCENARIO.lock().unwrap_or_else(|e|e.into_inner());
  let mut c=Core::default();c.accept_device_profile(&json!({"name":"synthetic","deviceType":"pc"}));c.account.token="synthetic-token".into();*lab().lock().unwrap()=Lab::default();
  let mut request=json!({"op":"assist_join","connectId":"synthetic-partner","connectCode":"synthetic-code","viewerWidth":1920,"viewerHeight":1080,"viewerRefresh":60});
  assert_eq!(dispatch(&mut c,request.clone())["error"],"explicit_assistance_confirmation_required");request["confirmed"]=json!(true);
  let mut bad=request.clone();bad["legacy"]=json!(true);assert_eq!(dispatch(&mut c,bad.clone())["error"],"assistance_fallback_not_authorized");
  let first=dispatch(&mut c,request.clone());assert!(first["request"]["url"].as_str().unwrap().ends_with("/api/v2/room/join/share/by_code"));assert_eq!(serde_json::from_str::<Value>(first["request"]["body"].as_str().unwrap()).unwrap(),json!({"connect_id":"synthetic-partner","connect_code":"synthetic-code"}));
  assert_eq!(dispatch(&mut c,json!({"op":"join_response","id":first["request"]["id"],"httpStatus":404}))["assistFallback"],true);
  let fallback=dispatch(&mut c,bad);assert!(fallback["request"]["url"].as_str().unwrap().ends_with("/api/v1/room/join/share/by_code"));
  assert_ne!(dispatch(&mut c,json!({"op":"join_response","id":fallback["request"]["id"],"httpStatus":404}))["assistFallback"],true);
  let last=dispatch(&mut c,request);dispatch(&mut c,json!({"op":"session_cancel"}));assert_eq!(dispatch(&mut c,json!({"op":"join_response","id":last["request"]["id"],"httpStatus":200}))["error"],"stale_join_response");*lab().lock().unwrap()=Lab::default();
 }
}

#[cfg(test)] mod repeated_connection_tests {
 use super::*;
 fn refresh(c:&mut Core)->String{
  let dev=json!({"device_id":"synthetic-repeat","platform":1,"name":"Synthetic repeat","status":"CONNECTED"});
  c.pending=Some((9000,"devices".into()));dispatch(c,json!({"op":"response","id":9000,"httpStatus":200,"body":json!({"code":0,"data":{"my_binded_devices":[dev.clone()]}}).to_string()}));crate::devices::key(c,&dev).unwrap()
 }
 fn core()->Core{let mut c=Core::default();c.accept_device_profile(&json!({"name":"synthetic","deviceType":"pc"}));c.id.client_id="synthetic-install".into();c.id.device_id="synthetic-viewer".into();c.account=Account{token:"synthetic-token".into(),csrf:"synthetic-csrf".into(),user_id:"synthetic-user".into()};c}
 fn select(c:&mut Core,key:&str){assert_eq!(dispatch(c,json!({"op":"select_device","deviceKey":key}))["selectionValid"],true);}
 fn join(c:&mut Core,key:&str)->Value{dispatch(c,json!({"op":"join","deviceKey":key,"confirmed":true}))}
 #[test]fn room_client_type_follows_validated_device_profile_and_cancel(){
  let _scenario=TEST_LAB_SCENARIO.lock().unwrap_or_else(|e|e.into_inner());*lab().lock().unwrap()=Lab::default();
  let mut c=core();let key=refresh(&mut c);
  for (kind,expected) in [("phone",2),("tablet",2),("pc",3),("2in1",3)] {
   c.accept_device_profile(&json!({"name":"synthetic","deviceType":kind}));select(&mut c,&key);
   let r=join(&mut c,&key);assert!(r["request"].is_object());assert_eq!(lab().lock().unwrap().client_type,Some(expected));
   dispatch(&mut c,json!({"op":"session_cancel"}));assert_eq!(lab().lock().unwrap().client_type,None);
  }
  c.accept_device_profile(&json!({"name":"synthetic","deviceType":"unknown"}));select(&mut c,&key);
  let r=join(&mut c,&key);assert_eq!(r["error"],"local_device_type_unknown");assert!(r.get("request").is_none());assert_eq!(lab().lock().unwrap().client_type,None);
  *lab().lock().unwrap()=Lab::default();
 }
 #[test]fn multi_join_requires_matching_ready_primary_before_request(){let _scenario=TEST_LAB_SCENARIO.lock().unwrap_or_else(|e|e.into_inner());*lab().lock().unwrap()=Lab::default();let mut c=core();let key=refresh(&mut c);select(&mut c,&key);for fields in [json!({}),json!({"renderSlot":1,"videoGeneration":1}),json!({"renderSlot":0,"videoGeneration":0})]{let mut v=json!({"op":"join","deviceKey":key,"confirmed":true,"multiVideo":true});for(k,val)in fields.as_object().unwrap(){v[k]=val.clone();}let result=dispatch(&mut c,v);assert_eq!(result["error"],"primary_renderer_required");assert!(result.get("request").is_none());assert!(c.pending.is_none());}*lab().lock().unwrap()=Lab::default();}
 #[test]fn repeated_confirmed_join_requests_survive_third_and_later_cancelled_attempts(){let _scenario=TEST_LAB_SCENARIO.lock().unwrap_or_else(|e|e.into_inner());
  *lab().lock().unwrap()=Lab::default();let mut c=core();let key=refresh(&mut c);let mut ids=std::collections::BTreeSet::new();
  // Every controller entry uses this same select/join/cancel dispatch. Keep the Core/Lab alive
  // across more than two complete cycles, including cancellation after a successful room response.
  for entry in ["desktop","watch","files","detail-preview","detail-lock","desktop","watch","files","detail-preview","detail-lock"]{
   select(&mut c,&key);assert_eq!(dispatch(&mut c,json!({"op":"join","deviceKey":key,"confirmed":false}))["error"],"explicit_device_confirmation_required");
   let request=join(&mut c,&key);let r=&request["request"];assert!(r.is_object(),"{entry}: {request}");assert!(ids.insert(r["id"].as_u64().unwrap()));assert_eq!(r["method"],"POST");assert_eq!(r["body"],"{\"force_join\":false}");
   for op in ["refresh","resume"]{let refresh=dispatch(&mut c,json!({"op":op}));assert!(refresh["request"].is_null());assert_eq!(c.pending.as_ref().map(|(id,_)|*id),r["id"].as_u64());}
   assert_eq!(join(&mut c,&key)["error"],"join_request_pending");
   if ids.len()%2==0{
    let response=dispatch(&mut c,json!({"op":"join_response","id":r["id"],"httpStatus":200,"body":json!({"code":0,"data":{"token":"synthetic-room","signaling_list":["wss://synthetic.invalid"],"report_token":"synthetic","report_url":"https://synthetic.invalid"}}).to_string()}));assert_eq!(response["joinPassed"],true);assert_eq!(response["actions"][0]["kind"],"connect");
    assert_eq!(join(&mut c,&key)["error"],"session_already_active");
   }
   dispatch(&mut c,json!({"op":"session_cancel"}));assert!(c.pending.is_none());assert!(!lab().lock().unwrap().signal.active());
   assert_eq!(dispatch(&mut c,json!({"op":"join_response","id":r["id"],"httpStatus":200,"body":"{}"}))["error"],"stale_join_response");
  }
  assert_eq!(ids.len(),10);*lab().lock().unwrap()=Lab::default();
 }
 #[test]fn real_auth_busy_service_and_freshness_errors_remain_distinct_without_a_quota(){let _scenario=TEST_LAB_SCENARIO.lock().unwrap_or_else(|e|e.into_inner());
  *lab().lock().unwrap()=Lab::default();let mut c=core();let key=refresh(&mut c);
  for(status,code,expected)in[(200,2002,"remote_session_busy"),(503,0,"join_service_unavailable"),(429,0,"join_rate_limited"),(403,0,"join_http_rejected"),(200,7777,"join_service_rejected")]{select(&mut c,&key);let request=join(&mut c,&key);let response=dispatch(&mut c,json!({"op":"join_response","id":request["request"]["id"],"httpStatus":status,"body":json!({"code":code}).to_string()}));assert_eq!(response["error"],expected);assert_eq!(response["joinHttp"],status);assert_eq!(response["joinCode"],code);assert!(c.logged());dispatch(&mut c,json!({"op":"session_cancel"}));}
  select(&mut c,&key);c.devices_clock=Some(std::time::Instant::now()-crate::devices::FRESH_FOR*100);assert!(!c.devices_fresh());assert!(join(&mut c,&key)["request"].is_object());dispatch(&mut c,json!({"op":"session_cancel"}));
  c.pending=Some((9900,"devices".into()));dispatch(&mut c,json!({"op":"network_error","id":9900}));assert!(c.devices_refresh_failed);select(&mut c,&key);assert!(join(&mut c,&key)["request"].is_object());dispatch(&mut c,json!({"op":"session_cancel"}));
  c.pending=Some((9901,"devices".into()));dispatch(&mut c,json!({"op":"response","id":9901,"httpStatus":200,"body":json!({"code":0,"data":{"my_binded_devices":[{"device_id":"synthetic-repeat","platform":1,"status":"DISCONNECTED"}]}}).to_string()}));assert_eq!(dispatch(&mut c,json!({"op":"select_device","deviceKey":key}))["error"],"select_own_online_windows_required");let key=refresh(&mut c);
  select(&mut c,&key);let request=join(&mut c,&key);assert_eq!(dispatch(&mut c,json!({"op":"join_response","id":request["request"]["id"],"httpStatus":401,"body":"{\"code\":1120}"}))["error"],"authentication_expired");assert!(!c.logged());assert_eq!(join(&mut c,&key)["error"],"authentication_required");*lab().lock().unwrap()=Lab::default();
 }
 #[test]fn data_only_entries_join_without_a_viewer_display(){let _scenario=TEST_LAB_SCENARIO.lock().unwrap_or_else(|e|e.into_inner());*lab().lock().unwrap()=Lab::default();let mut c=core();let key=refresh(&mut c);for mode in ["filesOnly","catalogOnly","lockOnly","terminalOnly"]{select(&mut c,&key);let mut request=json!({"op":"join","deviceKey":key,"confirmed":true,"viewerWidth":0,"viewerHeight":0,"viewerRefresh":0});request[mode]=json!(true);let r=dispatch(&mut c,request);assert!(r["request"].is_object(),"{mode}: {r}");dispatch(&mut c,json!({"op":"session_cancel"}));}*lab().lock().unwrap()=Lab::default();}
 #[test]fn detail_lock_is_ct5_and_cancellation_never_falls_back_to_desktop(){let _scenario=TEST_LAB_SCENARIO.lock().unwrap_or_else(|e|e.into_inner());*lab().lock().unwrap()=Lab::default();let mut c=core();let key=refresh(&mut c);for _ in 0..4{select(&mut c,&key);let r=dispatch(&mut c,json!({"op":"join","deviceKey":key,"confirmed":true,"lockOnly":true}));assert!(r["request"].is_object());assert_eq!(lab().lock().unwrap().capture_type,5);dispatch(&mut c,json!({"op":"session_cancel"}));assert_eq!(dispatch(&mut c,json!({"op":"join_response","id":r["request"]["id"],"httpStatus":200,"body":"{}"}))["error"],"stale_join_response");}select(&mut c,&key);assert!(join(&mut c,&key)["request"].is_object());assert_eq!(lab().lock().unwrap().capture_type,1);dispatch(&mut c,json!({"op":"session_cancel"}));*lab().lock().unwrap()=Lab::default();}

}
