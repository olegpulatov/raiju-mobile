use crate::provider::{
    protocol::{ServerEvent, context_messages, parse_server_event},
    transport::ProviderTransport,
};
use parking_lot::Mutex;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{HashSet, VecDeque},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};
use tokio::runtime::Handle;

const MAX_EVENTS: usize = 256;
const MAX_SEEN: usize = 512;
#[derive(Default)]
struct Recent {
    set: HashSet<String>,
    order: VecDeque<String>,
}
impl Recent {
    fn insert(&mut self, key: String) -> bool {
        if !self.set.insert(key.clone()) {
            return false;
        }
        self.order.push_back(key);
        if self.order.len() > MAX_SEEN {
            if let Some(old) = self.order.pop_front() {
                self.set.remove(&old);
            }
        }
        true
    }
    fn clear(&mut self) {
        self.set.clear();
        self.order.clear()
    }
}
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum Command {
    Connect {
        #[serde(rename = "accessToken")]
        access_token: String,
        #[serde(rename = "accountId")]
        account_id: Option<String>,
        instructions: String,
        voice: String,
    },
    SendText {
        text: String,
        #[serde(rename = "delegationId")]
        delegation_id: Option<String>,
        channel: Option<String>,
    },
    SetMuted {
        muted: bool,
    },
    Stop,
}

