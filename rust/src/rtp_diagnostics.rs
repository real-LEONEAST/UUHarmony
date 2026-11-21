//! Numeric-only summary of negotiated video extensions and H.264 fmtp.
use serde_json::{json, Value};
pub fn answer_summary(sdp: &str) -> Value {
    let mut sections: Vec<Vec<&str>> = Vec::new();
    let mut video = false;
    for line in sdp.lines().map(str::trim) {
        if line.starts_with("m=") {
            video = line.starts_with("m=video ");
            if video && sections.len() < 2 { sections.push(Vec::new()); }
            else if video { video = false; }
        } else if video {
            if let Some(section) = sections.last_mut() { section.push(line); }
        }
    }
    let sections: Vec<Value> = sections.iter().map(|lines| {
        let has = |uri:&str| lines.iter().any(|l| {
            let mut parts=l.split_whitespace();
            parts.next().is_some_and(|head|head.starts_with("a=extmap:")&&!head.ends_with("/inactive")) && parts.next()==Some(uri)
        });
        let payload = lines.iter().find_map(|l| {
            let rest=l.strip_prefix("a=rtpmap:")?; let (pt, codec)=rest.split_once(' ')?;
            codec.to_ascii_lowercase().starts_with("h264/90000").then(|| pt.parse::<u8>().ok().filter(|v|*v<=127)).flatten()
        });
        let profile = payload.and_then(|pt| lines.iter().find_map(|l| {
            let rest=l.strip_prefix("a=fmtp:")?; let (id,params)=rest.split_once(' ')?;
            if id.parse::<u8>().ok()!=Some(pt) { return None; }
            params.split(';').find_map(|item| {
                let (key,value)=item.trim().split_once('=')?;
                if key.trim().eq_ignore_ascii_case("profile-level-id") && value.trim().len()==6 {
                    u32::from_str_radix(value.trim(),16).ok()
                } else { None }
            })
        }));
        json!({"midExtension":has("urn:ietf:params:rtp-hdrext:sdes:mid"),
            "ridExtension":has("urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id"),
            "repairedRidExtension":has("urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id"),
            "h264PayloadType":payload,"h264ProfileIdc":profile.map(|v|(v>>16)&255),
            "h264Constraints":profile.map(|v|(v>>8)&255),"h264LevelIdc":profile.map(|v|v&255)})
    }).collect();
    json!({"videoSections":sections})
}
#[cfg(test)]mod tests {use super::*;#[test]fn summary_keeps_only_numeric_and_boolean_metadata(){let s="m=video 9 RTP/AVP 102\r\na=mid:private\r\na=rtpmap:102 H264/90000\r\na=fmtp:102 profile-level-id=42e01f;packetization-mode=1\r\na=extmap:1 urn:ietf:params:rtp-hdrext:sdes:mid\r\na=candidate:private\r\n";let v=answer_summary(s);assert_eq!(v["videoSections"][0]["midExtension"],true);assert_eq!(v["videoSections"][0]["ridExtension"],false);assert_eq!(v["videoSections"][0]["h264LevelIdc"],31);assert!(!v.to_string().contains("private"));}
 #[test]fn sections_missing_codec_or_inactive_extension_stay_unknown(){let s="m=video 9 RTP/AVP 102\r\na=rtpmap:102 H264/90000\r\na=fmtp:102 profile-level-id=42e032\r\na=extmap:3/inactive urn:ietf:params:rtp-hdrext:sdes:mid\r\nm=video 9 RTP/AVP 96\r\na=rtpmap:96 H265/90000\r\n";let v=answer_summary(s);assert_eq!(v["videoSections"].as_array().unwrap().len(),2);assert_eq!(v["videoSections"][0]["midExtension"],false);assert_eq!(v["videoSections"][0]["h264LevelIdc"],50);assert!(v["videoSections"][1]["h264PayloadType"].is_null());assert!(v["videoSections"][1]["h264LevelIdc"].is_null());}}
