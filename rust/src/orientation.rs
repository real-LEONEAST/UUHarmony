//! Resolve CVO in assembled access-unit order, within one display epoch.
use std::collections::VecDeque;

pub const CVO_URI: &str = "urn:3gpp:video-orientation";
const MAX_FRAMES: usize = 64;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Orientation { pub turns: u8, pub flipped: bool }
impl Orientation {
    pub fn parse(bytes: &[u8]) -> Result<Self, &'static str> {
        if bytes.len()!=1 || bytes[0]&0xf0!=0 { return Err("invalid_cvo"); }
        Ok(Self { turns: bytes[0]&3, flipped: bytes[0]&4!=0 })
    }
    pub fn packed(self) -> u32 { u32::from(self.turns) | if self.flipped {4} else {0} }
}
#[derive(Default)]
struct Frame { ts:u32, orientation:Option<Orientation>, invalid:bool }
#[derive(Default)]
pub struct Frames { enabled:bool, frames:VecDeque<Frame>, retired:VecDeque<u32>, current:Orientation }
impl Frames {
    pub fn set_enabled(&mut self, enabled:bool) {
        if self.enabled!=enabled { self.frames.clear();self.retired.clear();self.current=Orientation::default();self.enabled=enabled; }
    }
    pub fn note(&mut self, ts:u32, extension:Option<&[u8]>) {
        if !self.enabled || self.retired.contains(&ts) { return; }
        let parsed=extension.map(Orientation::parse);
        let i=match self.frames.iter().position(|f|f.ts==ts) {Some(i)=>i,None=>{
            if self.frames.len()==MAX_FRAMES { self.frames.pop_front(); }
            self.frames.push_back(Frame {ts,..Frame::default()});self.frames.len()-1
        }};
        let f=&mut self.frames[i];
        match parsed {
            Some(Ok(value))=>{if f.orientation.is_some_and(|old|old!=value){f.invalid=true;}else{f.orientation=Some(value);}},
            Some(Err(_))=>f.invalid=true,
            None=>(),
        }
    }
    pub fn take(&mut self, ts:u32) -> Result<Orientation, &'static str> {
        if !self.enabled { return Ok(Orientation::default()); }
        if self.retired.contains(&ts) { return Err("retired_cvo_frame"); }
        let frame=self.frames.iter().position(|f|f.ts==ts).and_then(|i|self.frames.remove(i));
        if self.retired.len()==MAX_FRAMES*2 { self.retired.pop_front(); }
        self.retired.push_back(ts);
        if let Some(frame)=frame {
            if frame.invalid { return Err("conflicting_cvo"); }
            if let Some(value)=frame.orientation { self.current=value; }
        }
        Ok(self.current)
    }
}

/// Inspect only accepted video payload mappings. Rejected/malformed sections do
/// not turn transport or authentication failures into a codec fallback.
pub fn answer_accepts_hevc(sdp:&str)->Option<bool> {
    if sdp.len()>1024*1024{return None;}
    let mut video=false;let mut active=false;let mut seen=false;let mut accepted=false;let mut payloads=Vec::<u8>::new();
    for line in sdp.lines().map(str::trim) {
        if line.starts_with("m=") {
            video=line.starts_with("m=video ");active=false;payloads.clear();
            if video {seen=true;let parts:Vec<_>=line.split_whitespace().collect();if parts.len()<4{return None;}let port=parts[1].split('/').next()?.parse::<u16>().ok()?;active=port!=0;for s in &parts[3..]{payloads.push(s.parse::<u8>().ok().filter(|v|*v<=127)?);}}
        } else if video&&active {
            if let Some(rest)=line.strip_prefix("a=rtpmap:") {let (id,codec)=rest.split_once(' ')?;let id=id.parse::<u8>().ok()?;if payloads.contains(&id)&&codec.eq_ignore_ascii_case("H265/90000"){accepted=true;}}
        }
    }
    seen.then_some(accepted)
}

#[cfg(test)]mod tests {
    use super::*;
    #[test]fn all_rotations_flip_and_camera_bit(){for b in 0..16 {let o=Orientation::parse(&[b]).unwrap();assert_eq!(o.turns,b&3);assert_eq!(o.flipped,b&4!=0);assert_eq!(o.packed(),u32::from(b&7));}assert!(Orientation::parse(&[]).is_err());assert!(Orientation::parse(&[0x10]).is_err());assert!(Orientation::parse(&[1,2]).is_err());}
    #[test]fn marker_packet_metadata_and_reordered_access_units(){let mut f=Frames::default();f.set_enabled(true);f.note(100,None);f.note(200,Some(&[3]));f.note(100,Some(&[1]));assert_eq!(f.take(200).unwrap().turns,3);assert_eq!(f.take(100).unwrap().turns,1);f.note(100,Some(&[0]));assert!(f.take(100).is_err());}
    #[test]fn sparse_cvo_inherits_last_valid_orientation(){
        let mut f=Frames::default();
        f.set_enabled(true);
        assert_eq!(f.take(0),Ok(Orientation::default()));
        f.note(3,Some(&[2])); // Arrived early, but only takes effect on frame 3.
        f.note(1,Some(&[1]));
        assert_eq!(f.take(1).unwrap().turns,1);
        f.note(2,None);
        assert_eq!(f.take(2).unwrap().turns,1);
        assert_eq!(f.take(3).unwrap().turns,2);
        f.note(4,Some(&[1]));f.note(4,Some(&[2]));
        assert_eq!(f.take(4),Err("conflicting_cvo"));
        f.note(5,Some(&[16]));assert!(f.take(5).is_err());
        assert_eq!(f.take(6).unwrap().turns,2);
    }
    #[test]fn bounded_and_fresh_epoch(){let mut f=Frames::default();f.set_enabled(true);for ts in 0..1000{f.note(ts,Some(&[1]));}assert_eq!(f.frames.len(),MAX_FRAMES);assert_eq!(f.take(0),Ok(Orientation::default()));assert_eq!(f.take(999).unwrap().turns,1);let mut fresh=Frames::default();fresh.set_enabled(true);assert_eq!(fresh.take(999),Ok(Orientation::default()));fresh.set_enabled(false);assert_eq!(fresh.take(999).unwrap(),Orientation::default());}
    #[test]fn remote_hevc_rejection_is_distinct_from_unknown_answer(){assert_eq!(answer_accepts_hevc("m=video 9 RTP/AVP 96\r\na=rtpmap:96 H265/90000\r\n"),Some(true));assert_eq!(answer_accepts_hevc("m=video 0 RTP/AVP 96\r\na=rtpmap:96 H265/90000\r\n"),Some(false));assert_eq!(answer_accepts_hevc("m=video 9 RTP/AVP 102\r\na=rtpmap:102 H264/90000\r\n"),Some(false));assert_eq!(answer_accepts_hevc("m=video bad RTP/AVP 96"),None);assert_eq!(answer_accepts_hevc("v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel"),None);assert_eq!(answer_accepts_hevc("m=video 9 RTP/AVP 102\r\na=rtpmap:96 H265/90000\r\n"),Some(false));}
}
