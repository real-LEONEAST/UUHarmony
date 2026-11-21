#[cfg(test)]
mod session_rtcp_test;
#[cfg(test)]
mod session_rtp_test;

use std::collections::{HashMap, HashSet};
use std::marker::{Send, Sync};
use std::sync::Arc;
#[cfg(feature = "rtp-diagnostics")]
use std::sync::atomic::{AtomicU64, Ordering};

use bytes::Bytes;
use tokio::sync::{mpsc, Mutex};
use util::conn::Conn;
use util::marshal::*;

use crate::config::*;
use crate::context::*;
use crate::error::{Error, Result};
use crate::option::*;
use crate::stream::*;

const DEFAULT_SESSION_SRTP_REPLAY_PROTECTION_WINDOW: usize = 64;
const DEFAULT_SESSION_SRTCP_REPLAY_PROTECTION_WINDOW: usize = 64;

#[cfg(feature = "rtp-diagnostics")]
pub struct RtpDiagnostics {
    raw_packets: AtomicU64,
    raw_bytes: AtomicU64,
    auth_rejected: AtomicU64,
    replay_rejected: AtomicU64,
    other_rejected: AtomicU64,
    raw_packets_by_type: [AtomicU64; 128],
    raw_bytes_by_type: [AtomicU64; 128],
    auth_rejected_by_type: [AtomicU64; 128],
    replay_rejected_by_type: [AtomicU64; 128],
    other_rejected_by_type: [AtomicU64; 128],
    packets: AtomicU64,
    nonempty: AtomicU64,
    payload_bytes: AtomicU64,
    padding_only: AtomicU64,
    invalid_padding: AtomicU64,
    payload_packets_by_type: [AtomicU64; 128],
    payload_bytes_by_type: [AtomicU64; 128],
}
#[cfg(feature = "rtp-diagnostics")]
impl Default for RtpDiagnostics {
    fn default() -> Self {
        Self { raw_packets: AtomicU64::new(0), raw_bytes: AtomicU64::new(0), auth_rejected: AtomicU64::new(0), replay_rejected: AtomicU64::new(0), other_rejected: AtomicU64::new(0), packets: AtomicU64::new(0), nonempty: AtomicU64::new(0), payload_bytes: AtomicU64::new(0), padding_only: AtomicU64::new(0), invalid_padding: AtomicU64::new(0),
            raw_packets_by_type: std::array::from_fn(|_| AtomicU64::new(0)),
            raw_bytes_by_type: std::array::from_fn(|_| AtomicU64::new(0)),
            auth_rejected_by_type: std::array::from_fn(|_| AtomicU64::new(0)),
            replay_rejected_by_type: std::array::from_fn(|_| AtomicU64::new(0)),
            other_rejected_by_type: std::array::from_fn(|_| AtomicU64::new(0)),
            payload_packets_by_type: std::array::from_fn(|_| AtomicU64::new(0)),
            payload_bytes_by_type: std::array::from_fn(|_| AtomicU64::new(0)) }
    }
}
#[cfg(feature = "rtp-diagnostics")]
impl RtpDiagnostics {
    // This PT is taken before authentication and cannot establish packet identity.
    fn claimed_type(packet: &[u8]) -> Option<usize> {
        (packet.len() >= 12 && packet[0] >> 6 == 2).then(|| usize::from(packet[1] & 0x7f))
    }
    fn raw(&self, packet: &[u8]) {
        self.raw_packets.fetch_add(1, Ordering::Relaxed);
        self.raw_bytes.fetch_add(packet.len() as u64, Ordering::Relaxed);
        if let Some(i)=Self::claimed_type(packet) {
            self.raw_packets_by_type[i].fetch_add(1, Ordering::Relaxed);
            self.raw_bytes_by_type[i].fetch_add(packet.len() as u64, Ordering::Relaxed);
        }
    }
    fn reject(&self, packet: &[u8], error: &Error) {
        let (total, selected) = match error {
            Error::RtpFailedToVerifyAuthTag | Error::ErrFailedToVerifyAuthTag | Error::AesGcm(_) => (&self.auth_rejected, &self.auth_rejected_by_type),
            Error::SrtpSsrcDuplicated(_, _) => (&self.replay_rejected, &self.replay_rejected_by_type),
            _ => (&self.other_rejected, &self.other_rejected_by_type),
        };
        total.fetch_add(1, Ordering::Relaxed);
        if let Some(i)=Self::claimed_type(packet) { selected[i].fetch_add(1, Ordering::Relaxed); }
    }
    pub fn snapshot(&self, payload_type: u8) -> [u64; 17] {
        let i = usize::from(payload_type.min(127));
        [self.packets.load(Ordering::Relaxed), self.nonempty.load(Ordering::Relaxed),
         self.payload_bytes.load(Ordering::Relaxed), self.padding_only.load(Ordering::Relaxed),
         self.payload_packets_by_type[i].load(Ordering::Relaxed), self.payload_bytes_by_type[i].load(Ordering::Relaxed),
         self.invalid_padding.load(Ordering::Relaxed), self.raw_packets.load(Ordering::Relaxed), self.raw_bytes.load(Ordering::Relaxed), self.auth_rejected.load(Ordering::Relaxed), self.replay_rejected.load(Ordering::Relaxed), self.other_rejected.load(Ordering::Relaxed), self.raw_packets_by_type[i].load(Ordering::Relaxed), self.raw_bytes_by_type[i].load(Ordering::Relaxed), self.auth_rejected_by_type[i].load(Ordering::Relaxed), self.replay_rejected_by_type[i].load(Ordering::Relaxed), self.other_rejected_by_type[i].load(Ordering::Relaxed)]
    }
}

