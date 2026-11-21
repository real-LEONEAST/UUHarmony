// SPDX-License-Identifier: GPL-3.0-only
//! One-room screen/track/renderer ownership. Pure state is host-testable.
use serde_json::{json,Value};
use crate::protocol::{decode_wire,WireValue};
use std::{collections::{BTreeMap,BTreeSet},sync::atomic::{AtomicU64,Ordering},time::{Duration,Instant}};
static NEXT_EPOCH:AtomicU64=AtomicU64::new(1);
fn epoch()->u64{NEXT_EPOCH.fetch_update(Ordering::Relaxed,Ordering::Relaxed,|v|v.checked_add(1)).expect("media_epoch_exhausted")}
pub fn portrait_size(w: u32, h: u32, mut supported: impl FnMut(u32, u32) -> bool) -> Option<(u32, u32)> {
    if w < 2 || h <= w { return None; }
    let mut long = h.min(1280) & !1;
    while long >= 2 {
        let short = ((u64::from(long) * u64::from(w) / u64::from(h)) as u32) & !1;
        if short >= 2 && supported(short, long) { return Some((short, long)); }
        long -= 2;
    }
    None
}
/// Accept only a fresh portrait frame with the source's aspect ratio. A small
/// bounded rounding tolerance permits up to 32-pixel encoder alignment without
/// treating a materially different screen aspect as compatible at small sizes.
pub fn stream_aspect_matches(actual_w:u32,actual_h:u32,source_w:u32,source_h:u32)->bool {
    if actual_w<2||actual_h<2||source_w<2||source_h<2 || (actual_h>actual_w)!=(source_h>source_w) || (actual_w>actual_h)!=(source_w>source_h) {return false}
    let a=u64::from(actual_w)*u64::from(source_h);
    let b=u64::from(actual_h)*u64::from(source_w);
    let alignment_tolerance=u64::from(source_h.max(source_w))*32;
    let proportional_tolerance=a.max(b)/20;
    a.abs_diff(b)<=alignment_tolerance.min(proportional_tolerance)
}
pub fn portrait_aspect_matches(w:u32,h:u32,sw:u32,sh:u32)->bool { sh>sw && stream_aspect_matches(w,h,sw,sh) }
pub fn portrait_fallback_size(w: u32, h: u32, mut supported: impl FnMut(u32, u32) -> bool) -> Option<(u32, u32)> {
    if w < 2 || h <= w { return None; }
    let height = h.min(720) & !1;
    let width = ((u64::from(height) * u64::from(w) / u64::from(h)) as u32) & !1;
    (width >= 2 && height >= 2 && supported(width, height)).then_some((width, height))
}
pub fn portrait_bounds(expected:(u32,u32),mut supported:impl FnMut(u32,u32)->bool)->(u32,u32){
    let side=expected.1;
    if supported(side,side){(side,side)}else{expected}
}
pub fn portrait_fallback_due(fallback: bool, ack_age: Option<Duration>, epoch_aus: u64) -> bool {
    !fallback && ack_age.is_some_and(|age| age >= Duration::from_secs(2)) && epoch_aus == 0
}
#[cfg(test)]
mod portrait_size_tests {
    use super::{portrait_size,portrait_aspect_matches,portrait_bounds};
    #[test]
    fn preserves_source_aspect_with_bounded_long_edge() {
        assert_eq!(portrait_size(1600, 2560, |w, h| w <= 1600 && h <= 2560), Some((800, 1280)));
        assert_eq!(portrait_size(1600, 2560, |w, h| w <= 720 && h <= 1152), Some((720, 1152)));
        assert_eq!(portrait_size(1600, 2560, |w, h| w <= 700 && h <= 1000), Some((624, 1000)));
        assert_eq!(portrait_size(600, 960, |_, _| true), Some((600, 960)));
        assert_eq!(portrait_size(1920, 1080, |_, _| true), None);
    }
    #[test]
    fn aspect_gate_accepts_scaled_portrait_not_landscape_or_wrong_shape() {
        assert!(portrait_aspect_matches(720,1152,1600,2560));
        assert!(portrait_aspect_matches(800,1280,1600,2560));
        assert!(portrait_aspect_matches(768,1280,1600,2560));
        assert!(!portrait_aspect_matches(1280,800,1600,2560));
        assert!(!portrait_aspect_matches(720,1280,1600,2560));
        assert!(!portrait_aspect_matches(180,320,1600,2560));
        assert!(!portrait_aspect_matches(0,0,1600,2560));
    }
    #[test]
    fn max_bound_is_square_only_if_decoder_supports_it() {
        assert_eq!(portrait_bounds((800,1280),|w,h|w==1280&&h==1280),(1280,1280));
        assert_eq!(portrait_bounds((800,1280),|w,h|w<=800&&h<=1280),(800,1280));
        assert_eq!(portrait_bounds((450,720),|w,h|w==720&&h==720),(720,720));
    }
    #[test]
    fn fallback_is_once_after_ack_and_only_without_current_epoch_aus() {
        use super::{portrait_fallback_due, portrait_fallback_size};
        use std::time::Duration;
        assert_eq!(portrait_fallback_size(1600, 2560, |w, h| w <= 450 && h <= 720), Some((450, 720)));
        assert!(!portrait_fallback_due(false, None, 0));
        assert!(!portrait_fallback_due(false, Some(Duration::from_millis(1999)), 0));
        assert!(!portrait_fallback_due(false, Some(Duration::from_secs(2)), 1));
        assert!(!portrait_fallback_due(true, Some(Duration::from_secs(2)), 0));
        assert!(portrait_fallback_due(false, Some(Duration::from_secs(2)), 0));
    }
}
/// Manual stream limits take priority until their screen leaves the active set.
#[derive(Default)]
pub struct ManualScale { screens: BTreeSet<u32> }
impl ManualScale {
    pub fn select(&mut self, screen: u32) { self.screens.insert(screen); }
    pub fn active(&self, screen: u32) -> bool { self.screens.contains(&screen) }
    pub fn retain_active(&mut self, active: &[u32]) { self.screens.retain(|screen| active.contains(screen)); }
}
#[cfg(test)]
mod manual_scale_tests {
    use super::{ManualScale,portrait_fallback_due};
    use std::time::Duration;
    #[test]
    fn manual_scale_blocks_default_and_fallback_until_screen_changes_or_new_session() {
        let mut manual=ManualScale::default();
        assert!(!manual.active(7));
        manual.select(7);
        manual.retain_active(&[7]);
        assert!(manual.active(7)); // automatic request must not replace manual size
        assert!(!portrait_fallback_due(manual.active(7),Some(Duration::from_secs(3)),0));
        manual.retain_active(&[9]);
        assert!(!manual.active(7));
        assert!(!manual.active(9));
        assert!(!ManualScale::default().active(7));
    }
}
pub const MAX_STREAMS:usize=3;
pub const REGISTER_SEQ:u64=8_100_000;
// A newly mapped, previously active track can remain silent until the sender
// receives a keyframe request. Retry briefly, using only its observed SSRC.
pub fn startup_pli_due(age:std::time::Duration,since_pli:std::time::Duration,accepted:u64)->bool{accepted==0&&age<std::time::Duration::from_secs(12)&&since_pli>=std::time::Duration::from_secs(1)}
fn blob(d:&[u8],n:u32)->Option<&[u8]>{decode_wire(d).ok()?.into_iter().find_map(|f|match f.value{WireValue::Bytes(v)if f.number==n=>Some(v),_=>None})}
fn num(d:&[u8],n:u32)->Option<u64>{decode_wire(d).ok()?.into_iter().find_map(|f|match f.value{WireValue::Varint(v)if f.number==n=>Some(v),_=>None})}
pub fn register()->Vec<u8>{let mut h=vec![];crate::wire::int(1,REGISTER_SEQ,&mut h);let mut t=vec![];crate::wire::bytes(1,&[0,1,2],&mut t);let mut r=vec![];crate::wire::bytes(1,&h,&mut r);crate::wire::bytes(15,&t,&mut r);crate::wire::envelope(REGISTER_SEQ,21,&r)}
pub fn screen_action(seq:u64,id:u32,start:bool)->Vec<u8>{let mut a=vec![];crate::wire::int(1,if start{8}else{7},&mut a);crate::wire::bytes(2,json!({"screen_id":id}).to_string().as_bytes(),&mut a);crate::wire::envelope(seq,3,&a)}
pub fn answer_tracks(sdp:&str)->Option<[String;3]>{
 struct Section{active:bool,sending:bool,mid:Option<String>,ids:BTreeSet<usize>}
 let mut sections=vec![];for line in sdp.lines().map(str::trim){if let Some(m)=line.strip_prefix("m="){let mut f=m.split_whitespace();let video=f.next()==Some("video");let active=f.next()?.split('/').next()?.parse::<u32>().ok()?!=0;sections.push(Section{active:video&&active,sending:true,mid:None,ids:BTreeSet::new()});continue}let Some(s)=sections.last_mut()else{continue};if !s.active{continue}if matches!(line,"a=inactive"|"a=recvonly"){s.sending=false;}if let Some(mid)=line.strip_prefix("a=mid:"){if mid.is_empty()||mid.len()>32||!mid.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'_'||b==b'-'){return None}s.mid=Some(mid.into());}let id=if let Some(v)=line.strip_prefix("a=msid:"){v.split_whitespace().nth(1)}else if let Some(v)=line.strip_prefix("a=ssrc:"){let mut w=v.split_whitespace();w.next();if w.next().is_some_and(|x|x.starts_with("msid:")){w.next()}else{None}}else{None};if let Some(i)=id.and_then(track_index){s.ids.insert(i);}}
 let mut found:[Option<String>;3]=[None,None,None];for s in sections.into_iter().filter(|s|s.active&&s.sending){if s.ids.len()!=1{continue}let i=*s.ids.iter().next()?;if found[i].is_some(){return None}found[i]=Some(s.mid?);}let[Some(a),Some(b),Some(c)]=found else{return None};if a==b||a==c||b==c{return None}Some([a,b,c])
}
pub fn track_index(id:&str)->Option<usize>{match id{"video_0"=>Some(0),"video_1"=>Some(1),"video_2"=>Some(2),_=>None}}
#[derive(Clone,Copy,Debug,PartialEq,Eq)]pub struct Route{pub screen:u32,pub track:usize,pub slot:u32,pub generation:u32,pub epoch:u64}
#[derive(Clone,Debug,PartialEq,Eq)]pub struct Focus{pub screen:u32,pub scope:String,pub token:u64}
#[derive(Default)]pub struct TrackStats{pub seen:bool,pub mid:Option<String>,pub ssrc:u32,pub ssrc_changes:u64,pub packets:u64,pub bytes:u64,pub queue_drops:u64,pub stale_drops:u64,pub capture:Value,track_id:Option<String>,reader_serial:u64,reader_active:u64,reader_pending:u64}
struct Stream{sent:bool,closing:bool,activation_generation:u64,track:Option<usize>,binding:Option<(u32,u32)>,epoch:u64,pub observed:bool,pub width:u32,pub height:u32,configured:bool,error:Option<&'static str>,fps:u64,quality:u64}
impl Default for Stream{fn default()->Self{Self{sent:false,closing:false,activation_generation:0,track:None,binding:None,epoch:epoch(),observed:false,width:0,height:0,configured:false,error:None,fps:30,quality:5}}}
#[derive(Default)]pub struct Streams{
 pub enabled:bool,pub answer:Option<[String;3]>,pub registration_sent:bool,pub registration_ack:Option<bool>,pub registration_at:Option<Instant>,
 pub error:Option<&'static str>,pub stats:[TrackStats;3],screens:Vec<Value>,inventory_generation:u64,streams:BTreeMap<u32,Stream>,
 pub owner:Option<Focus>,owner_authorized:bool,last_token:u64,next_seq:u64,
}
impl Streams{
 pub fn new()->Self{Self{enabled:true,..Default::default()}}
 pub fn next_seq(&mut self)->u64{self.next_seq+=1;8_200_000+self.next_seq}
 pub fn observe(&mut self,d:&[u8],display:&Value){
  if !self.enabled{return}if self.registration_sent&&self.registration_ack.is_none(){if let Some(rpc)=blob(d,22){if blob(rpc,1).and_then(|h|num(h,1))==Some(REGISTER_SEQ){if let Some(r)=blob(rpc,11){if decode_wire(r).is_ok(){let ok=num(r,1).unwrap_or(0)==0;self.registration_ack=Some(ok);if !ok{self.error=Some("multi_video_registration_rejected");}}}}}}
  let generation=display["inventoryGeneration"].as_u64().unwrap_or(0);if generation==0||generation==self.inventory_generation{return}let Some(rows)=display["screens"].as_array()else{return};self.screens=rows.clone();self.inventory_generation=generation;
  for (&id,s) in &mut self.streams{let track=self.screens.iter().find(|v|v["id"]==id).and_then(|v|v["videoTrackIndex"].as_u64()).filter(|i|*i<3).map(|i|i as usize).filter(|i|self.screens.iter().filter(|v|v["videoTrackIndex"].as_u64()==Some(*i as u64)).count()==1).filter(|_|s.sent&&generation>s.activation_generation&&!s.closing);
   if track!=s.track{s.track=track;s.epoch=epoch();s.observed=false;}if !self.screens.iter().any(|v|v["id"]==id){s.error=Some("screen_removed");}
  }
 }
 pub fn open(&mut self,id:u32)->Result<(),&'static str>{if !self.screens.iter().any(|s|s["id"]==id){return Err("screen_not_in_inventory")}if self.streams.contains_key(&id){return Ok(())}if self.streams.len()>=3{return Err("multi_video_screen_limit")}self.streams.insert(id,Stream::default());Ok(())}
 pub fn activation_plan(&mut self)->Vec<(u32,u64,Vec<u8>)>{if self.error.is_some()||self.registration_ack!=Some(true){return vec![]}let ids=self.streams.iter().filter(|(_,s)|!s.sent&&!s.closing&&s.error.is_none()).map(|(id,_)|*id).collect::<Vec<_>>();ids.into_iter().map(|id|{let seq=self.next_seq();(id,seq,screen_action(seq,id,true))}).collect()}
 pub fn activation_start(&mut self,id:u32){if let Some(s)=self.streams.get_mut(&id){s.activation_generation=self.inventory_generation;}}
 pub fn activation_sent(&mut self,id:u32,ok:bool){if let Some(s)=self.streams.get_mut(&id){s.sent=ok;if !ok{s.error=Some("screen_activate_send_failed");}else if self.inventory_generation>s.activation_generation {let track=self.screens.iter().find(|v|v["id"]==id).and_then(|v|v["videoTrackIndex"].as_u64()).filter(|i|*i<3).filter(|i|self.screens.iter().filter(|v|v["videoTrackIndex"].as_u64()==Some(*i)).count()==1).map(|i|i as usize);if track!=s.track{s.track=track;s.epoch=epoch();s.observed=false;}}}}
 pub fn bind(&mut self,id:u32,slot:u32,generation:u32)->Result<(),&'static str>{if slot>2||generation==0{return Err("invalid_renderer_identity")}if self.streams.iter().any(|(&other,s)|other!=id&&s.binding.is_some_and(|(v,_)|v==slot)){return Err("renderer_slot_owned")}let s=self.streams.get_mut(&id).ok_or("screen_not_open")?;if s.closing{return Err("screen_closing")}if s.binding!=Some((slot,generation)){s.binding=Some((slot,generation));s.epoch=epoch();s.observed=false;}Ok(())}
 pub fn lanes(&self)->Vec<(u32,u32,u64)>{self.streams.values().filter_map(|s|s.binding.map(|(slot,generation)|(slot,generation,s.epoch))).collect()}
 pub fn binding(&self,id:u32)->Option<(u32,u32)>{self.streams.get(&id)?.binding}
 pub fn begin_close(&mut self,id:u32)->Result<Vec<u8>,&'static str>{let seq=self.next_seq();let s=self.streams.get_mut(&id).ok_or("screen_not_open")?;s.closing=true;s.epoch=epoch();s.observed=false;Ok(screen_action(seq,id,false))}
 pub fn close_sent(&mut self,id:u32,ok:bool){if ok{self.streams.remove(&id);}else if let Some(s)=self.streams.get_mut(&id){s.error=Some("screen_stop_send_failed");}}
 pub fn route(&self,index:usize)->Option<Route>{if self.error.is_some()||self.registration_ack!=Some(true)||!self.stats.get(index)?.seen{return None}self.streams.iter().find_map(|(&id,s)|{if s.closing||s.error.is_some()||s.track!=Some(index){return None}let(slot,generation)=s.binding?;Some(Route{screen:id,track:index,slot,generation,epoch:s.epoch})})}
 pub fn route_for(&self,id:u32)->Option<Route>{let track=self.streams.get(&id)?.track?;self.route(track).filter(|r|r.screen==id)}
 pub fn route_current(&self,route:Route)->bool{self.route(route.track)==Some(route)}
 pub fn bind_track(&mut self,id:&str,mid:Option<&str>)->Result<usize,&'static str>{let index=track_index(id).ok_or("unnegotiated_video_track")?;if !self.answer.as_ref().is_some_and(|a|mid==Some(a[index].as_str()))||self.stats[index].seen{self.error=Some("unexpected_or_duplicate_video_track");return Err("unexpected_or_duplicate_video_track")}self.stats[index].seen=true;self.stats[index].mid=mid.map(str::to_owned);Ok(index)}
 pub fn bind_reader(&mut self, id: &str, mid: Option<&str>) -> Result<(usize, u64, u64), &'static str> {
  let index = track_index(id).ok_or("unnegotiated_video_track")?;
  if !self.answer.as_ref().is_some_and(|a| mid == Some(a[index].as_str())) {
   self.error = Some("unexpected_video_track_mid");
   return Err("unexpected_video_track_mid");
  }
  let t = &mut self.stats[index];
  t.reader_serial = t.reader_serial.checked_add(1).ok_or("reader_generation_exhausted")?;
  let token = t.reader_serial;
  if !t.seen {
   t.seen = true;
   t.mid = mid.map(str::to_owned);
   t.track_id = Some(id.to_owned());
   t.reader_active = token;
  } else {
   t.reader_pending = token;
  }
  Ok((index, token, t.reader_active))
 }
 pub fn bind_legacy_reader(&mut self, id: &str, mid: Option<&str>) -> Result<(usize, u64, u64), &'static str> {
  let t = &mut self.stats[0];
  if t.seen && (t.track_id.as_deref() != Some(id) || t.mid.as_deref() != mid) {
   return Err("unexpected_legacy_track_identity");
  }
  t.reader_serial = t.reader_serial.checked_add(1).ok_or("reader_generation_exhausted")?;
  let token = t.reader_serial;
  if !t.seen {
   t.seen = true;
   t.mid = mid.map(str::to_owned);
   t.track_id = Some(id.to_owned());
   t.reader_active = token;
  } else {
   t.reader_pending = token;
  }
  Ok((0, token, t.reader_active))
 }
 pub fn reader_current(&self, index: usize, token: u64) -> bool {
  self.stats.get(index).is_some_and(|t| token != 0 && (token == t.reader_active || token == t.reader_pending))
 }
 pub fn packet_from(&mut self, index: usize, token: u64, ssrc: u32, len: usize) -> (bool, bool, Option<Route>) {
  if !self.reader_current(index, token) { return (false, false, None); }
  let t = &mut self.stats[index];
  let mut promoted = false;
  if token == t.reader_pending {
   if len == 0 { return (true, false, None); }
   t.reader_active = token;
   t.reader_pending = 0;
   promoted = true;
   if t.ssrc == ssrc {
    for s in self.streams.values_mut().filter(|s| s.track == Some(index)) {
     s.epoch = epoch();
     s.observed = false;
    }
   }
  }
  (true, promoted, self.packet(index, ssrc, len))
 }
 pub fn packet(&mut self,index:usize,ssrc:u32,len:usize)->Option<Route>{let t=&mut self.stats[index];t.packets+=1;t.bytes+=len as u64;if t.ssrc!=ssrc&&(len>0||t.ssrc==0){if t.ssrc!=0{t.ssrc_changes+=1;}t.ssrc=ssrc;if len>0{for s in self.streams.values_mut().filter(|s|s.track==Some(index)){s.epoch=epoch();s.observed=false;}}}self.route(index)}
 pub fn mark_observed(&mut self,route:Route,observed:bool){if self.route_current(route){if let Some(s)=self.streams.get_mut(&route.screen){s.observed=observed&&(s.width==0||s.configured);}}}
 pub fn mark_configured(&mut self,id:u32,configured:bool){if let Some(s)=self.streams.get_mut(&id){s.configured=configured;if !configured{s.observed=false;}}}
 pub fn routes(&self)->Vec<Route>{(0..3).filter_map(|i|self.route(i)).collect()}
 pub fn focus_request(v:&Value)->Result<Focus,&'static str>{let screen=screen_id(v)?;let scope=v["scope"].as_str().filter(|v|!v.is_empty()&&v.len()<=96&&!v.chars().any(char::is_control)).ok_or("invalid_input_scope")?;let token=v["token"].as_u64().filter(|v|*v>0&&*v<=9_007_199_254_740_991).ok_or("invalid_input_token")?;Ok(Focus{screen,scope:scope.into(),token})}
 pub fn prepare_claim(&mut self,focus:&Focus)->Result<(),&'static str>{if focus.token<=self.last_token{return Err("stale_input_token")}self.rendered_route(focus.screen)?;self.last_token=focus.token;self.owner_authorized=false;Ok(())}
 pub fn claim(&mut self,focus:Focus)->Result<(),&'static str>{self.rendered_route(focus.screen)?;self.owner=Some(focus);self.owner_authorized=true;Ok(())}
 pub fn rendered_route(&self,id:u32)->Result<Route,&'static str>{let r=self.route_for(id).ok_or("screen_mapping_or_renderer_pending")?;if !self.streams[&id].observed{return Err("screen_frame_not_observed")}Ok(r)}
 pub fn accepts_input(&self,v:&Value)->Result<u32,&'static str>{let focus=Self::focus_request(v)?;if !self.owner_authorized||self.owner.as_ref()!=Some(&focus){return Err("input_scope_not_current")}self.rendered_route(focus.screen)?;Ok(focus.screen)}
 pub fn matches_revoke(&self,v:&Value)->bool{self.owner.as_ref().is_some_and(|o|v["scope"].as_str()==Some(o.scope.as_str())&&v["token"].as_u64()==Some(o.token))}
 pub fn invalidate_owner(&mut self){self.owner_authorized=false;}
 pub fn revoke(&mut self){self.owner=None;self.owner_authorized=false;}
 pub fn set_size(&mut self,id:u32,w:u32,h:u32)->Result<Route,&'static str>{let s=self.streams.get_mut(&id).ok_or("screen_not_open")?;s.width=w;s.height=h;s.configured=false;s.epoch=epoch();s.observed=false;self.route_for(id).ok_or("screen_mapping_pending")}
 pub fn set_size_if(&mut self,id:u32,w:u32,h:u32,begin:impl FnOnce(Route,u64)->bool)->Result<Route,&'static str>{let old=self.route_for(id).ok_or("screen_mapping_pending")?;let next=epoch();if !begin(old,next){return Err("portrait_epoch_has_au_or_changed")};let s=self.streams.get_mut(&id).ok_or("screen_not_open")?;s.width=w;s.height=h;s.configured=false;s.epoch=next;s.observed=false;self.route_for(id).ok_or("screen_mapping_pending")}
 pub fn preferences(&self,id:u32)->Result<(u64,u64,u32,u32),&'static str>{let s=self.streams.get(&id).ok_or("screen_not_open")?;Ok((s.fps,s.quality,s.width,s.height))}
 pub fn set_preferences(&mut self,id:u32,fps:u64,quality:u64){if let Some(s)=self.streams.get_mut(&id){s.fps=fps;s.quality=quality;}}
 pub fn native_size(&self,id:u32)->Option<(u32,u32)>{let s=self.screens.iter().find(|s|s["id"]==id)?;let r=s.get("initial").filter(|v|v.is_object()).or_else(||s.get("native"))?;Some((u32::try_from(r["width"].as_u64()?).ok()?,u32::try_from(r["height"].as_u64()?).ok()?))}
 pub fn snapshot(&self)->Value{json!({"multiVideo":self.enabled,"answerTracksValid":self.answer.is_some(),"registrationSent":self.registration_sent,"registrationAck":self.registration_ack,"inventoryReceived":self.inventory_generation>0,"inventoryGeneration":self.inventory_generation,"screens":self.screens,"streams":self.streams.iter().map(|(&id,s)|json!({"screenId":id,"open":!s.closing,"captureSent":s.sent,"trackIndex":s.track,"renderSlot":s.binding.map(|v|v.0),"generation":s.binding.map(|v|v.1),"mediaEpoch":s.epoch,"mappingConfirmed":s.track.is_some(),"videoFrameObserved":s.observed,"width":s.width,"height":s.height,"error":s.error})).collect::<Vec<_>>(),"tracks":self.stats.iter().enumerate().map(|(i,t)|json!({"trackIndex":i,"mid":t.mid,"ssrc":t.ssrc,"ssrcChanges":t.ssrc_changes,"trackSeen":t.seen,"packets":t.packets,"bytes":t.bytes,"rtpQueueDrops":t.queue_drops,"staleEpochDrops":t.stale_drops,"capture":t.capture})).collect::<Vec<_>>(),"inputOwner":self.owner.as_ref().map(|o|json!({"screenId":o.screen,"scope":o.scope,"token":o.token})),"error":self.error})}
}
pub fn screen_id(v:&Value)->Result<u32,&'static str>{v["screenId"].as_u64().filter(|v|*v<=i32::MAX as u64).map(|v|v as u32).ok_or("invalid_screen_id")}

