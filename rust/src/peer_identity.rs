// Process-local diagnostic only. These digests never authorize credential delivery.
use sha2::{Digest, Sha256};
use std::sync::{Mutex, OnceLock};

#[derive(Clone, Copy)]
pub(super) struct Status { pub leaf: &'static str, pub spki: &'static str }
impl Status { pub const UNAVAILABLE: Self = Self { leaf: "unavailable", spki: "unavailable" }; }
struct Previous { scope: String, leaf: [u8;32], spki: [u8;32] }
static PREVIOUS: OnceLock<Mutex<Option<Previous>>> = OnceLock::new();

pub(super) fn observe(scope: &str, der: &[u8]) -> Status {
    if scope.is_empty() || der.is_empty() { return Status::UNAVAILABLE; }
    let Ok((remaining, cert)) = x509_parser::parse_x509_certificate(der) else { return Status::UNAVAILABLE; };
    if !remaining.is_empty() || cert.tbs_certificate.subject_pki.raw.is_empty() { return Status::UNAVAILABLE; }
    let leaf: [u8;32] = Sha256::digest(der).into();
    // Hash full DER SubjectPublicKeyInfo, including algorithm and parameters.
    let spki: [u8;32] = Sha256::digest(cert.tbs_certificate.subject_pki.raw).into();
    let Ok(mut previous) = PREVIOUS.get_or_init(|| Mutex::new(None)).lock() else { return Status::UNAVAILABLE; };
    let result = compare(previous.as_ref(), scope, &leaf, &spki);
    *previous = Some(Previous { scope: scope.to_owned(), leaf, spki });
    result
}
fn compare(previous: Option<&Previous>, scope: &str, leaf: &[u8;32], spki: &[u8;32]) -> Status {
    match previous.filter(|p| p.scope == scope) {
        Some(p) => Status { leaf: if p.leaf == *leaf { "same" } else { "changed" }, spki: if p.spki == *spki { "same" } else { "changed" } },
        None => Status { leaf: "first", spki: "first" },
    }
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn comparison_is_scoped_and_distinguishes_reissue_from_rekey() {
        let p = Previous { scope: "owned-device".into(), leaf: [1;32], spki: [2;32] };
        assert_eq!(compare(None,"owned-device",&[1;32],&[2;32]).leaf,"first");
        assert_eq!(compare(Some(&p),"other-device",&[1;32],&[2;32]).spki,"first");
        let same = compare(Some(&p),"owned-device",&[1;32],&[2;32]);
        assert_eq!((same.leaf,same.spki),("same","same"));
        let renewal = compare(Some(&p),"owned-device",&[3;32],&[2;32]);
        assert_eq!((renewal.leaf,renewal.spki),("changed","same"));
        assert_eq!(compare(Some(&p),"owned-device",&[3;32],&[4;32]).spki,"changed");
    }
    #[test] fn malformed_certificate_cannot_update_history() {
        assert_eq!(observe("",b"invalid").leaf,"unavailable");
        assert_eq!(observe("owned-device",b"invalid").spki,"unavailable");
    }
}
