use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const LIVE_MODEL: &str = "gpt-live-1-codex";
pub const CONTEXT_CHUNK_BYTES: usize = 500;

#[derive(Debug, Clone, PartialEq)]
pub enum ServerEvent {
    SessionStarted,
    Transcript {
        role: &'static str,
        text: String,
        final_: bool,
        id: Option<String>,
    },
    Delegation {
        id: String,
        text: String,
    },
    Error,
    Unknown,
}

pub fn session_payload(instructions: &str, voice: &str) -> Value {
    json!({"model":LIVE_MODEL,"instructions":instructions,"audio":{"output":{"voice":voice}},"delegation":{"type":"client"}})
}

pub fn parse_server_event(raw: &str) -> Option<ServerEvent> {
    let value: Value = serde_json::from_str(raw).ok()?;
    let kind = value.get("type")?.as_str()?;
    match kind {
        "session.started" => Some(ServerEvent::SessionStarted),
        "input_transcript.added" | "output_transcript.added" => {
            let text = value.pointer("/item/text")?.as_str()?.to_owned();
            let id = value
                .pointer("/item/id")
                .and_then(Value::as_str)
                .map(str::to_owned);
            Some(ServerEvent::Transcript {
                role: if kind.starts_with("input") {
                    "user"
                } else {
                    "assistant"
                },
                text,
                final_: false,
                id,
            })
        }
        "turn.done" => {
            let role = match value.pointer("/turn/role")?.as_str()? {
                "user" => "user",
                "assistant" => "assistant",
                _ => return None,
            };
            let text = value.pointer("/turn/transcript")?.as_str()?.to_owned();
            let id = value
                .pointer("/turn/id")
                .and_then(Value::as_str)
                .map(str::to_owned);
            Some(ServerEvent::Transcript {
                role,
                text,
                final_: true,
                id,
            })
        }
        "delegation.created" => {
            let id = value.pointer("/item/id")?.as_str()?.to_owned();
            let content = value.pointer("/item/content").and_then(Value::as_array);
            let text = content
                .into_iter()
                .flatten()
                .filter(|item| item.get("type").and_then(Value::as_str) == Some("input_text"))
                .filter_map(|item| item.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
                .trim()
                .to_owned();
            Some(ServerEvent::Delegation { id, text })
        }
        "error" => Some(ServerEvent::Error),
        _ => Some(ServerEvent::Unknown),
    }
}

pub fn context_messages(text: &str, channel: &str, delegation_id: Option<&str>) -> Vec<String> {
    chunk_utf8(text, CONTEXT_CHUNK_BYTES).into_iter().map(|text| {
        let item = match delegation_id {
            Some(id) => json!({"type":"delegation.context.append","delegation_item_id":id,"channel":channel,"content":[{"type":"input_text","text":text}]}),
            None => json!({"type":"session.context.append","channel":channel,"content":[{"type":"input_text","text":text}]}),
        };
        serde_json::to_string(&item).expect("JSON values serialize")
    }).collect()
}

pub fn chunk_utf8(text: &str, max_bytes: usize) -> Vec<String> {
    if text.is_empty() {
        return vec![String::new()];
    }
    if max_bytes == 0 {
        return Vec::new();
    }
    let mut chunks = Vec::new();
    let mut start = 0;
    let mut bytes = 0;
    for (offset, ch) in text.char_indices() {
        let width = ch.len_utf8();
        if bytes > 0 && bytes + width > max_bytes {
            chunks.push(text[start..offset].to_owned());
            start = offset;
            bytes = 0;
        }
        if width > max_bytes {
            continue;
        }
        bytes += width;
    }
    if start < text.len() {
        chunks.push(text[start..].to_owned());
    }
    chunks
}

#[derive(Serialize, Deserialize)]
pub struct WireFixture(pub Value);

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chunks_on_utf8_boundaries() {
        let s = "🙂".repeat(126);
        let c = chunk_utf8(&s, 500);
        assert_eq!(c.iter().map(String::len).sum::<usize>(), s.len());
        assert!(c.iter().all(|v| v.len() <= 500));
    }
    #[test]
    fn parses_final_transcript() {
        let e = parse_server_event(
            r#"{"type":"turn.done","turn":{"role":"assistant","transcript":"hello","id":"t1"}}"#,
        )
        .unwrap();
        assert_eq!(
            e,
            ServerEvent::Transcript {
                role: "assistant",
                text: "hello".into(),
                final_: true,
                id: Some("t1".into())
            }
        );
    }
    #[test]
    fn empty_delegation_preserves_realtime_item_id() {
        assert_eq!(
            parse_server_event(
                r#"{"type":"delegation.created","item":{"id":"d-empty","content":[]}}"#
            ),
            Some(ServerEvent::Delegation {
                id: "d-empty".into(),
                text: String::new(),
            })
        );
        assert_eq!(
            parse_server_event(
                r#"{"type":"delegation.created","item":{"id":"d-blank","content":[{"type":"input_text","text":"  "}]}}"#
            ),
            Some(ServerEvent::Delegation {
                id: "d-blank".into(),
                text: String::new(),
            })
        );
        assert_eq!(
            parse_server_event(r#"{"type":"delegation.created","item":{"id":"d-missing"}}"#),
            Some(ServerEvent::Delegation {
                id: "d-missing".into(),
                text: String::new(),
            })
        );
    }
    #[test]
    fn provider_errors_are_opaque() {
        assert_eq!(
            parse_server_event(r#"{"type":"error","error":{"message":"secret"}}"#),
            Some(ServerEvent::Error)
        );
    }
    #[test]
    fn session_shape_matches_iskra() {
        assert_eq!(
            session_payload("p", "sol"),
            json!({"model":"gpt-live-1-codex","instructions":"p","audio":{"output":{"voice":"sol"}},"delegation":{"type":"client"}})
        );
    }
    #[test]
    fn context_shapes_match_iskra() {
        let plain: Value =
            serde_json::from_str(&context_messages("x", "speakable", None)[0]).unwrap();
        assert_eq!(plain["type"], "session.context.append");
        let delegated: Value =
            serde_json::from_str(&context_messages("x", "commentary", Some("d1"))[0]).unwrap();
        assert_eq!(delegated["type"], "delegation.context.append");
        assert_eq!(delegated["delegation_item_id"], "d1");
    }
}
