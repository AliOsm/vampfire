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
        for p in extra {
            r = send(sender, addr, "GET", p, headers, Bytes::new()).await?;
            bytes += r.body.len() as u64;
            if r.status >= 400 {
                break;
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
        runs.push(json!({"post_status":201,"post_ms":post_ms,"thumb_status":thumb.status,
            "thumb_bytes":thumb.body.len(),"thumb_ms":total_ms-post_ms,"total_ms":total_ms,"readiness_polls":polls}));
    }
    let mut totals: Vec<f64> = runs
        .iter()
        .map(|r| r["total_ms"].as_f64().unwrap())
        .collect();
    totals.sort_by(|a, b| a.total_cmp(b));
    Ok(json!({"file":name,"bytes":data.len(),"median_total_ms":totals[totals.len()/2],"runs":runs}))
}
