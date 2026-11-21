// SPDX-License-Identifier: GPL-3.0-only
// Reuses uu-remote-linux viewer/wire.rs and viewer/sdl.rs @6bf05a6.
use serde_json::{json,Value};
use crate::protocol::{decode_wire,WireValue};
use std::collections::{BTreeSet,VecDeque};
fn integer(n:u64,out:&mut Vec<u8>){let mut v=n;while v>127{out.push(v as u8|128);v>>=7;}out.push(v as u8);}
fn int(f:u32,n:u64,out:&mut Vec<u8>){integer((f as u64)<<3,out);integer(n,out);}
fn bytes(f:u32,b:&[u8],out:&mut Vec<u8>){integer(((f as u64)<<3)|2,out);integer(b.len() as u64,out);out.extend_from_slice(b);}
fn number(data:&[u8],field:u32)->Option<u64>{decode_wire(data).ok()?.into_iter().find_map(|f|match f.value{WireValue::Varint(v)if f.number==field=>Some(v),_=>None})}
fn body(data:&[u8],field:u32)->Option<&[u8]>{decode_wire(data).ok()?.into_iter().find_map(|f|match f.value{WireValue::Bytes(v)if f.number==field=>Some(v),_=>None})}
fn capture(seq:u64,fields:&[(u32,u64)])->Vec<u8>{let mut h=vec![];int(1,seq,&mut h);let mut s=vec![];for &(f,v)in fields{int(f,v,&mut s)}let mut rpc=vec![];bytes(1,&h,&mut rpc);bytes(2,&s,&mut rpc);crate::wire::envelope(seq,21,&rpc)}
fn action(seq:u64,kind:u64,value:Option<u64>)->Vec<u8>{let mut a=vec![];int(1,kind,&mut a);if let Some(v)=value{int(5,v,&mut a)}crate::wire::envelope(seq,3,&a)}
fn stream_snapshot(seq:u64,fps:u64,quality:u64,w:u64,h:u64,codec:u64)->Vec<u8>{capture_snapshot(seq,fps,quality,w,h,codec)}
// Stream settings preserve the physical display mode for every request.
fn capture_snapshot(seq:u64,fps:u64,quality:u64,w:u64,h:u64,codec:u64)->Vec<u8>{
 capture(seq,&[(1,match fps{60=>2,90=>3,144=>4,_=>1}),(2,quality),(3,1),(4,(-2i64)as u64),(5,u64::MAX),(6,u64::MAX),(7,1),(9,0),(10,1),(11,0),(12,2),(13,codec),(14,w),(15,h),(16,0),(17,0),(18,fps)])
}
#[derive(Clone)]pub struct Setting {pub seq:u64,pub request:Value,pub sent:usize,pub total:usize,pub ack:Option<bool>,pub rpc:bool}
pub struct Center {codec:u64,decoder_width:u32,decoder_height:u32,decoder_fps:u64,unlock:crate::unlock::UnlockLifecycle,pub next:u64,pub history:VecDeque<Setting>,pub reported:Value,pub sync_count:u64,pub remote_fps:Option<u64>,pub remote_width:Option<u64>,pub remote_height:Option<u64>,pub privacy_support:Option<u64>,pub privacy_current:Option<u64>,privacy_live:bool,pub privacy_owned:bool,pub remote_auto_lock:Option<bool>,pub auto_lock_supported:bool,pub remote_locked:Option<bool>,pub auto_unlock_supported:Option<bool>,metrics_version:u64,media_ended:bool,privacy_reply:Option<u64>,privacy_saver:Option<(u64,Option<bool>)>,privacy_error:Option<&'static str>,privacy_reply_error:Option<i64>,privacy_saver_error:Option<i64>}
impl Default for Center {fn default()->Self{Self{codec:1,decoder_width:1280,decoder_height:720,decoder_fps:30,unlock:crate::unlock::UnlockLifecycle::default(),next:3_000_000,history:VecDeque::new(),reported:json!({}),sync_count:0,remote_fps:None,remote_width:None,remote_height:None,privacy_support:None,privacy_current:None,privacy_live:false,privacy_owned:false,remote_auto_lock:None,auto_lock_supported:false,remote_locked:None,auto_unlock_supported:None,metrics_version:0,media_ended:false,privacy_reply:None,privacy_saver:None,privacy_error:None,privacy_reply_error:None,privacy_saver_error:None}}}
fn rpc_request(seq:u64,case:u32,payload:&[u8])->Vec<u8>{let mut header=vec![];int(1,seq,&mut header);let mut rpc=vec![];bytes(1,&header,&mut rpc);bytes(case,payload,&mut rpc);crate::wire::envelope(seq,21,&rpc)}
fn setting_section(data:&[u8])->bool{let Ok(fields)=decode_wire(data)else{return false};fields.iter().any(|f|match(f.number,&f.value){(1,WireValue::Varint(2))=>true,(1,WireValue::Bytes(b))=>{if b.len()>64{return false;}let mut values=vec![];let mut value=0u64;let mut shift=0;for &byte in *b{if shift>=64{return false;}value|=((byte&127)as u64)<<shift;if byte&128==0{values.push(value);value=0;shift=0;}else{shift+=7;}}shift==0&&values.contains(&2)},_=>false})}
/// Only reuse this exact target's reported current FOLLOW_REMOTE rectangle.
fn reported_portrait_profile(enabled:bool,id:u32,screen:&Value)->Option<(u64,u64,u64,u64)> {
 if !enabled || screen["id"].as_u64()!=Some(u64::from(id)) || screen["resolutionType"].as_u64()!=Some(3) || screen["profileDimensionsReported"]!=true{return None;}
 let r=&screen["currentResolution"];
 let dimension=|key:&str|r[key].as_u64().filter(|v|(1..=32768).contains(v));
 Some((dimension("logicalWidth")?,dimension("logicalHeight")?,dimension("width")?,dimension("height")?))
}
impl Center {
 pub fn set_codec(&mut self, codec:u32){self.codec=u64::from(codec);}
 pub fn set_decoder_fps(&mut self, fps:u32){self.decoder_fps=u64::from(fps);}
 fn fps_limit(&self)->u64 { self.decoder_fps.min(self.remote_fps.unwrap_or(60)) }
 fn preferred_fps(&self, allow_pending:bool)->u64 {
  let limit=self.fps_limit();
  let selected=self.history.iter().rev()
   .find(|s|s.request["kind"]=="fps" && s.sent==s.total && (s.ack==Some(true) || (allow_pending && s.ack.is_none())))
   .and_then(|s|s.request["value"].as_u64())
   .or_else(||self.reported["fps"].as_u64()).unwrap_or(30);
  if selected>=60 && limit>=60 {60} else {30}
 }
 pub fn set_decoder_size(&mut self, width:u32, height:u32){self.decoder_width=width;self.decoder_height=height;}
 pub fn portrait_stream(&mut self, id: u32, w: u32, h: u32) -> (u64, Vec<u8>) {
  self.portrait_stream_with_report(id,w,h,false,&Value::Null)
 }
 pub fn portrait_stream_with_report(&mut self, id:u32, w:u32, h:u32, enabled:bool, screen:&Value)->(u64,Vec<u8>){
  let profile=reported_portrait_profile(enabled,id,screen);
  let (logical_w,logical_h,pixel_w,pixel_h,mode)=profile.map(|(lw,lh,pw,ph)|(lw,lh,pw,ph,3)).unwrap_or((u64::MAX,u64::MAX,0,0,1));
  let seq = self.next;
  self.next += 1;
  let fps = self.preferred_fps(false);
  let quality = self.reported["quality"].as_u64().filter(|v| (1..=6).contains(v))
   .or_else(|| self.history.iter().rev().find(|s| s.sent == s.total && s.ack == Some(true) && s.request["kind"] == "quality")
    .and_then(|s| s.request["value"].as_u64())).unwrap_or(5);
  let mut fields = vec![
   (1, match fps { 60 => 2, 90 => 3, 144 => 4, _ => 1 }), (2, quality), (3, 1),
   (4, id as u64), (5, logical_w), (6, logical_h), (7, 1), (9, 0), (10, mode),
   (11, 0), (12, 2), (13, self.codec), (14, w as u64), (15, h as u64),
   (16, pixel_w), (17, pixel_h), (18, fps),
  ];
  if quality == 6 {
   if let Some(bps) = self.reported["customBps"].as_u64().filter(|v| *v > 0 && *v <= u32::MAX as u64) {
    fields.push((8, bps));
   }
  }
  let packet = capture(seq, &fields);
  if self.history.len() >= 32 { self.history.pop_front(); }
  self.history.push_back(Setting {
   seq, request: json!({"kind":"portrait_stream", "screenId":id, "width":w, "height":h, "profileApplied":profile.is_some(), "profileType":screen["resolutionType"].as_u64(), "profileLogicalWidth":profile.map(|p|p.0), "profileLogicalHeight":profile.map(|p|p.1), "profileWidth":profile.map(|p|p.2), "profileHeight":profile.map(|p|p.3)}),
   sent: 0, total: 1, ack: None, rpc: true,
  });
  (seq, packet)
 }
 /// Diagnostic direct switch: require known stream preferences and preserve physical mode.
 pub fn direct_screen_setting(&mut self, id:u32)->Result<(u64,Vec<u8>),&'static str>{
  let fps=self.reported["fps"].as_u64().filter(|v|[30,60,90,144].contains(v)).or_else(||self.history.iter().rev().find(|s|s.sent==s.total&&s.ack==Some(true)&&s.request["kind"]=="fps").and_then(|s|s.request["value"].as_u64())).ok_or("direct_switch_fps_unknown")?;
  let quality=self.reported["quality"].as_u64().filter(|v|(1..=5).contains(v)).or_else(||self.history.iter().rev().find(|s|s.sent==s.total&&s.ack==Some(true)&&s.request["kind"]=="quality").and_then(|s|s.request["value"].as_u64()).filter(|v|(1..=5).contains(v))).ok_or("direct_switch_quality_unknown")?;
  let (w,h)=self.history.iter().rev().find(|s|matches!(s.request["kind"].as_str(),Some("resolution"|"portrait_stream"))&&s.sent==s.total&&s.ack==Some(true)).and_then(|s|Some((s.request["width"].as_u64()?,s.request["height"].as_u64()?))).unwrap_or((u64::from(self.decoder_width),u64::from(self.decoder_height)));
  let fps=fps.min(self.fps_limit());let seq=self.next;self.next+=1;
  // Field 7 is 4:2:0 chroma; field 10 is ChooseType DEFAULT.
  let packet=capture(seq,&[(1,match fps{60=>2,90=>3,144=>4,_=>1}),(2,quality),(3,1),(4,u64::from(id)),(5,u64::MAX),(6,u64::MAX),(7,1),(9,0),(10,1),(11,0),(12,2),(13,self.codec),(14,w),(15,h),(16,0),(17,0),(18,fps)]);
  if self.history.len()>=32{self.history.pop_front();}
  self.history.push_back(Setting{seq,request:json!({"kind":"direct_screen_setting","screenId":id,"width":w,"height":h}),sent:0,total:1,ack:None,rpc:true});
  Ok((seq,packet))
 }
 pub fn request_ack(&self, seq: u64) -> Option<bool> {
  self.history.iter().find(|s| s.seq == seq).and_then(|s| s.ack)
 }
 pub fn unlock_observed_unlocked(&self)->bool{self.unlock.observed_unlocked()}
 pub fn unlock_permitted(&self)->bool{self.unlock.permitted()}
 pub fn unlock_active(&self)->bool{self.unlock.active()}
 pub fn prepare_unlock(&mut self,password:&[u8])->Result<zeroize::Zeroizing<Vec<u8>>,&'static str>{self.unlock.reserve()?;let packet=crate::unlock::desktop_packet(self.next,password)?;self.next+=1;Ok(packet)}
 pub fn unlock_submitted(&mut self){self.unlock.submitted();}
 // Official Android 4.45.0 SendSystemMetricsRequest: Message13, packed sections 0/1/2, empty response.
 pub fn security_query(&mut self)->Vec<u8>{let seq=self.next;self.next+=1;crate::wire::envelope(seq,13,&[10,3,0,1,2])}
 pub fn tool_lock_allowed(&self,e:&Value)->Result<(),&'static str>{if e["kind"]!="lock_now"||e["confirmed"]!=true{return Err("lock_only_operation_blocked")}if self.history.iter().any(|s|s.request["kind"]=="lock_now"){return Err("lock_already_attempted")}Ok(())}
 pub fn revoke_unlock(&mut self){self.unlock.revoke();}
 pub fn close_security(&mut self){self.unlock.close();self.remote_locked=None;self.auto_unlock_supported=None;}
 pub fn begin_end_media(&mut self)->bool{self.revoke_unlock();if self.media_ended{return false;}self.media_ended=true;true}
 pub fn screensaver_response(&self,seq:u64)->Option<bool>{self.privacy_saver.filter(|(request,_)|*request==seq+1).and_then(|(_,ack)|ack)}
 fn observe_security(&mut self,data:&[u8]){
  if let Some(action)=body(data,3){if number(action,1).unwrap_or(0)<=1{if let Some(flags)=body(action,4){if let Some(v)=number(flags,3){self.metrics_version=v;self.auto_lock_supported|=v>=2;}}}}
  if let Some(metrics)=body(data,13){if let Some(setting)=body(metrics,4){if decode_wire(setting).is_ok(){let value=number(setting,3);if matches!(value,Some(0|1))||(value.is_none()&&self.metrics_version>=2&&setting_section(metrics)){self.remote_auto_lock=Some(value.unwrap_or(0)==1);self.auto_lock_supported=true;for setting in self.history.iter_mut().filter(|s|s.request["kind"]=="auto_lock"&&s.sent==s.total){setting.ack=Some(setting.request["enabled"].as_bool()==self.remote_auto_lock);}}}}}
  if let Some(report)=self.unlock.observe(data){self.remote_locked=report.map(|r|r.locked);self.auto_unlock_supported=report.map(|r|r.supported);}
 }