#[cfg(all(test, feature = "rtp-diagnostics"))]
mod diagnostic_tests {
    use super::*;
    #[test]
    fn counts_raw_datagrams_and_error_classes_without_identifiers() {
        let d=RtpDiagnostics::default();
        let mut video=vec![0x80,96];video.resize(100,0);
        let mut audio=vec![0x80,111];audio.resize(60,0);
        let invalid=[0x40,96];
        d.raw(&video);d.raw(&audio);d.raw(&invalid);
        d.reject(&video,&Error::RtpFailedToVerifyAuthTag);
        d.reject(&audio,&Error::ErrFailedToVerifyAuthTag);
        d.reject(&video,&Error::SrtpSsrcDuplicated(123,456));
        d.reject(&invalid,&Error::SrtpTooSmall(2,12));
        let s=d.snapshot(96);
        assert_eq!(&s[7..12],&[3,162,2,1,1]);
        assert_eq!(&s[12..17],&[1,100,1,1,0]);
        assert_eq!(&s[..7],&[0;7]);
    }
}
/// Session implements io.ReadWriteCloser and provides a bi-directional SRTP session
/// SRTP itself does not have a design like this, but it is common in most applications
/// for local/remote to each have their own keying material. This provides those patterns
/// instead of making everyone re-implement
pub struct Session {
    local_context: Arc<Mutex<Context>>,
    streams_map: Arc<Mutex<HashMap<u32, Arc<Stream>>>>,
    new_stream_rx: Arc<Mutex<mpsc::Receiver<Arc<Stream>>>>,
    close_stream_tx: mpsc::Sender<u32>,
    close_session_tx: mpsc::Sender<()>,
    pub(crate) udp_tx: Arc<dyn Conn + Send + Sync>,
    is_rtp: bool,
    #[cfg(feature = "rtp-diagnostics")]
    diagnostics: Arc<RtpDiagnostics>,
}

