//! Live adapter around the unchanged S2 receiver. Bounded metadata; no video recording.
use crate::media;
use serde_json::{json,Value};
use std::time::Instant;
pub struct Report;impl Report {fn emit(&self,_line:impl AsRef<str>) {}}
use webrtc::rtp::packet::Packet;
use std::collections::{HashSet,VecDeque};
extern "C" { fn s5_submit_oriented_epoch(data:*const u8,len:usize,ts:u32,flags:u32,epoch:u64,orientation:u32)->i32; fn s26_discontinuity(); fn s5_submit_slot_oriented_epoch(slot:u32,generation:u32,data:*const u8,len:usize,ts:u32,flags:u32,epoch:u64,orientation:u32)->i32; fn s5_video_slot_discontinuity(slot:u32,generation:u32); fn s5_video_note_epoch_au(epoch:u64); fn s5_video_slot_note_epoch_au(slot:u32,generation:u32,epoch:u64); }
pub struct Capture {
 cvo_id:u8, orientations:crate::orientation::Frames, cvo_packets:u64, cvo_rejected:u64, last_orientation:u32,
 slot:Option<(u32,u32)>, receiver:media::Receiver, pub aus:Vec<Value>, pub errors:Vec<String>, pub pli:u64, epoch:u64,
 packets:u64,padding:u64,payload_bytes:u64,seen:HashSet<u64>,recent:VecDeque<u64>,first:Option<u64>,highest:u64,unique:u64,duplicates:u64,reordered:u64,
 complete_aus:u64,no_picture:u64,profile_rejected:u64,timestamp_rejected:u64,oversize_rejected:u64,other_nal_rejected:u64,metadata_rejected:u64,started:Instant,last_ts:Option<u32>,ticks:i64,accepted:u64,dropped:u64,codec:u32,nals:crate::nal_policy::NalPolicy,pub request_pli:bool,
}
impl Capture {
 pub fn new(codec:u32)->Self{Self{cvo_id:0,orientations:crate::orientation::Frames::default(),cvo_packets:0,cvo_rejected:0,last_orientation:0,slot:None,receiver:media::Receiver::new(if codec==2{media::Codec::H265}else{media::Codec::H264}),aus:Vec::new(),errors:Vec::new(),pli:0,epoch:0,packets:0,padding:0,payload_bytes:0,seen:HashSet::new(),recent:VecDeque::new(),first:None,highest:0,unique:0,duplicates:0,reordered:0,complete_aus:0,no_picture:0,profile_rejected:0,timestamp_rejected:0,oversize_rejected:0,other_nal_rejected:0,metadata_rejected:0,started:Instant::now(),last_ts:None,ticks:0,accepted:0,dropped:0,codec,nals:crate::nal_policy::NalPolicy::default(),request_pli:false}}
 pub fn for_epoch(epoch:u64,codec:u32)->Self{let mut c=Self::new(codec);c.epoch=epoch;c.request_pli=true;c}
 pub fn for_slot(epoch:u64,slot:u32,generation:u32,codec:u32)->Self{let mut c=Self::for_epoch(epoch,codec);c.slot=Some((slot,generation));c}
 fn discontinuity(&mut self){self.request_pli=true;if self.codec==2{self.nals=crate::nal_policy::NalPolicy::default();self.last_ts=None;self.ticks=0;}unsafe{if let Some((s,g))=self.slot{s5_video_slot_discontinuity(s,g)}else{s26_discontinuity()}};}
 fn output(&mut self,o:media::Output,log:&Report){
  if o.pli{self.pli+=1;self.discontinuity();}
  if o.units.len()!=o.timestamps.len(){self.metadata_rejected+=1;self.errors.push("AU timestamp metadata mismatch".into());self.discontinuity();return;}
  for (data,ts) in o.units.into_iter().zip(o.timestamps){
   self.complete_aus+=1;
   unsafe{if let Some((s,g))=self.slot{s5_video_slot_note_epoch_au(s,g,self.epoch)}else{s5_video_note_epoch_au(self.epoch)}};
   if data.len()>1024*1024{self.oversize_rejected+=1;if self.errors.len()<8{self.errors.push("bounded session/AU limit".into())}self.discontinuity();continue;}
   let picture=match self.nals.picture(&data,self.codec){Ok(Some(v))=>v,Ok(None)=>{self.no_picture+=1;continue},Err(e)=>{if crate::nal_policy::is_unsupported_hevc_profile(e){self.profile_rejected+=1}else{self.other_nal_rejected+=1}if self.errors.len()<8{self.errors.push(e.into())}self.discontinuity();continue;}};
   if let Some(last)=self.last_ts {let Some(delta)=crate::nal_policy::rtp_delta(self.codec,last,ts)else{self.timestamp_rejected+=1;self.discontinuity();if self.errors.len()<8{self.errors.push("invalid AU timestamp/order".into())}continue;};self.ticks+=delta;}self.last_ts=Some(ts);
   let types=picture.types;let key=picture.key;let flags=(if key{2}else{0})|(if picture.ready{8}else{0});let normalized=picture.data;
   if !crate::nal_policy::fits_native_input(normalized.len()){self.oversize_rejected+=1;if self.errors.len()<8{self.errors.push("normalized_AU_exceeds_native_limit".into())}self.discontinuity();continue;}
   let orientation=match self.orientations.take(ts){Ok(value)=>value.packed(),Err(_)=>{self.cvo_rejected+=1;self.metadata_rejected+=1;self.request_pli=true;continue;}};self.last_orientation=orientation;
   let rc=unsafe{if let Some((s,g))=self.slot{s5_submit_slot_oriented_epoch(s,g,normalized.as_ptr(),normalized.len(),ts,flags,self.epoch,orientation)}else{s5_submit_oriented_epoch(normalized.as_ptr(),normalized.len(),ts,flags,self.epoch,orientation)}};
   if rc==0{self.accepted+=1}else{self.dropped+=1;if rc==1{self.request_pli=true}}
   let n=self.aus.len();if self.aus.len()>=2048 {self.aus.remove(0);}self.aus.push(json!({"index":n,"length":data.len(),"timestamp":ts,"pts_us":self.ticks*1000000/90000,"keyframe":key,"nalu_types":types,"queue_result":rc,"arrival_ms":self.started.elapsed().as_secs_f64()*1000.}));
   if n<3||key||(n+1)%30==0{log.emit(format!("AU index={n} bytes={} timestamp={ts} pts_us={} keyframe={key} queue_result={rc}",data.len(),self.ticks*1000000/90000));}
  }
 }
 pub fn push(&mut self,p:Packet,cvo_id:u8,log:&Report){self.cvo_id=cvo_id;self.orientations.set_enabled(cvo_id!=0);let h=&p.header;self.packets+=1;self.payload_bytes+=p.payload.len() as u64;if h.padding&&p.payload.is_empty(){self.padding+=1;}
  if h.version!=2||(p.payload.is_empty()&&!h.padding){if self.errors.len()<8{self.errors.push("invalid RTP header/payload".into())}self.discontinuity();return;}
  let seq=h.sequence_number as u64;let base=self.highest&!65535;let mut ext=if self.first.is_none(){seq}else{base+seq};if self.first.is_some(){if ext+32768<self.highest{ext+=65536}else if ext>self.highest+32768&&ext>=65536{ext-=65536}}if !self.seen.insert(ext){self.duplicates+=1}else{self.unique+=1;self.recent.push_back(ext);if self.recent.len()>8192{if let Some(v)=self.recent.pop_front(){self.seen.remove(&v);}}}if self.first.is_some()&&ext<self.highest{self.reordered+=1}self.first.get_or_insert(ext);self.highest=self.highest.max(ext);
  if !p.payload.is_empty(){let ext=if cvo_id==0{None}else{h.get_extension(cvo_id)};if ext.is_some(){self.cvo_packets+=1;}self.orientations.note(h.timestamp,ext.as_deref());}
  let out=self.receiver.push(media::Packet{seq:h.sequence_number,timestamp:h.timestamp,marker:h.marker,payload:p.payload.to_vec(),padding_only:h.padding&&p.payload.is_empty()});self.output(out,log);
 }
 pub fn expire(&mut self,log:&Report){let out=self.receiver.expire();self.output(out,log)}
 /// Bounded numeric-only counters for the current media epoch. No payload or error text.
 pub fn counters(&self)->Value{json!({"cvoId":self.cvo_id,"cvoPackets":self.cvo_packets,"cvoRejected":self.cvo_rejected,"orientation":self.last_orientation,"epoch":self.epoch,"packets":self.packets,"padding":self.padding,"payloadBytes":self.payload_bytes,"completeAus":self.complete_aus,"accepted":self.accepted,"queueRejected":self.dropped,"noPicture":self.no_picture,"profileRejected":self.profile_rejected,"timestampRejected":self.timestamp_rejected,"oversizeRejected":self.oversize_rejected,"otherNalRejected":self.other_nal_rejected,"metadataRejected":self.metadata_rejected,"reassemblyPli":self.pli})}
 pub fn stats(&self)->Value{json!({"cvoId":self.cvo_id,"cvoPackets":self.cvo_packets,"cvoRejected":self.cvo_rejected,"orientation":self.last_orientation,"packets_received":self.packets,"padding_only_packets":self.padding,"unique_packets":self.unique,"missing_packets":self.first.map(|f|(self.highest-f+1).saturating_sub(self.unique)).unwrap_or(0),"duplicates":self.duplicates,"reordered":self.reordered,"payload_bytes":self.payload_bytes,"access_units":self.aus.len(),"keyframes":self.aus.iter().filter(|v|v["keyframe"]==true).count(),"accepted":self.accepted,"queue_rejected":self.dropped,"reassembly_pli_events":self.pli,"errors":self.errors,"elapsed_ms":self.started.elapsed().as_millis() as u64})}
 pub fn evidence(&self)->Value{json!({"origin":"live TrackRemote.read_rtp DTLS-SRTP -> unchanged S2 Receiver -> C ABI bounded queue", "aus":self.aus,"stats":self.stats()})}
}