#[cfg(test)]mod tests{
 use super::*;
 #[test]fn silent_warm_track_keyframe_requests_are_bounded_and_stop_on_video(){use std::time::Duration as D;assert!(startup_pli_due(D::from_millis(40),D::from_secs(1),0));assert!(!startup_pli_due(D::from_secs(2),D::from_millis(999),0));assert!(!startup_pli_due(D::from_secs(12),D::from_secs(1),0));assert!(!startup_pli_due(D::from_secs(1),D::from_secs(1),1));}
 fn display(g:u64,a:i64,b:i64)->Value{json!({"inventoryGeneration":g,"screens":[{"id":1,"videoTrackIndex":a,"native":{"width":2560,"height":1600}},{"id":0,"videoTrackIndex":b,"native":{"width":1920,"height":1080}}]})}
 fn ready()->Streams{let mut s=Streams::new();s.answer=Some(["a".into(),"b".into(),"c".into()]);s.registration_ack=Some(true);s.observe(&[],&display(1,-1,0));s.open(1).unwrap();s.open(0).unwrap();s.activation_plan();s.activation_start(1);s.activation_sent(1,true);s.activation_start(0);s.activation_sent(0,true);s.bind(1,0,11).unwrap();s.bind(0,1,12).unwrap();s.bind_track("video_0",Some("a")).unwrap();s.bind_track("video_1",Some("b")).unwrap();s.observe(&[],&display(2,1,0));s}
 #[test]fn reverse_mapping_routes_by_screen_not_renderer_order(){let s=ready();assert_eq!(s.route(1).unwrap().slot,0);assert_eq!(s.route(0).unwrap().slot,1);assert_eq!(s.route(1).unwrap().screen,1);assert_ne!(s.route(1).unwrap().epoch,s.route(0).unwrap().epoch);}
 #[test]fn stale_binding_mapping_and_ssrc_queue_tokens_are_rejected(){let mut s=ready();let old=s.route(1).unwrap();s.bind(1,0,13).unwrap();assert!(!s.route_current(old));let old=s.route(1).unwrap();s.packet(1,55,1);assert!(!s.route_current(old));let old=s.route(1).unwrap();s.observe(&[],&display(3,0,1));assert!(!s.route_current(old));}
 #[test]fn replacement_promotes_only_on_payload_and_rejects_old_reader(){let mut s=ready();let(_,old,_)=s.bind_reader("video_1",Some("b")).unwrap();s.stats[1].reader_active=old;s.stats[1].reader_pending=0;s.packet_from(1,old,55,5);let first=s.route(1).unwrap();let sibling=s.route(0).unwrap();let(_,new,_)=s.bind_reader("video_1",Some("b")).unwrap();assert_eq!(s.packet_from(1,new,66,0),(true,false,None));assert_eq!(s.route(1),Some(first));s.packet_from(1,old,55,0);assert_eq!(s.route(1),Some(first));let (_,promoted,route)=s.packet_from(1,new,66,5);assert!(promoted);let changed=route.unwrap();assert_ne!(changed.epoch,first.epoch);assert_eq!(s.route(0),Some(sibling));assert_eq!(s.packet_from(1,old,55,5),(false,false,None));assert_eq!(s.route(1),Some(changed));assert_eq!(s.stats[1].ssrc_changes,1);}
 #[test]fn late_reader_insertion_cannot_revive_superseded_candidate(){let mut s=ready();let(_,active,_)=s.bind_reader("video_1",Some("b")).unwrap();s.stats[1].reader_active=active;s.stats[1].reader_pending=0;let(_,old_candidate,_)=s.bind_reader("video_1",Some("b")).unwrap();let(_,new_candidate,_)=s.bind_reader("video_1",Some("b")).unwrap();assert!(s.reader_current(1,active));assert!(!s.reader_current(1,old_candidate));assert!(s.reader_current(1,new_candidate));assert!(s.packet_from(1,new_candidate,55,5).1);assert!(!s.reader_current(1,active));assert!(s.reader_current(1,new_candidate));let(_,later,_)=s.bind_reader("video_1",Some("b")).unwrap();assert!(s.reader_current(1,new_candidate));assert!(s.reader_current(1,later));assert!(!s.reader_current(1,old_candidate));}
 #[test]fn legacy_track_identity_and_padding_do_not_promote_replacement(){let mut s=Streams::default();let(_,old,_)=s.bind_legacy_reader("arbitrary-track",Some("legacy-mid")).unwrap();s.packet_from(0,old,10,5);assert!(s.bind_legacy_reader("different",Some("legacy-mid")).is_err());assert!(s.bind_legacy_reader("arbitrary-track",Some("other")).is_err());let(_,new,_)=s.bind_legacy_reader("arbitrary-track",Some("legacy-mid")).unwrap();assert_eq!(s.packet_from(0,new,11,0),(true,false,None));assert!(s.reader_current(0,old));assert!(s.packet_from(0,new,11,5).1);assert_eq!(s.packet_from(0,old,10,0),(false,false,None));assert!(s.reader_current(0,new));}
 #[test]fn fallback_epoch_claim_keeps_old_route_when_au_arrives(){let mut s=ready();let old=s.route_for(1).unwrap();assert!(s.set_size_if(1,450,720,|route,_|{assert_eq!(route,old);false}).is_err());assert_eq!(s.route_for(1),Some(old));let new=s.set_size_if(1,450,720,|route,next|route==old&&next>route.epoch).unwrap();assert_ne!(new.epoch,old.epoch);assert!(!s.route_current(old));}
 #[test]fn duplicate_or_unknown_mapping_does_not_route(){let mut s=ready();s.observe(&[],&display(3,0,0));assert!(s.routes().is_empty());assert!(s.open(99).is_err());assert!(s.bind(1,1,90).is_err());}
 #[test]fn close_has_specific_id_and_preserves_sibling(){let mut s=ready();let brother=s.route(0).unwrap();let bytes=s.begin_close(1).unwrap();let a=blob(&bytes,3).unwrap();assert_eq!(num(a,1),Some(7));assert_eq!(blob(a,2).unwrap(),br#"{"screen_id":1}"#);assert!(s.route(1).is_none());assert_eq!(s.route(0),Some(brother));s.close_sent(1,true);assert_eq!(s.route(0),Some(brother));}
 #[test]fn focus_scope_token_and_release_barrier_are_explicit(){let mut s=ready();let a=Streams::focus_request(&json!({"screenId":1,"scope":"pane-a","token":1})).unwrap();assert!(s.prepare_claim(&a).is_err());s.mark_observed(s.route(1).unwrap(),true);s.prepare_claim(&a).unwrap();assert!(s.owner.is_none());s.claim(a.clone()).unwrap();assert_eq!(s.accepts_input(&json!({"screenId":1,"scope":"pane-a","token":1})),Ok(1));assert!(s.accepts_input(&json!({"screenId":0,"scope":"pane-a","token":1})).is_err());s.mark_observed(s.route(0).unwrap(),true);let b=Focus{screen:0,scope:"pane-b".into(),token:2};s.prepare_claim(&b).unwrap();s.revoke();s.claim(b).unwrap();assert!(!s.matches_revoke(&json!({"scope":"pane-a","token":1})));assert!(s.prepare_claim(&a).is_err());}
 #[test]fn registration_requires_correlated_success_before_activation(){let mut s=Streams::new();s.observe(&[],&display(1,-1,0));s.open(1).unwrap();assert!(s.activation_plan().is_empty());let p=register();assert_eq!(blob(blob(&p,21).unwrap(),15).unwrap(),[10,3,0,1,2]);let mut h=vec![];crate::wire::int(1,REGISTER_SEQ+1,&mut h);let mut r=vec![];crate::wire::bytes(1,&h,&mut r);crate::wire::bytes(11,&[],&mut r);s.registration_sent=true;s.observe(&crate::wire::envelope(0,22,&r),&display(1,-1,0));assert!(s.registration_ack.is_none());h.clear();crate::wire::int(1,REGISTER_SEQ,&mut h);r.clear();crate::wire::bytes(1,&h,&mut r);crate::wire::bytes(11,&[],&mut r);s.observe(&crate::wire::envelope(0,22,&r),&display(1,-1,0));assert_eq!(s.registration_ack,Some(true));assert_eq!(s.activation_plan().len(),1);}
 #[test]fn inventory_arriving_during_activation_send_is_reconciled(){let mut s=Streams::new();s.registration_ack=Some(true);s.observe(&[],&display(1,-1,0));s.open(1).unwrap();s.activation_plan();s.activation_start(1);s.observe(&[],&display(2,1,0));s.activation_sent(1,true);s.bind(1,0,1).unwrap();s.answer=Some(["a".into(),"b".into(),"c".into()]);s.bind_track("video_1",Some("b")).unwrap();assert_eq!(s.route(1).unwrap().screen,1);}
 #[test]fn answer_requires_three_active_exact_track_ids(){let s="m=video 9 RTP/SAVPF 102\r\na=mid:b\r\na=msid:s video_1\r\nm=video 9 RTP/SAVPF 102\r\na=mid:a\r\na=msid:s video_0\r\nm=video 9 RTP/SAVPF 102\r\na=mid:c\r\na=msid:s video_2\r\n";assert_eq!(answer_tracks(s),Some(["a".into(),"b".into(),"c".into()]));assert!(answer_tracks(&s.replace("video_1","video_2")).is_none());assert!(answer_tracks(&s.replace("m=video 9","m=video 0")).is_none());assert!(answer_tracks(&s.replace("a=mid:c","a=mid:a")).is_none());}
 #[test]fn third_stream_closes_without_changing_two_sibling_routes(){let mut s=ready();let a=s.route(0).unwrap();let b=s.route(1).unwrap();let inventory=|g|json!({"inventoryGeneration":g,"screens":[{"id":0,"videoTrackIndex":0},{"id":1,"videoTrackIndex":1},{"id":2,"videoTrackIndex":2}]});s.observe(&[],&inventory(3));s.open(2).unwrap();s.activation_start(2);s.activation_sent(2,true);s.observe(&[],&inventory(4));s.bind(2,2,99).unwrap();s.bind_track("video_2",Some("c")).unwrap();assert_eq!(s.packet(2,303,100).unwrap().screen,2);assert_eq!(s.route(2).unwrap().slot,2);s.begin_close(2).unwrap();assert!(s.route(2).is_none());s.close_sent(2,true);assert_eq!(s.route(0),Some(a));assert_eq!(s.route(1),Some(b));assert!(s.bind(1,3,1).is_err());}
}
