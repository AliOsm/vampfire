//! Protocol adapter only. Scheduling, histograms, timing, fan-out markers and drains stay upstream.
use super::*;

pub static ENABLED: AtomicBool = AtomicBool::new(false);
static SOCKET_FAILURES: AtomicUsize = AtomicUsize::new(0);

pub fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

pub fn post_path(room: &str) -> String {
    format!(
        "{}/rooms/{room}/messages",
        if enabled() { "/api" } else { "" }
    )
}

pub fn message(cookie: &str, csrf: &str, text: &str) -> (Vec<(&'static str, String)>, Bytes) {
    (
        vec![
            ("cookie", cookie.into()),
            ("content-type", "application/json".into()),
            ("x-csrf-token", csrf.into()),
            same_origin(),
        ],
        Bytes::from(json!({"body": text, "client_id": nonce()}).to_string()),
    )
}

pub async fn login(a: &Args) -> Res<Value> {
    let addr = host_port(&a.get("base"));
    let r = one_shot(
        &addr,
        "POST",
        "/api/session",
        &[("content-type", "application/json".into()), same_origin()],
        Bytes::from(json!({"email": a.get("email"), "password": a.get("password")}).to_string()),
    )
    .await?;
    if r.status != 200 {
        return Err(format!("login failed: {}", r.status).into());
    }
    let mut jar = Vec::new();
    merge_cookies(&mut jar, &r.headers);
    let body: Value = serde_json::from_slice(&r.body)?;
    Ok(json!({"cookie": cookie_header(&jar), "csrf": body["csrf"]}))
}

pub async fn scrape(a: &Args) -> Res<Value> {
    let r = one_shot(
        &host_port(&a.get("base")),
        "GET",
        "/api/bootstrap",
        &[("cookie", a.get("cookie"))],
        Bytes::new(),
    )
    .await?;
    let body: Value = serde_json::from_slice(&r.body)?;
    Ok(json!({"status": r.status, "csrf": body["csrf"], "streams": [], "css": "/assets/app.css"}))
}

/// A V room view needs a shell and API requests. Count the whole sequence as one operation.
/// Rust has no additional paths and still executes its original single request.
pub async fn send_http(
    sender: &mut SendRequest<Full<Bytes>>,
    addr: &str,
    method: &str,
    path: &str,
    headers: &[(&str, String)],
    body: Bytes,
    extra: &[String],
) -> Res<(Resp, u64)> {
    let mut r = send(sender, addr, method, path, headers, body).await?;
    let mut bytes = r.body.len() as u64;
    if r.status < 400 && method == "GET" {
        if enabled() && !extra.is_empty() {
            validate_extra(&r, path)?;
        }
        for p in extra {
            r = send(sender, addr, "GET", p, headers, Bytes::new()).await?;
            bytes += r.body.len() as u64;
            if r.status >= 400 {
                break;
            }
            if enabled() {
                validate_extra(&r, p)?;
            }
        }
    }
    Ok((r, bytes))
}

#[allow(clippy::too_many_arguments)]
pub async fn cable_client(
    addr: String,
    source: Option<std::net::IpAddr>,
    cookie: String,
    subs: Vec<String>,
    confirmed: Arc<AtomicUsize>,
    connected: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
    delivery: Arc<Delivery>,
) -> Res<()> {
    let mut req = format!("ws://{addr}/ws").into_client_request()?;
    req.headers_mut().insert("cookie", cookie.parse()?);
    req.headers_mut()
        .insert("origin", format!("http://{addr}").parse()?);
    let socket = tokio::net::TcpSocket::new_v4()?;
    if let Some(source) = source {
        socket.bind(std::net::SocketAddr::new(source, 0))?;
    }
    let stream = socket
        .connect(
            tokio::net::lookup_host(&addr)
                .await?
                .next()
                .ok_or("no address")?,
        )
        .await?;
    stream.set_nodelay(true)?;
    let (ws, _) = tokio_tungstenite::client_async(req, stream).await?;
    connected.fetch_add(1, Ordering::Relaxed);
    let (mut tx, mut rx) = ws.split();
    tx.send(WsMessage::text(
        json!({"type":"subscribe", "room_id":subs[0].parse::<u64>()?}).to_string(),
    ))
    .await?;
    let mut seen = HashSet::new();
    let mut confirms = 0;
    while let Some(msg) = rx.next().await {
        if stop.load(Ordering::Relaxed) {
            break;
        }
        let msg = match msg {
            Ok(value) => value,
            Err(error) => {
                if SOCKET_FAILURES.fetch_add(1, Ordering::Relaxed) < 5 {
                    eprintln!("V WebSocket read failed: {error}");
                }
                return Err(error.into());
            }
        };
        match msg {
            WsMessage::Text(t) => {
                if confirms == 0 && t.contains("\"kind\":\"presence\"") {
                    on_text(
                        "confirm_subscription",
                        1,
                        &mut confirms,
                        &mut seen,
                        &confirmed,
                        &delivery,
                    );
                }
                on_text(&t, 1, &mut confirms, &mut seen, &confirmed, &delivery);
            }
            WsMessage::Ping(bytes) => tx.send(WsMessage::Pong(bytes)).await?,
            WsMessage::Close(frame) => {
                if SOCKET_FAILURES.fetch_add(1, Ordering::Relaxed) < 5 {
                    eprintln!("V WebSocket closed: {frame:?}");
                }
                break;
            }
            _ => {}
        }
    }
    let _ = tx.send(WsMessage::Close(None)).await;
    Ok(())
}

pub async fn upload(a: &Args) -> Res<Value> {
    let addr = host_port(&a.get("base"));
    let cookie = a.get("cookie");
    let room = a.get("room");
    let csrf = a.get("csrf");
    let file = a.get("file");
    let data = std::fs::read(&file)?;
    let name = std::path::Path::new(&file)
        .file_name()
        .unwrap()
        .to_string_lossy();
    let mut runs = Vec::new();
    for _ in 0..a.num("reps", 5) {
        let boundary = format!("----bench{}", nonce());
        let mut body = format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\nContent-Type: image/jpeg\r\n\r\n").into_bytes();
        body.extend(&data);
        body.extend(format!("\r\n--{boundary}--\r\n").as_bytes());
        let t0 = Instant::now();
        let r = one_shot(
            &addr,
            "POST",
            "/api/uploads",
            &[
                ("cookie", cookie.clone()),
                ("x-csrf-token", csrf.clone()),
                (
                    "content-type",
                    format!("multipart/form-data; boundary={boundary}"),
                ),
                same_origin(),
            ],
            Bytes::from(body),
        )
        .await?;
        if r.status != 201 {
            return Err(format!("upload status {}", r.status).into());
        }
        let uploaded: Value = serde_json::from_slice(&r.body)?;
        let id = uploaded["id"].as_u64().ok_or("missing upload ID")?;
        let (h, _) = message(&cookie, &csrf, "");
        let r = one_shot(
            &addr,
            "POST",
            &post_path(&room),
            &h,
            Bytes::from(json!({"upload_id":id, "client_id":nonce()}).to_string()),
        )
        .await?;
        if r.status != 201 {
            return Err(format!("attachment message status {}", r.status).into());
        }
        let post_ms = t0.elapsed().as_secs_f64() * 1000.;
        let message: Value = serde_json::from_slice(&r.body)?;
        let mid = message["id"].as_u64().ok_or("missing message ID")?;
        let mut polls = 0;
        loop {
            if t0.elapsed().as_secs() > 30 {
                return Err("thumbnail timed out".into());
            }
            let r = one_shot(
                &addr,
                "GET",
                &format!("/api/rooms/{room}/messages?around={mid}"),
                &[("cookie", cookie.clone())],
                Bytes::new(),
            )
            .await?;
            if r.status != 200 {
                return Err(format!("thumbnail poll status {}", r.status).into());
            }
            let rows: Value = serde_json::from_slice(&r.body)?;
            polls += 1;
            if rows.as_array().ok_or("missing messages")?.iter().any(|m| {
                m["id"].as_u64() == Some(mid)
                    && m["attachment"]["thumb"]
                        .as_str()
                        .is_some_and(|s| !s.is_empty())
            }) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let thumb = one_shot(
            &addr,
            "GET",
            &format!("/uploads/{id}?thumb=1"),
            &[("cookie", cookie.clone())],
            Bytes::new(),
        )
        .await?;
        let total_ms = t0.elapsed().as_secs_f64() * 1000.;
        if thumb.status != 200 {
            return Err("thumbnail failed".into());
        }
        decode_image(&thumb.body)?;
        runs.push(json!({"post_status":201,"post_ms":post_ms,"thumb_status":thumb.status,"pixels_decoded":true,
            "thumb_bytes":thumb.body.len(),"thumb_ms":total_ms-post_ms,"total_ms":total_ms,"readiness_polls":polls}));
    }
    let mut totals: Vec<f64> = runs
        .iter()
        .map(|r| r["total_ms"].as_f64().unwrap())
        .collect();
    totals.sort_by(|a, b| a.total_cmp(b));
    Ok(json!({"file":name,"bytes":data.len(),"median_total_ms":totals[totals.len()/2],"runs":runs}))
}

fn validate_extra(response: &Resp, path: &str) -> Res<()> {
    use std::io::Read;
    let body = if response
        .headers
        .get("content-encoding")
        .is_some_and(|e| e == "gzip")
    {
        let mut output = Vec::new();
        flate2::read::GzDecoder::new(response.body.as_ref())
            .take(8 * 1024 * 1024)
            .read_to_end(&mut output)?;
        output
    } else {
        response.body.to_vec()
    };
    if path.starts_with("/api/") {
        let value: Value = serde_json::from_slice(&body)?;
        let valid = if path == "/api/bootstrap" {
            value["user"]["id"].as_u64().is_some_and(|id| id > 0)
                && value["csrf"].as_str().is_some_and(|s| !s.is_empty())
        } else {
            value.is_array()
        };
        if !valid {
            return Err("invalid room API response".into());
        }
    } else if !body.starts_with(b"<!doctype html>") && !body.starts_with(b"<!DOCTYPE html>") {
        return Err("invalid room shell".into());
    }
    Ok(())
}

pub fn validate_json(
    kind: &str,
    body: &[u8],
    ids: &Option<Vec<u64>>,
    content: &Option<Vec<Vec<String>>>,
    required: &[String],
    posted: Option<&str>,
) -> Result<Option<u64>, &'static str> {
    let value: Value = serde_json::from_slice(body).map_err(|_| "invalid JSON")?;
    if kind == "post_message" {
        let id = value["id"]
            .as_u64()
            .filter(|id| *id > 0)
            .ok_or("invalid message ID")?;
        if !posted.is_some_and(|text| {
            value["plain"].as_str() == Some(text)
                && value["body"]
                    .as_str()
                    .is_some_and(|html| html.contains(text))
        }) {
            return Err("POST did not render the requested message");
        }
        return Ok(Some(id));
    }
    if ["room_show", "messages_page", "search"].contains(&kind) {
        let rows = if kind == "search" {
            value["messages"].as_array()
        } else {
            value.as_array()
        }
        .ok_or("missing message array")?;
        let actual: Vec<u64> = rows
            .iter()
            .map(|row| row["id"].as_u64().unwrap_or(0))
            .collect();
        if Some(&actual) != ids.as_ref() {
            return Err("incorrect message window");
        }
        static WORDS: OnceLock<regex::Regex> = OnceLock::new();
        static TAGS: OnceLock<regex::Regex> = OnceLock::new();
        let words = WORDS.get_or_init(|| regex::Regex::new(r"[A-Za-z0-9_]+").unwrap());
        let tags = TAGS.get_or_init(|| regex::Regex::new(r"<[^>]*>").unwrap());
        let expected = content.as_ref().ok_or("missing expected content")?;
        for (row, tokens) in rows.iter().zip(expected) {
            let plain = row["plain"].as_str().ok_or("missing plain message")?;
            let html = row["body"].as_str().ok_or("missing rendered message")?;
            let rendered = tags.replace_all(html, " ");
            for text in [plain, rendered.as_ref()] {
                let mut actual = words.find_iter(text);
                for token in tokens {
                    if !actual.by_ref().any(|word| word.as_str() == token) {
                        return Err("missing seeded message content");
                    }
                }
            }
        }
    } else if kind == "sidebar" {
        let rows = value.as_array().ok_or("invalid sidebar")?;
        if required
            .iter()
            .any(|name| !rows.iter().any(|r| r["name"].as_str() == Some(name)))
        {
            return Err("missing sidebar room");
        }
    } else if kind == "up" && value != json!({"ok":true}) {
        return Err("invalid health response");
    }
    Ok(None)
}

/// Decode pixels after timing the transfer; a JPEG signature is insufficient.
pub fn decode_image(body: &[u8]) -> Res<()> {
    use std::io::Write;
    use std::process::{Command, Stdio};
    let mut child = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-threads",
            "1",
            "-count_frames",
            "-show_entries",
            "stream=width,height,nb_read_frames",
            "-of",
            "json",
            "-i",
            "pipe:0",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    child
        .stdin
        .take()
        .ok_or("no image decoder input")?
        .write_all(body)?;
    let output = child.wait_with_output()?;
    let data: Value = serde_json::from_slice(&output.stdout)?;
    let errors = String::from_utf8_lossy(&output.stderr);
    let allowed = regex::Regex::new(
        r"^\[webp @ 0x[0-9a-f]+\] invalid TIFF header in (?:EXIF|Exif) data(?:: Invalid data found when processing input)?\s*$",
    )?;
    if !output.status.success()
        || errors.lines().any(|line| !allowed.is_match(line))
        || !data["streams"].as_array().is_some_and(|streams| {
            streams.iter().any(|s| {
                s["width"].as_u64().unwrap_or(0) > 0
                    && s["height"].as_u64().unwrap_or(0) > 0
                    && s["nb_read_frames"]
                        .as_str()
                        .and_then(|n| n.parse::<u64>().ok())
                        .unwrap_or(0)
                        > 0
            })
        })
    {
        return Err(format!("invalid image pixels: {errors}").into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn json_contract_rejects_wrong_ids_and_rendered_content() {
        let ids = Some(vec![42]);
        let content = Some(vec![vec!["coffee".into()]]);
        assert!(validate_json(
            "messages_page",
            br#"[{"id":42,"plain":"coffee","body":"<p>coffee</p>"}]"#,
            &ids,
            &content,
            &[],
            None
        )
        .is_ok());
        for bad in [
            br#"[{"id":43,"plain":"coffee","body":"coffee"}]"#.as_slice(),
            br#"[{"id":42,"plain":"coffee","body":"error"}]"#,
            br#"{"error":"failed"}"#,
        ] {
            assert!(validate_json("messages_page", bad, &ids, &content, &[], None).is_err());
        }
        assert_eq!(
            validate_json(
                "post_message",
                br#"{"id":9,"plain":"bench write abc","body":"bench write abc"}"#,
                &None,
                &None,
                &[],
                Some("bench write abc")
            )
            .unwrap(),
            Some(9)
        );
        assert!(validate_json(
            "post_message",
            br#"{"id":9,"plain":"other","body":"other"}"#,
            &None,
            &None,
            &[],
            Some("bench write abc")
        )
        .is_err());
    }
}
