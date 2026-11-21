//! Shapes from viewer-connect-shape-20261016.md; values describe caller capabilities.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use crate::protocol::{decode_wire, WireValue};

pub const CHANNELS: [&str; 5] = ["CONTROL_DATA_CHANNEL", "TEXT_DATA_CHANNEL", "STREAMER_DATA_CHANNEL", "FILE_DATA_CHANNEL", "BINARY_DATA_CHANNEL"];
// Keep the interoperable media profile. Decoder allocation is not an SDP profile negotiation.
pub const H264_FMTP:&str="level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f";
// Account-owned desktop sessions use Normal. Assistance rejects Windows privacy
// requests (402), even when enhanced privacy is advertised. CaptureParams still
// follow remote resolution; runtime stream requests keep physical dimensions -1.
pub const OWNED_DESKTOP_CONNECT_TYPE:u64=1;
static LOCAL_DISPLAY:std::sync::Mutex<Option<(u32,u32,u32)>>=std::sync::Mutex::new(None);
pub fn local_display(w:u64,h:u64,hz:u64)->Result<(),&'static str>{if !(2..=16384).contains(&w)||!(2..=16384).contains(&h)||!(1..=1000).contains(&hz){return Err("invalid_viewer_display")};*LOCAL_DISPLAY.lock().unwrap()=Some((w as u32,h as u32,hz as u32));Ok(())}
#[cfg(test)]mod recovery_tests{
 use super::*;
 #[test]fn recovery_owned_desktop_allows_manual_privacy_and_follows_remote_resolution(){assert_eq!(OWNED_DESKTOP_CONNECT_TYPE,1);let saved=*LOCAL_DISPLAY.lock().unwrap();local_display(2560,1600,165).unwrap();let shape=desktop_shape();assert_eq!((shape.width,shape.height),(2560,1600));let options=shape.connect_options("synthetic",false).unwrap();let outer=decode_wire(&options).unwrap();let cap=outer.iter().find_map(|f|match(f.number,&f.value){(3,WireValue::Bytes(b))=>Some(*b),_=>None}).unwrap();let params=decode_wire(cap).unwrap();assert!(!params.iter().any(|f|f.number==9));assert!(params.iter().any(|f|f.number==1&&f.value==WireValue::Varint(1)));let flag=outer.iter().find_map(|f|match(f.number,&f.value){(11,WireValue::Bytes(b))=>Some(*b),_=>None}).unwrap();assert!(decode_wire(flag).unwrap().iter().any(|f|f.number==4&&f.value==WireValue::Varint(2)));assert!(decode_wire(&session_features(false)).unwrap().iter().any(|f|f.number==4&&f.value==WireValue::Varint(2)));assert!(outer.iter().any(|f|f.number==10&&f.value==WireValue::Varint(OWNED_DESKTOP_CONNECT_TYPE)));let mut other=shape.clone();other.capture_type=5;let non_desktop=other.connect_options("synthetic",false).unwrap();assert!(decode_wire(&non_desktop).unwrap().iter().any(|f|f.number==10&&f.value==WireValue::Varint(2)));*LOCAL_DISPLAY.lock().unwrap()=saved;}
}
pub fn varint(mut n: u64, out: &mut Vec<u8>) { while n >= 128 { out.push(n as u8 | 128); n >>= 7; } out.push(n as u8); }
pub fn int(field: u32, value: u64, out: &mut Vec<u8>) { varint(u64::from(field) << 3,out); varint(value,out); }
pub fn bytes(field: u32, value: &[u8], out: &mut Vec<u8>) { varint((u64::from(field)<<3)|2,out); varint(value.len() as u64,out); out.extend(value); }
pub fn envelope(seq:u64, kind:u32, payload:&[u8]) -> Vec<u8> {
    let mut out=Vec::new(); int(1,seq,&mut out); bytes(kind,payload,&mut out); out
}
#[derive(Clone, Deserialize)]
pub struct Decoder { pub fps:u32, pub codec:u32, pub width:u32, pub height:u32, pub chroma:u32 }
#[derive(Clone, Deserialize, Serialize)]
pub struct Display { pub id:u32, pub fps:u32, pub r#type:u32, pub hdr:u32 }
#[derive(Clone, Deserialize, Serialize)]
pub struct Codec { pub video_codec:u32, pub chroma_sampling:u32, #[serde(skip_serializing_if="Option::is_none")] pub codec_impl:Option<u32>, pub bit_depth:u32, pub width:u32, pub height:u32 }
#[derive(Clone, Deserialize)]
pub struct Shape {
    pub capture_type:u32,
    pub platform:u32,
    pub client_version:String,
    pub width:u32,
    pub height:u32,
    pub fps:u32,
    pub chroma:u32,
    pub decoders:Vec<Decoder>,
    pub display_modes:Vec<[u32;3]>,
    pub displays:Vec<Display>,
    pub codecs:Vec<Codec>,
    /// FeatureFlag {field: version} pairs (ConnectOptions 11). Empty by default; official hosts may
    /// require it (live: official Mac/Windows hosts did not answer an empty flag set).
    #[serde(default)]
    pub feature_flag:Vec<[u32;2]>,
}
impl Shape {
    pub fn validate(&self) -> Result<(),String> {
        if ![1,5,7,8,9].contains(&self.capture_type) || ![2,3,4].contains(&self.platform)
            || self.width==0 || self.height==0 || self.fps==0 || ![1,3].contains(&self.chroma) {
            return Err("Invalid explicit viewer shape".into());
        }
        if self.decoders.iter().any(|d| ![1,2].contains(&d.codec) || ![1,3].contains(&d.chroma) || d.width==0 || d.height==0 || d.fps==0) {
            return Err("Invalid decoder capability".into());
        }
        Ok(())
    }
    pub fn validate_session(&self)->Result<(),String> {
        self.validate()?;
        if self.codecs.iter().any(|c|![1,2].contains(&c.video_codec) || ![1,3].contains(&c.chroma_sampling))
            || (self.capture_type==1 && self.decoders.is_empty()) {
            return Err("Sessions require supported decoder and codec capabilities".into());
        }
        Ok(())
    }
    /// Advertise software decoding of both 8-bit chroma formats. Keep caller size/fps limits.
    /// The explicit chroma request is sent on CONTROL, so initial capture stays 4:2:0.
    pub fn video_preferences(&self,h264_only:bool)->Self {
        let mut shape=self.clone();
        if shape.capture_type==1 {
            shape.chroma=1;
            shape.decoders.clear();
            for codec in if h264_only {&[1][..]}else{&[2,1][..]} {
                let base=self.decoders.iter().find(|d|d.codec==*codec).or_else(||self.decoders.first());
                if let Some(base)=base {for chroma in [1,3] {
                    let mut d=base.clone();d.codec=*codec;d.chroma=chroma;shape.decoders.push(d);
                }}
            }
        }
        if h264_only {shape.decoders.retain(|d|d.codec==1);shape.codecs.retain(|c|c.video_codec==1);}
        shape
    }
    pub fn connect_options(&self, device:&str, clipboard:bool) -> Result<Vec<u8>,String> { self.connect_options_multi(device,clipboard,false) }
    pub fn connect_options_multi(&self, device:&str, clipboard:bool, multi:bool) -> Result<Vec<u8>,String> {
        self.validate()?;
        let mut out=Vec::new(); int(1,self.capture_type.into(),&mut out);
        if [1,8].contains(&self.capture_type) { int(2,u64::MAX,&mut out); }
        if [1,5].contains(&self.capture_type) {
            let mut params=Vec::new(); int(1,1,&mut params); int(2,5,&mut params); int(4,3,&mut params);
            let mut size=Vec::new(); int(1,self.width.into(),&mut size); int(2,self.height.into(),&mut size);
            bytes(5,&size,&mut params);
            if self.capture_type==1 { int(7,self.chroma.into(),&mut params); int(10,2,&mut params); int(11,self.fps.into(),&mut params); }
            bytes(3,&params,&mut out);
            for d in &self.decoders {
                let mut cap=Vec::new();
                for (f,v) in [(1,d.fps),(2,d.codec),(3,d.width),(4,d.height)] { int(f,v.into(),&mut cap); }
                if self.capture_type==1 { int(5,d.chroma.into(),&mut cap); }
                bytes(4,&cap,&mut out);
            }
            for mode in &self.display_modes {
                let mut value=Vec::new(); for (f,v) in mode.iter().enumerate() { int(f as u32+1,(*v).into(),&mut value); }
                bytes(6,&value,&mut out);
            }
        }
        int(8,self.platform.into(),&mut out); bytes(9,device.as_bytes(),&mut out); int(10,if self.capture_type==1&&!multi {OWNED_DESKTOP_CONNECT_TYPE}else{2},&mut out);
        if self.capture_type==1 {
            let mut flags=Vec::new(); for [field,version] in &self.feature_flag { if *field!=8 {int((*field).into(),(*version).into(),&mut flags);} }
            if clipboard{int(8,3,&mut flags);}
            bytes(11,&flags,&mut out);
        }
        if self.capture_type!=5 { bytes(12,self.client_version.as_bytes(),&mut out); }
        Ok(out)
    }
    pub fn control(&self, client:&str, id:&str, ice:&str) -> Result<Value,String> {
        self.validate()?;
        let streamer=json!({"control_id":id,"device_capability":{"display_info":self.displays,"ice_id":"","video_codec_capability":self.codecs}});
        // Official Control::SerializeSioMsg (libstreamer 0x107bf8) sends only these three keys. A
        // viewer-chosen ice_id reaches the host via be-controlled while the ack assigns another, and the
        // official host drops the offer ("drop the soac event ... not in current ice connections").
        let _=(client,ice);
        Ok(json!({"app_control_id":id,"app_data":{"_placeholder":true,"num":0},"streamer_data":streamer.to_string()}))
    }
}

/// Existing viewer FeatureFlag pairs; clipboard uses the host text protocol version (3).
/// Session encoders omit clipboard when its local backend is disabled or unavailable.
pub const VIEWER_FEATURES:[[u32;2];8]=[[1,6],[2,2],[3,1],[4,2],[6,2],[7,2],[8,3],[9,1]];
pub fn feature_flag(flags:&[[u32;2]]) -> Vec<u8> { let mut out=Vec::new(); for [f,v] in flags { int(*f,(*v).into(),&mut out); } out }
pub fn echo_request(seq:u64) -> Vec<u8> {echo_request_with_clipboard(seq,false)}
fn session_features(clipboard:bool)->Vec<u8>{
    // The implemented manual privacy controls require their capability in both
    // ConnectOptions and CONTROL echo. Advertisement does not enable a mode.
    let mut flags:Vec<_>=VIEWER_FEATURES.iter().copied().filter(|p|p[0]!=8).collect();
    if clipboard{flags.push([8,3]);}feature_flag(&flags)
}
pub fn echo_request_with_clipboard(seq:u64,clipboard:bool)->Vec<u8>{
    let mut action=Vec::new();int(1,0,&mut action);bytes(4,&session_features(clipboard),&mut action);envelope(seq,3,&action)
}
pub fn echo_clipboard_supported(data:&[u8])->bool{
    let Ok(fields)=decode_wire(data) else{return false};
    fields.iter().any(|f|match (f.number,&f.value){
        (3,WireValue::Bytes(action))=>decode_wire(action).is_ok_and(|fields|fields.iter().any(|f|match (f.number,&f.value){
            (4,WireValue::Bytes(flags))=>decode_wire(flags).is_ok_and(|flags|flags.iter().any(|f|matches!((f.number,&f.value),(8,WireValue::Varint(3..))))),_=>false,
        })),_=>false,
    })
}
/// Official hosts also send an echo request (SimpleAction action 0) and repeat it until answered.
/// Returns the request's Message seq when `data` is such a request.
pub fn echo_request_seq(data:&[u8]) -> Option<u64> {
    let fields=decode_wire(data).ok()?;
    let seq=fields.iter().find_map(|f|match (f.number,&f.value){(1,WireValue::Varint(v))=>Some(*v),_=>None})?;
    fields.iter().find_map(|f|match (f.number,&f.value) {
        // proto3 omits the default action 0, so a SimpleAction without field 1 is an echo request too.
        (3,WireValue::Bytes(action))=>decode_wire(action).ok()?.iter().find_map(|f|match (f.number,&f.value){(1,WireValue::Varint(v))=>Some(*v),_=>None}).unwrap_or(0).eq(&0).then_some(seq),
        _=>None,
    })
}
/// Answer like the host side does: action 1, args {"seq": request seq}, our FeatureFlag.
pub fn echo_response(seq:u64,request_seq:u64)->Vec<u8>{echo_response_with_clipboard(seq,request_seq,false)}
pub fn echo_response_with_clipboard(seq:u64, request_seq:u64,clipboard:bool) -> Vec<u8> {
    let mut action=Vec::new(); int(1,1,&mut action);
    bytes(2,format!("{{\"seq\":{request_seq}}}").as_bytes(),&mut action);
    bytes(4,&session_features(clipboard),&mut action); envelope(seq,3,&action)
}
pub fn echo_matches(data:&[u8], seq:u64) -> bool {
    let Ok(fields)=decode_wire(data) else {return false};
    fields.iter().any(|f| match (f.number,&f.value) {
        (3,WireValue::Bytes(action))=> {
            let Ok(fields)=decode_wire(action) else {return false};
            let response=fields.iter().any(|f|f.number==1 && f.value==WireValue::Varint(1));
            response && fields.iter().any(|f|match (f.number,&f.value) {
                (2,WireValue::Bytes(args))=>serde_json::from_slice::<Value>(args).ok().and_then(|v|v.get("seq").and_then(Value::as_u64))==Some(seq), _=>false,
            })
        }, _=>false,
    })
}

pub fn request_video_track()->Vec<u8>{
    let mut header=Vec::new();int(1,2_000_001,&mut header);
    let mut rpc=Vec::new();bytes(1,&header,&mut rpc);bytes(15,&[],&mut rpc);
    envelope(2_000_001,21,&rpc)
}
/// Explicit registration of the one negotiated video transceiver, on TEXT/text PPID.
pub fn register_video_track_zero(seq:u64)->Vec<u8>{let mut h=vec![];int(1,seq,&mut h);let mut tracks=vec![];bytes(1,&[0],&mut tracks);let mut rpc=vec![];bytes(1,&h,&mut rpc);bytes(15,&tracks,&mut rpc);envelope(seq,21,&rpc)}

// Alter only the transmitted copy after set_local_description, as upstream rtc.rs does.
pub fn offer_copy(sdp:&str)->String {
 let mut sdp=sdp.to_owned();
 if !sdp.contains("a=x-uuremote-quic") {if let Some(i)=sdp.find("a=group:BUNDLE"){sdp.insert_str(i,"a=x-uuremote-quic\r\n");}}
 if sdp.contains("a=max-message-size:"){return sdp}
 let eol=if sdp.contains("\r\n"){"\r\n"}else{"\n"};let mut out=String::new();
 for line in sdp.split_inclusive('\n'){out.push_str(line);if line.trim_end().starts_with("a=sctp-port:"){out.push_str("a=max-message-size:262144");out.push_str(eol);}}out
}
#[cfg(test)]mod desktop_tests {
 use super::*;
 #[test]fn desktop_options_have_observed_flags_and_media_capabilities(){
  let shape=desktop_shape();shape.validate_session().unwrap();let options=shape.connect_options("synthetic-device",false).unwrap();let fields=decode_wire(&options).unwrap();
  assert!(fields.iter().any(|f|f.number==1&&f.value==WireValue::Varint(1)));
  assert!(fields.iter().any(|f|f.number==2&&f.value==WireValue::Varint(u64::MAX)));
  assert!(fields.iter().any(|f|f.number==10&&f.value==WireValue::Varint(OWNED_DESKTOP_CONNECT_TYPE)));
  let flags=fields.iter().find_map(|f|match(f.number,&f.value){(11,WireValue::Bytes(b))=>Some(*b),_=>None}).unwrap();
  assert_eq!(hex::encode(flags),"0806100218012002300238024801");
  let header=shape.control("client","synthetic-app","synthetic-proposal").unwrap();let streamer:Value=serde_json::from_str(header["streamer_data"].as_str().unwrap()).unwrap();
  assert_eq!(streamer["control_id"],header["app_control_id"]);assert_eq!(streamer["device_capability"]["ice_id"],"");assert_eq!(streamer["device_capability"]["video_codec_capability"][0]["video_codec"],1);
 }
 #[test]fn echo_and_video_request_are_correlated_protobuf(){assert_eq!(echo_request_seq(&echo_request(7)),Some(7));assert!(echo_matches(&echo_response(99,7),7));assert!(!echo_matches(&echo_response(99,7),99));let msg=request_video_track();let rpc=decode_wire(&msg).unwrap().into_iter().find_map(|f|match(f.number,f.value){(21,WireValue::Bytes(b))=>Some(b),_=>None}).unwrap();assert!(decode_wire(rpc).unwrap().iter().any(|f|matches!((f.number,&f.value),(15,WireValue::Bytes(b))if b.is_empty())));}
 #[test]fn sent_offer_uses_real_crlf_and_idempotent_attributes(){let s="v=0\r\na=group:BUNDLE 0 1 2\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=sctp-port:5000\r\n";let out=offer_copy(s);assert!(out.contains("a=x-uuremote-quic\r\na=group:BUNDLE"));assert!(out.contains("a=sctp-port:5000\r\na=max-message-size:262144\r\n"));assert!(!out.contains("\\r\\n"));assert_eq!(offer_copy(&out),out);}
}
pub fn desktop_shape()->Shape {
 let mut shape:Shape=serde_json::from_str(r#"{"capture_type":1,"platform":3,"client_version":"4.42.0","width":1280,"height":720,"fps":30,"chroma":1,"decoders":[{"fps":30,"codec":1,"width":1280,"height":720,"chroma":1}],"display_modes":[[1280,720,30]],"displays":[{"id":1,"fps":30,"type":0,"hdr":0}],"codecs":[{"video_codec":1,"chroma_sampling":1,"codec_impl":34,"bit_depth":8,"width":1280,"height":720}],"feature_flag":[[1,6],[2,2],[3,1],[4,2],[6,2],[7,2],[9,1]]}"#).unwrap();
 // Local physical display and decoder envelope describe different capabilities.
 if let Some((w,h,hz))=*LOCAL_DISPLAY.lock().unwrap(){shape.width=w;shape.height=h;shape.display_modes=vec![[w,h,hz]];for d in &mut shape.displays{d.fps=hz;}}
 #[cfg(target_env="ohos")] unsafe {
  extern "C"{fn s5_video_limit_width()->u32;fn s5_video_limit_height()->u32;}
  let(w,h)=(s5_video_limit_width(),s5_video_limit_height());
  if (2..=8192).contains(&w)&&(2..=8192).contains(&h){for d in &mut shape.decoders{d.width=w;d.height=h;}for c in &mut shape.codecs{c.width=w;c.height=h;}}
 }
 shape
}
#[cfg(test)]mod display_tests{
 use super::*;
 #[test]fn display_track_registration_uses_packed_zero_and_correlated_header(){let packet=register_video_track_zero(4_100_007);let outer=decode_wire(&packet).unwrap();let rpc=outer.iter().find_map(|f|match(f.number,&f.value){(21,WireValue::Bytes(b))=>Some(*b),_=>None}).unwrap();let fields=decode_wire(rpc).unwrap();assert!(fields.iter().any(|f|matches!((f.number,&f.value),(1,WireValue::Bytes(_)))));let tracks=fields.iter().find_map(|f|match(f.number,&f.value){(15,WireValue::Bytes(b))=>Some(*b),_=>None}).unwrap();assert_eq!(tracks,&[10,1,0]);}
}
#[cfg(test)]mod handshake_tests{
 use super::*;
 #[test]fn handshake_preserves_compatible_profile_and_remote_mode(){assert_eq!(H264_FMTP,"level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f");let options=desktop_shape().connect_options("synthetic",false).unwrap();let fields=decode_wire(&options).unwrap();let cap=fields.iter().find_map(|f|match(f.number,&f.value){(3,WireValue::Bytes(v))=>Some(*v),_=>None}).unwrap();assert!(decode_wire(cap).unwrap().iter().any(|f|f.number==4&&f.value==WireValue::Varint(3)));}
}
