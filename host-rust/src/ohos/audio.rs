//! Opus system-playback packets from the consent-owned native screen capture.
use std::{sync::Arc,time::Duration};
use webrtc::{media::Sample,peer_connection::{RTCPeerConnection,peer_connection_state::RTCPeerConnectionState},track::track_local::track_local_static_sample::TrackLocalStaticSample};
extern "C" {fn uu_host_audio_enabled()->bool;fn uu_host_audio_poll(data:*mut u8,capacity:usize)->i32;}
pub fn enabled()->bool {unsafe{uu_host_audio_enabled()}}
pub async fn stream_audio(pc:Arc<RTCPeerConnection>,track:Arc<TrackLocalStaticSample>){
 let mut buffer=[0u8;4000];
 loop {
  if matches!(pc.connection_state(),RTCPeerConnectionState::Closed|RTCPeerConnectionState::Failed)||!enabled(){break;}
  if pc.connection_state()!=RTCPeerConnectionState::Connected{tokio::time::sleep(Duration::from_millis(20)).await;continue;}
  let size=unsafe{uu_host_audio_poll(buffer.as_mut_ptr(),buffer.len())};
  if size<0{break;}if size==0{tokio::time::sleep(Duration::from_millis(2)).await;continue;}
  if track.write_sample(&Sample{data:bytes::Bytes::copy_from_slice(&buffer[..size as usize]),duration:Duration::from_millis(20),..Default::default()}).await.is_err(){break;}
 }
}
pub async fn probe(_:u64)->Result<(),String>{Err("Desktop audio requires screen-capture consent".into())}
