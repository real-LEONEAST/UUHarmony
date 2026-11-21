//! Codec-specific Annex B parameter-set and random-access admission.
#[derive(Default)]
pub struct NalPolicy {
    vps: Vec<u8>, sps: Vec<u8>, pps: Vec<u8>, suppress_rasl: bool,
}
pub struct Picture { pub data: Vec<u8>, pub types: Vec<u8>, pub key: bool, pub ready: bool }
pub fn codec_matches(expected: u32, actual: u32) -> bool { [1, 2].contains(&expected) && expected == actual }
pub fn is_unsupported_hevc_profile(error:&str)->bool { error == "hevc_profile_not_main" }
pub fn hevc_fmtp(level: u32) -> Option<String> {
    [120, 150, 153, 180, 183, 186].contains(&level).then(|| format!("profile-id=1;tier-flag=0;level-id={level}"))
}
pub fn fits_native_input(size: usize) -> bool { size > 0 && size <= 1024 * 1024 }
pub fn rtp_delta(codec: u32, previous: u32, current: u32) -> Option<i64> {
    let delta = current.wrapping_sub(previous) as i32;
    if delta.unsigned_abs() > 90000 * 5 || (codec == 1 && delta < 0) { None } else { Some(i64::from(delta)) }
}
pub fn mime_matches(codec: u32, mime: &str) -> bool {
    match codec { 1 => mime.eq_ignore_ascii_case("video/H264"), 2 => mime.eq_ignore_ascii_case("video/H265"), _ => false }
}
fn nals(data: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new(); let mut i = 0;
    while i + 4 < data.len() {
        if data[i..].starts_with(&[0, 0, 0, 1]) { starts.push(i); i += 4; } else { i += 1; }
    }
    starts.iter().enumerate().map(|(n, &s)| &data[s..starts.get(n + 1).copied().unwrap_or(data.len())]).collect()
}
impl NalPolicy {
    pub fn picture(&mut self, data: &[u8], codec: u32) -> Result<Option<Picture>, &'static str> {
        if ![1, 2].contains(&codec) { return Err("invalid_video_codec"); }
        let ns = nals(data);
        if ns.is_empty() || ns.iter().any(|n| n.len() < if codec == 2 { 6 } else { 5 }) {
            return Err("invalid_annexb_nal");
        }
        let types: Vec<u8> = ns.iter().map(|n| if codec == 2 { (n[4] >> 1) & 63 } else { n[4] & 31 }).collect();
        for (n, &kind) in ns.iter().zip(&types) {
            if n.len() >= 65536 { continue; }
            // HEVC SPS begins with a two-byte NAL header, one byte of SPS
            // identifiers, then general_profile_space/tier/profile_idc.
            // This session advertises Main only; do not silently admit Main10.
            if codec == 2 && kind == 33 && (n.len() < 8 || n[7] & 31 != 1) {
                return Err("hevc_profile_not_main");
            }
            match (codec, kind) {
                (2, 32) => self.vps = n.to_vec(), (2, 33) | (1, 7) => self.sps = n.to_vec(),
                (2, 34) | (1, 8) => self.pps = n.to_vec(), _ => (),
            }
        }
        let has_vcl = types.iter().any(|&t| if codec == 2 { t <= 31 } else { t == 1 || t == 5 });
        if !has_vcl {
            return if types.iter().any(|&t| if codec == 2 { (32..=40).contains(&t) } else { t == 7 || t == 8 }) { Ok(None) } else { Err("AU has no VCL") };
        }
        if codec == 2 && self.suppress_rasl {
            if types.iter().any(|&t| t == 8 || t == 9) { return Ok(None); }
            // RADL leading pictures may precede RASL pictures in decode order.
            // End suppression only at a trailing picture or the next IRAP.
            if types.iter().any(|&t| t <= 5 || (16..=21).contains(&t)) { self.suppress_rasl = false; }
        }
        let key = types.iter().any(|&t| if codec == 2 { (16..=21).contains(&t) } else { t == 5 });
        if codec == 2 && types.iter().any(|t| (16..=21).contains(t)) { self.suppress_rasl = true; }
        let ready = key && !self.sps.is_empty() && !self.pps.is_empty() && (codec != 2 || !self.vps.is_empty());
        let mut normalized = Vec::new();
        if key {
            if codec == 2 && !types.contains(&32) { normalized.extend_from_slice(&self.vps); }
            if !types.contains(&(if codec == 2 { 33 } else { 7 })) { normalized.extend_from_slice(&self.sps); }
            if !types.contains(&(if codec == 2 { 34 } else { 8 })) { normalized.extend_from_slice(&self.pps); }
        }
        normalized.extend_from_slice(data);
        Ok(Some(Picture { data: normalized, types, key, ready }))
    }
}
#[cfg(test)] mod tests {
    use super::*;
    fn h265(kind: u8) -> Vec<u8> { vec![0, 0, 0, 1, kind << 1, 1, 0x80, 1] }
    #[test] fn unsupported_hevc_profile_has_a_fixed_diagnostic_class() {
        let mut p=NalPolicy::default();let mut sps=h265(33);sps[7]=2;
        let error=p.picture(&sps,2).err().unwrap();
        assert!(is_unsupported_hevc_profile(error));
        assert!(!is_unsupported_hevc_profile("invalid_annexb_nal"));
    }
    #[test] fn hevc_parameter_sets_irap_and_cra_rasl_are_scoped() {
        let mut p = NalPolicy::default();
        for t in [32,33,34] { assert!(p.picture(&h265(t),2).unwrap().is_none()); }
        assert!(p.picture(&h265(39),2).unwrap().is_none());
        let cra=p.picture(&h265(21),2).unwrap().unwrap(); assert!(cra.ready && cra.key);
        assert_eq!(nals(&cra.data).iter().map(|n|(n[4]>>1)&63).collect::<Vec<_>>(),vec![32,33,34,21]);
        assert!(p.picture(&h265(6),2).unwrap().is_some()); assert!(p.picture(&h265(7),2).unwrap().is_some());
        assert!(p.picture(&h265(8),2).unwrap().is_none()); assert!(p.picture(&h265(9),2).unwrap().is_none());
        assert!(p.picture(&h265(1),2).unwrap().is_some()); assert!(p.picture(&h265(8),2).unwrap().is_some());
        assert!(p.picture(&h265(16),2).unwrap().unwrap().key);assert!(p.picture(&h265(8),2).unwrap().is_none());
        let fresh=NalPolicy::default().picture(&h265(19),2).unwrap().unwrap();assert!(!fresh.ready);
        p=NalPolicy::default();let after_loss=p.picture(&h265(19),2).unwrap().unwrap();assert!(!after_loss.ready);
        let mut main10=h265(33);main10[7]=2;assert!(p.picture(&main10,2).is_err());
    }
    #[test] fn avc_remains_scoped_and_does_not_accept_hevc_headers() {
        let mut p=NalPolicy::default();
        for t in [7,8] { let n=vec![0,0,0,1,t,0x80];assert!(p.picture(&n,1).unwrap().is_none()); }
        let idr=vec![0,0,0,1,5,0x80];assert!(p.picture(&idr,1).unwrap().unwrap().ready);
        assert!(NalPolicy::default().picture(&h265(19),1).is_err());
    }
    #[test] fn mismatched_codec_and_mime_are_rejected() {
        assert!(codec_matches(1,1)); assert!(codec_matches(2,2));
        assert!(!codec_matches(1,2)); assert!(!codec_matches(2,1)); assert!(!codec_matches(0,0));
        assert!(mime_matches(2,"video/H265")); assert!(!mime_matches(2,"video/H264"));
        assert!(mime_matches(1,"video/H264")); assert!(!mime_matches(1,"video/H265"));
        assert_eq!(hevc_fmtp(180).as_deref(),Some("profile-id=1;tier-flag=0;level-id=180"));
        assert!(hevc_fmtp(0).is_none()); assert!(hevc_fmtp(60).is_none());
    }
    #[test] fn normalized_unit_includes_parameter_sets_in_native_limit() {
        let mut p=NalPolicy::default();
        for t in [32,33,34] { p.picture(&h265(t),2).unwrap(); }
        let mut idr=h265(19);idr.resize(1024*1024,0x55);
        let picture=p.picture(&idr,2).unwrap().unwrap();
        assert!(fits_native_input(idr.len()));
        assert!(!fits_native_input(picture.data.len()));
        assert!(!fits_native_input(0));
    }
    #[test] fn malformed_start_codes_return_error_without_indexing_empty_nals() {
        let bad=[0,0,0,1,0,0,0,1,0x26,1];
        assert!(NalPolicy::default().picture(&bad,2).is_err());
        assert!(NalPolicy::default().picture(&[0,0,0,1,0x26],2).is_err());
        assert!(NalPolicy::default().picture(&[0,0,0,1,5],99).is_err());
    }
    #[test] fn hevc_accepts_bounded_presentation_reordering_and_wrap() {
        assert_eq!(rtp_delta(2, 100_000, 97_000), Some(-3_000));
        assert_eq!(rtp_delta(2, u32::MAX - 9, 10), Some(20));
        assert_eq!(rtp_delta(1, 100_000, 97_000), None);
        assert_eq!(rtp_delta(2, 1_000_000, 1), None);
    }
}
