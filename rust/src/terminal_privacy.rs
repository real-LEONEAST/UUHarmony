// SPDX-License-Identifier: GPL-3.0-only
//! Ownership for data-only terminal privacy. ACKs are deliberately not observations.
use serde_json::{json,Value};
use crate::protocol::{decode_wire,WireValue};
fn number(b:&[u8],n:u32)->Option<u64>{decode_wire(b).ok()?.into_iter().find_map(|f|match f.value{WireValue::Varint(v)if f.number==n=>Some(v),_=>None})}
fn body(b:&[u8],n:u32)->Option<&[u8]>{decode_wire(b).ok()?.into_iter().find_map(|f|match f.value{WireValue::Bytes(v)if f.number==n=>Some(v),_=>None})}
#[derive(Default)]
pub struct TerminalPrivacy {baseline:Option<u64>,current:Option<u64>,attempted:bool,sent:bool,owned:bool,external:bool,failed:bool}
impl TerminalPrivacy {
 pub fn observe(&mut self,b:&[u8]){
  // Only actual SystemStateChange or SystemMetrics. RpcResponse is not proof.
  let current=body(b,15).and_then(|v|body(v,5)).and_then(|v|number(v,3))
   .or_else(||body(b,13).and_then(|v|body(v,4)).and_then(|v|number(v,7)))
   .filter(|v|[1,2,3].contains(v));
  if let Some(mode)=current{
   self.baseline.get_or_insert(mode);self.current=Some(mode);
   if self.sent&&self.baseline==Some(1)&&mode==3&&!self.external{self.owned=true;}
   if self.owned&&mode!=3{self.owned=false;self.external=true;}
  }
 }
 pub fn enable(&mut self,support:Option<u64>)->bool{
  if self.baseline!=Some(1)||self.current!=Some(1)||self.attempted||support!=Some(2){return false}
  self.attempted=true;true
 }
 pub fn sent(&mut self,ok:bool){self.sent=ok;self.failed=!ok;}
 pub fn restore(&self)->bool{self.owned&&self.current==Some(3)&&self.baseline==Some(1)&&!self.external}
 pub fn snapshot(&self,support:Option<u64>)->Value{
  let protected=matches!(self.current,Some(2|3));
  let state=if protected{"protected"}else if self.failed{"failed"}else if self.attempted{"requested"}else if support.is_some_and(|s|s!=2){"unsupported"}else{"unknown"};
  json!({"privacyProtected":protected,"privacyState":state,"privacyOwned":self.owned,"privacyBaseline":self.baseline,"privacyCurrent":self.current})
 }
}
#[cfg(test)] mod tests{
 use super::*;
 fn report(p:&mut TerminalPrivacy,n:u64){let b=vec![0x7a,4,0x2a,2,0x18,n as u8];p.observe(&b);}
 #[test]fn preserve_existing_and_restore_only_changed(){
  for n in [2,3]{let mut p=TerminalPrivacy::default();report(&mut p,n);assert!(!p.enable(Some(2)));assert!(!p.restore());assert_eq!(p.snapshot(Some(2))["privacyProtected"],true);}
  let mut p=TerminalPrivacy::default();assert!(!p.enable(Some(2)));report(&mut p,1);assert!(p.enable(Some(2)));p.sent(true);
  // A successful RPC reporting mode3 is insufficient.
  p.observe(&[0xb2,1,4,0x1a,2,0x18,3]);assert_eq!(p.snapshot(Some(2))["privacyProtected"],false);assert!(!p.restore());
  report(&mut p,3);assert!(p.restore());report(&mut p,2);assert!(!p.restore());report(&mut p,3);assert!(!p.restore());
 }
 #[test]fn preserve_privacy_changed_before_first_request(){let mut p=TerminalPrivacy::default();report(&mut p,1);report(&mut p,2);assert!(!p.enable(Some(2)));assert!(!p.restore());assert_eq!(p.snapshot(Some(2))["privacyProtected"],true);}
 #[test]fn rejected_and_unsupported_are_not_protected(){
  let mut p=TerminalPrivacy::default();report(&mut p,1);assert!(!p.enable(Some(1)));assert_eq!(p.snapshot(Some(1))["privacyState"],"unsupported");
  assert!(p.enable(Some(2)));p.sent(false);assert!(!p.restore());assert_eq!(p.snapshot(Some(2))["privacyProtected"],false);
 }
}
