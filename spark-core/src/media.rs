// Adapted from OMP crates/pi-voice/src/live.rs at ed7c05c288b12e69f6986d8b379eb2c33f55e914.
use bytes::Bytes;
use opus::{Application, Channels, Decoder, Encoder};
use parking_lot::Mutex;
use std::{
    collections::VecDeque,
    sync::{
        Arc, Weak,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{sync::watch, task::JoinHandle};
use webrtc::{
    api::{
        APIBuilder,
        interceptor_registry::register_default_interceptors,
        media_engine::{MIME_TYPE_OPUS, MediaEngine},
    },
    data_channel::RTCDataChannel,
    interceptor::registry::Registry,
    media::Sample,
    peer_connection::{
        RTCPeerConnection, configuration::RTCConfiguration,
        sdp::session_description::RTCSessionDescription,
    },
    rtp_transceiver::{
        rtp_codec::{RTCRtpCodecCapability, RTCRtpCodecParameters, RTPCodecType},
        rtp_sender::RTCRtpSender,
    },
    track::{
        track_local::{TrackLocal, track_local_static_sample::TrackLocalStaticSample},
        track_remote::TrackRemote,
    },
};

const INPUT_RATE: u32 = 16_000;
const INPUT_FRAME: usize = 320;
const MAX_INPUT: usize = 32_000;
const OUTPUT_RATE: u32 = 48_000;
const OUTPUT_FRAME: usize = 960;
const MAX_DECODED: usize = 5_760;
const MAX_OUTPUT: usize = 480_000;
const MAX_OPUS: usize = 1_275;
enum Input {
    Audio(u64, Vec<f32>),
    Mute(u64),
    Close,
}
struct Resources {
    peer: Arc<RTCPeerConnection>,
    data_channel: Arc<RTCDataChannel>,
    tx: flume::Sender<Input>,
    input: JoinHandle<()>,
    rtcp: JoinHandle<()>,
}

pub struct MediaPeer {
    resources: Mutex<Option<Resources>>,
    pending_peer: Mutex<Option<Arc<RTCPeerConnection>>>,
    output: Mutex<VecDeque<f32>>,
    queued: AtomicUsize,
    epoch: AtomicU64,
    muted: AtomicBool,
    closing: AtomicBool,
    open: watch::Sender<bool>,
    on_data: Arc<dyn Fn(String) + Send + Sync>,
    on_error: Arc<dyn Fn() + Send + Sync>,
    on_level: Arc<dyn Fn(f32) + Send + Sync>,
}
impl MediaPeer {
    pub fn new(
        on_data: Arc<dyn Fn(String) + Send + Sync>,
        on_error: Arc<dyn Fn() + Send + Sync>,
        on_level: Arc<dyn Fn(f32) + Send + Sync>,
    ) -> Arc<Self> {
        let (open, _) = watch::channel(false);
        Arc::new(Self {
            resources: Mutex::new(None),
            pending_peer: Mutex::new(None),
            output: Mutex::new(VecDeque::new()),
            queued: AtomicUsize::new(0),
            epoch: AtomicU64::new(0),
            muted: AtomicBool::new(false),
            closing: AtomicBool::new(false),
            open,
            on_data,
            on_error,
            on_level,
        })
    }
    pub async fn offer(self: &Arc<Self>) -> Result<String, String> {
        let mut me = MediaEngine::default();
        let cap = capability();
        me.register_codec(
            RTCRtpCodecParameters {
                capability: cap.clone(),
                payload_type: 111,
                ..Default::default()
            },
            RTPCodecType::Audio,
        )
        .map_err(|_| "media setup failed".to_owned())?;
        let registry = register_default_interceptors(Registry::new(), &mut me)
            .map_err(|_| "media setup failed".to_owned())?;
        let peer = Arc::new(
            APIBuilder::new()
                .with_media_engine(me)
                .with_interceptor_registry(registry)
                .build()
                .new_peer_connection(RTCConfiguration::default())
                .await
                .map_err(|_| "peer setup failed".to_owned())?,
        );
        *self.pending_peer.lock() = Some(peer.clone());
        let track = Arc::new(TrackLocalStaticSample::new(
            cap,
            "audio".into(),
            "spark-live".into(),
        ));
        let sender = peer
            .add_track(track.clone() as Arc<dyn TrackLocal + Send + Sync>)
            .await
            .map_err(|_| "audio track setup failed".to_owned())?;
        install_callbacks(&peer, Arc::downgrade(self));
        let dc = peer
            .create_data_channel("oai-events", None)
            .await
            .map_err(|_| "data channel setup failed".to_owned())?;
        let weak = Arc::downgrade(self);
        dc.on_open(Box::new(move || {
            let weak = weak.clone();
            Box::pin(async move {
                if let Some(p) = weak.upgrade() {
                    p.open.send_replace(true);
                }
            })
        }));
        let weak = Arc::downgrade(self);
        dc.on_message(Box::new(move |message| {
            let weak = weak.clone();
            Box::pin(async move {
                if message.is_string {
                    if let (Some(p), Ok(s)) =
                        (weak.upgrade(), String::from_utf8(message.data.to_vec()))
                    {
                        (p.on_data)(s)
                    }
                }
            })
        }));
        let offer = peer
            .create_offer(None)
            .await
            .map_err(|_| "offer creation failed".to_owned())?;
        peer.set_local_description(offer.clone())
            .await
            .map_err(|_| "offer setup failed".to_owned())?;
        let (tx, rx) = flume::unbounded();
        let input = tokio::spawn(run_input(track, rx, Arc::downgrade(self)));
        let rtcp = tokio::spawn(drain_rtcp(sender));
        *self.resources.lock() = Some(Resources {
            peer,
            data_channel: dc,
            tx,
            input,
            rtcp,
        });
        self.pending_peer.lock().take();
        Ok(offer.sdp)
    }
    pub async fn answer(&self, sdp: String) -> Result<(), String> {
        let p = self
            .resources
            .lock()
            .as_ref()
            .map(|r| r.peer.clone())
            .ok_or("peer is not started")?;
        let a = RTCSessionDescription::answer(sdp)
            .map_err(|_| "invalid signaling answer".to_owned())?;
        p.set_remote_description(a)
            .await
            .map_err(|_| "answer setup failed".to_owned())
    }
    pub async fn wait_open(&self) -> Result<(), String> {
        let mut rx = self.open.subscribe();
        let wait = async {
            loop {
                if *rx.borrow() {
                    return Ok(());
                }
                if self.closing.load(Ordering::Acquire) {
                    return Err("peer closed before opening".into());
                }
                rx.changed()
                    .await
                    .map_err(|_| "peer stopped before opening".to_owned())?
            }
        };
        tokio::time::timeout(Duration::from_secs(20), wait)
            .await
            .map_err(|_| "data channel open timed out".to_owned())?
    }
    pub fn push(&self, s: &[f32]) {
        if s.is_empty()
            || self.muted.load(Ordering::Acquire)
            || self.closing.load(Ordering::Acquire)
        {
            return;
        }
        let n = s.len().min(MAX_INPUT);
        if self.queued.fetch_add(n, Ordering::AcqRel) + n > MAX_INPUT {
            self.queued.fetch_sub(n, Ordering::AcqRel);
            return;
        }
        if let Some(tx) = self.resources.lock().as_ref().map(|r| r.tx.clone()) {
            let e = self.epoch.load(Ordering::Acquire);
            if tx.send(Input::Audio(e, s[s.len() - n..].to_vec())).is_err() {
                self.queued.fetch_sub(n, Ordering::AcqRel);
            }
        } else {
            self.queued.fetch_sub(n, Ordering::AcqRel);
        }
    }
    pub fn mute(&self, m: bool) {
        self.muted.store(m, Ordering::Release);
        let e = self.epoch.fetch_add(1, Ordering::AcqRel) + 1;
        if let Some(tx) = self.resources.lock().as_ref().map(|r| r.tx.clone()) {
            let _ = tx.send(Input::Mute(e));
        }
    }
    pub fn read(&self, out: &mut [f32]) -> usize {
        let mut q = self.output.lock();
        let n = out.len().min(q.len());
        for slot in &mut out[..n] {
            *slot = q.pop_front().unwrap()
        }
        n
    }
    pub async fn close(&self) {
        if self.closing.swap(true, Ordering::AcqRel) {
            return;
        }
        let resources = { self.resources.lock().take() };
        let pending = { self.pending_peer.lock().take() };
        if let Some(r) = resources {
            let _ = r.tx.send(Input::Close);
            let _ = tokio::time::timeout(Duration::from_secs(1), r.peer.close()).await;
            let _ = tokio::time::timeout(Duration::from_secs(1), r.input).await;
            r.rtcp.abort();
            drop(r.data_channel)
        } else if let Some(peer) = pending {
            let _ = tokio::time::timeout(Duration::from_secs(1), peer.close()).await;
        }
        self.open.send_replace(false);
        self.output.lock().clear();
        self.queued.store(0, Ordering::Release)
    }
    fn write_output(&self, s: &[f32]) {
        let retained = &s[s.len().saturating_sub(MAX_OUTPUT)..];
        let mut q = self.output.lock();
        let overflow = q
            .len()
            .saturating_add(retained.len())
            .saturating_sub(MAX_OUTPUT)
            .min(q.len());
        q.drain(..overflow);
        q.extend(retained.iter().copied())
    }
}
impl Drop for MediaPeer {
    fn drop(&mut self) {
        self.closing.store(true, Ordering::Release);
        if let Some(r) = self.resources.get_mut().take() {
            let _ = r.tx.send(Input::Close);
            r.input.abort();
            r.rtcp.abort();
            drop(r.data_channel);
            drop(r.peer)
        }
        self.pending_peer.get_mut().take();
    }
}
fn capability() -> RTCRtpCodecCapability {
    RTCRtpCodecCapability {
        mime_type: MIME_TYPE_OPUS.into(),
        clock_rate: OUTPUT_RATE,
        channels: 2,
        sdp_fmtp_line: "minptime=10;useinbandfec=1".into(),
        rtcp_feedback: vec![],
    }
}
fn install_callbacks(peer: &Arc<RTCPeerConnection>, weak: Weak<MediaPeer>) {
    let output = weak.clone();
    peer.on_track(Box::new(move |track, _, _| {
        let w = output.clone();
        Box::pin(async move {
            if track.kind() == RTPCodecType::Audio {
                tokio::spawn(receive(track, w));
            }
        })
    }));
    let fail = weak;
    peer.on_peer_connection_state_change(Box::new(move |state| {
        let w = fail.clone();
        Box::pin(async move {
            use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState::*;
            if matches!(state, Failed | Closed) {
                if let Some(p) = w.upgrade() {
                    if !p.closing.load(Ordering::Acquire) {
                        (p.on_error)()
                    }
                }
            }
        })
    }));
}
async fn run_input(
    track: Arc<TrackLocalStaticSample>,
    rx: flume::Receiver<Input>,
    weak: Weak<MediaPeer>,
) {
    let Ok(mut encoder) = Encoder::new(INPUT_RATE, Channels::Mono, Application::Voip) else {
        return;
    };
    let _ = encoder.set_inband_fec(true);
    let mut pending = Vec::<f32>::new();
    let mut epoch = 0;
    let mut encoded = [0; MAX_OPUS];
    let mut ticker = tokio::time::interval(Duration::from_millis(20));
    loop {
        tokio::select! {biased;
         cmd=rx.recv_async()=>match cmd{
          Ok(Input::Audio(e,s))=>{if let Some(p)=weak.upgrade(){p.queued.fetch_sub(s.len(),Ordering::AcqRel);}if e==epoch{let overflow=pending.len().saturating_add(s.len()).saturating_sub(MAX_INPUT).min(pending.len());pending.drain(..overflow);pending.extend(s)}},
          Ok(Input::Mute(e))=>{epoch=e;pending.clear()},
          _=>break,
         },
         _=ticker.tick()=>{
          let Some(core)=weak.upgrade()else{break};if core.muted.load(Ordering::Acquire){pending.clear();continue}
          let tick_epoch=core.epoch.load(Ordering::Acquire);if tick_epoch!=epoch{epoch=tick_epoch;pending.clear();continue}
          let mut frame=[0.0;INPUT_FRAME];let n=pending.len().min(INPUT_FRAME);frame[..n].copy_from_slice(&pending[..n]);pending.drain(..n);
          if core.muted.load(Ordering::Acquire)||core.epoch.load(Ordering::Acquire)!=tick_epoch{pending.clear();continue}
          let Ok(len)=encoder.encode_float(&frame,&mut encoded)else{break};
          if core.muted.load(Ordering::Acquire)||core.epoch.load(Ordering::Acquire)!=tick_epoch{continue}
          if track.write_sample(&Sample{data:Bytes::copy_from_slice(&encoded[..len]),duration:Duration::from_millis(20),..Default::default()}).await.is_err(){break}
         }
        }
    }
}
async fn drain_rtcp(sender: Arc<RTCRtpSender>) {
    while sender.read_rtcp().await.is_ok() {}
}
async fn receive(track: Arc<TrackRemote>, weak: Weak<MediaPeer>) {
    if !track
        .codec()
        .capability
        .mime_type
        .eq_ignore_ascii_case(MIME_TYPE_OPUS)
    {
        if let Some(p) = weak.upgrade() {
            (p.on_error)()
        }
        return;
    }
    let Ok(mut decoder) = Decoder::new(OUTPUT_RATE, Channels::Mono) else {
        return;
    };
    let mut decoded = vec![0.0; MAX_DECODED];
    let mut expected = None;
    let mut last_frame = OUTPUT_FRAME;
    loop {
        let Ok((packet, _)) = track.read_rtp().await else {
            return;
        };
        let seq = packet.header.sequence_number;
        if let Some(e) = expected {
            let gap = seq.wrapping_sub(e);
            if gap >= u16::MAX / 2 {
                continue;
            }
            if gap > 0 {
                for _ in 1..gap.min(5) {
                    if let Ok(n) = decoder.decode_float(&[], &mut decoded[..last_frame], false) {
                        if let Some(p) = weak.upgrade() {
                            p.write_output(&decoded[..n])
                        }
                    }
                }
                if let Ok(n) =
                    decoder.decode_float(&packet.payload, &mut decoded[..last_frame], true)
                {
                    if let Some(p) = weak.upgrade() {
                        p.write_output(&decoded[..n])
                    }
                }
            }
        }
        expected = Some(seq.wrapping_add(1));
        let Ok(n) = decoder.decode_float(&packet.payload, &mut decoded, false) else {
            return;
        };
        last_frame = n;
        if let Some(p) = weak.upgrade() {
            p.write_output(&decoded[..n]);
            let rms = (decoded[..n].iter().map(|x| x * x).sum::<f32>() / n.max(1) as f32)
                .sqrt()
                .clamp(0.0, 1.0);
            (p.on_level)(rms)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn output_is_bounded() {
        let p = MediaPeer::new(Arc::new(|_| {}), Arc::new(|| {}), Arc::new(|_| {}));
        p.write_output(&vec![1.0; MAX_OUTPUT + 7]);
        assert_eq!(p.output.lock().len(), MAX_OUTPUT)
    }
    #[test]
    fn mute_advances_epoch() {
        let p = MediaPeer::new(Arc::new(|_| {}), Arc::new(|| {}), Arc::new(|_| {}));
        p.mute(true);
        assert_eq!(p.epoch.load(Ordering::Acquire), 1)
    }
}