impl Session {
    pub async fn new(
        conn: Arc<dyn Conn + Send + Sync>,
        config: Config,
        is_rtp: bool,
    ) -> Result<Self> {
        let local_context = Context::new(
            &config.keys.local_master_key,
            &config.keys.local_master_salt,
            config.profile,
            config.local_rtp_options,
            config.local_rtcp_options,
        )?;

        let mut remote_context = Context::new(
            &config.keys.remote_master_key,
            &config.keys.remote_master_salt,
            config.profile,
            if config.remote_rtp_options.is_none() {
                Some(srtp_replay_protection(
                    DEFAULT_SESSION_SRTP_REPLAY_PROTECTION_WINDOW,
                ))
            } else {
                config.remote_rtp_options
            },
            if config.remote_rtcp_options.is_none() {
                Some(srtcp_replay_protection(
                    DEFAULT_SESSION_SRTCP_REPLAY_PROTECTION_WINDOW,
                ))
            } else {
                config.remote_rtcp_options
            },
        )?;

        let streams_map = Arc::new(Mutex::new(HashMap::new()));
        let (mut new_stream_tx, new_stream_rx) = mpsc::channel(8);
        let (close_stream_tx, mut close_stream_rx) = mpsc::channel(8);
        let (close_session_tx, mut close_session_rx) = mpsc::channel(8);
        let udp_tx = Arc::clone(&conn);
        let udp_rx = Arc::clone(&conn);
        let cloned_streams_map = Arc::clone(&streams_map);
        let cloned_close_stream_tx = close_stream_tx.clone();
        #[cfg(feature = "rtp-diagnostics")]
        let diagnostics = Arc::new(RtpDiagnostics::default());
        #[cfg(feature = "rtp-diagnostics")]
        let incoming_diagnostics = Arc::clone(&diagnostics);

        tokio::spawn(async move {
            let mut buf = vec![0u8; 8192];

            loop {
                let incoming_stream = Session::incoming(
                    &udp_rx,
                    &mut buf,
                    &cloned_streams_map,
                    &cloned_close_stream_tx,
                    &mut new_stream_tx,
                    &mut remote_context,
                    is_rtp,
                    #[cfg(feature = "rtp-diagnostics")]
                    &incoming_diagnostics,
                );
                let close_stream = close_stream_rx.recv();
                let close_session = close_session_rx.recv();

                tokio::select! {
                    result = incoming_stream => match result{
                        Ok(()) => {},
                        Err(err) => {
                            #[cfg(not(feature = "rtp-diagnostics"))]
                            log::info!("{}", err);
                            // RTP errors can contain SSRC or other sensitive values.
                            #[cfg(feature = "rtp-diagnostics")]
                            if !is_rtp { log::info!("{}", err); }
                        },
                    },
                    opt = close_stream => if let Some(ssrc) = opt {
                        Session::close_stream(&cloned_streams_map, ssrc).await
                    },
                    _ = close_session => break
                }
            }
        });

        Ok(Session {
            local_context: Arc::new(Mutex::new(local_context)),
            streams_map,
            new_stream_rx: Arc::new(Mutex::new(new_stream_rx)),
            close_stream_tx,
            close_session_tx,
            udp_tx,
            is_rtp,
            #[cfg(feature = "rtp-diagnostics")]
            diagnostics,
        })
    }

    async fn close_stream(streams_map: &Arc<Mutex<HashMap<u32, Arc<Stream>>>>, ssrc: u32) {
        let mut streams = streams_map.lock().await;
        streams.remove(&ssrc);
    }

    async fn incoming(
        udp_rx: &Arc<dyn Conn + Send + Sync>,
        buf: &mut [u8],
        streams_map: &Arc<Mutex<HashMap<u32, Arc<Stream>>>>,
        close_stream_tx: &mpsc::Sender<u32>,
        new_stream_tx: &mut mpsc::Sender<Arc<Stream>>,
        remote_context: &mut Context,
        is_rtp: bool,
        #[cfg(feature = "rtp-diagnostics")]
        diagnostics: &RtpDiagnostics,
    ) -> Result<()> {
        let n = udp_rx.recv(buf).await?;
        if n == 0 {
            return Err(Error::SessionEof);
        }

        #[cfg(feature = "rtp-diagnostics")]
        if is_rtp { diagnostics.raw(&buf[0..n]); }
        let decrypted = if is_rtp {
            let result = remote_context.decrypt_rtp(&buf[0..n]);
            #[cfg(feature = "rtp-diagnostics")]
            if let Err(ref error) = result { diagnostics.reject(&buf[0..n], error); }
            result?
        } else {
            remote_context.decrypt_rtcp(&buf[0..n])?
        };

        let mut buf = &decrypted[..];
        let ssrcs = if is_rtp {
            let header = rtp::header::Header::unmarshal(&mut buf)?;
            #[cfg(feature = "rtp-diagnostics")]
            {
                let padding = if header.padding { decrypted.last().copied().unwrap_or(0) as usize } else { 0 };
                diagnostics.packets.fetch_add(1, Ordering::Relaxed);
                let invalid_padding = header.padding && (padding == 0 || padding > buf.len());
                let length = buf.len().saturating_sub(padding);
                if invalid_padding { diagnostics.invalid_padding.fetch_add(1, Ordering::Relaxed); }
                else if length > 0 {
                    diagnostics.nonempty.fetch_add(1, Ordering::Relaxed);
                    diagnostics.payload_bytes.fetch_add(length as u64, Ordering::Relaxed);
                    diagnostics.payload_packets_by_type[usize::from(header.payload_type)].fetch_add(1, Ordering::Relaxed);
                    diagnostics.payload_bytes_by_type[usize::from(header.payload_type)].fetch_add(length as u64, Ordering::Relaxed);
                } else if header.padding { diagnostics.padding_only.fetch_add(1, Ordering::Relaxed); }
            }
            vec![header.ssrc]
        } else {
            let pkts = rtcp::packet::unmarshal(&mut buf)?;
            destination_ssrc(&pkts)
        };

        for ssrc in ssrcs {
            let (stream, is_new) =
                Session::get_or_create_stream(streams_map, close_stream_tx.clone(), is_rtp, ssrc)
                    .await;
            if is_new {
                log::trace!(
                    "srtp session got new {} stream {}",
                    if is_rtp { "rtp" } else { "rtcp" },
                    ssrc
                );
                new_stream_tx.send(Arc::clone(&stream)).await?;
            }

            match stream.buffer.write(&decrypted).await {
                Ok(_) => {}
                Err(err) => {
                    // Silently drop data when the buffer is full.
                    if util::Error::ErrBufferFull != err {
                        return Err(err.into());
                    }
                }
            }
        }

        Ok(())
    }