 pub fn prepare(&mut self,e:&Value)->Result<(u64,Vec<Vec<u8>>),&'static str>{
  let seq=self.next;let kind=e["kind"].as_str().ok_or("invalid_setting_kind")?;
  let allowed:&[&str]=match kind {"quality"=>&["kind","value"],"fps"=>&["kind","value","localFpsLimit"],"resolution"=>&["kind","value","width","height","screenId","logicalWidth","logicalHeight"],"lock_now"|"reboot"|"shutdown"=>&["kind","confirmed"],"privacy"=>&["kind","value","confirmed"],"auto_lock"|"host_mute"=>&["kind","enabled","confirmed"],_=>return Err("unsupported_setting")};
  if e.as_object().is_none_or(|o|o.keys().any(|k|!allowed.contains(&k.as_str()))){return Err("unrecognized_setting_field")}

  if kind=="resolution" {if let Some(v)=e.get("value"){if !matches!(v.as_str(),Some("remote"|"720p"|"1080p"|"fit")){return Err("invalid_resolution_value")}}for key in ["logicalWidth","logicalHeight"]{if e.get(key).is_some_and(|v|v.as_u64().is_none()){return Err("invalid_resolution_value")}}}
  let fps=self.preferred_fps(true);
  let quality=self.history.iter().rev().find(|s|s.sent==s.total&&(s.request["kind"]=="quality"||(s.request["kind"]=="resolution"&&s.request["value"]=="remote"))).and_then(|s|if s.request["kind"]=="resolution"{Some(4)}else{s.request["value"].as_u64()}).unwrap_or(5);
  let scale=self.history.iter().rev().find(|s|matches!(s.request["kind"].as_str(),Some("resolution"|"portrait_stream"))&&s.sent==s.total&&s.ack==Some(true)).and_then(|s|Some((s.request["width"].as_u64()?,s.request["height"].as_u64()?))).unwrap_or((self.decoder_width as u64,self.decoder_height as u64));
  let packets=match kind {
   "quality"=>{let q=e["value"].as_u64().filter(|q|[2,3,4,5].contains(q)).ok_or("invalid_quality")?;vec![stream_snapshot(seq,fps,q,scale.0,scale.1,self.codec)]},
   "fps"=>{let f=e["value"].as_u64().filter(|f|[30,60,90,144].contains(f)).ok_or("invalid_fps")?;let local=e["localFpsLimit"].as_u64().filter(|f|*f>0&&*f<=60).ok_or("local_capability_required")?;if f>local||f>self.fps_limit(){return Err("fps_capability_limited")}vec![stream_snapshot(seq,f,quality,scale.0,scale.1,self.codec)]},
   "resolution"=>{
    let w=e["width"].as_u64().filter(|v|*v>=2&&*v<=8192&&v%2==0).ok_or("invalid_width")?;
    let h=e["height"].as_u64().filter(|v|*v>=2&&*v<=8192&&v%2==0).ok_or("invalid_height")?;
    let id=e["screenId"].as_u64().filter(|v|*v<=i32::MAX as u64).ok_or("screen_report_required")?;
    let native=e["value"]=="remote";
    let _ = id;
    vec![capture_snapshot(seq,fps,if native{4}else{quality},w,h,self.codec)]
   },
   // Fixed upstream system_actions.rs: dedicated actions, never shell/keyboard commands.
   "lock_now"|"reboot"|"shutdown"=>{if e["confirmed"]!=true{return Err("explicit_remote_state_confirmation_required")}vec![action(seq,match kind{"lock_now"=>10,"reboot"=>9,_=>12},None)]},
   "privacy"=>{if e["confirmed"]!=true{return Err("explicit_remote_state_confirmation_required")}
    let mode=e["value"].as_u64().filter(|n|[1,2,3].contains(n)).ok_or("invalid_privacy_mode")?;
    if mode==3&&self.privacy_support!=Some(2){return Err("remote_privacy_capability_required")}
    if mode==2&&!matches!(self.privacy_support,Some(1|2)){return Err("remote_privacy_capability_required")}
    if mode==1&&self.privacy_support.is_none()&&!self.privacy_owned{return Err("remote_privacy_capability_required")}
    self.privacy_error=None;self.privacy_reply_error=None;self.privacy_saver_error=None;let mut header=vec![];int(1,seq,&mut header);let mut request=vec![];int(1,u64::from(mode!=1),&mut request);int(2,mode,&mut request);
    let mut rpc=vec![];bytes(1,&header,&mut rpc);bytes(7,&request,&mut rpc);let privacy=crate::wire::envelope(seq,21,&rpc);if mode==2{self.privacy_saver=Some((seq+1,None));vec![rpc_request(seq+1,25,&[]),privacy]}else{vec![privacy]}
   },
   "auto_lock"|"host_mute"=>{if e["confirmed"]!=true{return Err("explicit_remote_state_confirmation_required")}let on=e["enabled"].as_bool().ok_or("invalid_toggle")?;if kind=="auto_lock"{if !self.auto_lock_supported{return Err("remote_auto_lock_capability_required")}vec![action(seq,19,Some(if on{2}else{1}))]}else if on{vec![action(seq,14,None),action(seq+1,18,None)]}else{vec![action(seq,16,None)]}},
   _=>return Err("unsupported_setting")
  };
  self.next+=packets.len() as u64;let setting=Setting{seq,request:e.clone(),sent:0,total:packets.len(),ack:None,rpc:matches!(kind,"quality"|"fps"|"resolution"|"privacy")};
  if self.history.len()>=32{self.history.pop_front();}self.history.push_back(setting);Ok((seq,packets))
 }
 pub fn sent(&mut self,seq:u64,n:usize){if let Some(s)=self.history.iter_mut().find(|s|s.seq==seq){s.sent=n;if s.request["kind"]=="privacy"&&n==s.total&&s.request["value"]!=1{self.privacy_owned=true;}}}
 pub fn observe(&mut self,data:&[u8]){
  if data.len()>1024*1024{return;}self.observe_security(data);
  if let Some(report)=body(data,12){if number(report,2)==Some((-7i64)as u64){self.privacy_error=Some("privacy_remote_failure");}}
  if let Some(rpc)=body(data,22){if let Some(seq)=body(rpc,1).and_then(|h|number(h,1)){if let Some(reply)=body(rpc,21){if self.privacy_saver.is_some_and(|(request,_)|request==seq)&&decode_wire(reply).is_ok(){let code=number(reply,1).unwrap_or(0) as i64;self.privacy_saver_error=Some(code);self.privacy_saver=Some((seq,Some(code==0)));}}}}
  if let Some(a)=body(data,3){if number(a,1).unwrap_or(0)<=1{if let Some(flags)=body(a,4){if let Some(v)=number(flags,4).filter(|v|[1,2].contains(v)){self.privacy_support=Some(v);}}}}
  if let Some(state)=body(data,15).and_then(|s|body(s,5)){if let Some(current)=number(state,3).filter(|v|[1,2,3].contains(v)){self.privacy_current=Some(current);self.privacy_live=true;if current==1{self.privacy_owned=false;}}}
  if let Some(setting)=body(data,13).and_then(|s|body(s,4)).filter(|_|!self.privacy_live){if let Some(current)=number(setting,7).filter(|v|[1,2,3].contains(v)){self.privacy_current=Some(current);if current==1{self.privacy_owned=false;}}}
  if let Some(rpc)=body(data,22){if let Some(seq)=body(rpc,1).and_then(|h|number(h,1)){if let Some(reply)=body(rpc,3){if let Some(s)=self.history.iter_mut().find(|s|s.seq==seq&&s.request["kind"]=="privacy"){if decode_wire(reply).is_ok()&&number(reply,2)==s.request["value"].as_u64(){if let Some(current)=number(reply,3).filter(|v|[1,2,3].contains(v)){self.privacy_reply=Some(current);let code=number(reply,1).unwrap_or(0) as i64;self.privacy_reply_error=Some(code);s.ack=Some(code==0);if code!=0{self.privacy_error=Some("privacy_remote_rejected");}else{self.privacy_error=None;self.privacy_current=Some(current);self.privacy_live=true;if current==1{self.privacy_owned=false;}}}}}}}}

  if let Some(rpc)=body(data,22){if let Some(seq)=body(rpc,1).and_then(|h|number(h,1)){if let Some(s)=self.history.iter_mut().find(|s|s.seq==seq&&s.rpc&&s.request["kind"]!="privacy"){if let Some(reply)=body(rpc,2){if let Ok(fields)=decode_wire(reply){let mut ok=true;let mut valid=true;for f in fields{if let(1,WireValue::Bytes(e))=(f.number,f.value){if decode_wire(e).is_err(){valid=false;}if number(e,1).unwrap_or(0)!=0{ok=false;}}}if valid{s.ack=Some(ok);}}}}}}
  if let Some(sync)=body(data,25){
   let mut report=json!({});
   if let Some(raw)=number(sync,1){
    report["fpsRaw"]=json!(raw);
    // Official CaptureSettingSync uses an enum; the pinned Linux host also
    // emits literal FPS values, which remain supported for compatibility.
    let fps=match raw{1=>Some(30),2=>Some(60),3=>Some(90),4=>Some(144),30|60|90|144=>Some(raw),_=>None};
    if let Some(fps)=fps{report["fps"]=json!(fps);}
   }
   for (field,key)in [(2,"quality"),(4,"customBps"),(5,"width"),(6,"height")] {if let Some(n)=number(sync,field){report[key]=json!(n)}}
   self.reported=report;self.sync_count+=1;
  }
  if let Some(caps)=body(data,18){if let Ok(fields)=decode_wire(caps){for f in fields{if let (1,WireValue::Bytes(c))=(f.number,f.value){if number(c,1)==Some(1)&&number(c,3)==Some(self.codec){
    if let Some(fps)=number(c,2).filter(|v|*v>0&&*v<=1000&&*v>=self.remote_fps.unwrap_or(0)){
     self.remote_fps=Some(fps);self.remote_width=number(c,4);self.remote_height=number(c,5);
    }
   }}}}}
 }
 pub fn snapshot(&self)->Value{json!({"autoUnlockAvailable":false,"autoUnlockAttempted":self.unlock.attempted(),"autoUnlockSubmittedCount":self.unlock.submitted_count(),"autoUnlockBlockReason":self.unlock.reason(),"autoUnlockStateReason":self.unlock.state_reason(),"autoUnlockSessionStopReason":self.unlock.stop_reason(),"remoteAutoLock":self.remote_auto_lock,"autoLockSupported":self.auto_lock_supported,"remoteLocked":self.remote_locked,"autoUnlockSupported":self.auto_unlock_supported,"privacyReply":self.privacy_reply,"privacyReplyError":self.privacy_reply_error,"privacySaverError":self.privacy_saver_error,"privacyError":self.privacy_error,"privacySupport":self.privacy_support,"privacyCurrent":self.privacy_current,"privacyOwned":self.privacy_owned,"settings":self.history.iter().map(|s|json!({"seq":s.seq,"request":s.request,"sentMessages":s.sent,"totalMessages":s.total,"sent":s.sent==s.total,"remoteAck":s.ack,"ackSupported":s.rpc})).collect::<Vec<_>>(),"reported":self.reported,"syncCount":self.sync_count,"remoteMaxFps":self.remote_fps,"remoteCapWidth":self.remote_width,"remoteCapHeight":self.remote_height,"localSessionFpsLimit":self.decoder_fps})}
}
#[cfg(test)]
mod portrait_stream_tests {
 use super::*;
 #[test]
 fn quality_and_fps_preserve_confirmed_stream_budget_and_physical_mode() {
  let mut c=Center::default();c.set_decoder_size(4096,4096);
  let (portrait,_) = c.portrait_stream(7,1280,1280);
  c.sent(portrait,1);
  c.history.iter_mut().find(|s|s.seq==portrait).unwrap().ack=Some(true);
  let (pending,_) = c.portrait_stream(7,720,720);
  c.sent(pending,1); // no ACK: do not inherit
  for request in [json!({"kind":"quality","value":3}),json!({"kind":"fps","value":30,"localFpsLimit":60})] {
   let (_,packets)=c.prepare(&request).unwrap();
   let setting=body(body(&packets[0],21).unwrap(),2).unwrap();
   for (f,v) in [(5,u64::MAX),(6,u64::MAX),(9,0),(14,1280),(15,1280),(16,0),(17,0)] {assert_eq!(number(setting,f),Some(v));}
  }
  let (manual,_) = c.prepare(&json!({"kind":"resolution","screenId":7,"width":450,"height":720})).unwrap();
  c.sent(manual,1);c.history.iter_mut().find(|s|s.seq==manual).unwrap().ack=Some(true);
  let (_,packets)=c.prepare(&json!({"kind":"quality","value":2})).unwrap();
  let setting=body(body(&packets[0],21).unwrap(),2).unwrap();
  assert_eq!(number(setting,14),Some(450));assert_eq!(number(setting,15),Some(720));
 }
 #[test]
 fn all_stream_requests_preserve_physical_display_mode() {
  let mut c=Center::default();
  let (_,portrait)=c.portrait_stream(7,1280,1280);
  let requests=[json!({"kind":"quality","value":3}),json!({"kind":"fps","value":30,"localFpsLimit":60}),
   json!({"kind":"resolution","value":"720p","screenId":7,"width":720,"height":1280}),
   json!({"kind":"resolution","value":"1080p","screenId":7,"width":1080,"height":1920}),
   json!({"kind":"resolution","value":"remote","screenId":7,"width":1600,"height":2560,"logicalWidth":800,"logicalHeight":1280})];
  let mut packets=vec![portrait];
  for request in requests {let (_,p)=c.prepare(&request).unwrap();packets.extend(p);}
  for packet in packets {let s=body(body(&packet,21).unwrap(),2).unwrap();
   for (field,value) in [(5,u64::MAX),(6,u64::MAX),(9,0),(10,1),(16,0),(17,0)]{assert_eq!(number(s,field),Some(value));}
  }
 }
 #[test]
 fn capture_sync_fps_enum_and_linux_literals_are_decoded_without_inventing_unknown(){
  for (raw,expected) in [(1,Some(30)),(2,Some(60)),(3,Some(90)),(4,Some(144)),(30,Some(30)),(60,Some(60)),(90,Some(90)),(144,Some(144)),(0,None),(5,None)] {
   let mut c=Center::default();let mut sync=vec![];int(1,raw,&mut sync);int(2,3,&mut sync);
   c.observe(&crate::wire::envelope(0,25,&sync));
   assert_eq!(c.reported["fpsRaw"].as_u64(),Some(raw));assert_eq!(c.reported["fps"].as_u64(),expected);
   if raw==1 {let (_,packet)=c.direct_screen_setting(7).unwrap();let setting=body(body(&packet,21).unwrap(),2).unwrap();assert_eq!(number(setting,1),Some(1));assert_eq!(number(setting,18),Some(30));}
   if expected.is_none(){assert_eq!(c.direct_screen_setting(7).err(),Some("direct_switch_fps_unknown"));}
  }
 }
 #[test]
 fn direct_switch_requires_known_preferences_and_preserves_physical_mode(){
  let mut c=Center::default();c.set_codec(2);c.set_decoder_size(1280,1280);
  assert_eq!(c.direct_screen_setting(7).err(),Some("direct_switch_fps_unknown"));
  c.reported=json!({"fps":30});assert_eq!(c.direct_screen_setting(7).err(),Some("direct_switch_quality_unknown"));
  c.reported=json!({"fps":30,"quality":3});let(seq,p)=c.direct_screen_setting(7).unwrap();
  assert!(body(&p,3).is_none());
  let setting=body(body(&p,21).unwrap(),2).unwrap();
  for(f,v)in[(1,1),(2,3),(4,7),(5,u64::MAX),(6,u64::MAX),(9,0),(10,1),(11,0),(13,2),(14,1280),(15,1280),(16,0),(17,0),(18,30)] {assert_eq!(number(setting,f),Some(v));}
  assert_eq!(c.request_ack(seq),None);
 }
 #[test]
 fn reported_portrait_profile_is_targeted_and_keeps_video_budget_independent(){
  let screen=json!({"id":2,"resolutionType":3,"profileDimensionsReported":true,"currentResolution":{"logicalWidth":1600,"logicalHeight":2560,"width":1600,"height":2560}});
  for (enabled,id,mut row,applied) in [(false,2,screen.clone(),false),(true,3,screen.clone(),false),(true,2,screen.clone(),true),(true,2,screen.clone(),false),(true,2,screen.clone(),false)] {
   if enabled && id==2 && !applied {if row["resolutionType"]==3 {row["resolutionType"]=json!(2);} }
   let mut c=Center::default();let (_,p)=c.portrait_stream_with_report(id,1280,1280,enabled,&row);
   let b=body(body(&p,21).unwrap(),2).unwrap();let request=&c.history.back().unwrap().request;
   assert_eq!(request["profileApplied"],applied);assert_eq!(number(b,4),Some(u64::from(id)));
   assert_eq!(number(b,5),Some(if applied{1600}else{u64::MAX}));assert_eq!(number(b,6),Some(if applied{2560}else{u64::MAX}));
   assert_eq!(number(b,10),Some(if applied{3}else{1}));assert_eq!(number(b,16),Some(if applied{1600}else{0}));assert_eq!(number(b,17),Some(if applied{2560}else{0}));
   assert_eq!(number(b,9),Some(0));assert_eq!(number(b,14),Some(1280));assert_eq!(number(b,15),Some(1280));
  }
  let mut missing=screen.clone();missing["profileDimensionsReported"]=json!(false);
  let mut invalid=screen.clone();invalid["currentResolution"]["height"]=json!(0);
  for row in [&missing,&invalid] {let mut c=Center::default();let(_,p)=c.portrait_stream_with_report(2,720,720,true,row);let b=body(body(&p,21).unwrap(),2).unwrap();assert_eq!(number(b,10),Some(1));assert_eq!(number(b,5),Some(u64::MAX));assert_eq!(number(b,14),Some(720));assert_eq!(number(b,15),Some(720));assert_eq!(c.history.back().unwrap().request["profileApplied"],false);}
 }
 #[test]
 fn target_stream_keeps_physical_mode_and_correlates_ack() {
  let mut c = Center::default();
  let (seq, p) = c.portrait_stream(7, 720, 1152);
  let setting = body(body(&p, 21).unwrap(), 2).unwrap();
  for (f, v) in [(4, 7), (5, u64::MAX), (6, u64::MAX), (9, 0),
                 (10, 1), (14, 720), (15, 1152), (16, 0), (17, 0)] {
   assert_eq!(number(setting, f), Some(v));
  }
  for (f, v) in [(1, 1), (2, 5), (3, 1), (7, 1), (12, 2), (13, 1), (18, 30)] {
   assert_eq!(number(setting, f), Some(v));
  }
  c.set_decoder_fps(60);
  c.reported = json!({"fps":60,"quality":3});
  let (_, next) = c.portrait_stream(7, 450, 720);
  let next_setting = body(body(&next, 21).unwrap(), 2).unwrap();
  for (f, v) in [(1, 2), (2, 3), (18, 60)] { assert_eq!(number(next_setting, f), Some(v)); }
  let mut h = vec![];
  int(1, seq + 1, &mut h);
  let mut r = vec![];
  bytes(1, &h, &mut r);
  bytes(2, &[], &mut r);
  c.observe(&crate::wire::envelope(1, 22, &r));
  assert_eq!(c.request_ack(seq), None);
  h.clear();
  int(1, seq, &mut h);
  r.clear();
  bytes(1, &h, &mut r);
  bytes(2, &[], &mut r);
  c.observe(&crate::wire::envelope(1, 22, &r));
  assert_eq!(c.request_ack(seq), Some(true));
 }
 #[test]
 fn rejected_or_unconfirmed_preferences_are_not_inherited() {
  let mut c = Center::default();
  c.set_decoder_fps(60);
  for (seq, kind, value, ack) in [(1, "fps", 60, Some(true)), (2, "quality", 3, Some(true)),
                                   (3, "fps", 144, Some(false)), (4, "quality", 4, None)] {
   c.history.push_back(Setting { seq, request: json!({"kind":kind,"value":value}),
    sent: 1, total: 1, ack, rpc: true });
  }
  let (_, p) = c.portrait_stream(7, 450, 720);
  let setting = body(body(&p, 21).unwrap(), 2).unwrap();
  assert_eq!(number(setting, 1), Some(2));
  assert_eq!(number(setting, 2), Some(3));
  assert_eq!(number(setting, 18), Some(60));
  let mut defaults = Center::default();
  defaults.history.push_back(Setting { seq: 1, request: json!({"kind":"fps","value":144}),
   sent: 1, total: 1, ack: Some(false), rpc: true });
  let (_, p) = defaults.portrait_stream(7, 450, 720);
  assert_eq!(number(body(body(&p, 21).unwrap(), 2).unwrap(), 18), Some(30));
 }
 #[test]
 fn selected_hevc_is_used_in_all_capture_settings() {
  let mut c = Center::default();
  c.set_codec(2);
  c.reported = json!({"fps":60});
  let (_, portrait) = c.portrait_stream(7, 720, 1152);
  assert_eq!(number(body(body(&portrait, 21).unwrap(), 2).unwrap(), 13), Some(2));
  assert_eq!(number(body(body(&portrait, 21).unwrap(), 2).unwrap(), 18), Some(30));
  assert_eq!(c.snapshot()["localSessionFpsLimit"], 30);
  assert!(c.prepare(&json!({"kind":"fps","value":60,"localFpsLimit":60})).is_err());
  let (_, quality) = c.prepare(&json!({"kind":"quality","value":3})).unwrap();
  assert_eq!(number(body(body(&quality[0], 21).unwrap(), 2).unwrap(), 13), Some(2));
  let (_, fps) = c.prepare(&json!({"kind":"fps","value":30,"localFpsLimit":60})).unwrap();
  assert_eq!(number(body(body(&fps[0], 21).unwrap(), 2).unwrap(), 13), Some(2));
  let (_, resolution) = c.prepare(&json!({"kind":"resolution","screenId":7,"width":720,"height":1152})).unwrap();
  assert_eq!(number(body(body(&resolution[0], 21).unwrap(), 2).unwrap(), 13), Some(2));
 }
}
#[cfg(test)] mod privacy_rejection_tests {
 use super::*;
 fn response(seq:u64,case:u32,code:i64,mode:Option<u64>)->Vec<u8>{let mut h=vec![];int(1,seq,&mut h);let mut result=vec![];int(1,code as u64,&mut result);if let Some(mode)=mode{int(2,mode,&mut result);int(3,1,&mut result);}let mut rpc=vec![];bytes(1,&h,&mut rpc);bytes(case,&result,&mut rpc);crate::wire::envelope(seq,22,&rpc)}
 #[test] fn correlated_privacy_error_survives_and_never_becomes_actual_mode(){let mut c=Center::default();c.privacy_support=Some(2);let(seq,_)=c.prepare(&json!({"kind":"privacy","value":3,"confirmed":true})).unwrap();c.sent(seq,1);c.observe(&response(seq,3,7,Some(3)));assert_eq!(c.snapshot()["privacyReplyError"],7);assert_eq!(c.history.back().unwrap().ack,Some(false));assert_eq!(c.privacy_current,None);c.observe(&response(seq+100,3,99,Some(3)));assert_eq!(c.snapshot()["privacyReplyError"],7);}
 #[test] fn screensaver_error_is_correlated_and_visible(){let mut c=Center::default();c.privacy_support=Some(2);let(seq,_)=c.prepare(&json!({"kind":"privacy","value":2,"confirmed":true})).unwrap();c.observe(&response(seq+1,21,-7,None));assert_eq!(c.screensaver_response(seq),Some(false));assert_eq!(c.snapshot()["privacySaverError"],-7);assert_eq!(c.privacy_current,None);}
}
// Cumulative video RTP sequence-loss estimate; finalizes after 128 newer packets.
// Bounded set handles wrap/reorder/duplicates, excludes a late packet after the window.
#[derive(Default)]pub struct Traffic {pub bytes:u64,pub packets:u64,ssrc:Option<u32>,last:u16,highest:u64,next:u64,seen:BTreeSet<u64>,expected:u64,received:u64}
impl Traffic {
 pub fn packet(&mut self,ssrc:u32,seq:u16,bytes:usize){self.bytes+=bytes as u64;self.packets+=1;
  if self.ssrc!=Some(ssrc){self.finalize(self.highest.saturating_add(1));self.seen.clear();self.ssrc=Some(ssrc);self.last=seq;self.highest=65536+seq as u64;self.next=self.highest;}
  let delta=seq.wrapping_sub(self.last) as i16 as i64;let pos=(self.highest as i64+delta).max(0)as u64;
  if delta>0{self.highest=pos;self.last=seq;}
  if pos>=self.next{self.seen.insert(pos);}self.finalize(self.highest.saturating_sub(128));
 }
 fn finalize(&mut self,to:u64){if self.ssrc.is_none()||to<=self.next{return;}let found=self.seen.range(self.next..to).count()as u64;self.expected+=to-self.next;self.received+=found;self.seen=self.seen.split_off(&to);self.next=to;}
 pub fn loss(&self)->Value{let expected=self.expected+if self.ssrc.is_some(){self.highest-self.next+1}else{0};let received=self.received+self.seen.len()as u64;json!({"expected":expected,"receivedUnique":received,"lostEstimate":expected.saturating_sub(received),"lossPercent":if expected>=128{Some(expected.saturating_sub(received)as f64*100.0/expected as f64)}else{None},"method":"video_rtp_sequence_estimate_128_packet_reorder_window"})}
}
pub fn input_allowed(watch:bool,event:&crate::input::InputEvent)->bool{!watch||matches!(event,crate::input::InputEvent::Heartbeat|crate::input::InputEvent::Key{down:false,..}|crate::input::InputEvent::Button{down:false,..})}
#[cfg(test)]mod recovery_tests{
 #[test]fn recovery_all_stream_preferences_preserve_physical_display(){let mut c=super::Center::default();for request in [serde_json::json!({"kind":"quality","value":3}),serde_json::json!({"kind":"fps","value":30,"localFpsLimit":60}),serde_json::json!({"kind":"resolution","screenId":7,"width":1600,"height":2560})]{let(_,packets)=c.prepare(&request).unwrap();let s=super::body(super::body(&packets[0],21).unwrap(),2).unwrap();assert_eq!(super::number(s,4),Some((-2i64)as u64));for field in [5,6]{assert_eq!(super::number(s,field),Some(u64::MAX));}for field in [9,11,16,17]{assert_eq!(super::number(s,field),Some(0));}assert_eq!(super::number(s,10),Some(1));}}
}
#[cfg(test)]mod tests{
 #[test]fn credential_boundary_settings_reject_secret_fields_before_history(){
  for kind in ["quality","fps","resolution","lock_now","reboot","shutdown","privacy","auto_lock","host_mute","unlock"]{
   for key in ["password","credential","secret","pin","token","unknown"]{let mut c=Center::default();let mut request=json!({"kind":kind,"confirmed":true});request[key]=json!("synthetic-secret-never-send");assert!(c.prepare(&request).is_err());assert!(c.history.is_empty());assert!(!c.snapshot().to_string().contains("synthetic-secret"));}
  }
 }
 fn secure_packet(state:&[u8])->Vec<u8>{let mut change=vec![];bytes(1,state,&mut change);crate::wire::envelope(1,15,&change)}
 #[test]fn unlock_lifecycle_unrelated_control_json_heartbeat_and_other_reports_preserve_state(){
  let unrelated=vec![br#"{"action":"kbd_press","key":65}"#.to_vec(),br#"{"heartbeat":"kbd_heartbeat"}"#.to_vec(),br#"{"custom":"~\\u0001"}"#.to_vec(),crate::wire::echo_request(1),crate::wire::echo_response(99,1),crate::wire::envelope(1,13,&[]),crate::wire::envelope(1,15,&[42,0]),vec![0xff]];
  let mut c=Center::default();
  for message in &unrelated{c.observe(message);assert_eq!(c.remote_locked,None);assert_eq!(c.snapshot()["autoUnlockSessionStopReason"],Value::Null);}
  c.observe(&secure_packet(&[8,1,40,1]));
  for message in &unrelated{c.observe(message);assert_eq!(c.remote_locked,Some(true));assert_eq!(c.auto_unlock_supported,Some(true));assert_eq!(c.snapshot()["autoUnlockSessionStopReason"],Value::Null);assert_eq!(c.snapshot()["autoUnlockStateReason"],"unlock_verified_target_and_credential_channel_required");}
 }
 #[test]fn unlock_lifecycle_latest_readback_and_first_stop_reason_are_independent(){
  let locked=secure_packet(&[8,1,40,1]);let unsupported=secure_packet(&[8,1]);let unlocked=secure_packet(&[]);
  let mut c=Center::default();c.observe(&unsupported);assert_eq!(c.snapshot()["autoUnlockStateReason"],"unlock_unsupported");assert_eq!(c.snapshot()["autoUnlockSessionStopReason"],"unlock_unsupported");
  c.observe(&locked);assert_eq!(c.remote_locked,Some(true));assert_eq!(c.auto_unlock_supported,Some(true));assert_eq!(c.snapshot()["autoUnlockStateReason"],"unlock_verified_target_and_credential_channel_required");assert_eq!(c.snapshot()["autoUnlockSessionStopReason"],"unlock_unsupported");
  c.observe(&unlocked);assert_eq!(c.remote_locked,Some(false));assert_eq!(c.snapshot()["autoUnlockStateReason"],"unlock_not_locked");assert_eq!(c.snapshot()["autoUnlockSessionStopReason"],"unlock_unsupported");
  let mut c=Center::default();c.observe(&unlocked);c.observe(&locked);assert_eq!(c.snapshot()["autoUnlockSessionStopReason"],"unlock_already_unlocked");
  c.observe(&secure_packet(&[8,2]));assert_eq!(c.remote_locked,None);assert_eq!(c.snapshot()["autoUnlockStateReason"],"unlock_state_unknown");assert_eq!(c.snapshot()["autoUnlockSessionStopReason"],"unlock_already_unlocked");
  c.close_security();c.observe(&locked);assert_eq!(c.remote_locked,None);assert_eq!(c.snapshot()["autoUnlockStateReason"],"unlock_state_unknown");assert_eq!(c.snapshot()["autoUnlockSessionStopReason"],"unlock_already_unlocked");
 }
 #[test]fn unlock_lifecycle_real_center_entry_is_per_connection_and_terminal(){
  let locked=secure_packet(&[8,1,40,1]);let unlocked=secure_packet(&[]);
  let mut old=Center::default();assert_eq!(old.snapshot()["autoUnlockBlockReason"],"unlock_state_unknown");
  old.observe(&unlocked);old.observe(&locked);assert_eq!(old.snapshot()["autoUnlockBlockReason"],"unlock_already_unlocked");
  let mut next=Center::default();next.observe(&locked);assert_eq!(next.snapshot()["autoUnlockBlockReason"],"unlock_verified_target_and_credential_channel_required");
  next.observe(&locked);assert!(next.unlock_permitted());assert_eq!(next.snapshot()["autoUnlockSessionStopReason"],Value::Null);
  next.close_security();next.observe(&locked);assert_eq!(next.remote_locked,None);assert_eq!(next.snapshot()["autoUnlockBlockReason"],"unlock_session_revoked");
  let mut fresh=Center::default();fresh.observe(&locked);old.observe(&unlocked);assert_eq!(fresh.snapshot()["autoUnlockBlockReason"],"unlock_verified_target_and_credential_channel_required");
  fresh.begin_end_media();fresh.observe(&locked);assert_eq!(fresh.snapshot()["autoUnlockBlockReason"],"unlock_session_revoked");
  assert_eq!(fresh.snapshot()["autoUnlockAvailable"],false);assert!(fresh.history.is_empty());
 }
 #[test]fn unlock_lifecycle_malformed_duplicate_and_revocation_never_rearm(){
  let locked=secure_packet(&[8,1,40,1]);
  let mut duplicate=vec![];bytes(1,&[8,1],&mut duplicate);bytes(1,&[8,1],&mut duplicate);
  let mut duplicate_outer=locked.clone();duplicate_outer.extend_from_slice(&locked);
  for invalid in [secure_packet(&[8,2]),secure_packet(&[8,1,8,1]),crate::wire::envelope(1,15,&duplicate),duplicate_outer,secure_packet(&[8])]{
   let mut c=Center::default();c.observe(&locked);c.observe(&invalid);assert_eq!(c.remote_locked,None);c.observe(&locked);assert_eq!(c.snapshot()["autoUnlockBlockReason"],"unlock_invalid_state");
  }
  let mut c=Center::default();c.revoke_unlock();c.observe(&locked);assert_eq!(c.snapshot()["autoUnlockBlockReason"],"unlock_session_revoked");
 }
 #[test]fn handshake_stream_scaling_preserves_windows_physical_modes(){let mut c=super::Center::default();for value in ["720p","1080p","fit"]{let(_,packets)=c.prepare(&serde_json::json!({"kind":"resolution","value":value,"screenId":7,"width":1600,"height":2560})).unwrap();let s=super::body(super::body(&packets[0],21).unwrap(),2).unwrap();for f in [5,6]{assert_eq!(super::number(s,f),Some(u64::MAX));}for f in [16,17]{assert_eq!(super::number(s,f),Some(0));}assert_eq!(super::number(s,10),Some(1));assert_eq!(super::number(s,14),Some(1600));assert_eq!(super::number(s,15),Some(2560));}}
 #[test]fn watch_blocks_new_input_but_preserves_release(){use crate::input::InputEvent as E;assert!(!super::input_allowed(true,&E::Text("test".into())));assert!(!super::input_allowed(true,&E::Absolute{x:0.5,y:0.5}));assert!(!super::input_allowed(true,&E::Key{key:65,down:true}));assert!(!super::input_allowed(true,&E::Scroll{x:0,y:120}));assert!(super::input_allowed(true,&E::Key{key:65,down:false}));assert!(super::input_allowed(true,&E::Button{button:1,down:false}));assert!(super::input_allowed(false,&E::Text("test".into())));}
 use super::*;

 #[test]
 fn hevc_fps_uses_decoder_and_matching_host_report() {
  let mut c = Center::default();
  c.set_codec(2);
  c.set_decoder_fps(60);
  let request = json!({"kind":"fps","value":60,"localFpsLimit":60});
  let mut caps = vec![];
  for (codec, fps, width, height) in [(1, 20, 1280, 720), (2, 60, 1920, 1080)] {
   let mut cap = vec![];
   for (field, value) in [(1, 1), (2, fps), (3, codec), (4, width), (5, height)] {
    int(field, value, &mut cap);
   }
   bytes(1, &cap, &mut caps);
  }
  c.observe(&crate::wire::envelope(12,18,&caps));
  assert_eq!(c.snapshot()["remoteMaxFps"], 60);
  assert_eq!(c.snapshot()["remoteCapHeight"], 1080);
  let (seq, packets) = c.prepare(&request).unwrap();
  let setting = body(body(&packets[0], 21).unwrap(), 2).unwrap();
  assert_eq!(number(setting,1), Some(2));
  assert_eq!(number(setting,13), Some(2));
  assert_eq!(number(setting,18), Some(60));
  c.sent(seq, 1);
  let (_, packets) = c.prepare(&json!({"kind":"quality","value":3})).unwrap();
  let setting = body(body(&packets[0], 21).unwrap(), 2).unwrap();
  assert_eq!(number(setting,18), Some(60));
  c.set_decoder_fps(30);
  assert_eq!(c.prepare(&request).unwrap_err(), "fps_capability_limited");
 }
 #[test]fn quality_wire_and_limits(){let mut c=Center::default();let(_,p)=c.prepare(&json!({"kind":"quality","value":3})).unwrap();assert_eq!(number(body(body(&p[0],21).unwrap(),2).unwrap(),2),Some(3));assert!(c.prepare(&json!({"kind":"fps","value":144,"localFpsLimit":60})).is_err());c.remote_fps=Some(30);assert!(c.prepare(&json!({"kind":"fps","value":60,"localFpsLimit":60})).is_err());}
 #[test]fn sensitive_confirmation_and_two_step_mute(){let mut c=Center::default();assert!(c.prepare(&json!({"kind":"host_mute","enabled":true})).is_err());let(_,p)=c.prepare(&json!({"kind":"host_mute","enabled":true,"confirmed":true})).unwrap();assert_eq!(p.len(),2);assert_eq!(number(body(&p[0],3).unwrap(),1),Some(14));assert_eq!(number(body(&p[1],3).unwrap(),1),Some(18));}
 #[test]fn ack_not_fabricated_and_correlated(){let mut c=Center::default();let(seq,_)=c.prepare(&json!({"kind":"quality","value":5})).unwrap();c.sent(seq,1);assert!(c.history[0].ack.is_none());let mut h=vec![];int(1,seq+1,&mut h);let mut r=vec![];bytes(1,&h,&mut r);bytes(2,&[],&mut r);c.observe(&crate::wire::envelope(0,22,&r));assert!(c.history[0].ack.is_none());h.clear();int(1,seq,&mut h);r.clear();bytes(1,&h,&mut r);bytes(2,&[],&mut r);c.observe(&crate::wire::envelope(0,22,&r));assert_eq!(c.history[0].ack,Some(true));}
 #[test]fn partial_mute_does_not_claim_sent(){let mut c=Center::default();let(seq,_)=c.prepare(&json!({"kind":"host_mute","enabled":true,"confirmed":true})).unwrap();c.sent(seq,1);assert_eq!(c.snapshot()["settings"][0]["sent"],false);}
 #[test]fn display_zero_code_reply_is_success_and_error_reply_is_failure(){let mut c=Center::default();let(seq,_)=c.prepare(&json!({"kind":"resolution","screenId":0,"width":2560,"height":1600})).unwrap();let mut header=vec![];int(1,seq,&mut header);let mut response=vec![];bytes(1,&[],&mut response);let mut rpc=vec![];bytes(1,&header,&mut rpc);bytes(2,&response,&mut rpc);c.observe(&crate::wire::envelope(0,22,&rpc));assert_eq!(c.history[0].ack,Some(true));let mut failure=vec![];int(1,2,&mut failure);response.clear();bytes(1,&failure,&mut response);rpc.clear();bytes(1,&header,&mut rpc);bytes(2,&response,&mut rpc);c.observe(&crate::wire::envelope(0,22,&rpc));assert_eq!(c.history[0].ack,Some(false));}
 #[test]fn display_dimensions_native_portrait_and_wire(){let mut c=Center::default();for(w,h)in[(2560,1600),(1600,2560),(2560,1440),(1980,1080),(3840,2160)]{let(_,p)=c.prepare(&json!({"kind":"resolution","width":w,"height":h,"screenId":7})).unwrap();let s=body(body(&p[0],21).unwrap(),2).unwrap();assert_eq!(number(s,4),Some((-2i64)as u64));assert_eq!(number(s,5),Some(u64::MAX));assert_eq!(number(s,6),Some(u64::MAX));assert_eq!(number(s,14),Some(w));assert_eq!(number(s,15),Some(h));assert_eq!(number(s,16),Some(0));assert_eq!(number(s,17),Some(0));}for(w,h)in[(1921,1080),(0,1080),(8194,1080)]{assert!(c.prepare(&json!({"kind":"resolution","width":w,"height":h,"screenId":0})).is_err());}assert!(c.prepare(&json!({"kind":"resolution","width":2560,"height":1600})).is_err());let(_,p)=c.prepare(&json!({"kind":"resolution","value":"remote","screenId":0,"width":1600,"height":2560,"logicalWidth":800,"logicalHeight":1280})).unwrap();let s=body(body(&p[0],21).unwrap(),2).unwrap();assert_eq!(number(s,10),Some(1));assert_eq!(number(s,4),Some((-2i64) as u64));assert_eq!(number(s,5),Some(u64::MAX));assert_eq!(number(s,6),Some(u64::MAX));assert_eq!(number(s,16),Some(0));assert_eq!(number(s,17),Some(0));assert_eq!(number(s,2),Some(4));assert_eq!(number(s,14),Some(1600));}
 #[test]fn rtp_wrap_duplicate_reorder_and_gap(){let mut t=Traffic::default();for s in [65534,0,65535,0,2]{t.packet(1,s,100)}assert_eq!(t.loss()["lostEstimate"],1);t.packet(1,1,100);assert_eq!(t.loss()["lostEstimate"],0);assert_eq!(t.bytes,600);assert_eq!(t.loss()["receivedUnique"],5);for i in 3..200{t.packet(1,i,100)}assert_eq!(t.loss()["lossPercent"],0.0);}
}

