// SPDX-License-Identifier: GPL-3.0-only
//! Independent bounded TERM byte reader. No decoding, repaint parsing or permissions.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
const CAP: usize = 65536;
pub struct RawOutput { bytes: Vec<u8>, start:u64, end:u64, epoch:String }
impl Default for RawOutput {
 fn default()->Self { let mut nonce=[0u8;16]; let epoch=if getrandom::getrandom(&mut nonce).is_ok(){hex::encode(nonce)}else{String::new()};Self{bytes:vec![],start:0,end:0,epoch} }
}
impl RawOutput {
 pub fn append(&mut self,data:&[u8]) {self.end+=data.len() as u64;self.bytes.extend_from_slice(data);if self.bytes.len()>CAP {let n=self.bytes.len()-CAP;self.bytes.drain(..n);self.start+=n as u64;} }
 pub fn epoch(&self)->&str {&self.epoch}
 pub fn read(&self,e:&Value,session:u32,token:u32)->Result<Value,&'static str> {
  if self.epoch.is_empty(){return Err("terminal_raw_identity_unavailable")}
  if e.as_object().is_none_or(|o|o.keys().any(|k|!["action","session","sessionToken","streamEpoch","cursor","limit"].contains(&k.as_str()))){return Err("terminal_raw_invalid_field")}
  if e["session"].as_u64()!=Some(session as u64)||e["sessionToken"].as_u64()!=Some(token as u64){return Err("terminal_raw_session_changed")}
  if e["streamEpoch"].as_str()!=Some(self.epoch.as_str()){return Err("terminal_raw_epoch_changed")}
  let cursor=e["cursor"].as_u64().filter(|n|*n<=9007199254740991).ok_or("terminal_raw_cursor_required")?;
  let limit=e["limit"].as_u64().filter(|n|(1..=16384).contains(n)).ok_or("terminal_raw_limit")?;
  let gap=cursor<self.start||cursor>self.end;
  let (data,next)=if gap{(&[][..],self.start)}else{let from=(cursor-self.start)as usize;let to=(from+limit as usize).min(self.bytes.len());(&self.bytes[from..to],cursor+(to-from)as u64)};
  Ok(json!({"session":session,"sessionToken":token,"streamEpoch":self.epoch,"cursor":cursor,"nextCursor":next,"outputStart":self.start,"outputEnd":self.end,"gap":gap,"base64":STANDARD.encode(data)}))
 }

}
#[cfg(test)] mod tests {
 use super::*;
 fn req(r:&RawOutput,c:u64,l:u64)->Value {json!({"action":"raw_read","session":7,"sessionToken":2,"streamEpoch":r.epoch(),"cursor":c,"limit":l})}
 #[test]fn exact_split_unicode_crlf_and_ansi(){let mut r=RawOutput::default();let b="中文🙂\r\n\u{1b}[31mred\u{1b}[0m".as_bytes();for x in b.chunks(2){r.append(x)}let mut result=vec![];let mut c=0;while c<b.len()as u64 {let p=r.read(&req(&r,c,1),7,2).unwrap();result.extend(STANDARD.decode(p["base64"].as_str().unwrap()).unwrap());c=p["nextCursor"].as_u64().unwrap();}assert_eq!(result,b);}
 #[test]fn readers_are_independent(){let mut r=RawOutput::default();r.append(b"abc");assert_eq!(r.read(&req(&r,0,3),7,2),r.read(&req(&r,0,3),7,2));}
 #[test]fn old_generation_and_token_rejected(){let r=RawOutput::default();let mut q=req(&r,0,1);q["sessionToken"]=json!(3);assert!(r.read(&q,7,2).is_err());q=req(&r,0,1);q["streamEpoch"]=json!(RawOutput::default().epoch());assert!(r.read(&q,7,2).is_err());}
 #[test]fn overflow_is_explicit_and_requires_resync(){let mut r=RawOutput::default();r.append(&vec![42;70000]);let p=r.read(&req(&r,0,4),7,2).unwrap();assert_eq!(p["gap"],true);assert_eq!(p["base64"],"");assert_eq!(p["outputStart"],4464);let c=p["nextCursor"].as_u64().unwrap();assert_eq!(r.read(&req(&r,c,4),7,2).unwrap()["gap"],false);}
 #[test]fn missing_identity_and_bad_limits_rejected(){let r=RawOutput::default();assert!(r.read(&req(&r,0,0),7,2).is_err());assert!(r.read(&req(&r,0,16385),7,2).is_err());let mut q=req(&r,0,1);q.as_object_mut().unwrap().remove("streamEpoch");assert!(r.read(&q,7,2).is_err());}
}