pub struct Session {
    runtime: Handle,
    events: Arc<Mutex<VecDeque<String>>>,
    transport: Arc<Mutex<Option<Arc<ProviderTransport>>>>,
    connect_cancel: Mutex<Option<tokio::sync::watch::Sender<bool>>>,
    connecting: Arc<AtomicBool>,
    stopped: Arc<AtomicBool>,
    muted: AtomicBool,
    generation: Arc<Mutex<u64>>,
    seen: Arc<Mutex<Recent>>,
}
impl Session {
    pub fn new(runtime: Handle) -> Self {
        Self {
            runtime,
            events: Arc::new(Mutex::new(VecDeque::new())),
            transport: Arc::new(Mutex::new(None)),
            connect_cancel: Mutex::new(None),
            connecting: Arc::new(AtomicBool::new(false)),
            stopped: Arc::new(AtomicBool::new(false)),
            muted: AtomicBool::new(false),
            generation: Arc::new(Mutex::new(0)),
            seen: Arc::new(Mutex::new(Recent::default())),
        }
    }
    pub fn command(&self, raw: &str) -> Result<(), String> {
        let cmd: Command = serde_json::from_str(raw).map_err(|_| "invalid command".to_owned())?;
        match cmd {
            Command::Connect {
                access_token,
                account_id,
                instructions,
                voice,
            } => {
                if access_token.trim().is_empty() {
                    return Err("access token is required".into());
                }
                if self.transport.lock().is_some() || self.connecting.swap(true, Ordering::AcqRel) {
                    return Err("voice session is already active".into());
                }
                self.seen.lock().clear();
                self.stopped.store(false, Ordering::Release);
                let (cancel_tx, cancel_rx) = tokio::sync::watch::channel(false);
                *self.connect_cancel.lock() = Some(cancel_tx);
                let mut g = self.generation.lock();
                *g += 1;
                let generation = *g;
                drop(g);
                let events = self.events.clone();
                let slot = self.transport.clone();
                let stopped = self.stopped.clone();
                let connecting = self.connecting.clone();
                let current = self.generation.clone();
                let seen = self.seen.clone();
                self.runtime.spawn(async move{
   let emit_events=events.clone();let emit_seen=seen.clone();let emit_stop=stopped.clone();let emit_current=current.clone();let wire=Arc::new(move|raw:String|{if emit_stop.load(Ordering::Acquire)||*emit_current.lock()!=generation{return}if let Some(event)=parse_server_event(&raw){let normalized=match event{ServerEvent::SessionStarted=>None,ServerEvent::Transcript{role,text,final_,id}=>{if final_{if let Some(key)=id.as_ref(){if !emit_seen.lock().insert(format!("transcript:{key}:final")){return}}}Some(json!({"type":"transcript","role":role,"text":text,"final":final_,"id":id}))},ServerEvent::Delegation{id,text}=>{if !emit_seen.lock().insert(format!("delegation:{id}")){return}Some(json!({"type":"delegation","id":id,"text":text}))},ServerEvent::Error=>Some(json!({"type":"error","message":"voice provider reported an error"})),ServerEvent::Unknown=>None};if let Some(e)=normalized{push_event(&emit_events,e)}}});
   let err_events=events.clone();let err_stop=stopped.clone();let err_current=current.clone();let error=Arc::new(move||{if !err_stop.load(Ordering::Acquire)&&*err_current.lock()==generation{push_event(&err_events,json!({"type":"error","message":"voice transport failed"}))}});let level_events=events.clone();let level_stop=stopped.clone();let level_current=current.clone();let level=Arc::new(move|output:f32|{if !level_stop.load(Ordering::Acquire)&&*level_current.lock()==generation{push_event(&level_events,json!({"type":"levels","input":0.0,"output":output}))}});
   match ProviderTransport::connect(access_token,account_id,instructions,voice,wire,error,level,cancel_rx).await{Ok(t)=>{let stale={let current_guard=current.lock();let mut transport_guard=slot.lock();if stopped.load(Ordering::Acquire)||*current_guard!=generation{true}else{*transport_guard=Some(t.clone());push_event(&events,json!({"type":"connected"}));false}};if stale{t.close().await}},Err(_)=>{if !stopped.load(Ordering::Acquire)&&*current.lock()==generation{push_event(&events,json!({"type":"error","message":"voice connection failed"}))}}}if *current.lock()==generation{connecting.store(false,Ordering::Release)}
  });
                Ok(())
            }
            Command::SendText {
                text,
                delegation_id,
                channel,
            } => {
                let channel = channel.unwrap_or_else(|| "speakable".into());
                if !matches!(channel.as_str(), "speakable" | "commentary") {
                    return Err("invalid text channel".into());
                }
                let t = self
                    .transport
                    .lock()
                    .clone()
                    .ok_or("voice session is not connected")?;
                t.send_batch(context_messages(&text, &channel, delegation_id.as_deref()))
            }
            Command::SetMuted { muted } => {
                self.muted.store(muted, Ordering::Release);
                if let Some(t) = self.transport.lock().as_ref() {
                    t.media.mute(muted)
                }
                if muted {
                    push_event(
                        &self.events,
                        json!({"type":"levels","input":0.0,"output":0.0}),
                    )
                }
                Ok(())
            }
            Command::Stop => {
                self.stop();
                Ok(())
            }
        }
    }
    pub fn poll(&self) -> Option<String> {
        self.events.lock().pop_front()
    }
    pub fn push_audio(&self, s: &[f32]) {
        if self.muted.load(Ordering::Acquire) || s.is_empty() {
            return;
        }
        if let Some(t) = self.transport.lock().as_ref() {
            t.media.push(s);
            let input = (s.iter().map(|x| x * x).sum::<f32>() / s.len() as f32)
                .sqrt()
                .clamp(0.0, 1.0);
            push_event(
                &self.events,
                json!({"type":"levels","input":input,"output":0.0}),
            )
        }
    }
    pub fn read_audio(&self, out: &mut [f32]) -> usize {
        self.transport
            .lock()
            .as_ref()
            .map_or(0, |t| t.media.read(out))
    }
    pub fn stop(&self) {
        if self.stopped.swap(true, Ordering::AcqRel) {
            return;
        }
        *self.generation.lock() += 1;
        self.connecting.store(false, Ordering::Release);
        if let Some(cancel) = self.connect_cancel.lock().take() {
            cancel.send_replace(true);
        }
        if let Some(t) = self.transport.lock().take() {
            self.runtime.spawn(async move {
                t.close().await;
            });
        }
        self.events.lock().clear();
        push_event(&self.events, json!({"type":"closed"}))
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.stop()
    }
}
fn push_event(queue: &Mutex<VecDeque<String>>, value: Value) {
    let serialized = value.to_string();
    let mut q = queue.lock();
    if value.get("type").and_then(Value::as_str) == Some("levels") {
        if let Some(index) = q.iter().rposition(|item| {
            serde_json::from_str::<Value>(item)
                .ok()
                .and_then(|v| v.get("type").and_then(Value::as_str).map(str::to_owned))
                .as_deref()
                == Some("levels")
        }) {
            q[index] = serialized;
            return;
        }
    }
    if q.len() == MAX_EVENTS {
        q.pop_front();
    }
    q.push_back(serialized)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn event_queue_is_bounded() {
        let q = Mutex::new(VecDeque::new());
        for i in 0..300 {
            push_event(&q, json!({"type":"closed","n":i}))
        }
        assert_eq!(q.lock().len(), MAX_EVENTS)
    }
    #[test]
    fn recent_dedup_is_bounded() {
        let mut r = Recent::default();
        for i in 0..600 {
            assert!(r.insert(i.to_string()))
        }
        assert_eq!(r.set.len(), MAX_SEEN);
        assert!(r.insert("0".into()))
    }
    #[tokio::test]
    async fn stop_cancels_blocked_start() {
        let rt = tokio::runtime::Handle::current();
        let s = Session::new(rt);
        let (tx, mut rx) = tokio::sync::watch::channel(false);
        *s.connect_cancel.lock() = Some(tx);
        s.connecting.store(true, Ordering::Release);
        s.stop();
        rx.changed().await.unwrap();
        assert!(*rx.borrow());
        assert!(!s.connecting.load(Ordering::Acquire));
    }
}
