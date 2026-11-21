// SPDX-License-Identifier: GPL-3.0-only
// Pure protocol adapter from uu-remote-linux @ 6bf05a6361e58dbeec5846f044d234bed04fcf02.
use base64::{Engine,engine::general_purpose::STANDARD as B64};
use serde_json::{json,Value};
use std::{collections::VecDeque,io::Read};
use zeroize::Zeroize;
#[derive(Default)]
pub struct SignalCore {
 capture_type:u32,multi_video:bool,shape:Option<crate::wire::Shape>,state:String,message:String,app:String,ice:String,proposed:String,remote:String,local:String,device:String,
 now:u64,began:u64,stage_at:u64,ping_at:u64,ping_window:u64,timeout:u64,
 offer_delay:u64,ack_at:u64,offer_elapsed:u64,pending_peer:Option<Value>,
 text_frames:u64,binary_headers:u64,unknown_frames:u64,events:u64,unknown_events:u64,unknown_soac:u64,
 binary:Option<Binary>,early:VecDeque<Value>,
 opened:bool,connected:bool,ack:bool,app_match:bool,ice_changed:bool,remote_differs:bool,
 pings:u64,attachments:u64,answers:u64,remote_candidates:u64,offers:u64,local_candidates:u64,ignored:u64,
}
struct Binary { ack:Option<u64>,value:Value,count:usize,parts:Vec<String>,bytes:usize }
fn random_id(uuid:bool)->Result<String,&'static str>{let mut b=[0u8;16];getrandom::getrandom(&mut b).map_err(|_|"secure_random_failed")?;b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;let s=hex::encode(b);Ok(if uuid{format!("{}-{}-{}-{}-{}",&s[..8],&s[8..12],&s[12..16],&s[16..20],&s[20..])}else{s})}
fn options(device:&str)->Vec<u8>{crate::wire::desktop_shape().connect_options(device,false).expect("fixed desktop shape")}
fn options_for(device:&str,capture:u32,multi:bool)->Vec<u8>{let mut shape=crate::wire::desktop_shape();shape.capture_type=capture;if capture!=1{shape.feature_flag.clear();}shape.connect_options_multi(device,false,multi).expect("validated capture shape")}
fn attachment(device:&str,capture:u32,multi:bool)->Vec<u8>{let mut b=vec![4];b.extend(options_for(device,capture,multi));b}
fn text(s:String)->Value{json!({"kind":"text","text":s})}
impl SignalCore {
 fn view(&self)->Value{json!({"state":self.state,"message":self.message,"engineOpen":self.opened,"socketConnected":self.connected,"controlAck":self.ack,"appControlIdMatches":self.app_match,"serverIceReassigned":self.ice_changed,"remoteClientDiffersFromLocal":self.remote_differs,"pings":self.pings,"attachments":self.attachments,"answers":self.answers,"remoteCandidates":self.remote_candidates,"offers":self.offers,"localCandidates":self.local_candidates,"ignoredRoutesOrAcks":self.ignored,"offerDelayMs":self.offer_delay,"offerElapsedMs":self.offer_elapsed,"textFrames":self.text_frames,"binaryHeaders":self.binary_headers,"unknownFrames":self.unknown_frames,"events":self.events,"unknownEvents":self.unknown_events,"unknownSoac":self.unknown_soac})}
 fn reply(&self,actions:Vec<Value>)->Value{json!({"signal":self.view(),"actions":actions})}
 fn wipe(&mut self){for s in [&mut self.app,&mut self.ice,&mut self.proposed,&mut self.remote,&mut self.local,&mut self.device]{s.zeroize();}self.shape=None;self.binary=None;self.pending_peer=None;self.early.clear();}
 fn end(&mut self,state:&str,reason:&str)->Value{let active=self.active();self.state=state.into();self.message=reason.into();self.wipe();self.reply(if active{vec![text("41".into()),json!({"kind":"close"})]}else{vec![]})}
 fn fail(&mut self,s:&str)->Value{self.end("failed",s)}
 pub(crate) fn active(&self)->bool{matches!(self.state.as_str(),"engine_wait"|"socket_wait"|"control_wait"|"offer_wait"|"ready")}
 pub fn start(&mut self,room:Value,client:&str,device:&str,now_ms:u64)->Value{
  self.wipe();*self=Self::default();self.now=now_ms;self.began=now_ms;self.stage_at=now_ms;self.ping_at=now_ms;
  let token=room["token"].as_str().unwrap_or("");let url=room["signaling_list"][0].as_str().unwrap_or("");
  let allowed=url.starts_with("wss://")||url=="ws://127.0.0.1:18763";
  if !allowed||url.len()>4096||url.chars().any(char::is_control)||url.contains('@')||url.contains('?')||url.contains('#')||token.is_empty()||token.len()>8192||token.chars().any(char::is_control)||device.len()>1024{return self.fail("invalid_room_transport")}
  let (Ok(app),Ok(ice))=(random_id(true),random_id(false))else{return self.fail("secure_random_failed")};
  self.multi_video=room["multi_video"]==true;self.capture_type=match room["capture_type"].as_u64(){Some(5)=>5,Some(7)=>7,Some(8)=>8,_=>1};
  let mut shape=crate::wire::desktop_shape();
  let Some(client_type)=room["client_type"].as_u64().filter(|v|[2,3].contains(v)) else{return self.fail("local_device_type_unknown")};
  shape.platform=client_type as u32;
  if let Some(a)=room["decoder_envelope"].as_array().filter(|a|a.len()==5){let(Some(w),Some(h),Some(codec))=(a[0].as_u64().filter(|n|(2..=8192).contains(n)),a[1].as_u64().filter(|n|(2..=8192).contains(n)),a[2].as_u64().filter(|n|[1,2].contains(n)))else{return self.fail("primary_decoder_not_ready")};if codec==2&&a[3].as_u64().and_then(|n|u32::try_from(n).ok()).and_then(crate::nal_policy::hevc_fmtp).is_none(){return self.fail("hevc_level_unverified")}let Some(fps)=a[4].as_u64().filter(|n|(1..=60).contains(n))else{return self.fail("primary_decoder_not_ready")};shape.decoders=vec![crate::wire::Decoder{fps:fps as u32,codec:codec as u32,width:w as u32,height:h as u32,chroma:1}];shape.codecs=vec![crate::wire::Codec{video_codec:codec as u32,chroma_sampling:1,codec_impl:if codec==1{Some(34)}else{None},bit_depth:8,width:w as u32,height:h as u32}];}else if self.multi_video{return self.fail("primary_decoder_not_ready")}
  self.shape=Some(shape);
  self.offer_delay=room["offer_delay_ms"].as_u64().unwrap_or(0).min(3000);
  self.app=app;self.ice=ice.clone();self.proposed=ice;self.local=client.into();self.device=device.into();self.timeout=room["ws_connect_timeout_ms"].as_u64().unwrap_or(12000).clamp(1000,12000);self.ping_window=45000;self.state="engine_wait".into();self.message="waiting_for_engine_open".into();
  self.reply(vec![json!({"kind":"connect","url":format!("{}/socket.io/?transport=websocket&EIO=4",url.trim_end_matches('/')),"headers":{"X-NRD-AUTH":token}})])
 }
 pub fn call(&mut self,v:Value)->Value{
  self.now=self.now.max(v["nowMs"].as_u64().unwrap_or(self.now));
  let op=v["op"].as_str().unwrap_or("");
  if op=="signal_cancel"{return self.end("cancelled","cancelled_and_credentials_cleared")}
  if !self.active(){return self.reply(vec![])}
  if self.answers==0&&self.now.saturating_sub(self.began)>=45000{return self.end("timed_out","overall_timeout")}
  if matches!(self.state.as_str(),"engine_wait"|"socket_wait"|"control_wait")&&self.now.saturating_sub(self.stage_at)>=self.timeout{return self.end("timed_out",if self.state=="control_wait"{"control_ack_timeout"}else{"handshake_timeout"})}
  if self.opened&&self.now.saturating_sub(self.ping_at)>self.ping_window{return self.end("timed_out","engine_heartbeat_timeout")}
  match op {
   "signal_tick"=>{if self.state=="offer_wait"&&self.now.saturating_sub(self.ack_at)>=self.offer_delay {self.state="ready".into();self.message="offer_delay_elapsed".into();let c=self.pending_peer.take();let mut r=self.reply(vec![]);if let Some(c)=c{r["peerConfig"]=c;}return r;}if self.state=="ready"{if let Some(e)=self.early.pop_front(){return self.event(e)}}self.reply(vec![])},
   "signal_text"=>self.receive_text(v["text"].as_str().unwrap_or("")),
   "signal_binary"=>self.receive_binary(v["base64"].as_str().unwrap_or("")),
   "signal_offer"=>{if self.state!="ready"{return self.fail("offer_before_control_ack")};let s=v["sdp"].as_str().unwrap_or("");if s.is_empty()||s.len()>1048576{return self.fail("invalid_offer")};self.offers+=1;self.offer_elapsed=self.now.saturating_sub(self.ack_at);self.soac(json!({"type":"offer","sdp":s,"ice_network_type":3}))},
   "signal_candidate"=>{if self.state!="ready"{return self.fail("candidate_before_control_ack")};let c=&v["candidate"];if !c.is_object()||c.to_string().len()>16384{return self.fail("invalid_candidate")};self.local_candidates+=1;self.soac(json!({"type":"candidate","candidate":c}))},
   _=>self.reply(vec![])
  }
 }
 fn soac(&self,mut data:Value)->Value{data["app_control_id"]=json!(self.app);data["ice_id"]=json!(self.ice);self.reply(vec![text(format!("42{}",json!(["soac",{"client_id":self.remote,"data":data}])))])}
 fn receive_text(&mut self,t:&str)->Value{
  self.text_frames+=1;
  if t.len()>1048576{return self.fail("text_frame_limit")}
  if let Some(payload)=t.strip_prefix('2'){self.ping_at=self.now;self.pings+=1;return self.reply(vec![text(format!("3{payload}"))])}
  if t=="41"||t=="1"{return self.end("closed","server_room_closed")}
  if t.starts_with("44"){return self.fail("socket_connect_rejected")}
  if self.state=="engine_wait" {
   let Some(s)=t.strip_prefix('0')else{return self.fail("expected_engine_open")};let Ok(o)=serde_json::from_str::<Value>(s)else{return self.fail("invalid_engine_open")};
   let (Some(interval),Some(timeout))=(o["pingInterval"].as_u64(),o["pingTimeout"].as_u64())else{return self.fail("missing_heartbeat_parameters")};
   if !o["sid"].is_string()||interval==0||timeout==0||interval>120000||timeout>120000{return self.fail("invalid_engine_open")};
   self.opened=true;self.ping_window=interval+timeout;self.ping_at=self.now;self.stage_at=self.now;self.state="socket_wait".into();return self.reply(vec![text("40".into())])
  }
  if self.state=="socket_wait" {
   if !t.starts_with("40"){return self.fail("expected_socket_connect")};if t.len()>2&&serde_json::from_str::<Value>(&t[2..]).is_err(){return self.fail("invalid_socket_connect")};
   self.connected=true;self.stage_at=self.now;self.state="control_wait".into();self.message="control_sent_waiting_ack".into();
   let mut shape=self.shape.clone().expect("shape stored at start");let header=shape.control(&self.local,&self.app,&self.ice).expect("fixed desktop shape");shape.capture_type=self.capture_type;if self.capture_type!=1{shape.feature_flag.clear();}let mut body=vec![4];body.extend(shape.connect_options_multi(&self.device,false,self.multi_video).expect("validated capture shape"));
   return self.reply(vec![text(format!("451-11{}",json!(["control",header]))),json!({"kind":"binary","base64":B64.encode(body)})])
  }
  if t.starts_with("45")||t.starts_with("46") {
   self.binary_headers+=1;
   if self.binary.is_some(){return self.fail("overlapping_binary_packet")};let Some(dash)=t.find('-')else{return self.fail("invalid_binary_header")};let Some(begin)=t.find('[')else{return self.fail("invalid_binary_body")};
   let Ok(count)=t[2..dash].parse::<usize>()else{return self.fail("invalid_attachment_count")};if count==0||count>8||begin<=dash{return self.fail("invalid_attachment_count")};
   let ack=if t.starts_with("46"){match t[dash+1..begin].parse::<u64>(){Ok(id)=>Some(id),_=>return self.fail("invalid_binary_ack")}}else{None};
   let Ok(value)=serde_json::from_str::<Value>(&t[begin..])else{return self.fail("invalid_binary_body")};self.binary=Some(Binary{ack,value,count,parts:vec![],bytes:0});return self.reply(vec![])
  }
  if self.binary.is_some(){return self.fail("text_interleaves_binary_attachments")}
  if t.starts_with("43") {let Some(begin)=t.find('[')else{return self.fail("invalid_ack")};let Ok(id)=t[2..begin].parse::<u64>()else{return self.fail("invalid_ack_id")};let Ok(v)=serde_json::from_str::<Value>(&t[begin..])else{return self.fail("invalid_ack_json")};return self.packet(Some(id),v)}
  if t.starts_with("42"){let Some(begin)=t.find('[')else{return self.fail("invalid_event")};let Ok(v)=serde_json::from_str::<Value>(&t[begin..])else{return self.fail("invalid_event_json")};return self.packet(None,v)}
  self.unknown_frames+=1;self.reply(vec![])
 }
 fn receive_binary(&mut self,s:&str)->Value{
  let Some(mut p)=self.binary.take()else{return self.fail("unsolicited_binary")};
  if s.len()>1500000{return self.fail("binary_frame_limit")};let Ok(mut b)=B64.decode(s)else{return self.fail("invalid_base64_bridge")};
  if b.len()>2&&b[0]==4&&b[1]==0x1f&&b[2]==0x8b{b.remove(0);}
  p.bytes+=b.len();if b.len()>1048576||p.bytes>4*1048576{return self.fail("attachment_limit")};p.parts.push(B64.encode(&b));self.attachments+=1;
  if p.parts.len()<p.count{self.binary=Some(p);return self.reply(vec![])}
  fn fill(v:&mut Value,a:&[String])->Result<(),()>{match v{Value::Object(o)if o.get("_placeholder")==Some(&Value::Bool(true))=>{let i=o.get("num").and_then(Value::as_u64).and_then(|n|usize::try_from(n).ok()).ok_or(())?;*v=Value::String(a.get(i).ok_or(())?.clone());},Value::Object(o)=>{for x in o.values_mut(){fill(x,a)?}},Value::Array(a2)=>{for x in a2{fill(x,a)?}},_=>{}}Ok(())}
  if fill(&mut p.value,&p.parts).is_err(){return self.fail("invalid_attachment_placeholder")};self.packet(p.ack,p.value)
 }
 fn packet(&mut self,ack:Option<u64>,v:Value)->Value{
  if let Some(id)=ack {
   if self.state!="control_wait"||id!=11{self.ignored+=1;return self.reply(vec![])}
   let Some(a)=v.as_array().filter(|a|a.len()==2&&a[0]=="success"&&a[1].is_object())else{return self.fail("control_refused_or_malformed")};let c=&a[1];
   if c.get("app_control_id").is_some_and(|x|x.as_str()!=Some(&self.app)){return self.fail("control_app_id_mismatch")}
   self.app_match=c["app_control_id"].as_str()==Some(&self.app);
   let Some(remote)=c["client_id"].as_str().filter(|s|!s.is_empty()&&s.len()<=1024)else{return self.fail("control_missing_peer_route")};
   if !c["iceServers"].is_array(){return self.fail("control_missing_ice_servers")};self.remote=remote.into();self.remote_differs=self.remote!=self.local;
   if let Some(ice)=c["ice_id"].as_str().filter(|s|!s.is_empty()&&s.len()<=128){self.ice=ice.into();}else if c.get("ice_id").is_some(){return self.fail("invalid_server_ice_id")}
   self.ice_changed=self.ice!=self.proposed;self.ack=true;self.ack_at=self.now;self.state=if self.offer_delay==0{"ready"}else{"offer_wait"}.into();self.message="control_ack_validated".into();
   let mut r=self.reply(vec![]);if self.offer_delay==0{r["peerConfig"]=c.clone();}else{self.pending_peer=Some(c.clone());}self.device.zeroize();self.local.zeroize();r
  }else{
   self.events+=1;
   if matches!(self.state.as_str(),"control_wait"|"offer_wait"){if self.early.len()>=64{return self.fail("early_event_limit")};self.early.push_back(v);return self.reply(vec![])}
   self.event(v)
  }
 }
 fn event(&mut self,v:Value)->Value{
  let name=v[0].as_str().unwrap_or("");let body=&v[1];let data=body.get("data").unwrap_or(body);
  let matches=!body.get("client_id").is_some_and(|x|x.as_str()!=Some(&self.remote))&&!data.get("app_control_id").is_some_and(|x|x.as_str()!=Some(&self.app))&&!data.get("ice_id").is_some_and(|x|x.as_str()!=Some(&self.ice));
  if !matches{self.ignored+=1;return self.reply(vec![])}
  if matches!(name,"released"|"left"|"leave"){return self.end("closed","remote_released")}
  if name!="soac"{self.unknown_events+=1;return self.reply(vec![])}
  match data["type"].as_str(){
   Some("answer")=>{let sdp=if let Some(s)=data["sdp"].as_str().filter(|s|s.len()<=1048576){s.to_owned()}else if let Some(s)=data["gzip_sdp"].as_str().filter(|s|s.len()<=1500000){let Ok(b)=B64.decode(s)else{return self.fail("invalid_gzip_answer")};let mut s=String::new();if flate2::read::GzDecoder::new(b.as_slice()).take(1048577).read_to_string(&mut s).is_err()||s.len()>1048576{return self.fail("invalid_gzip_answer")};s}else{return self.fail("missing_answer_sdp")};self.answers+=1;let mut r=self.reply(vec![]);r["peerEvent"]=json!({"type":"answer","sdp":sdp});r},
   Some("candidate")=>{let c=&data["candidate"];let c=if c.is_string(){json!({"candidate":c,"sdpMid":data["sdp_mid"],"sdpMLineIndex":data["sdp_mline_index"]})}else{c.clone()};if !c.is_object()||c.to_string().len()>16384{return self.fail("invalid_remote_candidate")};self.remote_candidates+=1;let mut r=self.reply(vec![]);r["peerEvent"]=json!({"type":"candidate","candidate":c});r},_=>{self.unknown_soac+=1;self.reply(vec![])}
  }
 }
}
impl Drop for SignalCore{fn drop(&mut self){self.wipe()}}
#[cfg(test)]mod tests{
 use super::*;use std::io::Write;
 #[test]fn room_client_type_is_encoded_and_cleared_on_cancel(){
  let mut s=SignalCore::default();
  for kind in [2u64,3] {
   s.start(json!({"client_type":kind,"token":"synthetic","signaling_list":["ws://127.0.0.1:18763"]}),"local","device",100);
   s.call(json!({"op":"signal_text","text":"0{\"sid\":\"s\",\"pingInterval\":4000,\"pingTimeout\":3000}"}));
   let r=s.call(json!({"op":"signal_text","text":"40"}));
   let sent=B64.decode(r["actions"][1]["base64"].as_str().unwrap()).unwrap();
   assert_eq!(crate::file_protocol::uint(&sent[1..],8),kind);
   s.call(json!({"op":"signal_cancel"}));assert!(s.shape.is_none());
  }
  let r=s.start(json!({"token":"synthetic","signaling_list":["ws://127.0.0.1:18763"]}),"local","device",100);
  assert_eq!(r["signal"]["message"],"local_device_type_unknown");assert!(s.shape.is_none());
 }
 #[test]fn hevc_room_advertises_only_started_codec(){let mut s=SignalCore::default();let room=json!({"client_type":3,"token":"synthetic","signaling_list":["ws://127.0.0.1:18763"],"multi_video":true,"decoder_envelope":[1600,2560,2,180,60]});s.start(room,"local","device",100);s.call(json!({"op":"signal_text","text":"0{\"sid\":\"s\",\"pingInterval\":4000,\"pingTimeout\":3000}"}));let r=s.call(json!({"op":"signal_text","text":"40"}));let sent=B64.decode(r["actions"][1]["base64"].as_str().unwrap()).unwrap();let cap=crate::file_protocol::blob(&sent[1..],4).unwrap();assert_eq!(crate::file_protocol::uint(cap,1),60);assert_eq!(crate::file_protocol::uint(cap,2),2);assert_eq!(crate::file_protocol::uint(cap,3),1600);assert_eq!(crate::file_protocol::uint(cap,4),2560);let control:Value=serde_json::from_str(r["actions"][0]["text"].as_str().unwrap().strip_prefix("451-11").unwrap()).unwrap();let streamer:Value=serde_json::from_str(control[1]["streamer_data"].as_str().unwrap()).unwrap();let list=streamer["device_capability"]["video_codec_capability"].as_array().unwrap();assert_eq!(list.len(),1);assert_eq!(list[0]["video_codec"],2);assert_eq!(list[0]["chroma_sampling"],1);assert!(list[0].get("codec_impl").is_none());}
 #[test]fn multi_handshake_uses_one_validated_decoder_snapshot(){let mut s=SignalCore::default();let room=json!({"client_type":3,"token":"synthetic","signaling_list":["ws://127.0.0.1:18763"],"multi_video":true,"decoder_envelope":[2560,2560,1,51,30]});s.start(room,"local","device",100);s.call(json!({"op":"signal_text","text":"0{\"sid\":\"s\",\"pingInterval\":4000,\"pingTimeout\":3000}"}));let r=s.call(json!({"op":"signal_text","text":"40"}));let sent=B64.decode(r["actions"][1]["base64"].as_str().unwrap()).unwrap();let cap=crate::file_protocol::blob(&sent[1..],4).unwrap();assert_eq!(crate::file_protocol::uint(cap,3),2560);assert_eq!(crate::file_protocol::uint(cap,4),2560);let control:Value=serde_json::from_str(r["actions"][0]["text"].as_str().unwrap().strip_prefix("451-11").unwrap()).unwrap();let streamer:Value=serde_json::from_str(control[1]["streamer_data"].as_str().unwrap()).unwrap();assert_eq!(streamer["device_capability"]["video_codec_capability"][0]["width"],2560);assert_eq!(streamer["device_capability"]["video_codec_capability"][0]["height"],2560);s.call(json!({"op":"signal_cancel"}));assert!(s.shape.is_none());}
 #[test]fn data_modes_send_official_capture_types_in_control_attachment(){for capture in [5,7,8]{let mut s=SignalCore::default();s.start(json!({"client_type":3,"token":"synthetic","signaling_list":["ws://127.0.0.1:18763"],"capture_type":capture}),"synthetic-local","synthetic-device",100);s.call(json!({"op":"signal_text","text":"0{\"sid\":\"s\",\"pingInterval\":4000,\"pingTimeout\":3000}"}));let r=s.call(json!({"op":"signal_text","text":"40{\"sid\":\"socket\"}"}));let sent=B64.decode(r["actions"][1]["base64"].as_str().unwrap()).unwrap();assert_eq!(sent[0],4);assert_eq!(crate::file_protocol::uint(&sent[1..],1),capture);assert!(crate::file_protocol::blob(&sent[1..],11).is_none());if capture==7{assert!(crate::file_protocol::blob(&sent[1..],3).is_none());}}}

 fn start()->SignalCore{let mut s=SignalCore::default();s.start(json!({"client_type":3,"token":"synthetic","signaling_list":["ws://127.0.0.1:18763"],"offer_delay_ms":0}),"synthetic-local","synthetic-device",100);s}
 fn connected()->SignalCore{let mut s=start();assert_eq!(s.call(json!({"op":"signal_text","text":"0{\"sid\":\"s\",\"pingInterval\":4000,\"pingTimeout\":3000}"}))["actions"][0]["text"],"40");let r=s.call(json!({"op":"signal_text","text":"40{\"sid\":\"socket\"}"}));assert!(r["actions"][0]["text"].as_str().unwrap().starts_with("451-11["));let sent=B64.decode(r["actions"][1]["base64"].as_str().unwrap()).unwrap();assert_eq!(sent[0],4);assert_eq!(&sent[1..],options("synthetic-device"));s}
 fn ready()->SignalCore{let mut s=connected();let ack=format!("4311{}",json!(["success",{"app_control_id":s.app,"client_id":"synthetic-remote","ice_id":"synthetic-assigned-ice","iceServers":[]}]));let r=s.call(json!({"op":"signal_text","text":ack}));assert!(r["peerConfig"].is_object());assert_eq!(r["signal"]["serverIceReassigned"],true);assert_eq!(r["signal"]["appControlIdMatches"],true);s}
 #[test]fn healthy_answered_session_has_no_fifteen_minute_lifetime_but_heartbeat_still_expires(){
  let mut s=ready();let answer=format!("42{}",json!(["soac",{"client_id":s.remote,"data":{"type":"answer","app_control_id":s.app,"ice_id":s.ice,"sdp":"synthetic-answer"}}]));assert_eq!(s.call(json!({"op":"signal_text","text":answer}))["signal"]["answers"],1);
  let mut last=100;
  // Advance a synthetic clock over thirty minutes through actual parsed engine heartbeat frames.
  for now in (4100..=1_804_100).step_by(4000){let r=s.call(json!({"op":"signal_text","text":"2alive","nowMs":now}));assert_eq!(r["signal"]["state"],"ready");assert_eq!(r["actions"][0]["text"],"3alive");last=now;}
  assert!(last>900_000);assert!(s.active());let r=s.call(json!({"op":"signal_tick","nowMs":last+7001}));assert_eq!(r["signal"]["message"],"engine_heartbeat_timeout");assert_eq!(r["signal"]["state"],"timed_out");
 }
 #[test]fn minimal_options_golden_and_three_key_control(){assert_eq!(options("d"),crate::wire::desktop_shape().connect_options("d",false).unwrap());let mut s=connected();let h=json!({"app_control_id":s.app,"app_data":{"_placeholder":true,"num":0},"streamer_data":json!({"control_id":s.app,"device_capability":{"display_info":[],"ice_id":"","video_codec_capability":[]}}).to_string()});assert_eq!(h.as_object().unwrap().len(),3);assert!(!h.to_string().contains(&s.proposed));s.call(json!({"op":"signal_cancel"}));}
 #[test]fn engine_ack_and_adopt_server_ice_for_soac(){let mut s=ready();assert_eq!(s.call(json!({"op":"signal_text","text":"2payload"}))["actions"][0]["text"],"3payload");let r=s.call(json!({"op":"signal_offer","sdp":"v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"}));let v:Value=serde_json::from_str(&r["actions"][0]["text"].as_str().unwrap()[2..]).unwrap();assert_eq!(v[1]["data"]["ice_id"],"synthetic-assigned-ice");assert_eq!(v[1]["client_id"],"synthetic-remote");assert_eq!(s.call(json!({"op":"signal_offer","sdp":"m=video 9 RTP\r\n"}))["signal"]["state"],"ready");}
 #[test]fn ack_number_rejection_and_app_mismatch(){let mut s=connected();assert_eq!(s.call(json!({"op":"signal_text","text":"4399[\"success\",{}]"}))["signal"]["state"],"control_wait");assert_eq!(s.call(json!({"op":"signal_text","text":"4311[\"failure\",{}]"}))["signal"]["state"],"failed");let mut s=connected();assert_eq!(s.call(json!({"op":"signal_text","text":"4311[\"success\",{\"app_control_id\":\"other\"}]"}))["signal"]["message"],"control_app_id_mismatch");}
 #[test]fn attachment_order_gzip_and_heartbeat_interleaving(){let mut s=ready();let mut gz=flate2::write::GzEncoder::new(vec![],flate2::Compression::default());gz.write_all(b"synthetic-answer").unwrap();let gz=gz.finish().unwrap();let header=format!("452-{}",json!(["soac",{"client_id":s.remote,"data":{"type":"answer","ice_id":s.ice,"app_control_id":s.app,"gzip_sdp":{"_placeholder":true,"num":1},"other":{"_placeholder":true,"num":0}}}]));s.call(json!({"op":"signal_text","text":header}));s.call(json!({"op":"signal_binary","base64":B64.encode(b"attachment-zero")}));assert_eq!(s.call(json!({"op":"signal_text","text":"2between"}))["actions"][0]["text"],"3between");let mut legacy=vec![4];legacy.extend(gz);let r=s.call(json!({"op":"signal_binary","base64":B64.encode(legacy)}));assert_eq!(r["peerEvent"]["sdp"],"synthetic-answer");assert_eq!(r["signal"]["attachments"],2);}
 #[test]fn route_rejection_timeout_close_and_cancel_late_frames(){let mut s=ready();assert!(s.call(json!({"op":"signal_text","text":"42[\"soac\",{\"client_id\":\"other\",\"data\":{\"type\":\"answer\",\"sdp\":\"private\"}}]"})).get("peerEvent").is_none());let r=s.call(json!({"op":"signal_cancel"}));assert!(r["actions"].as_array().unwrap().iter().any(|a|a["kind"]=="close"));assert!(s.app.is_empty()&&s.ice.is_empty()&&s.remote.is_empty());assert!(s.call(json!({"op":"signal_text","text":"40"}))["actions"].as_array().unwrap().is_empty());let mut s=start();assert_eq!(s.call(json!({"op":"signal_tick","nowMs":12100}))["signal"]["state"],"timed_out");let mut s=ready();assert_eq!(s.call(json!({"op":"signal_text","text":"41"}))["signal"]["state"],"closed");let mut s=ready();assert_eq!(s.call(json!({"op":"signal_tick","nowMs":7201}))["signal"]["message"],"engine_heartbeat_timeout");}
 #[test]fn delayed_offer_keeps_heartbeat_queues_event_and_emits_once(){
  let mut s=connected();s.offer_delay=1500;
  let ack=format!("4311{}",json!(["success",{"client_id":"synthetic-remote","ice_id":"synthetic-assigned-ice","iceServers":[]}]));
  let r=s.call(json!({"op":"signal_text","text":ack,"nowMs":200}));assert_eq!(r["signal"]["state"],"offer_wait");assert!(r.get("peerConfig").is_none());
  assert_eq!(s.call(json!({"op":"signal_tick","nowMs":1699}))["signal"]["offers"],0);
  assert_eq!(s.call(json!({"op":"signal_text","text":"2waiting","nowMs":1699}))["actions"][0]["text"],"3waiting");
  let event=format!("42{}",json!(["soac",{"client_id":s.remote,"data":{"type":"candidate","ice_id":s.ice,"candidate":{"candidate":"synthetic"}}}]));
  assert!(s.call(json!({"op":"signal_text","text":event})).get("peerEvent").is_none());
  assert!(s.call(json!({"op":"signal_tick","nowMs":1700}))["peerConfig"].is_object());
  assert!(s.call(json!({"op":"signal_tick","nowMs":1701})).get("peerConfig").is_none());
  let r=s.call(json!({"op":"signal_offer","sdp":"v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n","nowMs":1702}));assert_eq!(r["signal"]["offerElapsedMs"],1502);assert_eq!(r["signal"]["remoteCandidates"],1);
 }
 #[test]fn delay_cancel_clears_config_and_does_not_extend_deadline(){
  let mut s=connected();s.offer_delay=3000;let ack=format!("4311{}",json!(["success",{"client_id":"synthetic","iceServers":[]}]));s.call(json!({"op":"signal_text","text":ack,"nowMs":200}));assert!(s.pending_peer.is_some());
  let r=s.call(json!({"op":"signal_cancel"}));assert_eq!(r["actions"][0]["text"],"41");assert!(s.pending_peer.is_none());assert!(s.call(json!({"op":"signal_tick","nowMs":4000})).get("peerConfig").is_none());
  let mut s=connected();s.offer_delay=1500;s.began=0;s.ping_at=44900;s.stage_at=44900;s.call(json!({"op":"signal_text","text":ack,"nowMs":44900}));assert_eq!(s.call(json!({"op":"signal_tick","nowMs":45000}))["signal"]["message"],"overall_timeout");assert!(s.pending_peer.is_none());
 }
 #[test]fn delay_bounds_and_unknown_frame_diagnostics(){
  for (requested,expected) in [(0,0),(1500,1500),(999999,3000)]{let mut s=SignalCore::default();let r=s.start(json!({"client_type":3,"token":"synthetic","signaling_list":["ws://127.0.0.1:18763"],"offer_delay_ms":requested}),"local","device",0);assert_eq!(r["signal"]["offerDelayMs"],expected);}
  let mut s=ready();assert_eq!(s.call(json!({"op":"signal_text","text":"6private-unused-payload"}))["signal"]["unknownFrames"],1);let r=s.call(json!({"op":"signal_text","text":"42[\"unknown-private-event\",{}]"}));assert_eq!(r["signal"]["unknownEvents"],1);assert!(!r.to_string().contains("private"));
 }
 #[test]fn invalid_placeholder_and_binary_bound_fail_closed(){let mut s=ready();s.call(json!({"op":"signal_text","text":"451-[\"soac\",{\"_placeholder\":true,\"num\":9}]"}));assert_eq!(s.call(json!({"op":"signal_binary","base64":"AA=="}))["signal"]["state"],"failed");let mut s=ready();assert_eq!(s.call(json!({"op":"signal_text","text":"459-[\"soac\",{}]"}))["signal"]["state"],"failed");}
}
