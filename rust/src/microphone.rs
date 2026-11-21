//! Independently implemented UU microphone policy and permission gates.
//! Public wire facts: RPC request 21 / policy field 21, response 22 / field 17;
//! SimpleAction 23 opens the host microphone, 24 closes it, 27 restarts it.
//! No PCM or Opus bytes are retained in this state object.
use serde_json::{json,Value};
use crate::{file_protocol::{blob,uint},wire};
use std::sync::atomic::{AtomicU64,Ordering};
static NEXT:AtomicU64=AtomicU64::new(8_000_000);
#[derive(Clone,Copy,Debug,PartialEq)]pub struct Encoding{pub stereo:bool,pub packet_ms:u64}
pub fn negotiated(sdp:&str)->Option<Encoding>{
 if sdp.len()>1_048_576{return None}let mut section=Vec::new();let mut audio=false;
 for line in sdp.lines(){let l=line.trim_end_matches('\r');if l.starts_with("m="){if audio{break}let v:Vec<_>=l.split_whitespace().collect();audio=v.len()>=4&&v[0]=="m=audio"&&v[1]!="0";}if audio{section.push(l)}}
 if section.is_empty()||section.iter().any(|l|matches!(*l,"a=inactive"|"a=sendonly")){return None}
 let direction=section.iter().find(|l|matches!(**l,"a=recvonly"|"a=sendrecv"|"a=inactive"|"a=sendonly"));
 if direction.is_none()&&sdp.lines().take_while(|l|!l.starts_with("m=")).any(|l|matches!(l.trim_end_matches('\r'),"a=inactive"|"a=sendonly")){return None}
 let pt=section.iter().find_map(|l|{let (pt,codec)=l.strip_prefix("a=rtpmap:")?.split_once(' ')?;codec.eq_ignore_ascii_case("opus/48000/2").then_some(pt)})?;
 if !section[0].split_whitespace().skip(3).any(|p|p==pt){return None}
 let ptime=section.iter().find_map(|l|l.strip_prefix("a=ptime:"));if ptime.is_some_and(|p|p!="20"){return None}
 if let Some(v)=section.iter().find_map(|l|l.strip_prefix("a=maxptime:")){if v.parse::<u32>().ok()?<20{return None}}
 let mut stereo=false;let mut maximum=None;
 for l in &section{if let Some((id,params))=l.strip_prefix("a=fmtp:").and_then(|s|s.split_once(' ')){if id!=pt{continue}for item in params.split(';'){if let Some((k,v))=item.trim().split_once('='){match k.trim(){"stereo"=>stereo=match v.trim(){"1"=>true,"0"=>false,_=>return None},"minptime"=>{if v.trim().parse::<u32>().ok()?>20{return None}},"maxaveragebitrate"=>maximum=Some(v.trim().parse::<u32>().ok()?),_=>()}}}}}
 if maximum.is_some_and(|v|v<if stereo{96_000}else{64_000}){return None}Some(Encoding{stereo,packet_ms:20})
}
#[derive(Default)]pub struct Microphone{pub encoding:Option<Encoding>,pub generation:u64,pub enabled:bool,pub remote_active:bool,pub ack:Option<bool>,pub error:Option<&'static str>,pending:Option<u64>,deadline:u64,pub sent_packets:u64,last_timestamp:Option<u32>}
impl Microphone{
 pub fn configure(&mut self,sdp:&str){self.encoding=negotiated(sdp);}
 pub fn request(&mut self,permission:bool,foreground:bool,watch:bool,now:u64)->Result<(u64,Vec<u8>),&'static str>{
  if !permission||!foreground||watch{return Err("microphone_explicit_permission_and_control_required")}if self.encoding.is_none(){return Err("microphone_audio_negotiation_unsupported")}
  if self.enabled||self.pending.is_some(){return Err("microphone_operation_busy")}
  self.generation=NEXT.fetch_add(1,Ordering::Relaxed);self.enabled=true;self.remote_active=false;self.ack=None;self.error=None;self.sent_packets=0;self.last_timestamp=None;let seq=self.generation;self.pending=Some(seq);self.deadline=now+10_000;Ok((seq,policy(seq,true)))
 }
 pub fn stop(&mut self)->Vec<u8>{let seq=NEXT.fetch_add(1,Ordering::Relaxed);self.generation=seq;self.enabled=false;self.remote_active=false;self.ack=None;self.pending=None;self.deadline=0;self.last_timestamp=None;policy(seq,false)}
 pub fn sent(&mut self,seq:u64,success:bool){if self.pending==Some(seq)&&!success{self.fail("microphone_policy_send_failed")}}
 fn fail(&mut self,error:&'static str){self.enabled=false;self.remote_active=false;self.pending=None;self.deadline=0;self.error=Some(error);self.generation=NEXT.fetch_add(1,Ordering::Relaxed);}
 pub fn observe(&mut self,data:&[u8]){if !self.enabled||data.len()>65_536{return}
  if let Some(action)=blob(data,3).map(|a|uint(a,1)){match action{23=>self.remote_active=true,24=>self.fail("microphone_remote_closed"),27=>self.fail("microphone_remote_restarted"),_=>()}}
  if let Some(rpc)=blob(data,22){if blob(rpc,1).is_some_and(|h|self.pending==Some(uint(h,1))){if let Some(reply)=blob(rpc,17){if crate::protocol::decode_wire(reply).is_err(){return}self.ack=Some(uint(reply,1)==0);self.pending=None;if self.ack==Some(false){self.fail("microphone_remote_policy_rejected")}}}}
  if self.allowed(){self.deadline=0;}
 }
 pub fn tick(&mut self,now:u64){if self.enabled&&self.deadline>0&&now>=self.deadline{self.fail("microphone_remote_confirmation_timeout")}}
 pub fn allowed(&self)->bool{self.enabled&&self.encoding.is_some()&&self.ack==Some(true)&&self.remote_active}
 pub fn packet(&mut self,generation:u64,timestamp:u32,bytes:usize)->Result<(),&'static str>{if !self.allowed()||generation!=self.generation{return Err("microphone_generation_or_authorization_changed")}if bytes==0||bytes>4000{return Err("microphone_packet_size_invalid")}if self.last_timestamp.is_some_and(|last|{let delta=timestamp.wrapping_sub(last);delta==0||delta>48_000||delta%960!=0}){return Err("microphone_timestamp_discontinuity")}self.last_timestamp=Some(timestamp);Ok(())}
 pub fn snapshot(&self)->Value{json!({"generation":self.generation,"enabled":self.enabled,"pending":self.enabled&&!self.allowed(),"negotiated":self.encoding.is_some(),"stereo":self.encoding.is_some_and(|e|e.stereo),"packetMs":20,"captureAllowed":self.allowed(),"remoteAck":self.ack,"remoteActive":self.remote_active,"sentPackets":self.sent_packets,"error":self.error,"observedOnWindows":null})}
}
fn policy(seq:u64,on:bool)->Vec<u8>{let mut header=vec![];wire::int(1,seq,&mut header);let mut body=vec![];wire::int(1,u64::from(on),&mut body);let mut rpc=vec![];wire::bytes(1,&header,&mut rpc);wire::bytes(21,&body,&mut rpc);wire::envelope(seq,21,&rpc)}
#[cfg(test)]mod tests{
 use super::*;
 fn answer(direction:&str)->String{format!("v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na={direction}\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 stereo=1;minptime=10;useinbandfec=1\r\na=ptime:20\r\n")}
 fn event(action:u64)->Vec<u8>{let mut b=vec![];wire::int(1,action,&mut b);wire::envelope(1,3,&b)}
 fn ack(seq:u64,code:u64)->Vec<u8>{let mut h=vec![];wire::int(1,seq,&mut h);let mut b=vec![];wire::int(1,code,&mut b);let mut r=vec![];wire::bytes(1,&h,&mut r);wire::bytes(17,&b,&mut r);wire::envelope(seq,22,&r)}
 #[test]fn microphone_negotiation_rejects_receive_only_host_and_unsupported_frames(){assert!(negotiated(&answer("sendonly")).is_none());assert!(negotiated(&answer("inactive")).is_none());assert!(negotiated(&answer("recvonly")).unwrap().stereo);assert!(negotiated(&answer("sendrecv").replace("ptime:20","ptime:10")).is_none());assert!(negotiated(&answer("sendrecv").replace("minptime=10","maxaveragebitrate=32000")).is_none());let inherited=answer("sendrecv").replace("v=0\r\n","v=0\r\na=sendonly\r\n").replace("a=sendrecv\r\n","");assert!(negotiated(&inherited).is_none());}
 #[test]fn microphone_requires_permission_policy_ack_and_open_event(){let mut m=Microphone::default();m.configure(&answer("sendrecv"));assert!(m.request(false,true,false,0).is_err());assert!(m.request(true,true,true,0).is_err());let(seq,p)=m.request(true,true,false,0).unwrap();assert_eq!(uint(blob(blob(&p,21).unwrap(),21).unwrap(),1),1);m.observe(&event(23));assert!(!m.allowed());m.observe(&ack(seq+1,0));assert!(!m.allowed());m.observe(&ack(seq,0));assert!(m.allowed());assert!(m.packet(m.generation,0,12).is_ok());assert!(m.packet(m.generation,0,12).is_err());let old=m.generation;m.stop();assert!(m.packet(old,960,12).is_err());m.observe(&ack(seq,0));m.observe(&event(23));assert!(!m.allowed());}
 #[test]fn microphone_timeout_rejection_and_remote_close_stop_capture(){let mut m=Microphone::default();m.configure(&answer("sendrecv"));let(seq,_)=m.request(true,true,false,0).unwrap();m.observe(&ack(seq,1));assert!(!m.allowed());let(_,_) =m.request(true,true,false,0).unwrap();m.tick(10_000);assert!(!m.enabled);let(seq,_)=m.request(true,true,false,11_000).unwrap();m.observe(&ack(seq,0));m.observe(&event(23));assert!(m.allowed());m.observe(&event(24));assert!(!m.enabled);}
}
