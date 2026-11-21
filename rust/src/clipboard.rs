// SPDX-License-Identifier: GPL-3.0-only
//! Manual, session-scoped Windows text clipboard. No OS access or payload logging.
use serde_json::{json,Value};
use sha2::{Digest,Sha256};
use std::time::{Duration,Instant};
use crate::{clipboard_protocol as text,clipboard_rich as rich,protocol::{decode_wire,WireValue}};
pub const MAX_TEXT:usize=30*1024;
fn hash(s:&str)->[u8;32]{Sha256::digest(s.as_bytes()).into()}
fn field(data:&[u8],n:u32)->Option<&[u8]>{decode_wire(data).ok()?.into_iter().find_map(|f|match f.value{WireValue::Bytes(b)if f.number==n=>Some(b),_=>None})}
fn number(data:&[u8],n:u32)->Option<u64>{decode_wire(data).ok()?.into_iter().find_map(|f|match f.value{WireValue::Varint(v)if f.number==n=>Some(v),_=>None})}
fn valid(s:&str)->bool{s.len()<=MAX_TEXT&&!s.contains('\0')}
struct Incoming {text:String,version:u64,header:Option<Vec<u8>>}
pub struct Clipboard {seq:u64,window:Option<Instant>,assembly:text::Assembly,rich:rich::State,incoming:Option<Incoming>,version:u64,last_sent:Option<[u8;32]>,last_applied:Option<[u8;32]>,pending:Option<(u64,[u8;32])>,sent:bool,ack:Option<bool>,received:u64,rejected:u64}
impl Default for Clipboard {fn default()->Self{Self{seq:4_000_000,window:None,assembly:Default::default(),rich:Default::default(),incoming:None,version:0,last_sent:None,last_applied:None,pending:None,sent:false,ack:None,received:0,rejected:0}}}
impl Clipboard {
 fn next(&mut self)->u64{self.seq+=1;self.seq}
 fn expire(&mut self){if self.window.is_some_and(|until|Instant::now()>=until){self.disable();}}
 pub fn disable(&mut self){self.window=None;self.incoming=None;self.assembly=Default::default();self.rich=Default::default();self.pending=None;self.ack=None;self.sent=false;}
 pub fn snapshot(&mut self)->Value{self.expire();json!({"manualOnly":true,"listening":self.window.is_some(),"incomingAvailable":self.incoming.is_some(),"incomingBytes":self.incoming.as_ref().map(|v|v.text.len()),"incomingVersion":self.incoming.as_ref().map(|v|v.version),"localMessageSent":self.sent,"remoteAck":self.ack,"pendingSeq":self.pending.as_ref().map(|p|p.0),"receivedTexts":self.received,"rejectedMessages":self.rejected,"windowsCompatibility":"offline_protocol_only","maxTextBytes":MAX_TEXT})}
 pub fn command(&mut self,v:&Value)->Result<(Value,Vec<(usize,Vec<u8>)>),&'static str>{self.expire();let mut out=vec![];
  let response=match v["action"].as_str(){
   Some("listen")=>{self.disable();self.window=Some(Instant::now()+Duration::from_secs(60));out.push((0,crate::wire::echo_request_with_clipboard(1,true)));self.snapshot()},
   Some("disable")=>{self.disable();out.push((0,crate::wire::echo_request_with_clipboard(1,false)));self.snapshot()},
   Some("send")=>{let s=v["text"].as_str().filter(|s|valid(s)).ok_or("clipboard_text_invalid_or_over_30kib")?;let h=hash(s);if v["force"]!=true&&(self.last_sent==Some(h)||self.last_applied==Some(h)){json!({"deduplicated":true,"sent":false})}else{let id=self.next();self.pending=Some((id,h));self.sent=false;self.ack=None;self.window=Some(Instant::now()+Duration::from_secs(60));out.push((0,crate::wire::echo_request_with_clipboard(1,true)));out.push((1,crate::wire::envelope(id,21,&text::text_request(id,s))));json!({"seq":id,"sent":false,"remoteAck":null,"queuedMessages":2,"textBytes":s.len()})}},
   Some("peek")=>{if let Some(i)=&self.incoming{json!({"version":i.version,"text":i.text,"textBytes":i.text.len()})}else{json!({"error":"no_remote_clipboard_text"})}},
   Some("applied")=>{let version=v["version"].as_u64().ok_or("clipboard_version_required")?;if !self.incoming.as_ref().is_some_and(|i|i.version==version){return Err("stale_clipboard_version")};let i=self.incoming.take().unwrap();self.last_applied=Some(hash(&i.text));if let Some(header)=i.header{let seq=self.next();out.push((1,crate::wire::envelope(seq,22,&text::text_response(&header))));}json!({"localPasteboardApplied":true,"version":version,"remoteAckSent":false})},
   Some("status")=>self.snapshot(),_=>return Err("invalid_clipboard_action")
  };Ok((response,out))
 }
 pub fn mark_sent(&mut self,seq:u64,sent:bool){if let Some((id,h))=self.pending{if id==seq{self.sent=sent;if sent{self.last_sent=Some(h)}}}}
 fn receive_inner(&mut self,data:&[u8])->Result<Vec<Vec<u8>>,&'static str>{
  if data.len()>MAX_TEXT*2+1024{return Err("clipboard_message_too_large")};let fields=decode_wire(data).map_err(|_|"clipboard_invalid_envelope")?;let mut replies=vec![];
  for f in fields{let WireValue::Bytes(payload)=f.value else{continue};let mut incoming=None;let mut header=None;
   match f.number {
    17=>incoming=self.assembly.accept(payload)?,
    21=>{let mut next=self.seq;let result=self.rich.request(payload,&mut||{next+=1;next})?;self.seq=next;incoming=result.text;for(kind,body)in result.messages{let id=self.next();replies.push(crate::wire::envelope(id,kind,&body));}if let Some((h,s))=text::read_text_request(payload)?{incoming=Some(s);header=Some(h);}},
    22=>{if let Some((seq,_))=self.pending{if field(payload,1).and_then(|h|number(h,1))==Some(seq){if let Some(status)=field(payload,6){if let Some(err)=number(status,1){self.ack=Some(err==1);}}}}if let Some(s)=self.rich.response(payload)?{incoming=Some(s)}},_=>{}
   }
   if let Some(s)=incoming{if !valid(&s){return Err("clipboard_invalid_text")};if self.last_applied!=Some(hash(&s)){self.version+=1;self.incoming=Some(Incoming{text:s,version:self.version,header});self.received+=1;}}
  }Ok(replies)
 }
 pub fn receive(&mut self,data:&[u8])->Vec<Vec<u8>>{self.expire();if self.window.is_none(){return vec![];}match self.receive_inner(data){Ok(v)=>v,Err(_)=>{self.rejected+=1;self.incoming=None;self.assembly=Default::default();self.rich=Default::default();vec![]}}}
}
#[cfg(test)]mod tests{
 use super::*;
 #[test]fn disabled_never_collects_or_replies(){let mut c=Clipboard::default();let msg=crate::wire::envelope(1,21,&text::text_request(1,"private"));assert!(c.receive(&msg).is_empty());assert_eq!(c.snapshot()["incomingAvailable"],false);}
 #[test]fn windows_outbound_uses_only_case10_not_rich_offer(){let mut c=Clipboard::default();let(r,p)=c.command(&json!({"action":"send","text":"中文\nEnglish"})).unwrap();assert!(r["remoteAck"].is_null());assert_eq!(p.len(),2);assert_eq!(p[1].0,1);let rpc=field(&p[1].1,21).unwrap();assert_eq!(text::read_text_request(rpc).unwrap().unwrap().1,"中文\nEnglish");assert!(field(rpc,9).is_none());c.mark_sent(r["seq"].as_u64().unwrap(),true);assert_eq!(c.snapshot()["localMessageSent"],true);assert!(c.snapshot()["remoteAck"].is_null());}
 #[test]fn incoming_ack_waits_for_native_pasteboard_commit(){let mut c=Clipboard::default();c.command(&json!({"action":"listen"})).unwrap();let msg=crate::wire::envelope(1,21,&text::text_request(88,"多行\ntext"));assert!(c.receive(&msg).is_empty());let (peek,_)=c.command(&json!({"action":"peek"})).unwrap();assert_eq!(peek["text"],"多行\ntext");assert!(c.command(&json!({"action":"applied","version":0})).is_err());let (_,replies)=c.command(&json!({"action":"applied","version":peek["version"]})).unwrap();assert_eq!(replies.len(),1);assert_eq!(c.snapshot()["incomingAvailable"],false);assert!(c.receive(&msg).is_empty());}
 #[test]fn no_payload_in_status_and_no_echo_loop(){let mut c=Clipboard::default();c.command(&json!({"action":"listen"})).unwrap();let msg=crate::wire::envelope(1,21,&text::text_request(1,"sensitive-value"));c.receive(&msg);assert!(!c.snapshot().to_string().contains("sensitive-value"));let(peek,_)=c.command(&json!({"action":"peek"})).unwrap();c.command(&json!({"action":"applied","version":peek["version"]})).unwrap();let(r,p)=c.command(&json!({"action":"send","text":"sensitive-value"})).unwrap();assert_eq!(r["deduplicated"],true);assert!(p.is_empty());}
 #[test]fn utf8_byte_limit_nul_and_window_expiry(){let mut c=Clipboard::default();assert!(c.command(&json!({"action":"send","text":"中".repeat(MAX_TEXT/3+1)})).is_err());assert!(c.command(&json!({"action":"send","text":"a\0b"})).is_err());c.command(&json!({"action":"listen"})).unwrap();c.window=Some(Instant::now()-Duration::from_secs(1));assert_eq!(c.snapshot()["listening"],false);}
}