#[cfg(test)]mod system_action_tests {
 use super::*;
 #[test]fn restricted_actions_require_confirmation_and_never_fabricate_ack(){
  for(kind,n)in[("lock_now",10),("reboot",9),("shutdown",12)]{
   let mut c=Center::default();assert!(c.prepare(&json!({"kind":kind})).is_err());assert_eq!(c.history.len(),0);
   let(seq,packets)=c.prepare(&json!({"kind":kind,"confirmed":true})).unwrap();assert_eq!(packets.len(),1);
   let fields=body(&packets[0],3).unwrap();assert_eq!(number(fields,1),Some(n));assert!(body(fields,2).is_none());
   c.sent(seq,1);assert_eq!(c.snapshot()["settings"][0]["sent"],true);assert_eq!(c.snapshot()["settings"][0]["remoteAck"],Value::Null);assert_eq!(c.snapshot()["settings"][0]["ackSupported"],false);
  }
  for kind in ["terminal","launch","exec","unlock","privacy"]{assert!(Center::default().prepare(&json!({"kind":kind,"confirmed":true})).is_err());}
 }
}

#[cfg(test)]mod privacy_tests{
 #[test]fn current_mode_from_response_survives_saved_default_in_metrics(){
  let mut c=super::Center::default();c.privacy_support=Some(2);
  let(seq,_)=c.prepare(&serde_json::json!({"kind":"privacy","value":3,"confirmed":true})).unwrap();c.sent(seq,1);
  let mut h=vec![];super::int(1,seq,&mut h);let mut result=vec![];super::int(2,3,&mut result);super::int(3,3,&mut result);let mut rpc=vec![];super::bytes(1,&h,&mut rpc);super::bytes(3,&result,&mut rpc);c.observe(&crate::wire::envelope(1,22,&rpc));assert_eq!(c.privacy_current,Some(3));
  let mut settings=vec![];super::int(7,1,&mut settings);let mut metrics=vec![];super::bytes(4,&settings,&mut metrics);c.observe(&crate::wire::envelope(2,13,&metrics));assert_eq!(c.privacy_current,Some(3));
  c.observe(&crate::wire::envelope(3,15,&[42,4,16,1,24,1]));assert_eq!(c.privacy_current,Some(1));assert!(!c.privacy_owned);
 }
 #[test]fn routine_stream_updates_do_not_own_physical_modes(){
  let mut c=super::Center::default();for req in [serde_json::json!({"kind":"quality","value":4}),serde_json::json!({"kind":"fps","value":30,"localFpsLimit":30})]{
   let(_,packets)=c.prepare(&req).unwrap();let s=super::body(super::body(&packets[0],21).unwrap(),2).unwrap();assert_eq!(super::number(s,10),Some(1));assert_eq!(super::number(s,5),Some(u64::MAX));assert_eq!(super::number(s,6),Some(u64::MAX));
  }
 }
 use super::*;
 #[test]fn no_capability_no_enable_and_correlated_state(){let mut c=Center::default();let req=json!({"kind":"privacy","value":3,"confirmed":true});assert!(c.prepare(&req).is_err());
 let mut flags=vec![];int(4,2,&mut flags);let mut echo=vec![];int(1,1,&mut echo);bytes(4,&flags,&mut echo);c.observe(&crate::wire::envelope(1,3,&echo));assert_eq!(c.privacy_support,Some(2));
 assert!(c.prepare(&json!({"kind":"privacy","value":3})).is_err());assert!(c.prepare(&json!({"kind":"privacy","value":4,"confirmed":true})).is_err());
 let(seq,p)=c.prepare(&req).unwrap();let rpc=body(&p[0],21).unwrap();assert_eq!(number(body(rpc,7).unwrap(),2),Some(3));c.sent(seq,1);assert!(c.privacy_owned);assert_eq!(c.history.back().unwrap().ack,None);
 let mut h=vec![];int(1,seq,&mut h);let mut result=vec![];int(2,3,&mut result);int(3,3,&mut result);let mut rsp=vec![];bytes(1,&h,&mut rsp);bytes(3,&result,&mut rsp);c.observe(&crate::wire::envelope(2,22,&rsp));assert_eq!(c.privacy_current,Some(3));assert_eq!(c.history.back().unwrap().ack,Some(true));let state=vec![42,4,16,3,24,3];c.observe(&crate::wire::envelope(4,15,&state));assert_eq!(c.privacy_current,Some(3));
 let(seq,_)=c.prepare(&json!({"kind":"privacy","value":1,"confirmed":true})).unwrap();c.sent(seq,1);assert!(c.privacy_owned);let mut header=vec![];int(1,seq,&mut header);let mut result=vec![];int(2,1,&mut result);int(3,1,&mut result);let mut rsp=vec![];bytes(1,&header,&mut rsp);bytes(3,&result,&mut rsp);c.observe(&crate::wire::envelope(3,22,&rsp));assert!(!c.privacy_owned);let state=vec![42,4,16,1,24,1];c.observe(&crate::wire::envelope(5,15,&state));assert!(!c.privacy_owned);
 }
}

