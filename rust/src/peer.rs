// SPDX-License-Identifier: GPL-3.0-only
// Desktop transport from pinned Linux viewer rtc.rs; RTP/AVCodec adapter from S2.6.
#[path="peer_identity.rs"] mod identity;
use serde_json::{json,Value};
use base64::{Engine,engine::general_purpose::STANDARD};
use webrtc::track::track_local::{TrackLocalWriter,track_local_static_rtp::TrackLocalStaticRTP};
use crate::input::{InputEvent,InputState};
use std::{sync::{Arc,Mutex,OnceLock,atomic::{AtomicBool,AtomicU64,Ordering}},time::{Duration,Instant}};
use tokio::{runtime::Runtime,sync::{mpsc,watch},task::JoinHandle};
use webrtc::{api::{APIBuilder,media_engine::MediaEngine,setting_engine::SettingEngine},peer_connection::{RTCPeerConnection,configuration::RTCConfiguration,policy::ice_transport_policy::RTCIceTransportPolicy,sdp::session_description::RTCSessionDescription},ice_transport::{ice_server::RTCIceServer,ice_candidate::RTCIceCandidateInit},data_channel::{RTCDataChannel,data_channel_init::RTCDataChannelInit,data_channel_state::RTCDataChannelState},rtp_transceiver::{rtp_codec::{RTPCodecType,RTCRtpCodecParameters,RTCRtpCodecCapability,RTCRtpHeaderExtensionCapability},rtp_transceiver_direction::RTCRtpTransceiverDirection,RTCRtpTransceiverInit}};
#[derive(Default)]struct Observed {legacy_capture:Mutex<Value>,link_stats:Mutex<Option<(Instant, Value)>>,tracks:AtomicU64,packets:AtomicU64,aus:AtomicU64,echo:AtomicBool,echo_sent:AtomicBool,security_queried:AtomicBool,video_requested:AtomicBool,messages:AtomicU64,input:AtomicU64,media_error:AtomicBool,touch_support:AtomicU64,catalog:Mutex<crate::app_catalog::Catalog>,center:Mutex<crate::center::Center>,traffic:Mutex<crate::center::Traffic>,advanced:Mutex<crate::advanced_controls::AdvancedControls>,clipboard:Mutex<crate::clipboard::Clipboard>,files:Mutex<crate::files::FileState>,microphone:Mutex<crate::microphone::Microphone>,terminal:Mutex<crate::terminal_client::TerminalClient>,terminal_privacy:Mutex<crate::terminal_privacy::TerminalPrivacy>,multi:Mutex<crate::multistream::Streams>,#[cfg(feature="rtp-diagnostics")] answer_diagnostics:Mutex<Value>,#[cfg(feature="rtp-diagnostics")] offer_diagnostics:Mutex<Value>}
struct PortraitAttempt {
    seq: u64,
    width: u32,
    height: u32,
    expected_width: u32,
    expected_height: u32,
    sent: bool,
    began: Instant,
    before: Value,
    error: Option<&'static str>,
    ack_since: Option<Instant>,
    fallback: bool,
}
struct Peer {direct_switch_active:bool,codec:u32,manual_scale_screens:crate::multistream::ManualScale,portrait_attempts:std::collections::BTreeMap<u32,PortraitAttempt>,multi_video:bool,initial_display_restores:usize,initial_display_failures:usize,identity_scope:Option<String>,identity_status:Mutex<Option<identity::Status>>,unlock_generation:Option<u64>,files_only:bool,catalog_only:bool,lock_only:bool,terminal_only:bool,microphone_track:Arc<TrackLocalStaticRTP>,microphone_sequence:u16,microphone_origin:u32,pc:Arc<RTCPeerConnection>,channels:Vec<Arc<RTCDataChannel>>,rx:mpsc::Receiver<Value>,early:Vec<RTCIceCandidateInit>,answered:bool,state:Arc<Observed>,overflow:Arc<AtomicU64>,readers:Arc<Mutex<Vec<JoinHandle<()>>>>,video_readers:Arc<Mutex<[Vec<(u64,JoinHandle<()>)>;3]>>,stop:watch::Sender<bool>,processor:JoinHandle<()>,input:InputState,touch_active:bool,touch_screen:Option<u64>,touch_sequence:u64,touch_query_attempts:u8,touch_query_last:Option<Instant>,pointer_screen:Option<u64>,anchor_after_switch:bool,watch:bool,began:Instant}
struct Worker {rt:Runtime,peer:Option<Peer>}
static WORKER:OnceLock<Mutex<Worker>>=OnceLock::new();
#[cfg(feature="rtp-diagnostics")]
async fn diagnostic_snapshot(p:&Peer)->Value{
 let answer=p.state.answer_diagnostics.lock().unwrap().clone();
 let offer=p.state.offer_diagnostics.lock().unwrap().clone();
 let answer_available=answer.is_object();let offer_available=offer.is_object();
 let answer=if answer_available{answer}else{json!({"videoSections":[]})};
 let offer=if offer_available{offer}else{json!({"videoSections":[]})};
 let selected_pt=answer["videoSections"].as_array().and_then(|a|a.first())
  .and_then(|v|v["h264PayloadType"].as_u64()).and_then(|v|u8::try_from(v).ok());
 let negotiated:Vec<Value>=offer["videoSections"].as_array().zip(answer["videoSections"].as_array())
  .map(|(o,a)|o.iter().zip(a).map(|(x,y)|json!({
   "midExtension":x["midExtension"]==true&&y["midExtension"]==true,
   "ridExtension":x["ridExtension"]==true&&y["ridExtension"]==true,
   "repairedRidExtension":x["repairedRidExtension"]==true&&y["repairedRidExtension"]==true
  })).collect()).unwrap_or_default();
 let pt=selected_pt.unwrap_or(if p.codec==2{96}else{102});
 let Ok((srtp,demux))=tokio::time::timeout(Duration::from_millis(150),p.pc.rtp_diagnostics(pt)).await else {
  return json!({"directSwitchEnabled":cfg!(feature="direct-screen-setting"),"portraitScaleBypassed":cfg!(feature="portrait-no-scale-rpc"),"offer":offer,"answer":answer,"offerAvailable":offer_available,"answerAvailable":answer_available,"negotiatedVideoExtensions":negotiated,
   "selectedPayloadType":selected_pt,"sampledPayloadType":pt,"srtp":null,"demux":null,"diagnosticTimedOut":true});
 };
 json!({"directSwitchEnabled":cfg!(feature="direct-screen-setting"),"portraitScaleBypassed":cfg!(feature="portrait-no-scale-rpc"),"offer":offer,"answer":answer,"offerAvailable":offer_available,"answerAvailable":answer_available,"negotiatedVideoExtensions":negotiated,"selectedPayloadType":selected_pt,"sampledPayloadType":pt,
  "srtp":srtp.map(|v|json!({"packets":v[0],"nonemptyPackets":v[1],"payloadBytes":v[2],"paddingOnly":v[3],"selectedPayloadPackets":v[4],"selectedPayloadBytes":v[5],"invalidPadding":v[6],"rawPackets":v[7],"rawBytes":v[8],"authRejected":v[9],"replayRejected":v[10],"otherRejected":v[11],"selectedRawPackets":v[12],"selectedRawBytes":v[13],"selectedAuthRejected":v[14],"selectedReplayRejected":v[15],"selectedOtherRejected":v[16]})),
  "demux":{"unknownStreams":demux[0],"errors":demux[1],"missingMidExtension":demux[2],"missingRidExtension":demux[3],"noMatchingRid":demux[4],"probeFailed":demux[5],"unknownCodec":demux[6],"otherError":demux[7],"midPresent":demux[8],"ridPresent":demux[9],"midMatched":demux[10],"ridMatched":demux[11],"payloadTypeKnown":demux[12],"bound":demux[13],"probeOverflow":demux[14],"probePayloadPackets":demux[15],"probePayloadBytes":demux[16],"probePaddingOnly":demux[17],"probeSelectedPackets":demux[18],"probeSelectedBytes":demux[19]},"diagnosticTimedOut":false})
}
extern "C" {fn s5_audio_push(seq:u16,timestamp:u32,data:*const u8,size:usize);fn s5_audio_stop();}
extern "C" {fn s5_video_size_supported(w:u32,h:u32)->bool;fn s5_video_begin_epoch(epoch:u64);fn s5_video_observed(epoch:u64,w:u32,h:u32)->bool;fn s5_video_observed_size(epoch:u64,w:*mut u32,h:*mut u32)->bool;fn s5_video_sdp_level()->u32;fn s26_discontinuity();fn s5_video_rtp_queue_sample(ms:u64);fn s5_video_begin_epoch_if_no_au(previous:u64,next:u64)->bool;fn s5_video_slot_begin_epoch_if_no_au(slot:u32,generation:u32,previous:u64,next:u64)->bool;fn s5_video_epoch_aus(epoch:u64)->u64;fn s5_video_slot_epoch_aus(slot:u32,generation:u32,epoch:u64)->u64;fn s5_video_slot_ready_codec(slot:u32,generation:u32)->u32;fn s5_video_slot_size_supported(slot:u32,generation:u32,w:u32,h:u32)->bool;fn s5_video_slot_begin_epoch(slot:u32,generation:u32,epoch:u64);fn s5_video_slot_rtp_queue_sample(slot:u32,generation:u32,ms:u64);fn s5_video_slot_observed(slot:u32,generation:u32,epoch:u64,w:u32,h:u32)->bool;fn s5_video_slot_observed_size(slot:u32,generation:u32,epoch:u64,w:*mut u32,h:*mut u32)->bool;}
fn display_sample(p: &Peer) -> Value {
    let mut a = p.state.advanced.lock().unwrap();
    let epoch = a.epoch();
    let (w, h) = a.target_size().unwrap_or((0, 0));
    let observed = unsafe { s5_video_observed(epoch, 0, 0) };
    let matches = unsafe { s5_video_observed(epoch, w as u32, h as u32) };
    let portrait = if a.stream_scale_seq().is_some() { None } else { a.active_id().and_then(|id| p.portrait_attempts.get(&(id as u32))) };
    let ready = if a.is_stream_scale() {
        let (mut actual_w, mut actual_h) = (0, 0);
        let size_observed = unsafe { s5_video_observed_size(epoch, &mut actual_w, &mut actual_h) };
        let source = a.stream_scale_source().unwrap_or((0,0));
        let seq = portrait.map(|attempt| attempt.seq).or_else(|| a.stream_scale_seq());
        let sent = portrait.is_none_or(|attempt| attempt.sent);
        sent && seq.is_some_and(|seq| p.state.center.lock().unwrap().request_ack(seq) == Some(true)) &&
            size_observed && stream_aspect_matches(actual_w, actual_h, source.0, source.1)
    } else if p.direct_switch_active {
        let (mut actual_w,mut actual_h)=(0,0);
        let seen=unsafe{s5_video_observed_size(epoch,&mut actual_w,&mut actual_h)};
        let source=a.stream_scale_source().unwrap_or((0,0));
        seen && stream_aspect_matches(actual_w,actual_h,source.0,source.1)
    } else { true };
    a.observe_frame(observed && ready, matches);
    let mut status = a.snapshot();
    status["directScreenSetting"] = json!(crate::advanced_controls::direct_switch_enabled(p.multi_video));
    if let Some(attempt) = portrait {
        let (mut actual_w, mut actual_h) = (0, 0);
        let seen = unsafe { s5_video_observed_size(epoch, &mut actual_w, &mut actual_h) };
        status["streamRenderWidth"] = json!(seen.then_some(actual_w));
        status["streamRenderHeight"] = json!(seen.then_some(actual_h));
        status["streamMaxWidth"] = json!(attempt.width);
        status["streamMaxHeight"] = json!(attempt.height);
        status["streamWithinBudget"] = json!(seen.then_some(actual_w <= attempt.width && actual_h <= attempt.height));
    }
    if a.is_stream_scale() && portrait.is_none() {
        let (mut actual_w, mut actual_h) = (0, 0);
        let seen = unsafe { s5_video_observed_size(epoch, &mut actual_w, &mut actual_h) };
        status["streamRenderWidth"] = json!(seen.then_some(actual_w));
        status["streamRenderHeight"] = json!(seen.then_some(actual_h));
        status["streamMaxWidth"] = json!(w);
        status["streamMaxHeight"] = json!(h);
        status["streamWithinBudget"] = json!(seen.then_some(u64::from(actual_w) <= w && u64::from(actual_h) <= h));
    }
    status
}
use crate::multistream::{portrait_size,portrait_fallback_size,portrait_fallback_due,portrait_aspect_matches,portrait_bounds,stream_aspect_matches};
fn portrait_status(p: &Peer) -> Value {
    let display = p.state.advanced.lock().unwrap().snapshot();
    let center = p.state.center.lock().unwrap();
    json!(p.portrait_attempts.iter().map(|(&id, a)| {
        let current = display["screens"].as_array()
            .and_then(|rows| rows.iter().find(|s| s["id"] == id))
            .map(|s| s["currentResolution"].clone()).unwrap_or(Value::Null);
        let ack = center.request_ack(a.seq);
        let (mut actual_w,mut actual_h)=(0,0);
        let observed=if p.multi_video {
            p.state.multi.lock().unwrap().route_for(id).is_some_and(|route|unsafe{
                s5_video_slot_observed_size(route.slot,route.generation,route.epoch,&mut actual_w,&mut actual_h)
            })
        } else {
            display["displayEpoch"].as_u64().is_some_and(|epoch|unsafe{s5_video_observed_size(epoch,&mut actual_w,&mut actual_h)})
        };
        let source_w=a.before["width"].as_u64().and_then(|v|u32::try_from(v).ok()).unwrap_or(0);
        let source_h=a.before["height"].as_u64().and_then(|v|u32::try_from(v).ok()).unwrap_or(0);
        let error = a.error.or_else(|| {
            if !a.sent { Some("portrait_setting_send_failed") }
            else if ack == Some(false) { Some("portrait_setting_rejected") }
            else if ack.is_none() && a.began.elapsed() >= Duration::from_secs(12) {
                Some("portrait_setting_ack_timeout")
            } else { None }
        });
        json!({"screenId": id, "width": a.width, "height": a.height, "seq": a.seq,
            "sent": a.sent, "ack": ack, "error": error, "fallback": a.fallback,
            "beforeResolution": a.before, "currentResolution": current,
            "renderWidth":observed.then_some(actual_w),"renderHeight":observed.then_some(actual_h),
            "expectedWidth":a.expected_width,"expectedHeight":a.expected_height, "exactOutput":observed.then_some(actual_w==a.expected_width&&actual_h==a.expected_height),
            "withinBudget":observed.then_some(actual_w<=a.width&&actual_h<=a.height),
            "aspectCompatible":observed.then_some(portrait_aspect_matches(actual_w,actual_h,source_w,source_h))})
    }).collect::<Vec<_>>())
}
async fn portrait_advance(p: &mut Peer) {
    if cfg!(feature="portrait-no-scale-rpc") || p.direct_switch_active { return; }
    if p.files_only || p.catalog_only || p.lock_only || p.terminal_only || p.channels[1].ready_state() != RTCDataChannelState::Open { return; }
    let display = p.state.advanced.lock().unwrap().snapshot();
    let routes: Vec<(u32, Option<(u32, u32)>)> = if p.multi_video {
        p.state.multi.lock().unwrap().routes().into_iter()
            .map(|r| (r.screen, Some((r.slot, r.generation)))).collect()
    } else {
        display["selectedScreen"].as_u64().and_then(|id| u32::try_from(id).ok())
            .map(|id| vec![(id, None)]).unwrap_or_default()
    };
    let active_ids: Vec<u32> = if p.multi_video {
        p.state.multi.lock().unwrap().snapshot()["streams"].as_array()
            .map(|rows| rows.iter().filter(|s| s["open"] == true)
                .filter_map(|s| s["screenId"].as_u64().and_then(|v| u32::try_from(v).ok())).collect())
            .unwrap_or_default()
    } else {
        display["requestedScreen"].as_u64().or_else(|| display["selectedScreen"].as_u64())
            .and_then(|v| u32::try_from(v).ok()).into_iter().collect()
    };
    p.portrait_attempts.retain(|id, _| active_ids.contains(id));
    p.manual_scale_screens.retain_active(&active_ids);
    if p.multi_video {
        let center = p.state.center.lock().unwrap();
        let mut multi = p.state.multi.lock().unwrap();
        for (&id, a) in &p.portrait_attempts {
            multi.mark_configured(id, a.sent && center.request_ack(a.seq) == Some(true));
        }
    }
    for &(id, slot) in &routes {
        let Some(attempt) = p.portrait_attempts.get_mut(&id) else { continue; };
        let ack = p.state.center.lock().unwrap().request_ack(attempt.seq);
        if attempt.sent && ack == Some(true) {
            attempt.ack_since.get_or_insert_with(Instant::now);
        }
        let epoch = if p.multi_video {
            p.state.multi.lock().unwrap().route_for(id).map(|r| r.epoch)
        } else {
            Some(p.state.advanced.lock().unwrap().epoch())
        };
        let Some(epoch) = epoch else { continue; };
        let aus = unsafe {
            if let Some((s, g)) = slot { s5_video_slot_epoch_aus(s, g, epoch) }
            else { s5_video_epoch_aus(epoch) }
        };
        if !portrait_fallback_due(attempt.fallback || p.manual_scale_screens.active(id), attempt.ack_since.map(|t| t.elapsed()), aus) { continue; }
        // Claim the single fallback budget before any asynchronous work.
        attempt.fallback = true;
        let size = portrait_fallback_size(attempt.expected_width, attempt.expected_height, |w, h| unsafe {
            if let Some((s, g)) = slot { s5_video_slot_size_supported(s, g, w, h) }
            else { s5_video_size_supported(w, h) }
        });
        let Some((width, height)) = size.filter(|&(w, h)| w != attempt.expected_width || h != attempt.expected_height) else { continue; };
        if p.multi_video {
            let result = p.state.multi.lock().unwrap().set_size_if(id, width, height, |route, next| unsafe {
                s5_video_slot_begin_epoch_if_no_au(route.slot, route.generation, epoch, next)
            });
            if result.is_err() { continue; }
        } else {
            let mut a = p.state.advanced.lock().unwrap();
            let Some(next) = epoch.checked_add(1) else { continue; };
            if a.epoch() != epoch || !unsafe { s5_video_begin_epoch_if_no_au(epoch, next) } { continue; }
            a.begin_stream_scale(u64::from(id), width as u64, height as u64);
        }
        let (bound_w, bound_h) = portrait_bounds((width, height), |w, h| unsafe {
            if let Some((s, g)) = slot { s5_video_slot_size_supported(s, g, w, h) }
            else { s5_video_size_supported(w, h) }
        });
        let profile_screen=display["screens"].as_array().and_then(|rows|rows.iter().find(|s|s["id"]==id)).unwrap_or(&Value::Null);
        let profile_enabled=cfg!(feature="reported-portrait-profile") && !p.multi_video && !p.direct_switch_active;
        let (seq, packet) = p.state.center.lock().unwrap().portrait_stream_with_report(id, bound_w, bound_h, profile_enabled, profile_screen);
        let ok = matches!(tokio::time::timeout(Duration::from_secs(2),
            p.channels[1].send_text_bytes(&bytes::Bytes::from(packet))).await, Ok(Ok(_)));
        p.state.center.lock().unwrap().sent(seq, usize::from(ok));
        if !p.multi_video { p.state.advanced.lock().unwrap().mark_sent(ok); }
        attempt.seq = seq;
        attempt.width = bound_w;
        attempt.height = bound_h;
        attempt.expected_width = width;
        attempt.expected_height = height;
        attempt.sent = ok;
        attempt.began = Instant::now();
        attempt.ack_since = None;
    }
    for (id, slot) in routes {
        if p.portrait_attempts.contains_key(&id) || p.manual_scale_screens.active(id) { continue; }
        let Some(screen) = display["screens"].as_array().and_then(|rows| rows.iter().find(|s| s["id"] == id)) else { continue; };
        let size = screen.get("currentResolution").filter(|s| s.is_object())
            .or_else(|| screen.get("initial").filter(|s| s.is_object()));
        let Some(size) = size else { continue; };
        let (Some(w), Some(h)) = (
            size["width"].as_u64().and_then(|v| u32::try_from(v).ok()),
            size["height"].as_u64().and_then(|v| u32::try_from(v).ok()),
        ) else { continue; };
        if h <= w { continue; }
        let output = portrait_size(w, h, |x, y| unsafe {
            if let Some((s, g)) = slot { s5_video_slot_size_supported(s, g, x, y) }
            else { s5_video_size_supported(x, y) }
        });
        let Some((width, height)) = output else {
            p.portrait_attempts.insert(id, PortraitAttempt {
                seq: 0, width: 0, height: 0, expected_width: 0, expected_height: 0, sent: false, began: Instant::now(),
                before: size.clone(), error: Some("portrait_decoder_size_unsupported"), ack_since: None, fallback: true,
            });
            continue;
        };
        if p.multi_video {
            let route = p.state.multi.lock().unwrap().set_size(id, width, height);
            if let Ok(route) = route {
                unsafe { s5_video_slot_begin_epoch(route.slot, route.generation, route.epoch) }
            } else { continue; }
        } else {
            let mut a = p.state.advanced.lock().unwrap();
            a.begin_stream_scale(u64::from(id), width as u64, height as u64);
            unsafe { s5_video_begin_epoch(a.epoch()) };
        }
        let (bound_w, bound_h) = portrait_bounds((width, height), |w, h| unsafe {
            if let Some((s, g)) = slot { s5_video_slot_size_supported(s, g, w, h) }
            else { s5_video_size_supported(w, h) }
        });
        let profile_screen=display["screens"].as_array().and_then(|rows|rows.iter().find(|s|s["id"]==id)).unwrap_or(&Value::Null);
        let profile_enabled=cfg!(feature="reported-portrait-profile") && !p.multi_video && !p.direct_switch_active;
        let (seq, packet) = p.state.center.lock().unwrap().portrait_stream_with_report(id, bound_w, bound_h, profile_enabled, profile_screen);
        let ok = matches!(tokio::time::timeout(Duration::from_secs(2),
            p.channels[1].send_text_bytes(&bytes::Bytes::from(packet))).await, Ok(Ok(_)));
        p.state.center.lock().unwrap().sent(seq, usize::from(ok));
        if !p.multi_video { p.state.advanced.lock().unwrap().mark_sent(ok); }
        p.portrait_attempts.insert(id, PortraitAttempt {
            seq, width: bound_w, height: bound_h, expected_width: width, expected_height: height, sent: ok, began: Instant::now(), before: size.clone(), error: None, ack_since: None, fallback: height <= 720,
        });
    }
}
fn now_ms()->u64{std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis()as u64}
async fn send_files(state:&Arc<Observed>,channels:&[Arc<RTCDataChannel>],messages:Vec<crate::files::Outbound>){
 for item in messages{let sent=if let Some(c)=channels.get(item.channel){c.ready_state()==RTCDataChannelState::Open && matches!(tokio::time::timeout(Duration::from_secs(2),c.send(&bytes::Bytes::from(item.data))).await,Ok(Ok(_)))}else{false};state.files.lock().unwrap().sent(item.request_id,sent,now_ms());}
}

