use super::protocol::{ServerEvent, parse_server_event, session_payload};
use crate::media::MediaPeer;
use futures_util::{SinkExt, StreamExt};
use http::HeaderValue;
use parking_lot::Mutex;
use reqwest::header;
use std::{
    future::Future,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::{
    sync::{mpsc, watch},
    task::JoinHandle,
};
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};
use uuid::Uuid;

const SIGNAL_URL: &str =
    "https://chatgpt.com/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas";
const SIDEBAND_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_CONTROL_BATCHES: usize = 16;
const MAX_CONTROL_MESSAGES: usize = 64;
const MAX_CONTROL_BYTES: usize = 32 * 1024;

pub struct ProviderTransport {
    pub(crate) media: Arc<MediaPeer>,
    side_tx: Mutex<Option<mpsc::Sender<Vec<String>>>>,
    side_task: Mutex<Option<JoinHandle<()>>>,
    closed: AtomicBool,
}
impl ProviderTransport {
    pub async fn connect(
        token: String,
        account: Option<String>,
        instructions: String,
        voice: String,
        on_wire: Arc<dyn Fn(String) + Send + Sync>,
        on_error: Arc<dyn Fn() + Send + Sync>,
        on_level: Arc<dyn Fn(f32) + Send + Sync>,
        mut cancel: watch::Receiver<bool>,
    ) -> Result<Arc<Self>, String> {
        let side_live = Arc::new(AtomicBool::new(false));
        let data_live = side_live.clone();
        let data_cb = {
            let cb = on_wire.clone();
            Arc::new(move |s: String| {
                if !data_live.load(Ordering::Acquire)
                    || matches!(parse_server_event(&s), Some(ServerEvent::Error))
                {
                    cb(s)
                }
            })
        };
        let media = MediaPeer::new(data_cb, on_error.clone(), on_level);
        let operation = Self::connect_inner(
            media.clone(),
            token,
            account,
            instructions,
            voice,
            on_wire,
            on_error,
            side_live,
            &mut cancel,
        );
        let cleanup = {
            let media = media.clone();
            async move { media.close().await }
        };
        cleanup_on_error(operation, cleanup).await
    }
    async fn connect_inner(
        media: Arc<MediaPeer>,
        token: String,
        account: Option<String>,
        instructions: String,
        voice: String,
        on_wire: Arc<dyn Fn(String) + Send + Sync>,
        on_error: Arc<dyn Fn() + Send + Sync>,
        side_live: Arc<AtomicBool>,
        cancel: &mut watch::Receiver<bool>,
    ) -> Result<Arc<Self>, String> {
        let offer = cancellable(cancel, media.offer()).await?;
        let session_id = Uuid::new_v4().to_string();
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(20))
            .build()
            .map_err(|_| "signaling setup failed".to_owned())?;
        let mut request = client
            .post(SIGNAL_URL)
            .bearer_auth(&token)
            .header("OpenAI-Alpha", "quicksilver=v2")
            .header("x-session-id", &session_id)
            .json(
                &serde_json::json!({"sdp":offer,"session":session_payload(&instructions,&voice)}),
            );
        if let Some(id) = &account {
            request = request.header("ChatGPT-Account-Id", id)
        }
        let response = cancellable(cancel, async {
            request
                .send()
                .await
                .map_err(|_| "signaling request failed".to_owned())
        })
        .await?;
        if !response.status().is_success() {
            return Err(format!(
                "signaling rejected ({})",
                response.status().as_u16()
            ));
        }
        let location = response
            .headers()
            .get(header::LOCATION)
            .and_then(|v| v.to_str().ok())
            .ok_or("signaling response was incomplete")?
            .to_owned();
        let call_id = parse_call_id(&location).ok_or("signaling response was incomplete")?;
        let answer = cancellable(cancel, async {
            response
                .text()
                .await
                .map_err(|_| "signaling response failed".to_owned())
        })
        .await?;
        if answer.trim().is_empty() {
            return Err("signaling response was incomplete".into());
        }
        cancellable(cancel, media.answer(answer)).await?;
        cancellable(cancel, media.wait_open()).await?;
        let url = format!("wss://api.openai.com/v1/live/{call_id}");
        let mut request = url
            .into_client_request()
            .map_err(|_| "sideband setup failed".to_owned())?;
        request.headers_mut().insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {token}"))
                .map_err(|_| "sideband setup failed".to_owned())?,
        );
        request
            .headers_mut()
            .insert("OpenAI-Alpha", HeaderValue::from_static("quicksilver=v2"));
        request.headers_mut().insert(
            "x-session-id",
            HeaderValue::from_str(&session_id).map_err(|_| "sideband setup failed".to_owned())?,
        );
        if let Some(id) = account {
            request.headers_mut().insert(
                "ChatGPT-Account-Id",
                HeaderValue::from_str(&id).map_err(|_| "sideband setup failed".to_owned())?,
            );
        }
        let handshake = async {
            tokio::time::timeout(SIDEBAND_TIMEOUT, tokio_tungstenite::connect_async(request))
                .await
                .map_err(|_| "sideband connection timed out".to_owned())?
                .map_err(|_| "sideband connection failed".to_owned())
        };
        let (socket, _) = cancellable(cancel, handshake).await?;
        side_live.store(true, Ordering::Release);
        let (mut sink, mut stream) = socket.split();
        let (tx, mut rx) = mpsc::channel::<Vec<String>>(MAX_CONTROL_BATCHES);
        let cb = on_wire;
        let error = on_error;
        let task = tokio::spawn(async move {
            loop {
                tokio::select! {batch=rx.recv()=>match batch{Some(messages)=>{for value in messages{if sink.send(Message::Text(value.into())).await.is_err(){return}}},None=>break},incoming=stream.next()=>match incoming{Some(Ok(Message::Text(v)))=>(cb)(v.to_string()),Some(Ok(Message::Close(_)))|Some(Err(_))|None=>{(error)();break},_=>{}}}
            }
        });
        Ok(Arc::new(Self {
            media,
            side_tx: Mutex::new(Some(tx)),
            side_task: Mutex::new(Some(task)),
            closed: AtomicBool::new(false),
        }))
    }
    pub fn send_batch(&self, messages: Vec<String>) -> Result<(), String> {
        if messages.is_empty() {
            return Ok(());
        }
        if messages.len() > MAX_CONTROL_MESSAGES
            || messages
                .iter()
                .try_fold(0usize, |total, message| total.checked_add(message.len()))
                .is_none_or(|total| total > MAX_CONTROL_BYTES)
        {
            return Err("voice control batch is too large".to_owned());
        }
        self.side_tx
            .lock()
            .as_ref()
            .ok_or("voice session is closed")?
            .try_send(messages)
            .map_err(|error| match error {
                mpsc::error::TrySendError::Full(_) => "voice control queue is full".to_owned(),
                mpsc::error::TrySendError::Closed(_) => "voice session is closed".to_owned(),
            })
    }
    pub async fn close(&self) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        let _ = self.send_batch(vec!["{\"type\":\"session.close\"}".into()]);
        self.side_tx.lock().take();
        if let Some(task) = self.side_task.lock().take() {
            task.abort()
        }
        self.media.close().await
    }
}
async fn cancellable<T, F: Future<Output = Result<T, String>>>(
    cancel: &mut watch::Receiver<bool>,
    future: F,
) -> Result<T, String> {
    if *cancel.borrow() {
        return Err("voice connection cancelled".into());
    }
    tokio::select! {result=future=>result,changed=cancel.changed()=>{let _=changed;Err("voice connection cancelled".into())}}
}
async fn cleanup_on_error<T, F: Future<Output = Result<T, String>>, C: Future<Output = ()>>(
    operation: F,
    cleanup: C,
) -> Result<T, String> {
    let result = operation.await;
    if result.is_err() {
        cleanup.await
    }
    result
}
fn parse_call_id(location: &str) -> Option<String> {
    location
        .split('?')
        .next()?
        .split('/')
        .find(|s| {
            s.starts_with("rtc_")
                && s.chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        })
        .map(str::to_owned)
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    #[test]
    fn call_id_is_strict() {
        assert_eq!(
            parse_call_id("https://x/rtc_a-1?q=x").as_deref(),
            Some("rtc_a-1")
        );
        assert!(parse_call_id("https://x/not_rtc").is_none())
    }
    async fn cancelled_blocked_stage_cleans_up() {
        let (tx, mut rx) = watch::channel(false);
        let cleaned = Arc::new(AtomicUsize::new(0));
        let marked = cleaned.clone();
        let task = tokio::spawn(async move {
            let operation = async {
                cancellable(&mut rx, async {
                    std::future::pending::<Result<(), String>>().await
                })
                .await
            };
            cleanup_on_error(operation, async move {
                marked.fetch_add(1, Ordering::AcqRel);
            })
            .await
        });
        tokio::task::yield_now().await;
        tx.send_replace(true);
        assert_eq!(
            task.await.unwrap().unwrap_err(),
            "voice connection cancelled"
        );
        assert_eq!(cleaned.load(Ordering::Acquire), 1);
    }
    #[tokio::test]
    async fn stop_while_signaling_cleans_transport() {
        cancelled_blocked_stage_cleans_up().await
    }
    #[tokio::test]
    async fn stop_while_sideband_handshake_cleans_transport() {
        cancelled_blocked_stage_cleans_up().await
    }
    #[test]
    fn stalled_sideband_queue_is_bounded() {
        let (tx, _rx) = mpsc::channel::<Vec<String>>(1);
        assert!(tx.try_send(vec!["first".into()]).is_ok());
        assert!(matches!(
            tx.try_send(vec!["second".into()]),
            Err(mpsc::error::TrySendError::Full(_))
        ))
    }
    #[test]
    fn oversized_batch_is_rejected_before_queueing() {
        let (tx, _rx) = mpsc::channel::<Vec<String>>(1);
        let media = MediaPeer::new(Arc::new(|_| {}), Arc::new(|| {}), Arc::new(|_| {}));
        let transport = ProviderTransport {
            media,
            side_tx: Mutex::new(Some(tx)),
            side_task: Mutex::new(None),
            closed: AtomicBool::new(false),
        };
        assert_eq!(
            transport
                .send_batch(vec!["x".repeat(MAX_CONTROL_BYTES + 1)])
                .unwrap_err(),
            "voice control batch is too large"
        );
        assert_eq!(
            transport
                .send_batch((0..MAX_CONTROL_MESSAGES + 1).map(|_| "x".into()).collect())
                .unwrap_err(),
            "voice control batch is too large"
        );
    }
}