#[cfg(test)]mod security_state_tests{
 use super::*;
 fn echo(c:&mut Center,metrics:u64,privacy:u64){let mut flags=vec![];int(3,metrics,&mut flags);int(4,privacy,&mut flags);let mut a=vec![];int(1,1,&mut a);bytes(4,&flags,&mut a);c.observe(&crate::wire::envelope(1,3,&a));}
 fn metrics(c:&mut Center,value:Option<u64>,sections:bool){let mut setting=vec![];if let Some(v)=value{int(3,v,&mut setting);}let mut m=vec![];if sections{bytes(1,&[1,2],&mut m);}bytes(4,&setting,&mut m);c.observe(&crate::wire::envelope(2,13,&m));}
 #[test]fn auto_lock_unknown_is_not_local_false_and_reports_do_not_write_preferences(){let mut c=Center::default();metrics(&mut c,None,true);assert_eq!(c.remote_auto_lock,None);echo(&mut c,2,0);metrics(&mut c,None,true);assert_eq!(c.remote_auto_lock,Some(false));metrics(&mut c,Some(1),true);assert_eq!(c.remote_auto_lock,Some(true));let(seq,_)=c.prepare(&json!({"kind":"auto_lock","enabled":false,"confirmed":true})).unwrap();c.sent(seq,1);assert_eq!(c.remote_auto_lock,Some(true));metrics(&mut c,Some(2),true);assert_eq!(c.remote_auto_lock,Some(true));metrics(&mut c,Some(0),true);assert_eq!(c.remote_auto_lock,Some(false));}
 #[test]fn secure_desktop_reports_are_capabilities_not_unlock_actions(){let mut c=Center::default();assert_eq!(c.remote_locked,None);assert_eq!(c.auto_unlock_supported,None);let mut state=vec![];int(1,1,&mut state);int(5,1,&mut state);let mut change=vec![];bytes(1,&state,&mut change);c.observe(&crate::wire::envelope(1,15,&change));assert_eq!(c.remote_locked,Some(true));assert_eq!(c.auto_unlock_supported,Some(true));assert!(c.history.is_empty());assert!(c.prepare(&json!({"kind":"unlock","confirmed":true})).is_err());c.observe(&crate::wire::envelope(2,15,&[10,2,8,2]));assert_eq!(c.remote_locked,None);assert_eq!(c.auto_unlock_supported,None);c.observe(&crate::wire::envelope(3,15,&[10,0]));assert_eq!(c.remote_locked,Some(false));assert_eq!(c.auto_unlock_supported,Some(false));}
 #[test]fn picture_mode_requires_host_capability_and_correlated_screensaver_response(){let mut c=Center::default();let req=json!({"kind":"privacy","value":2,"confirmed":true});assert!(c.prepare(&req).is_err());echo(&mut c,3,1);assert!(c.prepare(&json!({"kind":"privacy","value":3,"confirmed":true})).is_err());let(seq,p)=c.prepare(&req).unwrap();assert_eq!(p.len(),2);assert!(body(body(&p[0],21).unwrap(),25).is_some());assert_eq!(number(body(body(&p[1],21).unwrap(),7).unwrap(),2),Some(2));assert_eq!(c.screensaver_response(seq),None);let mut header=vec![];int(1,seq+2,&mut header);let mut rpc=vec![];bytes(1,&header,&mut rpc);bytes(21,&[],&mut rpc);c.observe(&crate::wire::envelope(2,22,&rpc));assert_eq!(c.screensaver_response(seq),None);header.clear();int(1,seq+1,&mut header);rpc.clear();bytes(1,&header,&mut rpc);bytes(21,&[],&mut rpc);c.observe(&crate::wire::envelope(3,22,&rpc));assert_eq!(c.screensaver_response(seq),Some(true));c.sent(seq,1);assert!(!c.privacy_owned);c.sent(seq,2);assert!(c.privacy_owned);assert_eq!(c.privacy_current,None);}
 #[test]fn media_end_is_single_use_per_peer_and_emits_no_lock_or_preference_setting(){let mut c=Center::default();assert!(c.begin_end_media());assert!(!c.begin_end_media());assert!(c.history.is_empty());assert_eq!(c.remote_auto_lock,None);assert!(Center::default().begin_end_media());}
 #[test]fn screensaver_rejection_and_privacy_report_error_never_claim_physical_success(){let mut c=Center::default();echo(&mut c,3,1);let(seq,_)=c.prepare(&json!({"kind":"privacy","value":2,"confirmed":true})).unwrap();let mut header=vec![];int(1,seq+1,&mut header);let mut rpc=vec![];bytes(1,&header,&mut rpc);bytes(21,&[8,1],&mut rpc);c.observe(&crate::wire::envelope(2,22,&rpc));assert_eq!(c.screensaver_response(seq),Some(false));assert_eq!(c.privacy_current,None);let mut report=vec![];int(2,(-7i64)as u64,&mut report);c.observe(&crate::wire::envelope(3,12,&report));assert_eq!(c.snapshot()["privacyError"],"privacy_remote_failure");assert_eq!(c.privacy_current,None);}
 #[test]fn auto_lock_requires_reported_capability_and_fresh_remote_readback(){let mut c=Center::default();let req=json!({"kind":"auto_lock","enabled":true,"confirmed":true});assert_eq!(c.prepare(&req).unwrap_err(),"remote_auto_lock_capability_required");echo(&mut c,2,0);metrics(&mut c,Some(0),true);let(seq,p)=c.prepare(&req).unwrap();let action=body(&p[0],3).unwrap();assert_eq!(number(action,1),Some(19));assert_eq!(number(action,5),Some(2));c.sent(seq,1);assert_eq!(c.remote_auto_lock,Some(false));assert_eq!(c.history.back().unwrap().ack,None);metrics(&mut c,Some(1),true);assert_eq!(c.history.back().unwrap().ack,Some(true));assert_eq!(c.remote_auto_lock,Some(true));}

 #[test]fn official_security_query_transitions_unknown_to_capable_without_writing(){let mut c=Center::default();let p=c.security_query();assert_eq!(body(&p,13),Some([10,3,0,1,2].as_slice()));assert!(c.history.is_empty());assert_eq!(c.remote_auto_lock,None);assert_eq!(c.privacy_support,None);echo(&mut c,3,2);metrics(&mut c,Some(0),true);assert!(c.auto_lock_supported);assert_eq!(c.remote_auto_lock,Some(false));assert_eq!(c.privacy_support,Some(2));let(seq,p)=c.prepare(&json!({"kind":"auto_lock","enabled":true,"confirmed":true})).unwrap();assert_eq!(number(body(&p[0],3).unwrap(),1),Some(19));c.sent(seq,1);assert_eq!(c.history.back().unwrap().ack,None);let query=c.security_query();assert!(body(&query,13).is_some());assert_eq!(c.remote_auto_lock,Some(false));metrics(&mut c,Some(1),true);assert_eq!(c.history.back().unwrap().ack,Some(true));}

 #[test]fn tool_lock_is_one_attempt_and_never_a_desktop_or_setting(){let mut c=Center::default();for e in [json!({"kind":"watch","enabled":true}),json!({"kind":"auto_lock","enabled":false,"confirmed":true}),json!({"kind":"reboot","confirmed":true}),json!({"kind":"lock_now"})]{assert!(c.tool_lock_allowed(&e).is_err());}let e=json!({"kind":"lock_now","confirmed":true});assert!(c.tool_lock_allowed(&e).is_ok());let(seq,p)=c.prepare(&e).unwrap();assert_eq!(p.len(),1);assert_eq!(number(body(&p[0],3).unwrap(),1),Some(10));assert!(c.tool_lock_allowed(&e).is_err());c.sent(seq,0);assert!(c.tool_lock_allowed(&e).is_err());assert_eq!(c.remote_auto_lock,None);}

}
