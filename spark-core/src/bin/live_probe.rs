use serde::Deserialize;
use spark_core::session::Session;
use std::{
    env,
    io::{self, Read},
    time::{Duration, Instant},
};

#[derive(Deserialize)]
struct Credential {
    #[serde(rename = "accessToken")]
    access_token: String,
    #[serde(rename = "accountId")]
    account_id: Option<String>,
}
fn credential() -> Result<Credential, ()> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).map_err(|_| ())?;
    let input = input.trim();
    if !input.is_empty() {
        if input.starts_with('{') {
            return serde_json::from_str(input).map_err(|_| ());
        }
        return Ok(Credential {
            access_token: input.to_owned(),
            account_id: env::var("SPARK_ACCOUNT_ID").ok(),
        });
    }
    let access_token = env::var("SPARK_ACCESS_TOKEN").map_err(|_| ())?;
    Ok(Credential {
        access_token,
        account_id: env::var("SPARK_ACCOUNT_ID").ok(),
    })
}
fn main() {
    let connect_only = env::args().any(|arg| arg == "--connect-only");
    let Ok(mut credential) = credential() else {
        eprintln!("spark-probe: credential input unavailable");
        std::process::exit(2)
    };
    if credential.access_token.trim().is_empty() {
        eprintln!("spark-probe: credential required");
        std::process::exit(2)
    }
    let voice = env::var("SPARK_VOICE").unwrap_or_else(|_| "sol".into());
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("runtime");
    let session = Session::new(runtime.handle().clone());
    let command=serde_json::json!({"type":"connect","accessToken":credential.access_token,"accountId":credential.account_id.take(),"instructions":"You are Spark. Keep live probe replies brief.","voice":voice}).to_string();
    credential.access_token.clear();
    drop(credential);
    if session.command(&command).is_err() {
        eprintln!("spark-probe: start rejected");
        std::process::exit(1)
    }
    drop(command);
    if !wait_for(&session, Duration::from_secs(30), |event| {
        event.get("type").and_then(|v| v.as_str()) == Some("connected")
    }) {
        session.stop();
        eprintln!("spark-probe: connect stage failed");
        std::process::exit(1)
    }
    println!("spark-probe: connected");
    if connect_only {
        session.stop();
        println!("spark-probe: connect-only complete");
        return;
    }
    let send=serde_json::json!({"type":"sendText","text":"Reply aloud with exactly: Spark probe ready.","channel":"speakable"}).to_string();
    if session.command(&send).is_err() {
        session.stop();
        eprintln!("spark-probe: text stage rejected");
        std::process::exit(1)
    }
    println!("spark-probe: text-sent");
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut final_transcript = false;
    let mut audio = false;
    let mut pcm = [0.0f32; 4_800];
    while Instant::now() < deadline && !(final_transcript && audio) {
        while let Some(raw) = session.poll() {
            let Ok(event) = serde_json::from_str::<serde_json::Value>(&raw) else {
                continue;
            };
            match event.get("type").and_then(|v| v.as_str()) {
                Some("transcript")
                    if event.get("role").and_then(|v| v.as_str()) == Some("assistant")
                        && event.get("final").and_then(|v| v.as_bool()) == Some(true) =>
                {
                    final_transcript = true
                }
                Some("error") => {
                    session.stop();
                    eprintln!("spark-probe: provider stage failed");
                    std::process::exit(1)
                }
                _ => {}
            }
        }
        let n = session.read_audio(&mut pcm);
        if n > 0 && pcm[..n].iter().any(|sample| sample.abs() > f32::EPSILON) {
            audio = true
        }
        std::thread::sleep(Duration::from_millis(20))
    }
    session.stop();
    if final_transcript {
        println!("spark-probe: final-transcript")
    }
    if audio {
        println!("spark-probe: audio-received")
    }
    if !(final_transcript && audio) {
        eprintln!("spark-probe: provider stage incomplete");
        std::process::exit(1)
    }
    println!("spark-probe: complete")
}
fn wait_for(
    session: &Session,
    timeout: Duration,
    predicate: impl Fn(&serde_json::Value) -> bool,
) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Some(raw) = session.poll() {
            if let Ok(event) = serde_json::from_str::<serde_json::Value>(&raw) {
                if event.get("type").and_then(|v| v.as_str()) == Some("error") {
                    return false;
                }
                if predicate(&event) {
                    return true;
                }
            }
        }
        std::thread::sleep(Duration::from_millis(20))
    }
    false
}