fn error(s:&str)->Value{json!({"error":s})}
fn config(v:&Value)->Result<RTCConfiguration,&'static str>{
 let a=v["iceServers"].as_array().filter(|a|a.len()<=32).ok_or("invalid_ice_servers")?;let mut servers=vec![];
 for s in a {let urls=match &s["urls"]{Value::String(s)=>vec![s.clone()],Value::Array(a)if a.len()<=16=>a.iter().map(|v|v.as_str().map(str::to_owned).ok_or("invalid_ice_url")).collect::<Result<Vec<_>,_>>()?,_=>return Err("invalid_ice_urls")};
  if urls.is_empty()||urls.iter().any(|u|u.len()>4096||!["stun:","stuns:","turn:","turns:"].iter().any(|p|u.starts_with(p))){return Err("invalid_ice_scheme")}
  let string=|k|match s.get(k){Some(Value::String(s))if s.len()<=8192=>Ok(s.clone()),None=>Ok(String::new()),_=>Err("invalid_ice_auth")};
  servers.push(RTCIceServer{urls,username:string("username")?,credential:string("credential")?,credential_type:webrtc::ice_transport::ice_credential_type::RTCIceCredentialType::Password});
 }
 let relay=match v.get("force_relay"){Some(Value::Bool(b))=>*b,None=>false,_=>return Err("invalid_relay_policy")};if relay&&!servers.iter().any(|s|s.urls.iter().any(|u|u.starts_with("turn:")||u.starts_with("turns:"))){return Err("relay_without_turn")}
 Ok(RTCConfiguration{ice_servers:servers,ice_transport_policy:if relay{RTCIceTransportPolicy::Relay}else{RTCIceTransportPolicy::All},..Default::default()})
}
async fn open(c:RTCConfiguration,files_only:bool,catalog_only:bool,lock_only:bool,terminal_only:bool,multi_video:bool,codec:u32,level:u32,decoder_width:u32,decoder_height:u32,decoder_fps:u32)->Result<(Peer,String),&'static str>{
 if terminal_only&&(files_only||catalog_only||lock_only||multi_video){return Err("conflicting_session_roles")}
 let data_only=files_only||catalog_only||lock_only||terminal_only;
 let mut settings=SettingEngine::default();settings.set_network_types(vec![webrtc::ice::network_type::NetworkType::Udp4]);settings.set_ice_multicast_dns_mode(webrtc::ice::mdns::MulticastDnsMode::Disabled);
 let mut engine=MediaEngine::default();
 let hevc_fmtp=if codec==2{Some(crate::nal_policy::hevc_fmtp(level).ok_or("hevc_level_unverified")?)}else{None};let video_mime=if codec==2{"video/H265"}else{"video/H264"};let video_fmtp=hevc_fmtp.as_deref().unwrap_or(crate::wire::H264_FMTP);let video_pt=if codec==2{96}else{102};
 for (kind,mime,rate,channels,fmtp,pt) in [(RTPCodecType::Video,video_mime,90000,0,video_fmtp,video_pt),(RTPCodecType::Audio,"audio/opus",48000,2,"minptime=10;useinbandfec=1",111)]{engine.register_codec(RTCRtpCodecParameters{capability:RTCRtpCodecCapability{mime_type:mime.into(),clock_rate:rate,channels,sdp_fmtp_line:fmtp.into(),..Default::default()},payload_type:pt,..Default::default()},kind).map_err(|_|"codec_register_failed")?;}
 for uri in [crate::orientation::CVO_URI,"http://www.webrtc.org/experiments/rtp-hdrext/video-capture-index","http://www.webrtc.org/experiments/rtp-hdrext/video-frame-is-new-frame"]{engine.register_header_extension(RTCRtpHeaderExtensionCapability{uri:uri.into()},RTPCodecType::Video,None).map_err(|_|"rtp_extension_failed")?;}
 for (kind,uri) in [(RTPCodecType::Audio,"urn:ietf:params:rtp-hdrext:sdes:mid"),(RTPCodecType::Video,"urn:ietf:params:rtp-hdrext:sdes:mid"),(RTPCodecType::Video,"urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id"),(RTPCodecType::Video,"urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id")]{engine.register_header_extension(RTCRtpHeaderExtensionCapability{uri:uri.into()},kind,None).map_err(|_|"rtp_extension_failed")?;}
 let registry=webrtc::api::interceptor_registry::register_default_interceptors(webrtc::interceptor::registry::Registry::new(),&mut engine).map_err(|_|"interceptors_failed")?;
 let api=APIBuilder::new().with_media_engine(engine).with_setting_engine(settings).with_interceptor_registry(registry).build();let pc=Arc::new(api.new_peer_connection(c).await.map_err(|_|"peer_create_failed")?);
 let (tx,rx)=mpsc::channel(256);let overflow=Arc::new(AtomicU64::new(0));let over=overflow.clone();let weak=Arc::downgrade(&pc);
 pc.on_ice_candidate(Box::new(move|c|{let tx=tx.clone();let weak=weak.clone();let over=over.clone();Box::pin(async move{if let Some(c)=c{if let Ok(mut c)=c.to_json(){if let Some(pc)=weak.upgrade(){if let Some(local)=pc.local_description().await{if let Some(mid)=local.sdp.lines().find_map(|l|l.strip_prefix("a=mid:")){c.sdp_mid=Some(mid.trim().into());c.sdp_mline_index=Some(0);}}}if let Ok(v)=serde_json::to_value(c){if tx.try_send(v).is_err(){over.fetch_add(1,Ordering::Relaxed);}}}}})}));
 let state=Arc::new(Observed::default());{let mut center=state.center.lock().unwrap();center.set_codec(codec);center.set_decoder_size(decoder_width,decoder_height);center.set_decoder_fps(decoder_fps);}if multi_video{*state.multi.lock().unwrap()=crate::multistream::Streams::new();}if data_only{state.center.lock().unwrap().revoke_unlock();}let readers:Arc<Mutex<Vec<JoinHandle<()>>>>=Arc::default();let video_readers:Arc<Mutex<[Vec<(u64,JoinHandle<()>)>;3]>>=Arc::new(Mutex::new([Vec::new(),Vec::new(),Vec::new()]));
 let (packets,mut media)=mpsc::channel::<(u64,Instant,webrtc::rtp::packet::Packet,u8)>(512);let (multi_packets,mut multi_media)=mpsc::channel::<(crate::multistream::Route,Instant,webrtc::rtp::packet::Packet,u8)>(512);let (stop,mut done)=watch::channel(false);
 let st=state.clone();let weak=Arc::downgrade(&pc);
 let processor=tokio::spawn(async move {if multi_video{let mut caps:[Option<(crate::multistream::Route,crate::capture::Capture)>;3]=[None,None,None];let mut ssrc=[0u32;3];let mut pli=[Instant::now()-Duration::from_secs(1);3];let mut route_started=[Instant::now();3];let log=crate::capture::Report;let mut tick=tokio::time::interval(Duration::from_millis(40));loop{tokio::select!{p=multi_media.recv()=>{let Some((route,queued,p,cvo_id))=p else{break};let guard=st.multi.lock().unwrap();if !guard.route_current(route){continue}let i=route.track;if caps[i].as_ref().map(|v|v.0)!=Some(route){unsafe{s5_video_slot_begin_epoch(route.slot,route.generation,route.epoch)};caps[i]=Some((route,crate::capture::Capture::for_slot(route.epoch,route.slot,route.generation,codec)));route_started[i]=Instant::now();}unsafe{s5_video_slot_rtp_queue_sample(route.slot,route.generation,queued.elapsed().as_millis() as u64)};ssrc[i]=p.header.ssrc;st.packets.fetch_add(1,Ordering::Relaxed);caps[i].as_mut().unwrap().1.push(p,cvo_id,&log);drop(guard);},_=tick.tick()=>{for i in 0..3{let (route,last_ssrc)={let m=st.multi.lock().unwrap();(m.route(i),m.stats[i].ssrc)};if let Some(route)=route{if caps[i].as_ref().map(|v|v.0)!=Some(route){unsafe{s5_video_slot_begin_epoch(route.slot,route.generation,route.epoch)};caps[i]=Some((route,crate::capture::Capture::for_slot(route.epoch,route.slot,route.generation,codec)));ssrc[i]=last_ssrc;route_started[i]=Instant::now();}}else{caps[i]=None;}if let Some((route,cap))=&mut caps[i]{if !st.multi.lock().unwrap().route_current(*route){caps[i]=None;continue}cap.expire(&log);let (width,height)={let m=st.multi.lock().unwrap();m.preferences(route.screen).map(|(_,_,w,h)|(w,h)).unwrap_or((0,0))};let observed=if width==0||height==0{unsafe{s5_video_slot_observed(route.slot,route.generation,route.epoch,0,0)}}else{let(mut w,mut h)=(0,0);(unsafe{s5_video_slot_observed_size(route.slot,route.generation,route.epoch,&mut w,&mut h)})&&portrait_aspect_matches(w,h,width,height)};{let mut m=st.multi.lock().unwrap();m.mark_observed(*route,observed);m.stats[i].capture=cap.stats();}if ssrc[i]!=0&&((cap.request_pli&&pli[i].elapsed()>=Duration::from_millis(250))||crate::multistream::startup_pli_due(route_started[i].elapsed(),pli[i].elapsed(),cap.stats()["accepted"].as_u64().unwrap_or(0))){if let Some(pc)=weak.upgrade(){let _=pc.write_rtcp(&[Box::new(webrtc::rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication{sender_ssrc:0,media_ssrc:ssrc[i]})]).await;}cap.request_pli=false;pli[i]=Instant::now();}}}},_=done.changed()=>break}}return;}if data_only{let _=done.changed().await;return;}let mut cap=crate::capture::Capture::new(codec);let log=crate::capture::Report;let mut tick=tokio::time::interval(Duration::from_millis(40));let mut ssrc=0;let mut last_pli=Instant::now()-Duration::from_secs(1);let mut epoch=0;let mut recovering=false;
  loop {let current_epoch=st.advanced.lock().unwrap().epoch();if epoch!=current_epoch{epoch=current_epoch;cap=crate::capture::Capture::for_epoch(epoch,codec);recovering=true;}
   tokio::select!{p=media.recv()=>{let Some((packet_epoch,queued,p,cvo_id))=p else{break};unsafe{s5_video_rtp_queue_sample(queued.elapsed().as_millis().min(u64::MAX as u128) as u64)};let (current,allowed)={let a=st.advanced.lock().unwrap();(a.epoch(),a.accepts_media())};if !allowed||packet_epoch!=current{continue;}
    if epoch!=current||(ssrc!=0&&ssrc!=p.header.ssrc){epoch=current;cap=crate::capture::Capture::for_epoch(epoch,codec);unsafe{s26_discontinuity()};recovering=true;}
    ssrc=p.header.ssrc;st.packets.fetch_add(1,Ordering::Relaxed);st.traffic.lock().unwrap().packet(p.header.ssrc,p.header.sequence_number,p.payload.len());cap.push(p,cvo_id,&log);},_=tick.tick()=>cap.expire(&log),_=done.changed()=>{break}}
   let stats=cap.stats();*st.legacy_capture.lock().unwrap()=cap.counters();st.aus.store(stats["accepted"].as_u64().unwrap_or(0)+stats["queue_rejected"].as_u64().unwrap_or(0),Ordering::Relaxed);
   if stats["accepted"].as_u64().unwrap_or(0)>0{recovering=false;}
   if (cap.request_pli||recovering)&&ssrc!=0&&last_pli.elapsed()>=Duration::from_millis(250){if let Some(pc)=weak.upgrade(){let _=pc.write_rtcp(&[Box::new(webrtc::rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication{sender_ssrc:0,media_ssrc:ssrc})]).await;}cap.request_pli=false;last_pli=Instant::now();}
  }
 });
 let st=state.clone();let rs=readers.clone();let video_tasks=video_readers.clone();
 pc.on_track(Box::new(move|track,receiver,transceiver|{
  let tx=packets.clone();let mtx=multi_packets.clone();let st=st.clone();let rs=rs.clone();let video_tasks=video_tasks.clone();
  Box::pin(async move{
   if data_only{return;}
   st.tracks.fetch_add(1,Ordering::Relaxed);
   let video=track.kind()==RTPCodecType::Video;
   let cvo_id=if video{receiver.get_parameters().await.header_extensions.iter().find(|e|e.uri==crate::orientation::CVO_URI).and_then(|e|u8::try_from(e.id).ok()).unwrap_or(0)}else{0};
   if video&&!crate::nal_policy::mime_matches(codec,&track.codec().capability.mime_type) {st.media_error.store(true,Ordering::Release);return;}
   let binding=if video {
    let mid=transceiver.mid();
    let mut multi=st.multi.lock().unwrap();
    let bound=if multi_video{multi.bind_reader(&track.id(),mid.as_deref())}else{multi.bind_legacy_reader(&track.id(),mid.as_deref())};
    match bound {
     Ok(v)=>{
      let mut tasks=video_tasks.lock().unwrap();
      tasks[v.0].retain(|(token,handle)| {if multi.reader_current(v.0,*token){true}else{handle.abort();false}});
      Some(v)
     },Err(_)=>return
    }
   } else {None};
   let registry_state=st.clone();
   let task_handles=video_tasks.clone();
   let handle=tokio::spawn(async move {
    loop {match track.read_rtp().await {
     Ok((packet,_))=>{
      if video {
       if let Some((index,token,_))=binding {
        let (alive,promoted,route,legacy_epoch)={
         let mut multi=st.multi.lock().unwrap();
         let (alive,promoted,route)=multi.packet_from(index,token,packet.header.ssrc,packet.payload.len());
         let legacy_epoch=if !multi_video&&alive{let mut a=st.advanced.lock().unwrap();if promoted{unsafe{s5_video_begin_epoch(a.transport_restart())}}Some((a.epoch(),a.accepts_media()))}else{None};
         for(s,g,e)in multi.lanes(){unsafe{s5_video_slot_begin_epoch(s,g,e)}}
         (alive,promoted,route,legacy_epoch)
        };
        if !alive{break;}
        if promoted {
         let multi=st.multi.lock().unwrap();
         let mut tasks=task_handles.lock().unwrap();
         tasks[index].retain(|(other,handle)| {if multi.reader_current(index,*other){true}else{handle.abort();false}});
        }
        if multi_video {
         if let Some(route)=route {if mtx.send((route,Instant::now(),packet,cvo_id)).await.is_err(){break;}}
        } else {
         if let Some((epoch,true))=legacy_epoch{if tx.send((epoch,Instant::now(),packet,cvo_id)).await.is_err(){break;}}
        }
        continue;
       }
       let (epoch,allowed)={let a=st.advanced.lock().unwrap();(a.epoch(),a.accepts_media())};
       if allowed&&tx.send((epoch,Instant::now(),packet,cvo_id)).await.is_err(){break;}
      } else if track.codec().capability.mime_type.eq_ignore_ascii_case("audio/opus") {
       unsafe{s5_audio_push(packet.header.sequence_number,packet.header.timestamp,packet.payload.as_ptr(),packet.payload.len())}
      }
     },Err(_)=>break
    }}
   });
   if let Some((index,token,_))=binding {
    let multi=registry_state.multi.lock().unwrap();
    let mut tasks=video_tasks.lock().unwrap();
    tasks[index].retain(|(other,existing)| {if multi.reader_current(index,*other){true}else{existing.abort();false}});
    if multi.reader_current(index,token){tasks[index].push((token,handle));}else{handle.abort();}
   }
   else {rs.lock().unwrap().push(handle);}
  })
 }));
 let microphone_track=Arc::new(TrackLocalStaticRTP::new(RTCRtpCodecCapability{mime_type:"audio/opus".into(),clock_rate:48000,channels:2,sdp_fmtp_line:"minptime=10;stereo=1;useinbandfec=1".into(),..Default::default()},"audio_0".into(),"audio_0".into()));
 let mut random=[0u8;6];getrandom::getrandom(&mut random).map_err(|_|"microphone_random_failed")?;
 let microphone_sequence=u16::from_le_bytes([random[0],random[1]]);let microphone_origin=u32::from_le_bytes([random[2],random[3],random[4],random[5]]);
 let mut channels=vec![];
 let result=async {
  if !data_only{pc.add_transceiver_from_kind(RTPCodecType::Video,Some(RTCRtpTransceiverInit{direction:RTCRtpTransceiverDirection::Recvonly,send_encodings:vec![]})).await.map_err(|_|"transceiver_failed")?;
  if multi_video{for _ in 0..2{pc.add_transceiver_from_kind(RTPCodecType::Video,Some(RTCRtpTransceiverInit{direction:RTCRtpTransceiverDirection::Recvonly,send_encodings:vec![]})).await.map_err(|_|"transceiver_failed")?;}}
  let microphone_transceiver=pc.add_transceiver_from_track(microphone_track.clone(),Some(RTCRtpTransceiverInit{direction:RTCRtpTransceiverDirection::Sendrecv,send_encodings:vec![]})).await.map_err(|_|"microphone_transceiver_failed")?;
  let sender=microphone_transceiver.sender().await;let mut stopped=stop.subscribe();let feedback=tokio::spawn(async move{loop{tokio::select!{r=sender.read_rtcp()=>{if r.is_err(){break}},_=stopped.changed()=>break}}});readers.lock().unwrap().push(feedback);}
  for name in crate::wire::CHANNELS{channels.push(pc.create_data_channel(name,Some(RTCDataChannelInit{ordered:Some(true),..Default::default()})).await.map_err(|_|"channel_create_failed")?);}
  let control=&channels[0];let weak=Arc::downgrade(control);let st=state.clone();control.on_open(Box::new(move||{let weak=weak.clone();let st=st.clone();Box::pin(async move{if let Some(c)=weak.upgrade(){if c.send(&bytes::Bytes::from(crate::wire::echo_request(1))).await.is_ok(){st.echo_sent.store(true,Ordering::Release);}if !data_only&&c.send(&bytes::Bytes::from(crate::wire::request_video_track())).await.is_ok(){st.video_requested.store(true,Ordering::Release);}}})}));
  let weak=Arc::downgrade(control);let st=state.clone();let file_channels=channels.iter().map(Arc::downgrade).collect::<Vec<_>>();control.on_message(Box::new(move|m|{let weak=weak.clone();let st=st.clone();let file_channels=file_channels.clone();Box::pin(async move{st.messages.fetch_add(1,Ordering::Relaxed);if let Some(value)=crate::tablet_wire::support_touch(&m.data){st.touch_support.store(if value{2}else{1},Ordering::Release);}st.microphone.lock().unwrap().observe(&m.data);st.catalog.lock().unwrap().observe(&m.data);st.center.lock().unwrap().observe(&m.data);st.terminal_privacy.lock().unwrap().observe(&m.data);st.advanced.lock().unwrap().observe(&m.data);if multi_video{let d=st.advanced.lock().unwrap().snapshot();{let mut multi=st.multi.lock().unwrap();multi.observe(&m.data,&d);for(slot,generation,epoch)in multi.lanes(){unsafe{s5_video_slot_begin_epoch(slot,generation,epoch)}}}}let outgoing=if lock_only||terminal_only{vec![]}else{st.files.lock().unwrap().on_packet(0,&m.data,now_ms()).unwrap_or_default()};let live_channels=file_channels.iter().filter_map(|c|c.upgrade()).collect::<Vec<_>>();if live_channels.len()==5{send_files(&st,&live_channels,outgoing).await;}if crate::wire::echo_matches(&m.data,1){st.echo.store(true,Ordering::Release);}if let Some(seq)=crate::wire::echo_request_seq(&m.data){if let Some(c)=weak.upgrade(){let _=c.send(&bytes::Bytes::from(crate::wire::echo_response(1_000_000+seq,seq))).await;}}})}));
  // Stock Windows returns FTP replies and download RPCs on TEXT, while other
  // hosts use FILE/CONTROL. Route all three through the same correlated state.
  let text=channels[1].clone();let weak_text=Arc::downgrade(&text);let file_channels=channels.iter().map(Arc::downgrade).collect::<Vec<_>>();let st=state.clone();text.on_message(Box::new(move|m|{let weak=weak_text.clone();let st=st.clone();let file_channels=file_channels.clone();Box::pin(async move{if let Some(value)=crate::tablet_wire::support_touch(&m.data){st.touch_support.store(if value{2}else{1},Ordering::Release);}st.files.lock().unwrap().observe_metadata(&m.data);let outgoing=if lock_only||terminal_only{vec![]}else{st.files.lock().unwrap().on_packet(1,&m.data,now_ms()).unwrap_or_default()};let live_channels=file_channels.iter().filter_map(|c|c.upgrade()).collect::<Vec<_>>();if live_channels.len()==5{send_files(&st,&live_channels,outgoing).await;}st.catalog.lock().unwrap().observe(&m.data);st.microphone.lock().unwrap().observe(&m.data);st.center.lock().unwrap().observe(&m.data);st.terminal_privacy.lock().unwrap().observe(&m.data);st.advanced.lock().unwrap().observe(&m.data);if multi_video{let d=st.advanced.lock().unwrap().snapshot();{let mut multi=st.multi.lock().unwrap();multi.observe(&m.data,&d);for(slot,generation,epoch)in multi.lanes(){unsafe{s5_video_slot_begin_epoch(slot,generation,epoch)}}}}let replies=if lock_only||terminal_only{vec![]}else{st.clipboard.lock().unwrap().receive(&m.data)};if let Some(c)=weak.upgrade(){for data in replies{if !matches!(tokio::time::timeout(Duration::from_secs(2),c.send(&bytes::Bytes::from(data))).await,Ok(Ok(_))){break;}}}})}));
  let st=state.clone();channels[4].on_message(Box::new(move|m|{let st=st.clone();Box::pin(async move{st.terminal.lock().unwrap().observe(&m.data);})}));
  let file=channels[3].clone();let file_channels=channels.iter().map(Arc::downgrade).collect::<Vec<_>>();let st=state.clone();file.on_message(Box::new(move|m|{let channels=file_channels.clone();let st=st.clone();Box::pin(async move{if lock_only||terminal_only{return;}let outgoing=st.files.lock().unwrap().on_packet(3,&m.data,now_ms()).unwrap_or_default();let channels=channels.iter().filter_map(|c|c.upgrade()).collect::<Vec<_>>();if channels.len()==5{send_files(&st,&channels,outgoing).await;}})}));
  let offer=pc.create_offer(None).await.map_err(|_|"offer_create_failed")?;#[cfg(feature="rtp-diagnostics")] {*state.offer_diagnostics.lock().unwrap()=crate::rtp_diagnostics::answer_summary(&offer.sdp);}let mut sdp=offer.sdp.clone();pc.set_local_description(offer).await.map_err(|_|"local_offer_failed")?;
  Ok(crate::wire::offer_copy(&sdp))
 }.await;
 match result {Ok(sdp)=>{readers.lock().unwrap().push(spawn_link_stats(pc.clone(),state.clone(),stop.subscribe()));Ok((Peer{direct_switch_active:false,codec,manual_scale_screens:crate::multistream::ManualScale::default(),portrait_attempts:std::collections::BTreeMap::new(),multi_video,initial_display_restores:0,initial_display_failures:0,identity_scope:None,identity_status:Mutex::new(None),unlock_generation:None,files_only,catalog_only,lock_only,terminal_only,microphone_track,microphone_sequence,microphone_origin,pc,channels,rx,early:vec![],answered:false,state,overflow,readers,video_readers,stop,processor,input:InputState::default(),touch_active:false,touch_screen:None,touch_sequence:2_000_000,touch_query_attempts:0,touch_query_last:None,pointer_screen:None,anchor_after_switch:false,watch:false,began:Instant::now()},sdp))},Err(e)=>{state.center.lock().unwrap().close_security();let _=pc.close().await;let _=stop.send(true);let _=processor.await;Err(e)}}
}
async fn multi_advance(p:&mut Peer){
 if !p.multi_video||!p.answered||p.channels[1].ready_state()!=RTCDataChannelState::Open||!p.state.echo.load(Ordering::Acquire){return}
 let register={let mut m=p.state.multi.lock().unwrap();if !m.registration_sent&&m.error.is_none(){m.registration_sent=true;m.registration_at=Some(Instant::now());true}else{false}};
 if register&&!matches!(tokio::time::timeout(Duration::from_secs(2),p.channels[1].send_text_bytes(&bytes::Bytes::from(crate::multistream::register()))).await,Ok(Ok(_))){p.state.multi.lock().unwrap().error=Some("registration_send_failed");}
 {let mut m=p.state.multi.lock().unwrap();if m.registration_ack.is_none()&&m.registration_at.is_some_and(|t|t.elapsed()>=Duration::from_secs(10)){m.error=Some("registration_ack_timeout");}}
 let plans=p.state.multi.lock().unwrap().activation_plan();for(id,_,packet)in plans{p.state.multi.lock().unwrap().activation_start(id);let ok=matches!(tokio::time::timeout(Duration::from_secs(2),p.channels[1].send_text_bytes(&bytes::Bytes::from(packet))).await,Ok(Ok(_)));p.state.multi.lock().unwrap().activation_sent(id,ok);}
}
async fn multi_command(p:&mut Peer,v:&Value)->Value{
 if !p.multi_video{return error("multi_video_not_enabled")}
 let action=v["action"].as_str().unwrap_or("");
 if action=="snapshot"{multi_advance(p).await;let mut snapshot=p.state.multi.lock().unwrap().snapshot();let display=p.state.advanced.lock().unwrap().snapshot();#[cfg(feature="rtp-diagnostics")] {snapshot["rtpDiagnostics"]=diagnostic_snapshot(p).await;}snapshot["portraitSettings"]=portrait_status(p);snapshot["currentReported"]=display["currentReported"].clone();snapshot["captureReported"]=display["captureReported"].clone();snapshot["reportError"]=display["reportError"].clone();snapshot["captureConfigResponse"]=display["captureConfigResponse"].clone();return snapshot}
 if action=="claim"{let f=match crate::multistream::Streams::focus_request(v){Ok(f)=>f,Err(e)=>return error(e)};if let Err(e)=p.state.multi.lock().unwrap().prepare_claim(&f){return error(e)}let _=release_all(p).await;if p.input.held_count()>0||p.touch_active{return error("input_release_incomplete")}p.state.multi.lock().unwrap().revoke();let result=p.state.multi.lock().unwrap().claim(f);return match result{Ok(())=>json!({"claimed":true}),Err(e)=>error(e)}}
 if action=="revoke"{let matches=p.state.multi.lock().unwrap().matches_revoke(v);if matches{p.state.multi.lock().unwrap().invalidate_owner();let _=release_all(p).await;if p.input.held_count()>0||p.touch_active{return error("input_release_incomplete")}p.state.multi.lock().unwrap().revoke();}return json!({"revoked":matches})}
 let id=match crate::multistream::screen_id(v){Ok(id)=>id,Err(e)=>return error(e)};
 match action{
 "open"=>{let result=p.state.multi.lock().unwrap().open(id);if let Err(e)=result{return error(e)}multi_advance(p).await;json!({"opened":true})},
 "bind"=>{let slot=v["renderSlot"].as_u64().and_then(|x|u32::try_from(x).ok());let generation=v["generation"].as_u64().and_then(|x|u32::try_from(x).ok());let(Some(slot),Some(generation))=(slot,generation)else{return error("invalid_renderer_identity")};if !crate::nal_policy::codec_matches(p.codec,unsafe{s5_video_slot_ready_codec(slot,generation)}){return error("renderer_codec_mismatch_or_not_ready")};let mut multi=p.state.multi.lock().unwrap();match multi.bind(id,slot,generation){Ok(())=>{for(s,g,e)in multi.lanes(){unsafe{s5_video_slot_begin_epoch(s,g,e)}}json!({"bound":true})},Err(e)=>error(e)}},
 "close"=>{p.portrait_attempts.remove(&id);let owned=p.state.multi.lock().unwrap().owner.as_ref().is_some_and(|o|o.screen==id);if owned{p.state.multi.lock().unwrap().invalidate_owner();let _=release_all(p).await;if p.input.held_count()>0||p.touch_active{return error("input_release_incomplete")}p.state.multi.lock().unwrap().revoke();}let packet={let mut multi=p.state.multi.lock().unwrap();let packet=match multi.begin_close(id){Ok(p)=>p,Err(e)=>return error(e)};for(s,g,e)in multi.lanes(){unsafe{s5_video_slot_begin_epoch(s,g,e)}}packet};let ok=matches!(tokio::time::timeout(Duration::from_secs(2),p.channels[1].send_text_bytes(&bytes::Bytes::from(packet))).await,Ok(Ok(_)));p.state.multi.lock().unwrap().close_sent(id,ok);if ok{json!({"closed":true})}else{error("screen_stop_send_failed")}},
 _=>error("invalid_multi_action")}
}
async fn receive(p:&mut Peer,e:&Value)->Result<(),&'static str>{match e["type"].as_str(){
 Some("answer")=>{if p.answered{return Ok(())}let s=e["sdp"].as_str().filter(|s|s.len()<=1048576).ok_or("invalid_answer")?;let answer=RTCSessionDescription::answer(s.into()).map_err(|_|"invalid_answer")?;if p.codec==2&&!p.files_only&&!p.catalog_only&&!p.lock_only&&!p.terminal_only&&crate::orientation::answer_accepts_hevc(s)==Some(false){return Err("remote_hevc_unsupported");}if p.multi_video{p.state.multi.lock().unwrap().answer=Some(crate::multistream::answer_tracks(s).ok_or("multi_answer_requires_three_tracks")?);}p.pc.set_remote_description(answer).await.map_err(|_|"remote_answer_failed")?;#[cfg(feature="rtp-diagnostics")] { *p.state.answer_diagnostics.lock().unwrap()=crate::rtp_diagnostics::answer_summary(s); }p.state.microphone.lock().unwrap().configure(s);p.answered=true;for c in p.early.drain(..){p.pc.add_ice_candidate(c).await.map_err(|_|"early_candidate_failed")?;}Ok(())},
 Some("candidate")=>{let c=serde_json::from_value::<RTCIceCandidateInit>(e["candidate"].clone()).map_err(|_|"invalid_candidate")?;if p.answered{p.pc.add_ice_candidate(c).await.map_err(|_|"remote_candidate_failed")?;}else{if p.early.len()>=256{return Err("early_candidate_limit")};p.early.push(c);}Ok(())},_=>Err("invalid_peer_event")}}