    async fn get_or_create_stream(
        streams_map: &Arc<Mutex<HashMap<u32, Arc<Stream>>>>,
        close_stream_tx: mpsc::Sender<u32>,
        is_rtp: bool,
        ssrc: u32,
    ) -> (Arc<Stream>, bool) {
        let mut streams = streams_map.lock().await;

        if let Some(stream) = streams.get(&ssrc) {
            (Arc::clone(stream), false)
        } else {
            let stream = Arc::new(Stream::new(ssrc, close_stream_tx, is_rtp));
            streams.insert(ssrc, Arc::clone(&stream));
            (stream, true)
        }
    }

    /// open on the given SSRC to create a stream, it can be used
    /// if you want a certain SSRC, but don't want to wait for Accept
    pub async fn open(&self, ssrc: u32) -> Arc<Stream> {
        let (stream, _) = Session::get_or_create_stream(
            &self.streams_map,
            self.close_stream_tx.clone(),
            self.is_rtp,
            ssrc,
        )
        .await;

        stream
    }

    /// accept returns a stream to handle RTCP for a single SSRC
    pub async fn accept(&self) -> Result<Arc<Stream>> {
        let mut new_stream_rx = self.new_stream_rx.lock().await;
        let result = new_stream_rx.recv().await;
        if let Some(stream) = result {
            Ok(stream)
        } else {
            Err(Error::SessionSrtpAlreadyClosed)
        }
    }
    #[cfg(feature = "rtp-diagnostics")]
    pub fn rtp_diagnostics(&self, payload_type: u8) -> [u64; 17] { self.diagnostics.snapshot(payload_type) }

    pub async fn close(&self) -> Result<()> {
        self.close_session_tx.send(()).await?;

        Ok(())
    }

    pub async fn write(&self, buf: &Bytes, is_rtp: bool) -> Result<usize> {
        if self.is_rtp != is_rtp {
            return Err(Error::SessionRtpRtcpTypeMismatch);
        }

        let encrypted = {
            let mut local_context = self.local_context.lock().await;

            if is_rtp {
                local_context.encrypt_rtp(buf)?
            } else {
                local_context.encrypt_rtcp(buf)?
            }
        };

        Ok(self.udp_tx.send(&encrypted).await?)
    }

    pub async fn write_rtp(&self, pkt: &rtp::packet::Packet) -> Result<usize> {
        let raw = pkt.marshal()?;
        self.write(&raw, true).await
    }

    pub async fn write_rtcp(
        &self,
        pkt: &(dyn rtcp::packet::Packet + Send + Sync),
    ) -> Result<usize> {
        let raw = pkt.marshal()?;
        self.write(&raw, false).await
    }
}

/// create a list of Destination SSRCs
/// that's a superset of all Destinations in the slice.
fn destination_ssrc(pkts: &[Box<dyn rtcp::packet::Packet + Send + Sync>]) -> Vec<u32> {
    let mut ssrc_set = HashSet::new();
    for p in pkts {
        for ssrc in p.destination_ssrc() {
            ssrc_set.insert(ssrc);
        }
    }
    ssrc_set.into_iter().collect()
}
