use serde::Serialize;
use webrtc::dtls_transport::dtls_transport_state::RTCDtlsTransportState;
use webrtc::ice::url::ProtoType;
use webrtc::ice_transport::{
    ice_candidate_type::RTCIceCandidateType as Candidate,
    ice_protocol::RTCIceProtocol as Protocol, ice_transport_state::RTCIceTransportState,
};
use webrtc::peer_connection::RTCPeerConnection;

#[derive(Debug, PartialEq, Eq, Serialize)]
pub(crate) struct ConnectionInfo {
    method: Option<&'static str>,
    protocol: Option<&'static str>,
}

fn classify(
    local: Candidate,
    remote: Candidate,
    local_protocol: Protocol,
    remote_protocol: Protocol,
    local_turn: Option<ProtoType>,
) -> ConnectionInfo {
    use Candidate::{Host, Prflx, Relay, Srflx};

    let direct = matches!(local, Host | Srflx | Prflx) && matches!(remote, Host | Srflx);
    let method = if local == Relay || remote == Relay {
        Some("relay")
    } else if direct {
        Some("direct")
    } else {
        None
    };
    // TURN candidates describe the advertised relay address. The transport of
    // this agent's allocation can differ. A remote allocation does not expose it.
    let protocol = if local == Relay {
        match local_turn {
            Some(ProtoType::Udp) => Some("udp"),
            Some(ProtoType::Tcp) => Some("tcp"),
            _ => None,
        }
    } else if direct && local_protocol == remote_protocol {
        match local_protocol {
            Protocol::Udp => Some("udp"),
            Protocol::Tcp => Some("tcp"),
            Protocol::Unspecified => None,
        }
    } else {
        None
    };
    ConnectionInfo { method, protocol }
}

pub(crate) async fn selected_connection(pc: &RTCPeerConnection) -> Option<ConnectionInfo> {
    // This peer's RTP and SCTP share the same ICE/DTLS transport.
    let dtls = pc.dtls_transport();
    let ice = dtls.ice_transport();
    let active = || {
        dtls.state() == RTCDtlsTransportState::Connected
            && matches!(ice.state(), RTCIceTransportState::Connected | RTCIceTransportState::Completed)
    };
    if !active() {
        return None;
    }
    let (pair, local_turn) = ice.get_selected_candidate_route().await?;
    if !active() {
        return None;
    }
    let (local, remote) = pair.candidates();
    Some(classify(local.typ, remote.typ, local.protocol, remote.protocol, local_turn))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidate_type_and_socket_transport_are_independent() {
        use Candidate::{Host, Prflx, Relay, Srflx, Unspecified};
        use Protocol::{Tcp, Udp};
        let cases = [
            (Host, Srflx, Udp, Udp, None, Some("direct"), Some("udp")),
            (Host, Host, Tcp, Tcp, None, Some("direct"), Some("tcp")),
            (Host, Host, Tcp, Udp, None, Some("direct"), None),
            (Relay, Host, Udp, Udp, Some(ProtoType::Tcp), Some("relay"), Some("tcp")),
            (Relay, Unspecified, Udp, Udp, Some(ProtoType::Udp), Some("relay"), Some("udp")),
            (Relay, Host, Udp, Udp, None, Some("relay"), None),
            (Host, Relay, Udp, Udp, None, Some("relay"), None),
            (Host, Prflx, Udp, Udp, None, None, None),
            (Host, Unspecified, Udp, Udp, None, None, None),
        ];
        for (local, remote, a, b, turn, method, protocol) in cases {
            assert_eq!(classify(local, remote, a, b, turn), ConnectionInfo { method, protocol });
        }
    }
}