async fn transmit_one(p:&mut Peer,event:&InputEvent)->Result<(),&'static str>{
 let c=&p.channels[0];if c.ready_state()!=RTCDataChannelState::Open{return Err("control_not_open")}
 if !p.input.before_send(event)?{return Ok(())}
 let screen=if p.multi_video{p.state.multi.lock().unwrap().owner.as_ref().map(|o|o.screen as u64)}else{p.state.advanced.lock().unwrap().active_id()};
 c.send(&bytes::Bytes::from(event.wire_for_screen(screen).to_string())).await.map_err(|_|"input_send_failed")?;
 if matches!(event,InputEvent::Absolute{..}){p.pointer_screen=screen;p.anchor_after_switch=false;}
 p.input.sent(event);if event.is_input(){p.state.input.fetch_add(1,Ordering::Relaxed);}Ok(())
}
async fn transmit(p:&mut Peer,event:&InputEvent)->Result<(),&'static str>{
 let screen=p.state.advanced.lock().unwrap().active_id();
 // A trackpad delta has no screen ID. Anchor only on the user's first mouse action
 // after changing screens; releases and keyboard/heartbeat never move the pointer.
 if p.anchor_after_switch&&screen.is_some()&&p.pointer_screen!=screen&&matches!(event,InputEvent::Relative{..}|InputEvent::Scroll{..}|InputEvent::Button{down:true,..}) {
  transmit_one(p,&InputEvent::Absolute{x:0.5,y:0.5}).await?;
 }
 transmit_one(p,event).await
}
async fn input(p:&mut Peer,e:&Value)->Result<(),&'static str>{if p.files_only||p.catalog_only||p.lock_only||p.terminal_only{return Err("files_only_input_blocked")}if p.multi_video{p.state.multi.lock().unwrap().accepts_input(e)?;}let event=InputEvent::parse(e)?;if !crate::center::input_allowed(p.watch,&event){return Err("watch_mode_input_blocked")}if !crate::center::input_allowed(p.state.advanced.lock().unwrap().input_blocked(),&event){return Err("display_change_input_blocked")}transmit(p,&event).await}
async fn touch_send(p:&mut Peer,kind:crate::tablet_wire::Kind,points:&[crate::tablet_wire::Point])->Result<(),&'static str>{
 use crate::tablet_wire::Kind;
 let final_event=matches!(kind,Kind::End|Kind::Cancel);
 if !final_event && (p.files_only||p.catalog_only||p.lock_only||p.terminal_only||p.watch||p.state.advanced.lock().unwrap().input_blocked()||p.state.touch_support.load(Ordering::Acquire)!=2){return Err("touch_input_blocked");}
 let screen=p.state.advanced.lock().unwrap().active_id();
 crate::tablet_wire::validate_transition(p.touch_active,p.touch_screen,screen,kind)?;
 p.touch_sequence=p.touch_sequence.wrapping_add(1);
 let packet=crate::tablet_wire::encode(p.touch_sequence,now_ms(),kind,points)?;
 if p.channels[0].ready_state()!=RTCDataChannelState::Open{return Err("control_not_open");}
 if matches!(kind,Kind::Start){p.touch_active=true;p.touch_screen=screen;}
 if !matches!(tokio::time::timeout(Duration::from_millis(500),p.channels[0].send(&bytes::Bytes::from(packet))).await,Ok(Ok(_))){return Err("touch_send_failed");}
 if final_event{p.touch_active=false;p.touch_screen=None;}Ok(())
}
async fn touch_input(p:&mut Peer,event:&Value)->Result<(),&'static str>{
 use crate::tablet_wire::{Kind,Point};
 let kind=match event["type"].as_str(){Some("start")=>Kind::Start,Some("move")=>Kind::Move,Some("end")=>Kind::End,Some("cancel")=>Kind::Cancel,_=>return Err("invalid_touch_event")};
 let list=event["points"].as_array().ok_or("invalid_touch_points")?;if list.len()>32{return Err("invalid_touch_points");}
 let mut points=Vec::new();for item in list{let id=item["id"].as_u64().filter(|v|*v<=u32::MAX as u64).ok_or("invalid_touch_id")?;let x=item["x"].as_f64().ok_or("invalid_touch_x")?;let y=item["y"].as_f64().ok_or("invalid_touch_y")?;if !x.is_finite()||!y.is_finite()||!(0.0..=1.0).contains(&x)||!(0.0..=1.0).contains(&y){return Err("invalid_touch_coordinates");}points.push(Point{id:id as u32,x:x as f32,y:y as f32});}
 touch_send(p,kind,&points).await
}
// All releases precede PC close. Keep unsuccessful entries for a later explicit
// release_all/close retry; one blocked send must not skip the remaining entries.
// At most 32 keys + 3 buttons, each bounded to 100ms (<=3.5s send wait total).
async fn release_all(p:&mut Peer)->(usize,usize){
 let touch=p.touch_active;let releases=p.input.releases();let attempted=releases.len()+usize::from(touch);let mut sent=0;
 if touch && touch_send(p,crate::tablet_wire::Kind::Cancel,&[]).await.is_ok(){sent+=1;}
 for event in releases{if matches!(tokio::time::timeout(Duration::from_millis(100),transmit(p,&event)).await,Ok(Ok(()))){sent+=1;}}
 (attempted,sent)
}
fn release_reply(p:&Peer,attempted:usize,sent:usize)->Value{
 let mut out=json!({"inputReleaseAttempted":attempted,"inputReleaseSent":sent,"inputUnreleased":p.input.held_count(),"pressedMouse":p.input.button_count(),"pressedKeys":p.input.key_count(),"inputSent":p.state.input.load(Ordering::Relaxed)});
 if p.touch_active{out["inputUnreleased"]=json!(p.input.held_count()+1);out["pressedTouch"]=json!(1);}
 if p.input.held_count()>0||p.touch_active{out["error"]=json!("input_release_incomplete");}out
}
fn close(w:&mut Worker)->Value{if let Some(mut p)=w.peer.take(){p.state.center.lock().unwrap().close_security();let weak=Arc::downgrade(&p.pc);let ((release_attempted,release_sent),result)=w.rt.block_on(async{p.state.microphone.lock().unwrap().stop();p.state.files.lock().unwrap().disconnect();p.state.clipboard.lock().unwrap().disable();unsafe{s5_audio_stop();}let released=release_all(&mut p).await;let closed=tokio::time::timeout(Duration::from_secs(4),p.pc.close()).await;let _=p.stop.send(true);let mut handles=std::mem::take(&mut *p.readers.lock().unwrap());{let mut video=p.video_readers.lock().unwrap();for lane in video.iter_mut(){for(_,handle)in lane.drain(..){handle.abort();handles.push(handle);}}}for mut h in handles{if tokio::time::timeout(Duration::from_secs(1),&mut h).await.is_err(){h.abort();let _=h.await;}}let joined=tokio::time::timeout(Duration::from_secs(2),&mut p.processor).await.is_ok();if !joined{p.processor.abort();let _=(&mut p.processor).await;}(released,matches!(closed,Ok(Ok(())))&&joined)});let pending_keys=p.input.key_count();let pending_mouse=p.input.button_count();let pending_touch=usize::from(p.touch_active);p.rx.close();p.channels.clear();p.early.clear();let st=p.state.clone();drop(p);let released=w.rt.block_on(async{for _ in 0..50{if weak.upgrade().is_none(){return true}tokio::time::sleep(Duration::from_millis(20)).await;}false});json!({"closed":result,"weakReleased":released,"tracksObserved":st.tracks.load(Ordering::Relaxed),"mediaPackets":st.packets.load(Ordering::Relaxed),"accessUnits":st.aus.load(Ordering::Relaxed),"inputSent":st.input.load(Ordering::Relaxed),"inputReleaseAttempted":release_attempted,"inputReleaseSent":release_sent,"inputUnreleased":pending_keys+pending_mouse+pending_touch,"pressedKeys":pending_keys,"pressedMouse":pending_mouse,"pressedTouch":pending_touch})}else{json!({"closed":true,"weakReleased":true,"tracksObserved":0,"inputReleaseAttempted":0,"inputReleaseSent":0,"inputUnreleased":0,"pressedKeys":0,"pressedMouse":0})}}
async fn terminal_privacy(p:&mut Peer,action:&str)->Value{
 if !p.terminal_only{return error("terminal_only_required")}
 if !p.state.security_queried.load(Ordering::Acquire)&&query_security(p).await{p.state.security_queried.store(true,Ordering::Release);}
 let support=p.state.center.lock().unwrap().privacy_support;
 let desired={let mut privacy=p.state.terminal_privacy.lock().unwrap();match action{"privacy_enable" if privacy.enable(support)=>Some(3),"privacy_restore" if privacy.restore()=>Some(1),_=>None}};
 if let Some(mode)=desired{let result=setting(p,&json!({"kind":"privacy","value":mode,"confirmed":true})).await;if mode==3{p.state.terminal_privacy.lock().unwrap().sent(result["sent"]==true);}else if result["sent"]==true{let until=Instant::now()+Duration::from_millis(800);while p.state.terminal_privacy.lock().unwrap().restore()&&Instant::now()<until{tokio::time::sleep(Duration::from_millis(20)).await;}}}
 let mut out=p.state.terminal_privacy.lock().unwrap().snapshot(support);let security=p.state.center.lock().unwrap().snapshot();if out["privacyProtected"]!=true&&security["privacyError"].is_string(){out["privacyState"]=json!("failed");out["privacyErrorCode"]=security["privacyReplyError"].clone();}if desired==Some(1){out["privacyRestoreConfirmed"]=json!(out["privacyCurrent"]==1&&out["privacyOwned"]==false);}out
}
async fn setting(p:&mut Peer,e:&Value)->Value{
 if p.lock_only{if let Err(reason)=p.state.center.lock().unwrap().tool_lock_allowed(e){return error(reason)}}
 if e["kind"]=="watch"{let Some(on)=e["enabled"].as_bool()else{return error("invalid_watch")};p.watch=on;if on{p.state.center.lock().unwrap().revoke_unlock();let _=microphone(p,&json!({"action":"stop"})).await;}if on&&p.multi_video{p.state.multi.lock().unwrap().invalidate_owner();}let (attempted,sent)=if on{release_all(p).await}else{(0,0)};if on&&p.multi_video&&p.input.held_count()==0&&!p.touch_active{p.state.multi.lock().unwrap().revoke();}return json!({"watch":on,"localApplied":true,"sentMessages":0,"remoteAck":null,"inputReleaseAttempted":attempted,"inputReleaseSent":sent,"inputUnreleased":p.input.held_count()});}
 if p.channels[0].ready_state()!=RTCDataChannelState::Open{return error("control_not_open")}
 let privacy=e["kind"]=="privacy";if privacy&&!p.state.echo.load(Ordering::Acquire){return error("control_echo_required")}if privacy&&p.channels[1].ready_state()!=RTCDataChannelState::Open{return error("text_channel_not_open")}let resolution=e["kind"]=="resolution";let mut request=e.clone();
 if resolution{
  if p.channels[1].ready_state()!=RTCDataChannelState::Open{return error("text_channel_not_open")}
  let target=p.state.advanced.lock().unwrap().resolution_target(e["value"]=="remote");let(id,size)=match target{Ok(t)=>t,Err(e)=>return error(e)};
  request["screenId"]=json!(id);
  if e["value"]=="remote"{request["width"]=size["width"].clone();request["height"]=size["height"].clone();request["logicalWidth"]=size["logicalWidth"].clone();request["logicalHeight"]=size["logicalHeight"].clone();}
  let Some(w)=request["width"].as_u64().filter(|v|*v>=2&&*v<=8192&&v%2==0)else{return error("invalid_width")};let Some(h)=request["height"].as_u64().filter(|v|*v>=2&&*v<=8192&&v%2==0)else{return error("invalid_height")};
  if !unsafe{s5_video_size_supported(w as u32,h as u32)}{return error("active_decoder_size_unsupported")}
 }
 if matches!(e["kind"].as_str(),Some("lock_now"|"reboot"|"shutdown"|"privacy")){if !p.state.echo.load(Ordering::Acquire){return error("control_echo_required")}if e["confirmed"]!=true{return error("explicit_remote_state_confirmation_required")}let restoring_privacy=privacy&&e["value"]==1;if !restoring_privacy{let _=release_all(p).await;if p.input.held_count()>0||p.touch_active{return error("input_release_incomplete")}if p.multi_video{p.state.multi.lock().unwrap().revoke();}}}
 let prepared=p.state.center.lock().unwrap().prepare(&request);let(seq,packets)=match prepared{Ok(p)=>p,Err(e)=>return error(e)};let total=packets.len();let mut sent=0;let mut saver_failed=false;
 if resolution{p.manual_scale_screens.select(request["screenId"].as_u64().unwrap() as u32);if let Some(attempt)=p.portrait_attempts.get_mut(&(request["screenId"].as_u64().unwrap() as u32)){attempt.fallback=true;}let(_,_) = release_all(p).await;if p.input.held_count()>0||p.touch_active{return error("input_release_incomplete")};let mut a=p.state.advanced.lock().unwrap();a.begin_stream_scale(request["screenId"].as_u64().unwrap(),request["width"].as_u64().unwrap(),request["height"].as_u64().unwrap());a.set_stream_scale_seq(seq);unsafe{s5_video_begin_epoch(a.epoch())};}
 for bytes in packets{let payload=bytes::Bytes::from(bytes);let stream=matches!(e["kind"].as_str(),Some("resolution"|"quality"|"fps"|"privacy"));let ok=if stream{matches!(tokio::time::timeout(Duration::from_secs(2),p.channels[1].send_text_bytes(&payload)).await,Ok(Ok(_)))}else{matches!(tokio::time::timeout(Duration::from_secs(2),p.channels[0].send(&payload)).await,Ok(Ok(_)))};if !ok{break;}sent+=1;p.state.center.lock().unwrap().sent(seq,sent);
  if privacy&&request["value"]==2&&sent==1&&total==2{let until=Instant::now()+Duration::from_secs(3);loop{match p.state.center.lock().unwrap().screensaver_response(seq){Some(true)=>break,Some(false)=>{saver_failed=true;break},None=>{}}if Instant::now()>=until{saver_failed=true;break;}tokio::time::sleep(Duration::from_millis(20)).await;}if saver_failed{break;}}
 }
 if resolution{p.state.advanced.lock().unwrap().mark_sent(sent==total);}
 if sent==total&&matches!(e["kind"].as_str(),Some("auto_lock"|"privacy")){let _=query_security(p).await;}
 let mut out=json!({"seq":seq,"localApplied":true,"sentMessages":sent,"totalMessages":total,"sent":sent==total,"remoteAck":null});if resolution{out["display"]=display_sample(p);}if sent!=total{out["error"]=json!(if saver_failed{"privacy_screensaver_unconfirmed"}else{"control_send_incomplete"})}out
}
async fn advanced(p:&mut Peer,e:&Value)->Value{
 if e["action"]!="switch_screen"{return p.state.advanced.lock().unwrap().command(e)}
 if p.channels[1].ready_state()!=RTCDataChannelState::Open{return error("text_channel_not_open")}
 let _=release_all(p).await;if p.input.held_count()>0||p.touch_active{return error("input_release_incomplete")}
 if crate::advanced_controls::direct_switch_enabled(p.multi_video) {
  if e["confirmed"]!=true{return error("explicit_screen_selection_required")}
  let Some(id)=e["id"].as_u64().and_then(|v|u32::try_from(v).ok()).filter(|v|*v<=i32::MAX as u32) else{return error("invalid_screen_id")};
  if !p.state.advanced.lock().unwrap().snapshot()["screens"].as_array().is_some_and(|rows|rows.iter().any(|s|s["id"]==id)){return error("screen_not_in_inventory")}
  let (seq,packet)=match p.state.center.lock().unwrap().direct_screen_setting(id){Ok(v)=>v,Err(e)=>return error(e)};
  p.portrait_attempts.clear();
  let prepared=p.state.advanced.lock().unwrap().prepare_switch(e);
  if let Err(e)=prepared{return error(e)}
  let epoch={let mut a=p.state.advanced.lock().unwrap();a.direct_switch_no_registration();a.epoch()};
  p.direct_switch_active=true;p.pointer_screen=None;p.anchor_after_switch=true;unsafe{s5_video_begin_epoch(epoch)};
  let sent=matches!(tokio::time::timeout(Duration::from_secs(2),p.channels[1].send_text_bytes(&bytes::Bytes::from(packet))).await,Ok(Ok(_)));
  p.state.center.lock().unwrap().sent(seq,usize::from(sent));
  let mut a=p.state.advanced.lock().unwrap();a.mark_sent(sent);let mut out=a.snapshot();out["seq"]=json!(seq);out["sent"]=json!(sent);out["remoteAck"]=Value::Null;if !sent{out["error"]=json!("display_send_incomplete");}return out;
 }
 p.portrait_attempts.clear();let prepared=p.state.advanced.lock().unwrap().prepare_switch(e);let(seq,packet)=match prepared{Ok(v)=>v,Err(e)=>return error(e)};
 let epoch=p.state.advanced.lock().unwrap().epoch();p.pointer_screen=None;p.anchor_after_switch=true;unsafe{s5_video_begin_epoch(epoch)};
 // One negotiated video track cannot capture a second screen while its old source owns it.
 // Stop this connection's capture before reassigning track zero to the selected source.
 let mut stop_action=vec![];crate::wire::int(1,7,&mut stop_action);crate::wire::bytes(2,b"{\"screen_id\":-1}",&mut stop_action);
 let stopped=matches!(tokio::time::timeout(Duration::from_secs(2),p.channels[1].send_text_bytes(&bytes::Bytes::from(crate::wire::envelope(seq+200_000,3,&stop_action)))).await,Ok(Ok(_)));
 let registered=matches!(tokio::time::timeout(Duration::from_secs(2),p.channels[1].send_text_bytes(&bytes::Bytes::from(crate::wire::register_video_track_zero(seq+100_000)))).await,Ok(Ok(_)));
 let sent=stopped&&registered&&matches!(tokio::time::timeout(Duration::from_secs(2),p.channels[1].send_text_bytes(&bytes::Bytes::from(packet))).await,Ok(Ok(_)));
 let mut a=p.state.advanced.lock().unwrap();a.mark_sent(sent);let mut out=a.snapshot();out["seq"]=json!(seq);out["sent"]=json!(sent);out["remoteAck"]=Value::Null;if !sent{out["error"]=json!("display_send_incomplete");}out
}
async fn query_security(p:&Peer)->bool{
 if p.files_only||p.catalog_only||p.lock_only||!p.state.echo.load(Ordering::Acquire)||p.channels[1].ready_state()!=RTCDataChannelState::Open{return false;}
 let packet=p.state.center.lock().unwrap().security_query();
 matches!(tokio::time::timeout(Duration::from_secs(2),p.channels[1].send_text_bytes(&bytes::Bytes::from(packet))).await,Ok(Ok(_)))
}
async fn identity_continuity(p:&Peer)->Value {
 let dtls=p.pc.sctp().transport();
 let connected=p.answered&&p.pc.connection_state()==webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState::Connected
  &&dtls.state()==webrtc::dtls_transport::dtls_transport_state::RTCDtlsTransportState::Connected;
 let mut result=identity::Status::UNAVAILABLE;
 if connected { if let Some(scope)=p.identity_scope.as_deref() {
  if let Some(cached)=*p.identity_status.lock().unwrap() { return json!({"leaf":cached.leaf,"spki":cached.spki}); }
  // Vendor stores the DER before verification; Connected is essential here.
  let der=dtls.get_remote_certificate().await;
  if dtls.state()==webrtc::dtls_transport::dtls_transport_state::RTCDtlsTransportState::Connected {
   let mut status=p.identity_status.lock().unwrap();
   if status.is_none() { let observed=identity::observe(scope,&der); if observed.leaf!="unavailable" { *status=Some(observed); } }
   result=status.unwrap_or(identity::Status::UNAVAILABLE);
  }
 } }
 json!({"leaf":result.leaf,"spki":result.spki})
}
fn spawn_link_stats(pc:Arc<RTCPeerConnection>, state:Arc<Observed>, mut stopped:watch::Receiver<bool>)->JoinHandle<()> {
 tokio::spawn(async move {
  use webrtc::stats::StatsReportType as T;
  let mut tick=tokio::time::interval(Duration::from_secs(1));
  tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
  loop {
   tokio::select! { _=stopped.changed()=>break, _=tick.tick()=>() }
   let sample=tokio::select! {
    _=stopped.changed()=>break,
    result=tokio::time::timeout(Duration::from_millis(500),pc.get_stats())=>result
   };
   let Ok(report)=sample else {continue};
   let pair=report.reports.values().filter_map(|r| match r {T::CandidatePair(p) if p.nominated=>Some(p),_=>None}).max_by_key(|p|p.bytes_received);
   let mut nack=0;let mut pli=0;let mut has_rtp=false;
   for entry in report.reports.values(){
    if let T::InboundRTP(rtp)=entry {
     if rtp.kind=="video" {has_rtp=true;nack+=rtp.nack_count;pli+=rtp.pli_count.unwrap_or(0);}
    }
   }
   let sample=json!({
    "rttMs":pair.and_then(|p| (p.current_round_trip_time>0.0).then_some(p.current_round_trip_time*1000.0)),
    "bytesIn":pair.map(|p|p.bytes_received),"bytesOut":pair.map(|p|p.bytes_sent),
    "nack":has_rtp.then_some(nack),"pli":has_rtp.then_some(pli)
   });
   *state.link_stats.lock().unwrap()=Some((Instant::now(),sample));
  }
 })
}
async fn metrics(p:&Peer)->Value{
 let identity_continuity=identity_continuity(p).await;
 if !p.files_only&&!p.catalog_only&&!p.lock_only&&p.state.echo.load(Ordering::Acquire)&&p.channels[1].ready_state()==RTCDataChannelState::Open
     && !p.state.security_queried.swap(true,Ordering::AcqRel){
  let channel=Arc::downgrade(&p.channels[1]);let state=p.state.clone();
  let packet=state.center.lock().unwrap().security_query();
  tokio::spawn(async move{
   if let Some(channel)=channel.upgrade() {
    if !matches!(tokio::time::timeout(Duration::from_secs(2),channel.send_text_bytes(&bytes::Bytes::from(packet))).await,Ok(Ok(_))){
     state.security_queried.store(false,Ordering::Release);
    }
   }
  });
 }
 let link=p.state.link_stats.lock().unwrap().as_ref().filter(|(at,_)|at.elapsed()<Duration::from_secs(4)).map(|(_,sample)|sample.clone()).unwrap_or(Value::Null);
 let display=display_sample(p);let unlock_available=p.unlock_generation.is_some_and(|generation|unlock_transport(p,generation));let mut center=p.state.center.lock().unwrap().snapshot();center["autoUnlockAvailable"]=json!(unlock_available);let t=p.state.traffic.lock().unwrap();json!({"initialDisplayRestores":p.initial_display_restores,"initialDisplayRestoreFailures":p.initial_display_failures,"peerIdentityContinuity":identity_continuity,"elapsedMs":p.began.elapsed().as_millis()as u64,"videoRtpBytesApprox":t.bytes,"videoPackets":t.packets,"loss":t.loss(),"rttMs":link["rttMs"],"link":link,"watch":p.watch,"inputSent":p.state.input.load(Ordering::Relaxed),"center":center,"display":display})
}
async fn microphone(p:&mut Peer,e:&Value)->Value{
 let action=e["action"].as_str().unwrap_or("");
 let connected=p.answered&&p.pc.connection_state()==webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState::Connected&&p.channels[0].ready_state()==RTCDataChannelState::Open&&p.channels[1].ready_state()==RTCDataChannelState::Open;
 p.state.microphone.lock().unwrap().tick(now_ms());
 if action=="stop"||(!connected&&p.state.microphone.lock().unwrap().enabled){
  let packet=p.state.microphone.lock().unwrap().stop();
  if p.channels[1].ready_state()==RTCDataChannelState::Open{let _=tokio::time::timeout(Duration::from_millis(300),p.channels[1].send_text_bytes(&bytes::Bytes::from(packet))).await;}
  return p.state.microphone.lock().unwrap().snapshot();
 }
 if action=="status"{return p.state.microphone.lock().unwrap().snapshot()}
 if !connected{return error("microphone_active_session_required")}
 if action=="request"{
  let prepared=p.state.microphone.lock().unwrap().request(e["permissionGranted"]==true,e["foreground"]==true,p.watch,now_ms());
  let(seq,packet)=match prepared{Ok(v)=>v,Err(e)=>return error(e)};
  let sent=matches!(tokio::time::timeout(Duration::from_secs(2),p.channels[1].send_text_bytes(&bytes::Bytes::from(packet))).await,Ok(Ok(_)));
  let mut mic=p.state.microphone.lock().unwrap();mic.sent(seq,sent);return mic.snapshot();
 }
 if action=="packet"{
  if p.watch{return error("microphone_watch_mode")}
  let Some(generation)=e["generation"].as_u64()else{return error("invalid_microphone_generation")};
  let Some(timestamp)=e["timestamp"].as_u64().and_then(|v|u32::try_from(v).ok())else{return error("invalid_microphone_timestamp")};
  let Some(encoded)=e["base64"].as_str().filter(|s|s.len()<=5336)else{return error("invalid_microphone_packet")};
  let Ok(data)=STANDARD.decode(encoded)else{return error("invalid_microphone_base64")};
  if let Err(e)=p.state.microphone.lock().unwrap().packet(generation,timestamp,data.len()){return error(e)}
  let packet=webrtc::rtp::packet::Packet{header:webrtc::rtp::header::Header{version:2,sequence_number:p.microphone_sequence,timestamp:timestamp.wrapping_add(p.microphone_origin),marker:timestamp==0,..Default::default()},payload:bytes::Bytes::from(data)};
  // The SRTP track owns SSRC/PT binding; no audio is sent on a data-channel tunnel.
  match tokio::time::timeout(Duration::from_millis(300),p.microphone_track.write_rtp(&packet)).await{
   Ok(Ok(_))=>{p.microphone_sequence=p.microphone_sequence.wrapping_add(1);let mut m=p.state.microphone.lock().unwrap();m.sent_packets+=1;m.snapshot()},
   _=>{p.state.microphone.lock().unwrap().stop();error("microphone_rtp_send_failed")}
  }
 }else{error("invalid_microphone_action")}
}
/// Invoked only by the authenticated native own-device session binding code.
/// There is deliberately no JSON operation that installs an unlock generation.
pub fn bind_unlock(generation:u64,identity_scope:&str)->bool {
 let Some(cell)=WORKER.get()else{return false};let Ok(mut w)=cell.lock()else{return false};
 let Some(p)=w.peer.as_mut()else{return false};
 if identity_scope.is_empty()||generation==0||p.unlock_generation.is_some()||p.files_only||p.catalog_only||p.lock_only||p.terminal_only{return false}
 p.identity_scope=Some(identity_scope.to_owned());p.unlock_generation=Some(generation);true
}
fn unlock_transport(p:&Peer,generation:u64)->bool {
 p.unlock_generation==Some(generation)&&!p.files_only&&!p.catalog_only&&!p.lock_only&&!p.terminal_only&&!p.watch&&p.answered
 &&p.pc.connection_state()==webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState::Connected
 &&p.pc.sctp().transport().state()==webrtc::dtls_transport::dtls_transport_state::RTCDtlsTransportState::Connected
 &&p.state.center.lock().unwrap().unlock_active()
 &&p.state.echo.load(Ordering::Acquire)&&p.channels[1].ready_state()==RTCDataChannelState::Open
}
pub fn unlock_ready(generation:u64)->bool {
 let Some(cell)=WORKER.get()else{return false};let Ok(w)=cell.lock()else{return false};
 w.peer.as_ref().is_some_and(|p|unlock_transport(p,generation))
}
pub fn unlock_permitted(generation:u64)->bool {
 let Some(cell)=WORKER.get()else{return false};let Ok(w)=cell.lock()else{return false};
 let Some(p)=w.peer.as_ref()else{return false};
 unlock_transport(p,generation)&&p.state.center.lock().unwrap().unlock_permitted()
}
pub fn unlock_observed_unlocked(generation:u64)->bool {
 let Some(cell)=WORKER.get()else{return false};let Ok(w)=cell.lock()else{return false};
 let Some(p)=w.peer.as_ref()else{return false};
 unlock_transport(p,generation)&&p.state.center.lock().unwrap().unlock_observed_unlocked()
}
pub fn unlock_send(generation:u64,password:&[u8])->Value {
 let Some(cell)=WORKER.get()else{return error("no_active_peer")};let Ok(mut w)=cell.lock()else{return error("peer_worker_unavailable")};
 let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_mut()else{return error("no_active_peer")};
 if !unlock_transport(p,generation){return error("unlock_bound_desktop_required")}
 // Lock state is revalidated and one use is consumed immediately before the
 // fixed send. Peer replacement/close is serialized by the same Worker lock.
 let packet=match p.state.center.lock().unwrap().prepare_unlock(password){Ok(v)=>v,Err(e)=>return error(e)};
 let sent=rt.block_on(async{tokio::time::timeout(Duration::from_secs(2),p.channels[1].send_text_bytes(&bytes::Bytes::copy_from_slice(&packet))).await});
 let sent=matches!(sent,Ok(Ok(_)));
 if sent{p.state.center.lock().unwrap().unlock_submitted();}
 let mut out=json!({"attempted":true,"sent":sent,"sentMessages":if sent{1}else{0},"remoteAck":null,"actualUnlocked":null});
 if !sent{out["error"]=json!("unlock_send_failed");}out
}
pub fn call(v:Value)->Value{
 let cell=WORKER.get_or_init(||Mutex::new(Worker{rt:tokio::runtime::Builder::new_multi_thread().worker_threads(2).max_blocking_threads(2).enable_all().build().expect("runtime"),peer:None}));let Ok(mut w)=cell.lock()else{return error("peer_worker_unavailable")};
 if w.peer.as_ref().is_some_and(|p|p.terminal_only)&&!matches!(v["op"].as_str(),Some("peer_poll"|"peer_receive"|"peer_terminal"|"peer_close"|"peer_release_all"|"peer_end_media")){return error("terminal_only_operation_blocked")}
 if w.peer.as_ref().is_some_and(|p|p.catalog_only)&&!matches!(v["op"].as_str(),Some("peer_poll"|"peer_receive"|"peer_catalog"|"peer_close"|"peer_release_all"|"peer_end_media")){return error("catalog_only_operation_blocked")}
 if w.peer.as_ref().is_some_and(|p|p.files_only)&&!matches!(v["op"].as_str(),Some("peer_poll"|"peer_receive"|"peer_files_prepare"|"peer_files_status"|"peer_files_read"|"peer_close"|"peer_release_all"|"peer_end_media")){return error("files_only_operation_blocked")}
 if w.peer.as_ref().is_some_and(|p|p.lock_only)&&!matches!(v["op"].as_str(),Some("peer_poll"|"peer_receive"|"peer_setting"|"peer_close"|"peer_release_all"|"peer_end_media")){return error("lock_only_operation_blocked")}
 match v["op"].as_str(){
 Some("peer_start")=>{if w.peer.is_some(){return error("peer_already_active")};let c=match config(&v["config"]){Ok(c)=>c,Err(e)=>return error(e)};let r=w.rt.block_on(async{tokio::time::timeout(Duration::from_secs(8),open(c,v["filesOnly"].as_bool().unwrap_or(false),v["catalogOnly"].as_bool().unwrap_or(false),v["lockOnly"].as_bool().unwrap_or(false),v["terminalOnly"].as_bool().unwrap_or(false),v["multiVideo"].as_bool().unwrap_or(false),v["decoderCodec"].as_u64().filter(|c|[1,2].contains(c)).unwrap_or(1) as u32,v["decoderLevel"].as_u64().and_then(|n|u32::try_from(n).ok()).unwrap_or(31),v["decoderWidth"].as_u64().and_then(|n|u32::try_from(n).ok()).unwrap_or(1280),v["decoderHeight"].as_u64().and_then(|n|u32::try_from(n).ok()).unwrap_or(720),v["decoderFps"].as_u64().filter(|n|(1..=60).contains(n)).unwrap_or(30) as u32)).await});match r{Ok(Ok((p,sdp)))=>{let files=p.files_only||p.catalog_only||p.lock_only||p.terminal_only;w.peer=Some(p);json!({"offer":sdp,"offerVideoSections":if files{0}else if v["multiVideo"]==true{2}else{1},"offerAudioSections":if files{0}else{1},"offerApplicationOnly":files})},Ok(Err(e))=>error(e),Err(_)=>error("peer_start_timeout")}},
 Some("peer_poll")=>{let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_mut()else{return error("no_active_peer")};rt.block_on(multi_advance(p));rt.block_on(portrait_advance(p));if !p.files_only&&!p.catalog_only&&!p.lock_only&&!p.terminal_only&&p.state.echo.load(Ordering::Acquire)&&p.state.touch_support.load(Ordering::Acquire)==0&&p.touch_query_attempts<3&&p.touch_query_last.map_or(true,|t|t.elapsed()>=Duration::from_secs(5)){p.touch_query_attempts+=1;p.touch_query_last=Some(Instant::now());let packet=crate::tablet_wire::metrics_request(1_900_000+u64::from(p.touch_query_attempts));let _=rt.block_on(async{tokio::time::timeout(Duration::from_millis(500),p.channels[0].send(&bytes::Bytes::from(packet))).await});}if !p.terminal_only{let messages=p.state.files.lock().unwrap().tick(now_ms());rt.block_on(send_files(&p.state,&p.channels,messages));}if p.overflow.load(Ordering::Relaxed)>0{return error("candidate_queue_limit")};let mut candidates=vec![];while let Ok(c)=p.rx.try_recv(){candidates.push(c)}#[cfg(feature="rtp-diagnostics")] let diagnostics=if v["collectDiagnostics"]!=false{rt.block_on(diagnostic_snapshot(p))}else{Value::Null};let st=&p.state;let mut out=json!({"portraitSettings":portrait_status(p),"legacyCapture":p.state.legacy_capture.lock().unwrap().clone(),"candidates":candidates,"iceState":p.pc.ice_connection_state().to_string(),"connectionState":p.pc.connection_state().to_string(),"dtlsState":p.pc.sctp().transport().state().to_string(),"answered":p.answered,"tracksObserved":st.tracks.load(Ordering::Relaxed),"fileChannelOpen":p.channels[3].ready_state()==RTCDataChannelState::Open,"dataChannelsOpen":p.channels.iter().filter(|c|c.ready_state()==RTCDataChannelState::Open).count(),"controlOpen":p.channels[0].ready_state()==RTCDataChannelState::Open,"touchSupport":p.state.touch_support.load(Ordering::Acquire),"touchQueryExhausted":p.touch_query_attempts>=3&&p.state.touch_support.load(Ordering::Acquire)==0,"pressedTouch":usize::from(p.touch_active),"echoReceived":st.echo.load(Ordering::Acquire),"echoSent":st.echo_sent.load(Ordering::Acquire),"videoRequested":st.video_requested.load(Ordering::Acquire),"controlMessages":st.messages.load(Ordering::Relaxed),"mediaPackets":st.packets.load(Ordering::Relaxed),"accessUnits":st.aus.load(Ordering::Relaxed),"inputSent":st.input.load(Ordering::Relaxed),"pressedMouse":p.input.button_count(),"pressedKeys":p.input.key_count(),"mediaError":st.media_error.load(Ordering::Relaxed)});#[cfg(feature="rtp-diagnostics")] {out["rtpDiagnostics"]=diagnostics;}
  if !p.files_only && !p.catalog_only && !p.lock_only && !p.terminal_only {
   let info = rt.block_on(async {
    tokio::time::timeout(Duration::from_millis(100), crate::connection_info::selected_connection(&p.pc))
        .await.ok().flatten()
   });
   out["connectionInfo"] = json!(info);
  }
  out},
 Some("peer_receive"|"peer_input")=>{let is_input=v["op"]=="peer_input";let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_mut()else{return error("no_active_peer")};let result=rt.block_on(async{tokio::time::timeout(Duration::from_secs(6),async{if is_input{input(p,&v["event"]).await}else{receive(p,&v["event"]).await}}).await});let mut reply=json!({"answered":p.answered,"inputSent":p.state.input.load(Ordering::Relaxed),"pressedMouse":p.input.button_count(),"pressedKeys":p.input.key_count()});match result{Ok(Ok(()))=>(),Ok(Err(e))=>reply["error"]=json!(e),Err(_)=>reply["error"]=json!("peer_operation_timeout")};reply},
 Some("peer_multi")=>{let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_mut()else{return error("no_active_peer")};rt.block_on(multi_command(p,&v["event"]))},
 Some("peer_touch")=>{if w.peer.as_ref().is_some_and(|p|p.multi_video){return error("multi_touch_not_supported")}let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_mut()else{return error("no_active_peer")};match rt.block_on(touch_input(p,&v["event"])) {Ok(())=>json!({"sent":true}),Err(e)=>error(e)}},
 Some("peer_release_all")=>{let Worker{rt,peer}=&mut *w;if let Some(p)=peer.as_mut(){if p.multi_video{p.state.multi.lock().unwrap().invalidate_owner();}let (attempted,sent)=rt.block_on(release_all(p));if p.multi_video&&p.input.held_count()==0&&!p.touch_active{p.state.multi.lock().unwrap().revoke();}release_reply(p,attempted,sent)}else{json!({"inputReleaseAttempted":0,"inputReleaseSent":0,"inputUnreleased":0,"pressedMouse":0,"pressedKeys":0})}},
 Some("peer_setting")=>{if w.peer.as_ref().is_some_and(|p|p.multi_video)&&matches!(v["event"]["kind"].as_str(),Some("quality"|"fps"|"resolution")){return error("multi_stream_setting_not_supported")}let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_mut()else{return error("no_active_peer")};rt.block_on(setting(p,&v["event"]))},
 Some("peer_restore_privacy")=>{let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_mut()else{return error("no_active_peer")};let owned=p.state.center.lock().unwrap().privacy_owned;if owned{rt.block_on(setting(p,&json!({"kind":"privacy","value":1,"confirmed":true})))}else{json!({"required":false})}},
 Some("peer_terminal")=>{let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_mut()else{return error("no_active_peer")};
  if matches!(v["event"]["action"].as_str(),Some("privacy_enable"|"privacy_status"|"privacy_restore")){return error("terminal_privacy_not_used")}
  if p.channels[4].ready_state()!=RTCDataChannelState::Open||!p.state.echo.load(Ordering::Acquire){return error("terminal_channel_not_ready")}
  if p.watch&&!matches!(v["event"]["action"].as_str(),Some("close"|"detach"|"detach_selected"|"status"|"read")){return error("terminal_watch_mode")}
  if v["event"]["action"]=="read"{return match p.state.terminal.lock().unwrap().read(&v["event"]){Ok(v)=>v,Err(e)=>error(e)}}
  if v["event"]["action"]=="raw_read"{return match p.state.terminal.lock().unwrap().read_v2(&v["event"]){Ok(v)=>v,Err(e)=>error(e)}}
  let prepared=p.state.terminal.lock().unwrap().prepare(&v["event"]);let packet=match prepared{Ok(p)=>p,Err(e)=>return error(e)};
  let sent=if let Some(packet)=packet{matches!(rt.block_on(async{tokio::time::timeout(Duration::from_secs(2),p.channels[4].send(&bytes::Bytes::from(packet))).await}),Ok(Ok(_)))}else{true};
  if !sent{p.state.terminal.lock().unwrap().send_failed(v["event"]["action"].as_str().unwrap_or(""),v["event"]["session"].as_u64().and_then(|n|u32::try_from(n).ok()));}let mut out=p.state.terminal.lock().unwrap().snapshot();out["sent"]=json!(sent);out},
 Some("peer_metrics")=>{let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_ref()else{return error("no_active_peer")};rt.block_on(metrics(p))},
 Some("peer_end_media")=>{if w.peer.as_ref().is_some_and(|p|p.terminal_only){let Worker{rt,peer}=&mut *w;return json!({"terminalOnly":true,"privacyChanged":false})}if w.peer.as_ref().is_some_and(|p|p.files_only||p.catalog_only||p.lock_only||p.terminal_only){return json!({"sent":false,"reason":"files_only"})}let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_mut()else{return json!({"sent":false,"reason":"no_active_peer"})};if !p.state.center.lock().unwrap().begin_end_media(){return json!({"sent":false,"alreadyEnded":true,"remoteAck":null,"operation":"prepare_disconnect"})}let terminal_close=p.state.terminal.lock().unwrap().prepare(&json!({"action":"detach_selected"})).ok().flatten();if let Some(packet)=terminal_close{let _=rt.block_on(async{tokio::time::timeout(Duration::from_millis(300),p.channels[4].send(&bytes::Bytes::from(packet))).await});}let privacy_owned=p.state.center.lock().unwrap().privacy_owned;let privacy_restore=if privacy_owned{rt.block_on(setting(p,&json!({"kind":"privacy","value":1,"confirmed":true})))}else{json!({"required":false})};// Pinned viewer rtc::Session::close ends the transport, without an extra quit_capture.
 json!({"sent":false,"prepared":true,"remoteAck":null,"operation":"prepare_disconnect","privacyRestore":privacy_restore})},
 Some("peer_microphone")=>{let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_mut()else{return error("no_active_peer")};rt.block_on(microphone(p,&v["event"]))},
 Some("peer_advanced")=>{if w.peer.as_ref().is_some_and(|p|p.multi_video){return error("multi_advanced_not_supported")}let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_mut()else{return error("no_active_peer")};display_sample(p);rt.block_on(advanced(p,&v["event"]))},
 Some("peer_clipboard")=>{let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_mut()else{return error("no_active_peer")};let prepared=p.state.clipboard.lock().unwrap().command(&v["event"]);let(mut out,messages)=match prepared{Ok(r)=>r,Err(e)=>return error(e)};let total=messages.len();let mut sent=0;
  for(channel,data)in messages{if !matches!(rt.block_on(async{tokio::time::timeout(Duration::from_secs(2),p.channels[channel].send(&bytes::Bytes::from(data))).await}),Ok(Ok(_))){break;}sent+=1;}
  if let Some(seq)=out["seq"].as_u64(){p.state.clipboard.lock().unwrap().mark_sent(seq,sent==total);}
  if total>0{out["sentMessages"]=json!(sent);out["totalMessages"]=json!(total);out["sent"]=json!(sent==total);if sent!=total{out["error"]=json!("clipboard_send_incomplete");}}
  out
 },
 Some("peer_files_prepare")=>{let Worker{rt,peer}=&mut *w;let Some(p)=peer.as_mut()else{return error("no_active_peer")};let event=&v["event"];if matches!(event["op"].as_str(),Some("list"|"upload"|"download")) && (p.channels[0].ready_state()!=RTCDataChannelState::Open || p.channels[3].ready_state()!=RTCDataChannelState::Open || !p.state.echo.load(Ordering::Acquire)){return error("file_channels_not_ready")}
  let prepared=p.state.files.lock().unwrap().prepare(event,now_ms());match prepared{Ok(messages)=>{rt.block_on(send_files(&p.state,&p.channels,messages));p.state.files.lock().unwrap().snapshot()},Err(e)=>json!({"error":e})}},
 Some("peer_catalog")=>{
  let Worker{rt,peer}=&mut *w;
  let Some(p)=peer.as_mut() else {return error("no_active_peer")};
  let event=&v["event"];
  let action=event["action"].as_str().unwrap_or("");
  if p.files_only || (action=="launch" && (p.catalog_only || p.watch || event["confirmed"]!=true)) {return error("catalog_action_unavailable")}
  let channel=&p.channels[1];
  if channel.ready_state()!=RTCDataChannelState::Open {return error("catalog_channel_opening")}
  let packet=p.state.catalog.lock().unwrap().command(action,event["id"].as_str().unwrap_or(""));
  match packet {
   Err(e)=>error(e),
   Ok(Some(packet))=>{let sent=rt.block_on(async{matches!(tokio::time::timeout(Duration::from_secs(3),channel.send_text_bytes(&bytes::Bytes::from(packet))).await,Ok(Ok(_)))});if sent{json!({"sent":true})}else{p.state.catalog.lock().unwrap().send_failed();error("catalog_send_failed")}},
   Ok(None)=>p.state.catalog.lock().unwrap().status(event["list"]==true)
  }
 },
 Some("peer_files_status")=>{let Some(p)=w.peer.as_ref()else{return error("no_active_peer")};p.state.files.lock().unwrap().snapshot()},
 Some("peer_files_read")=>{let Some(p)=w.peer.as_ref()else{return error("no_active_peer")};p.state.files.lock().unwrap().read_chunk()},
 Some("peer_close")=>close(&mut w),_=>error("invalid_peer_operation")}
}
