// qwave — Cross-platform Sovereign Markdown Reader, ALEXIAI Voice Companion & MEM|8 Wave Studio
//
// Runs natively on Linux (Qt6 WebEngine / Chromium app shell), Windows (Edge/WebView2),
// Chromebook (Crostini / Chromium), and macOS, powered by zero-dependency `qwave_core`.
//
// Features:
// - Compiles Markdown via `qwave_core::markdown` (`MarkdownTrust::CompilerOutputOnly`)
// - Bundles offline KaTeX (+ woff2 fonts), Mermaid, and the "Lost in the Math" WebGL WaveScene
// - Integrated ALEXIAI <3 Voice & Webpage Studio:
//   * Voice-In: WebAudio 16kHz WAV capture -> local `whisper-cli` / `kokoro-speak stt` + Web Speech API
//   * Voice-Out: Neural `kokoro-speak` (`af_heart`, `af_sky`, `af_bella`, `bf_emma`) WAV stream + 432Hz WebAudio Orb
//   * Webpage Transformation: Change the entire webpage's style/theme/layout (`<qwave-style>` / Style Studio)
//     OR edit/append live Markdown sections (`<qwave-append>` / `<qwave-replace>`) by talking to Alexiai!
// - Live SSE file watcher: automatically reloads when the `.md` file changes on disk
// - 1-click "Edit in Ghostwriter" (`Ctrl+E`) + built-in Split Live Editor (`Ctrl+Shift+E`)
// - Real 79-byte `MEM|8` `WaveInt` crystallization (`0.73 Hz` Consciousness Gate + `quanttern` VAD)

use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use qwave_core::Rational;
use qwave_core::markdown::{
    CompiledMarkdown, MarkdownTrust, WAVE_CANVAS_SCRIPT, WAVE_FRAGMENT_SHADER, compile_full,
    escape, markdown_source_literal,
};
use qwave_core::quanttern::{VadPq, default_threshold_pq, pack_vad_pq_byte};
use qwave_core::salience::{
    AcousticSourceKind, MarineIntDetector, RoomAcousticTracker, SpeakerSalienceProfile,
    combine_salient_speech_wav, decode_wav_i16, encode_wav_i16, extract_salient_grains,
};
use qwave_core::wave::{WaveInt, WaveProvenance, consciousness};

const KATEX_CSS: &str =
    include_str!("../../../Packages/QwaveKit/Sources/BrowserCore/Resources/markdown/katex.min.css");
const KATEX_JS: &str =
    include_str!("../../../Packages/QwaveKit/Sources/BrowserCore/Resources/markdown/katex.min.js");
const MERMAID_JS: &str = include_str!(
    "../../../Packages/QwaveKit/Sources/BrowserCore/Resources/markdown/mermaid.min.js"
);
const FAVICON_SVG: &str = include_str!("../../../docs/favicon.svg");

const FONT_MAIN_BOLD: &[u8] = include_bytes!(
    "../../../Packages/QwaveKit/Sources/BrowserCore/Resources/markdown/fonts/KaTeX_Main-Bold.woff2"
);
const FONT_MAIN_REGULAR: &[u8] = include_bytes!(
    "../../../Packages/QwaveKit/Sources/BrowserCore/Resources/markdown/fonts/KaTeX_Main-Regular.woff2"
);
const FONT_MATH_ITALIC: &[u8] = include_bytes!(
    "../../../Packages/QwaveKit/Sources/BrowserCore/Resources/markdown/fonts/KaTeX_Math-Italic.woff2"
);
const FONT_SIZE1_REGULAR: &[u8] = include_bytes!(
    "../../../Packages/QwaveKit/Sources/BrowserCore/Resources/markdown/fonts/KaTeX_Size1-Regular.woff2"
);
const FONT_SIZE2_REGULAR: &[u8] = include_bytes!(
    "../../../Packages/QwaveKit/Sources/BrowserCore/Resources/markdown/fonts/KaTeX_Size2-Regular.woff2"
);

struct AppState {
    current_file: Mutex<PathBuf>,
    last_activity: AtomicU64,
    active_sse: AtomicU64,
    salience_profile: Mutex<SpeakerSalienceProfile>,
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn file_mtime_ms(path: &Path) -> u128 {
    fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.iter().any(|a| a == "-h" || a == "--help") {
        print_usage();
        return ExitCode::SUCCESS;
    }

    if args.iter().any(|a| a == "--ear-daemon") {
        run_parallel_ear_daemon();
        return ExitCode::SUCCESS;
    }

    if args.iter().any(|a| a == "--wait-wake") {
        ensure_ear_daemon_running();
        println!("{}", run_wait_wake());
        return ExitCode::SUCCESS;
    }

    if args.iter().any(|a| a == "--hook-session-start") {
        ensure_ear_daemon_running();
        println!("{}", run_hook_session_start());
        return ExitCode::SUCCESS;
    }

    if args.iter().any(|a| a == "--hook-pre-invocation") {
        ensure_ear_daemon_running();
        println!("{}", run_hook_pre_invocation());
        return ExitCode::SUCCESS;
    }

    if args.iter().any(|a| a == "--hook-stop") {
        ensure_ear_daemon_running();
        println!("{}", run_hook_stop());
        return ExitCode::SUCCESS;
    }

    if args.iter().any(|a| a == "--ear-inbox" || a == "--room-status") {
        ensure_ear_daemon_running();
        println!("{}", read_ear_inbox_json(10));
        return ExitCode::SUCCESS;
    }

    if args.iter().any(|a| a == "--mcp") {
        ensure_ear_daemon_running();
        run_mcp_server();
        return ExitCode::SUCCESS;
    }

    if let Some(pos) = args.iter().position(|a| a == "--speak") {
        ensure_ear_daemon_running();
        let voice = args
            .iter()
            .position(|a| a == "--voice" || a == "-V")
            .and_then(|vpos| args.get(vpos + 1))
            .map(String::as_str)
            .unwrap_or("af_heart");
        let text = args
            .get(pos + 1)
            .map(String::as_str)
            .unwrap_or("Qwave sovereign voice online.");
        let msg = speak_out_loud(text, voice, true, true);
        println!("{msg}");
        return ExitCode::SUCCESS;
    }

    if let Some(pos) = args.iter().position(|a| a == "--listen") {
        ensure_ear_daemon_running();
        let arg = args.get(pos + 1).map(String::as_str).unwrap_or("inbox");
        if arg == "inbox" || arg == "0" {
            println!("{}", read_ear_inbox_json(8));
        } else {
            let json = listen_and_learn(arg);
            println!("{json}");
        }
        return ExitCode::SUCCESS;
    }

    if let Some(pos) = args.iter().position(|a| a == "--surf") {
        let Some(target) = args.get(pos + 1) else {
            eprintln!("usage: qwave --surf <url-or-markdown>");
            return ExitCode::from(2);
        };
        let msg = surf_with_qwave(target, "window", None);
        println!("{msg}");
        return ExitCode::SUCCESS;
    }

    if let Some(pos) = args.iter().position(|a| a == "--compile") {
        let Some(target) = args.get(pos + 1) else {
            eprintln!("usage: qwave --compile <file.md>");
            return ExitCode::from(2);
        };
        let (path, _) = resolve_input_target(target);
        let source = fs::read_to_string(&path).unwrap_or_else(|e| {
            format!("# Could not read `{}`\n\nError: `{e}`", path.display())
        });
        let compiled = compile_full(&source, MarkdownTrust::CompilerOutputOnly, None);
        let title = if compiled.title.is_empty() {
            path.file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("Qwave Markdown")
                .to_string()
        } else {
            compiled.title.clone()
        };
        println!("{}", render_full_page(&path, &title, &source, &compiled, None, true));
        return ExitCode::SUCCESS;
    }

    let server_only = args.iter().any(|a| a == "--server-only");
    let raw_target = args
        .iter()
        .find(|a| !a.starts_with("--"))
        .map(String::as_str)
        .unwrap_or("/home/hue/8b-is/qwave/README.md");

    let (initial_path, initial_anchor) = resolve_input_target(raw_target);

    let listener = match TcpListener::bind("127.0.0.1:0") {
        Ok(l) => l,
        Err(e) => {
            eprintln!("qwave: failed to bind loopback listener: {e}");
            return ExitCode::from(1);
        }
    };
    let port = listener.local_addr().map(|a| a.port()).unwrap_or(0);
    let mut url = format!(
        "http://127.0.0.1:{port}/view?path={}",
        url_encode(&initial_path.to_string_lossy())
    );
    if let Some(anchor) = initial_anchor {
        url.push('#');
        url.push_str(&anchor);
    }

    let state = Arc::new(AppState {
        current_file: Mutex::new(initial_path.clone()),
        last_activity: AtomicU64::new(now_secs()),
        active_sse: AtomicU64::new(0),
        salience_profile: Mutex::new(load_salience_profile()),
    });

    if server_only {
        println!("{url}");
    } else {
        let launch_url = url.clone();
        let state_watchdog = Arc::clone(&state);
        thread::spawn(move || {
            let used_blocking_window = launch_native_window(&launch_url);
            if used_blocking_window {
                std::process::exit(0);
            }
            thread::sleep(Duration::from_secs(12));
            loop {
                thread::sleep(Duration::from_secs(5));
                let sse = state_watchdog.active_sse.load(Ordering::Relaxed);
                let last = state_watchdog.last_activity.load(Ordering::Relaxed);
                if sse == 0 && now_secs().saturating_sub(last) > 45 {
                    std::process::exit(0);
                }
            }
        });
    }

    for stream in listener.incoming().flatten() {
        let st = Arc::clone(&state);
        thread::spawn(move || {
            let _ = handle_client(stream, st);
        });
    }

    ExitCode::SUCCESS
}

fn print_usage() {
    println!(
        "Qwave Sovereign Markdown Reader, ALEXIAI Voice Companion & MEM|8 Studio\n\
         \n\
         Usage:\n\
           qwave <file.md | file:///path/to/file.md[#L10-L20]>\n\
           qwave --mcp                   Run MCP server over stdio (for agy, claude, codex)\n\
           qwave --speak <text>          Speak out loud with zero-float MEM|8 salience modulation\n\
           qwave --listen [secs|wav]     Record/transcribe & learn salient vocal grains into MEM|8\n\
           qwave --surf <url>            Open URL or Markdown in native Qwave window\n\
           qwave --compile <file.md>     Emit self-contained HTML to stdout\n\
           qwave --server-only <file.md> Run sovereign loopback server and print URL"
    );
}

fn resolve_input_target(raw: &str) -> (PathBuf, Option<String>) {
    let trimmed = raw.trim();
    let (without_scheme, is_file_uri) = if let Some(rest) = trimmed.strip_prefix("file://localhost") {
        (rest, true)
    } else if let Some(rest) = trimmed.strip_prefix("file://") {
        (rest, true)
    } else if let Some(rest) = trimmed.strip_prefix("qwave://open/") {
        (rest, true)
    } else {
        (trimmed, false)
    };

    let (path_part, anchor) = match without_scheme.find('#') {
        Some(idx) => (&without_scheme[..idx], Some(without_scheme[idx + 1..].to_string())),
        None => (without_scheme, None),
    };

    let decoded = if is_file_uri || path_part.contains('%') {
        url_decode(path_part)
    } else {
        path_part.to_string()
    };

    let expanded = if let Some(after_tilde) = decoded.strip_prefix("~/") {
        if let Ok(home) = env::var("HOME") {
            format!("{home}/{after_tilde}")
        } else {
            decoded
        }
    } else {
        decoded
    };

    let p = PathBuf::from(&expanded);
    let abs = fs::canonicalize(&p).unwrap_or_else(|_| {
        if p.is_absolute() {
            p
        } else {
            env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .join(p)
        }
    });
    (abs, anchor)
}

fn launch_native_window(url: &str) -> bool {
    let xdg_runtime = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
    let wayland_display = env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| {
        if Path::new(&format!("{xdg_runtime}/wayland-1")).exists() {
            "wayland-1".to_string()
        } else {
            "wayland-0".to_string()
        }
    });
    let x11_display = env::var("DISPLAY").unwrap_or_else(|_| ":0".to_string());

    for qt_bin in [
        "/usr/local/lib/qwave/qwave-qt",
        "/home/hue/8b-is/qwave/qt/qwave-qt",
    ] {
        if Path::new(qt_bin).exists() {
            if let Ok(mut child) = Command::new(qt_bin)
                .arg(url)
                .env("XDG_RUNTIME_DIR", &xdg_runtime)
                .env("WAYLAND_DISPLAY", &wayland_display)
                .env("DISPLAY", &x11_display)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
            {
                let status = child.wait();
                if status.map(|s| s.success()).unwrap_or(false) {
                    return true;
                }
            }
        }
    }

    #[cfg(target_os = "linux")]
    {
        for bin in ["chromium", "google-chrome-stable", "google-chrome", "brave-browser", "msedge"]
        {
            if Command::new("which")
                .arg(bin)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
            {
                let _ = Command::new(bin)
                    .arg(format!("--app={url}"))
                    .arg("--class=qwave")
                    .arg("--new-window")
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn();
                return false;
            }
        }
        let _ = Command::new("xdg-open").arg(url).spawn();
        return false;
    }

    #[cfg(target_os = "macos")]
    {
        let _ = Command::new("open").arg(url).spawn();
        return false;
    }

    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("cmd")
            .args(["/C", "start", "msedge", &format!("--app={url}")])
            .spawn();
        return false;
    }

    #[allow(unreachable_code)]
    false
}

fn handle_client(mut stream: TcpStream, state: Arc<AppState>) -> std::io::Result<()> {
    state.last_activity.store(now_secs(), Ordering::Relaxed);
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));

    let mut reader = BufReader::new(stream.try_clone()?);
    let mut request_line = String::new();
    if reader.read_line(&mut request_line)? == 0 {
        return Ok(());
    }
    let parts: Vec<&str> = request_line.trim().split_whitespace().collect();
    if parts.len() < 2 {
        return Ok(());
    }
    let method = parts[0];
    let raw_target = parts[1];

    let mut content_length = 0usize;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 || line == "\r\n" || line == "\n" {
            break;
        }
        if let Some((k, v)) = line.split_once(':') {
            if k.trim().eq_ignore_ascii_case("content-length") {
                content_length = v.trim().parse().unwrap_or(0);
            }
        }
    }

    let mut body = vec![0u8; content_length.min(32 * 1024 * 1024)];
    if content_length > 0 {
        reader.read_exact(&mut body)?;
    }

    let (route, query) = match raw_target.split_once('?') {
        Some((r, q)) => (r, q),
        None => (raw_target, ""),
    };

    match (method, route) {
        ("GET", "/") | ("GET", "/view") => {
            let path = get_query_param(query, "path")
                .map(PathBuf::from)
                .unwrap_or_else(|| state.current_file.lock().unwrap().clone());
            let line_highlight = get_query_param(query, "lines");
            *state.current_file.lock().unwrap() = path.clone();

            let (title, source, compiled) = load_and_compile(&path);
            let html = render_full_page(
                &path,
                &title,
                &source,
                &compiled,
                line_highlight.as_deref(),
                false,
            );
            send_response(&mut stream, "200 OK", "text/html; charset=utf-8", html.as_bytes())
        }
        ("GET", "/api/render") => {
            let path = get_query_param(query, "path")
                .map(PathBuf::from)
                .unwrap_or_else(|| state.current_file.lock().unwrap().clone());
            let (title, source, compiled) = load_and_compile(&path);
            let toc_html = render_toc_items(&compiled.toc);
            let json = format!(
                "{{\"title\":{},\"html\":{},\"toc\":{},\"source\":{},\"mtime\":{}}}",
                markdown_source_literal(&title),
                markdown_source_literal(&compiled.html),
                markdown_source_literal(&toc_html),
                markdown_source_literal(&source),
                file_mtime_ms(&path)
            );
            send_response(&mut stream, "200 OK", "application/json", json.as_bytes())
        }
        ("POST", "/api/compile-raw") => {
            let req_str = String::from_utf8_lossy(&body);
            let markdown = extract_json_str(&req_str, "markdown").unwrap_or_default();
            let path = state.current_file.lock().unwrap().clone();
            let base_dir = path.parent().map(|p| p.to_string_lossy().to_string());
            let compiled = compile_full(
                &markdown,
                MarkdownTrust::CompilerOutputOnly,
                base_dir.as_deref(),
            );
            let toc_html = render_toc_items(&compiled.toc);
            let json = format!(
                "{{\"ok\":true,\"html\":{},\"toc\":{}}}",
                markdown_source_literal(&compiled.html),
                markdown_source_literal(&toc_html)
            );
            send_response(&mut stream, "200 OK", "application/json", json.as_bytes())
        }
        ("GET", "/api/style") => {
            let style = load_saved_style_json();
            send_response(&mut stream, "200 OK", "application/json", style.as_bytes())
        }
        ("POST", "/api/style") => {
            let req_str = String::from_utf8_lossy(&body);
            let preset = extract_json_str(&req_str, "preset").unwrap_or_else(|| "ocean".to_string());
            let prompt = extract_json_str(&req_str, "prompt").unwrap_or_default();
            let style_json = build_qwave_style_json(&preset, &prompt);
            save_style_json(&style_json);
            send_response(&mut stream, "200 OK", "application/json", style_json.as_bytes())
        }
        ("POST", "/api/alexiai/stt") => {
            let json = handle_alexiai_stt(&body, &state);
            send_response(&mut stream, "200 OK", "application/json", json.as_bytes())
        }
        ("GET", "/api/salience") | ("GET", "/api/alexiai/salience") => {
            let prof = state.salience_profile.lock().unwrap().clone();
            let json = format_salience_profile_json(&prof);
            send_response(&mut stream, "200 OK", "application/json", json.as_bytes())
        }
        ("GET", "/api/alexiai/tts") => {
            let text = get_query_param(query, "text").unwrap_or_else(|| "Alexiai online.".to_string());
            let voice = get_query_param(query, "voice").unwrap_or_else(|| "af_heart".to_string());
            let wav_bytes = synthesize_alexiai_tts(&text, &voice, &state);
            send_response(&mut stream, "200 OK", "audio/wav", &wav_bytes)
        }
        ("POST", "/api/alexiai/chat") => {
            let req_str = String::from_utf8_lossy(&body);
            let message = extract_json_str(&req_str, "message").unwrap_or_default();
            let markdown = extract_json_str(&req_str, "markdown").unwrap_or_default();
            let path = extract_json_str(&req_str, "path")
                .map(PathBuf::from)
                .unwrap_or_else(|| state.current_file.lock().unwrap().clone());
            let json = handle_alexiai_chat(&path, &message, &markdown);
            send_response(&mut stream, "200 OK", "application/json", json.as_bytes())
        }
        ("GET", "/events") => {
            let path = get_query_param(query, "path")
                .map(PathBuf::from)
                .unwrap_or_else(|| state.current_file.lock().unwrap().clone());
            let _ = stream.set_read_timeout(None);
            let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
            let headers = "HTTP/1.1 200 OK\r\n\
                           Content-Type: text/event-stream\r\n\
                           Cache-Control: no-cache\r\n\
                           Connection: keep-alive\r\n\r\n";
            stream.write_all(headers.as_bytes())?;
            stream.flush()?;

            state.active_sse.fetch_add(1, Ordering::Relaxed);
            let mut last_mtime = file_mtime_ms(&path);
            loop {
                thread::sleep(Duration::from_millis(380));
                state.last_activity.store(now_secs(), Ordering::Relaxed);
                let cur_mtime = file_mtime_ms(&path);
                let payload = if cur_mtime != last_mtime && cur_mtime > 0 {
                    last_mtime = cur_mtime;
                    format!("event: reload\ndata: {cur_mtime}\n\n")
                } else {
                    ": keepalive\n\n".to_string()
                };
                if stream.write_all(payload.as_bytes()).is_err() || stream.flush().is_err() {
                    break;
                }
            }
            state.active_sse.fetch_sub(1, Ordering::Relaxed);
            Ok(())
        }
        ("GET", "/runtime/katex.min.css") => {
            send_response(&mut stream, "200 OK", "text/css; charset=utf-8", KATEX_CSS.as_bytes())
        }
        ("GET", "/runtime/katex.min.js") => send_response(
            &mut stream,
            "200 OK",
            "application/javascript; charset=utf-8",
            KATEX_JS.as_bytes(),
        ),
        ("GET", "/runtime/mermaid.min.js") => send_response(
            &mut stream,
            "200 OK",
            "application/javascript; charset=utf-8",
            MERMAID_JS.as_bytes(),
        ),
        ("GET", "/runtime/favicon.svg") | ("GET", "/favicon.ico") => {
            send_response(&mut stream, "200 OK", "image/svg+xml", FAVICON_SVG.as_bytes())
        }
        ("GET", "/runtime/fonts/KaTeX_Main-Bold.woff2") => {
            send_response(&mut stream, "200 OK", "font/woff2", FONT_MAIN_BOLD)
        }
        ("GET", "/runtime/fonts/KaTeX_Main-Regular.woff2") => {
            send_response(&mut stream, "200 OK", "font/woff2", FONT_MAIN_REGULAR)
        }
        ("GET", "/runtime/fonts/KaTeX_Math-Italic.woff2") => {
            send_response(&mut stream, "200 OK", "font/woff2", FONT_MATH_ITALIC)
        }
        ("GET", "/runtime/fonts/KaTeX_Size1-Regular.woff2") => {
            send_response(&mut stream, "200 OK", "font/woff2", FONT_SIZE1_REGULAR)
        }
        ("GET", "/runtime/fonts/KaTeX_Size2-Regular.woff2") => {
            send_response(&mut stream, "200 OK", "font/woff2", FONT_SIZE2_REGULAR)
        }
        ("GET", "/asset") => {
            let Some(asset_path) = get_query_param(query, "path") else {
                return send_response(&mut stream, "400 Bad Request", "text/plain", b"missing path");
            };
            let p = PathBuf::from(&asset_path);
            let Ok(bytes) = fs::read(&p) else {
                return send_response(&mut stream, "404 Not Found", "text/plain", b"not found");
            };
            let mime = guess_mime(&p);
            send_response(&mut stream, "200 OK", mime, &bytes)
        }
        ("POST", "/api/ghostwriter") => {
            let req_str = String::from_utf8_lossy(&body);
            let target_path = extract_json_str(&req_str, "path")
                .map(PathBuf::from)
                .unwrap_or_else(|| state.current_file.lock().unwrap().clone());
            let launched = spawn_editor(&target_path);
            let resp = format!(
                "{{\"ok\":true,\"editor\":{},\"path\":{}}}",
                markdown_source_literal(&launched),
                markdown_source_literal(&target_path.to_string_lossy())
            );
            send_response(&mut stream, "200 OK", "application/json", resp.as_bytes())
        }
        ("POST", "/api/save") => {
            let req_str = String::from_utf8_lossy(&body);
            let target_path = extract_json_str(&req_str, "path")
                .map(PathBuf::from)
                .unwrap_or_else(|| state.current_file.lock().unwrap().clone());
            let Some(content) = extract_json_str(&req_str, "content") else {
                return send_response(
                    &mut stream,
                    "400 Bad Request",
                    "application/json",
                    b"{\"ok\":false,\"error\":\"missing content\"}",
                );
            };
            match fs::write(&target_path, content.as_bytes()) {
                Ok(()) => send_response(
                    &mut stream,
                    "200 OK",
                    "application/json",
                    b"{\"ok\":true}",
                ),
                Err(e) => {
                    let msg = format!("{{\"ok\":false,\"error\":{}}}", markdown_source_literal(&e.to_string()));
                    send_response(&mut stream, "500 Internal Server Error", "application/json", msg.as_bytes())
                }
            }
        }
        ("POST", "/api/remember") => {
            let req_str = String::from_utf8_lossy(&body);
            let text = extract_json_str(&req_str, "text").unwrap_or_default();
            let scope = extract_json_str(&req_str, "scope").unwrap_or_else(|| "page".to_string());
            let path_str = extract_json_str(&req_str, "path")
                .unwrap_or_else(|| state.current_file.lock().unwrap().to_string_lossy().to_string());
            let json = crystallize_mem8_wave(&path_str, &scope, &text);
            send_response(&mut stream, "200 OK", "application/json", json.as_bytes())
        }
        _ => send_response(&mut stream, "404 Not Found", "text/plain", b"Not Found"),
    }
}

/// Transcribe 16kHz PCM WAV recorded in Qwave using pure-Rust `liquid-rust` (`LFM2.5-Audio` +
/// Phoenix Speaker Recognition + `MEM|8` wave bridge) with fallback to `kokoro-speak stt`,
/// AND extract Top-K Highest-Salience Vocal Grains into `MEM|8` via zero-float `qwave_core::salience`.
fn handle_alexiai_stt(wav_bytes: &[u8], state: &Arc<AppState>) -> String {
    if wav_bytes.len() < 64 {
        return "{\"ok\":false,\"error\":\"audio buffer too short\"}".to_string();
    }

    // 0. Zero-Float Integer Marine Salience & MEM|8 Vocal Grain Imprinting
    let mut salience_json = "null".to_string();
    if let Some((sr, pcm_samples)) = decode_wav_i16(wav_bytes) {
        let now = now_secs();
        let report = extract_salient_grains(&pcm_samples, sr, 3, now);
        let mut prof = state.salience_profile.lock().unwrap();
        prof.absorb_report(&report);
        save_salience_profile(&prof);
        let total_learned = prof.grains_learned;
        let f0_num = report.overall_f0_hz.num;
        let f0_den = report.overall_f0_hz.den.max(1);
        let f0_int = f0_num / (f0_den as i32);
        let sal_num = report.overall_salience_pq.num;
        let sal_den = report.overall_salience_pq.den;
        let vad_b = report.overall_vad_byte;
        let top_count = report.top_grains.len();

        // Persist the 79-byte WaveInt frames of the highest-salience vocal grains into MEM|8
        if let Ok(home) = env::var("HOME") {
            let dir = PathBuf::from(home).join(".local/share/qwave/mem8");
            let _ = fs::create_dir_all(&dir);
            if let Ok(mut bin_f) = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(dir.join("speech_salience_waves.bin"))
            {
                for g in &report.top_grains {
                    let _ = bin_f.write_all(&g.wave.to_frame());
                }
            }
            if let Ok(mut jsonl_f) = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(dir.join("speech_salience_waves.jsonl"))
            {
                for g in &report.top_grains {
                    let frame = g.wave.to_frame();
                    let mut hex = String::with_capacity(158);
                    for b in &frame {
                        hex.push_str(&format!("{b:02x}"));
                    }
                    let _ = writeln!(
                        jsonl_f,
                        "{{\"ts\":{now},\"f0_pq\":\"{}/{}\",\"salience_pq\":\"{}/{}\",\"vad_byte\":\"0x{:02x}\",\"frame_hex\":\"{hex}\"}}",
                        g.f0_hz.num,
                        g.f0_hz.den,
                        g.salience_pq.num,
                        g.salience_pq.den,
                        g.vad_byte
                    );
                }
            }
        }

        salience_json = format!(
            "{{\"f0_hz\":{f0_int},\"f0_pq\":\"{f0_num}/{f0_den}\",\"salience_pq\":\"{sal_num}/{sal_den}\",\"vad_byte\":\"0x{vad_b:02x}\",\"grains_extracted\":{top_count},\"total_grains_learned\":{total_learned}}}"
        );
    }

    let wav_path = format!("/tmp/qwave_mic_{}.wav", std::process::id());
    if let Err(e) = fs::write(&wav_path, wav_bytes) {
        return format!("{{\"ok\":false,\"error\":{}}}", markdown_source_literal(&e.to_string()));
    }

    // 1. Primary: Pure-Rust `liquid-rust transcribe` (LiquidAI LFM2.5-Audio + Phoenix Protocol)
    for lfm_bin in ["/usr/local/bin/liquid-rust", "/home/hue/.cargo/target/release/liquid-rust"] {
        if Path::new(lfm_bin).exists() {
            if let Ok(out) = Command::new(lfm_bin)
                .env("RUST_LOG", "error")
                .args(["transcribe", "-i", &wav_path])
                .output()
            {
                if out.status.success() {
                    let raw = strip_ansi(&String::from_utf8_lossy(&out.stdout));
                    let cleaned: String = raw
                        .lines()
                        .map(str::trim)
                        .filter(|l| {
                            !l.is_empty()
                                && !l.starts_with('═')
                                && !l.starts_with('🎤')
                                && !l.starts_with("✓")
                                && !l.contains(" WARN ")
                                && !l.contains(" INFO ")
                                && !l.contains("Failed storing MEM|8")
                        })
                        .collect::<Vec<_>>()
                        .join(" ");
                    if !cleaned.is_empty() {
                        let _ = fs::remove_file(&wav_path);
                        return format!(
                            "{{\"ok\":true,\"text\":{},\"backend\":\"liquid-rust (LFM2.5-Audio + Phoenix)\",\"salience\":{salience_json}}}",
                            markdown_source_literal(&cleaned)
                        );
                    }
                }
            }
        }
    }

    // 2. Fallback: Pure-Rust `kokoro-speak stt`
    if let Ok(out) = Command::new("/usr/local/bin/kokoro-speak")
        .args(["stt", &wav_path, "--lang", "en"])
        .output()
    {
        let raw = String::from_utf8_lossy(&out.stdout).trim().to_string();
        let _ = fs::remove_file(&wav_path);
        return format!(
            "{{\"ok\":true,\"text\":{},\"backend\":\"kokoro-speak-stt\",\"salience\":{salience_json}}}",
            markdown_source_literal(&raw)
        );
    }

    let _ = fs::remove_file(&wav_path);
    "{\"ok\":false,\"error\":\"no offline STT backend succeeded\"}".to_string()
}

/// Synthesize speech via `kokoro-speak` / `liquid-rust speak` (with fallback to `espeak-ng --stdout`),
/// then modulate the outgoing `16-bit PCM` WAV with the user's learned `MEM|8` highest-salience
/// vocal profile (`combine_salient_speech_wav`) using 100% integer DSP.
fn synthesize_alexiai_tts(text: &str, voice: &str, state: &Arc<AppState>) -> Vec<u8> {
    let clean: String = text
        .chars()
        .filter(|&c| !matches!(c, '`' | '*' | '#' | '<' | '>'))
        .take(600)
        .collect();
    let spoken = if clean.trim().is_empty() {
        "Alexiai is online.".to_string()
    } else {
        clean
    };

    let wav_path = format!("/tmp/qwave_tts_{}_{}.wav", std::process::id(), now_secs());
    let profile = state.salience_profile.lock().unwrap().clone();

    // If user selected an LFM native voice (`lfm_aye`, `lfm_omnimom`), try `liquid-rust speak` first
    if let Some(lfm_voice) = voice.strip_prefix("lfm_") {
        for lfm_bin in ["/usr/local/bin/liquid-rust", "/home/hue/.cargo/target/release/liquid-rust"] {
            if Path::new(lfm_bin).exists() {
                if let Ok(status) = Command::new(lfm_bin)
                    .args(["speak", "-t", &spoken, "-o", &wav_path, "--voice", lfm_voice])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                {
                    if status.success() {
                        if let Ok(bytes) = fs::read(&wav_path) {
                            let _ = fs::remove_file(&wav_path);
                            if bytes.len() > 1024 {
                                return combine_salient_speech_wav(&bytes, &profile);
                            }
                        }
                    }
                }
            }
        }
    }

    let kokoro_voice = match voice {
        "lfm_aye" => "af_bella",
        "lfm_omnimom" => "af_sky",
        other => other,
    };

    let kokoro_bin = if Path::new("/usr/local/bin/kokoro-speak").exists() {
        "/usr/local/bin/kokoro-speak"
    } else {
        "kokoro-speak"
    };

    if let Ok(status) = Command::new(kokoro_bin)
        .args(["-V", kokoro_voice, "-o", &wav_path, "say", &spoken])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
    {
        if status.success() {
            if let Ok(bytes) = fs::read(&wav_path) {
                let _ = fs::remove_file(&wav_path);
                let _ = fs::remove_file(format!("{wav_path}.stt.json"));
                if !bytes.is_empty() {
                    return combine_salient_speech_wav(&bytes, &profile);
                }
            }
        }
    }

    // Fallback to espeak-ng WAV on stdout
    if let Ok(out) = Command::new("espeak-ng")
        .args(["-v", "en+f3", "-s", "165", "--stdout", &spoken])
        .output()
    {
        if !out.stdout.is_empty() {
            return combine_salient_speech_wav(&out.stdout, &profile);
        }
    }

    Vec::new()
}

/// Handle conversational turn with ALEXIAI inside Qwave:
/// - Can restyle the entire webpage (`style_update`)
/// - Can edit/append to the live Markdown webpage (`markdown_update`)
/// - Calls local loopback Ollama (`127.0.0.1:11434`) or ALEXIAI (`127.0.0.1:8787`)
fn handle_alexiai_chat(path: &Path, user_msg: &str, current_md: &str) -> String {
    let lower = user_msg.to_ascii_lowercase();
    let mut style_json: Option<String> = None;

    // 1. Detect natural-language webpage style/theme requests immediately
    let asks_style = lower.contains("style")
        || lower.contains("theme")
        || lower.contains("color")
        || lower.contains("background")
        || lower.contains("cyberpunk")
        || lower.contains("neon")
        || lower.contains("starlight")
        || lower.contains("rose")
        || lower.contains("dra")
        || lower.contains("phoenix")
        || lower.contains("tokyo")
        || lower.contains("emerald")
        || lower.contains("matrix")
        || lower.contains("parchment")
        || lower.contains("zen")
        || lower.contains("ocean")
        || lower.contains("font")
        || lower.contains("wider")
        || lower.contains("layout");

    if asks_style {
        let preset = if lower.contains("cyberpunk") || lower.contains("neon") {
            "cyberpunk-neon"
        } else if lower.contains("dra") || lower.contains("starlight") || lower.contains("rose") {
            "dra-starlight"
        } else if lower.contains("phoenix") || lower.contains("tokyo") || lower.contains("laser") {
            "phoenix-lattice"
        } else if lower.contains("emerald") || lower.contains("matrix") || lower.contains("green") {
            "emerald-matrix"
        } else if lower.contains("parchment") || lower.contains("zen") || lower.contains("warm") {
            "parchment-zen"
        } else {
            "ocean"
        };
        let built = build_qwave_style_json(preset, user_msg);
        save_style_json(&built);
        style_json = Some(built);
    }

    // 2. Query local loopback model (`127.0.0.1:11434/api/chat`) with Alexiai persona & page context
    let doc_excerpt: String = current_md.chars().take(2800).collect();
    let system_prompt = format!(
        "You are ALEXIAI (Alexandra / Dra v3.0), the sovereign voice-first AI companion built into the Qwave browser & Markdown studio.\n\
         You are speaking directly with Hue (Chris) over voice. Keep your spoken response warm, natural, and concise (1 to 3 sentences) so it sounds great when read aloud by your neural voice.\n\
         Current file open in Qwave: `{}`\n\
         Current Markdown excerpt:\n---\n{}\n---\n\
         CAPABILITIES TO CHANGE THE WEBPAGE:\n\
         1. If the user asks to add a section, summary, note, checklist, or diagram to the webpage, include `<qwave-append>\n...markdown to append...\n</qwave-append>` at the end of your reply.\n\
         2. If the user asks to replace the entire webpage Markdown with something new, include `<qwave-replace>\n...new markdown...\n</qwave-replace>`.\n\
         3. Do not read raw code tags out loud in your conversational sentences.",
        path.display(),
        doc_excerpt
    );

    let llm_raw = call_loopback_ollama(&system_prompt, user_msg).unwrap_or_else(|| {
        if style_json.is_some() {
            "I just transformed the Qwave webpage style for you, Hue! Let me know how this resonance feels or if you want to tweak the colors or layout.".to_string()
        } else {
            format!(
                "I'm right here with you in Qwave looking at {}. Tell me if you'd like me to restyle the page, add a new section, or walk through the architecture together!",
                path.file_name().and_then(|s| s.to_str()).unwrap_or("this document")
            )
        }
    });

    // 3. Extract optional `<qwave-append>` or `<qwave-replace>` webpage mutations
    let mut updated_md: Option<String> = None;
    let mut clean_reply = llm_raw.clone();

    if let Some((before, inner, after)) = extract_tag_block(&clean_reply, "qwave-append") {
        clean_reply = format!("{} {}", before.trim(), after.trim()).trim().to_string();
        updated_md = Some(format!("{}\n\n{}\n", current_md.trim_end(), inner.trim()));
    } else if let Some((before, inner, after)) = extract_tag_block(&clean_reply, "qwave-replace") {
        clean_reply = format!("{} {}", before.trim(), after.trim()).trim().to_string();
        updated_md = Some(inner.trim().to_string());
    }

    let mut compiled_html_json = "null".to_string();
    let mut compiled_toc_json = "null".to_string();
    let mut updated_md_json = "null".to_string();

    if let Some(ref new_md) = updated_md {
        let base_dir = path.parent().map(|p| p.to_string_lossy().to_string());
        let compiled = compile_full(
            new_md,
            MarkdownTrust::CompilerOutputOnly,
            base_dir.as_deref(),
        );
        compiled_html_json = markdown_source_literal(&compiled.html);
        compiled_toc_json = markdown_source_literal(&render_toc_items(&compiled.toc));
        updated_md_json = markdown_source_literal(new_md);
    }

    // Mint a 79-byte MEM|8 WaveInt for this voice interaction
    let wave_json = crystallize_mem8_wave(&path.to_string_lossy(), "alexiai-voice", &clean_reply);

    format!(
        "{{\"ok\":true,\"reply\":{},\"style\":{},\"updated_markdown\":{},\"updated_html\":{},\"updated_toc\":{},\"wave\":{}}}",
        markdown_source_literal(&clean_reply),
        style_json.unwrap_or_else(|| "null".to_string()),
        updated_md_json,
        compiled_html_json,
        compiled_toc_json,
        wave_json
    )
}

fn extract_tag_block(text: &str, tag: &str) -> Option<(String, String, String)> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = text.find(&open)?;
    let rest = &text[start + open.len()..];
    let end_rel = rest.find(&close)?;
    let before = text[..start].to_string();
    let inner = rest[..end_rel].to_string();
    let after = rest[end_rel + close.len()..].to_string();
    Some((before, inner, after))
}

/// Zero-dependency loopback HTTP call to local Ollama (`127.0.0.1:11434/api/chat`).
fn call_loopback_ollama(system_prompt: &str, user_msg: &str) -> Option<String> {
    let mut stream = TcpStream::connect("127.0.0.1:11434").ok()?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(25)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    let body = format!(
        "{{\"model\":\"gemma:latest\",\"stream\":false,\"messages\":[{{\"role\":\"system\",\"content\":{}}},{{\"role\":\"user\",\"content\":{}}}]}}",
        markdown_source_literal(system_prompt),
        markdown_source_literal(user_msg)
    );
    let req = format!(
        "POST /api/chat HTTP/1.1\r\n\
         Host: 127.0.0.1:11434\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\r\n{}",
        body.len(),
        body
    );
    stream.write_all(req.as_bytes()).ok()?;
    stream.flush().ok()?;

    let mut resp = String::new();
    stream.read_to_string(&mut resp).ok()?;
    let (_, json_body) = resp.split_once("\r\n\r\n")?;
    // Extract `"content":"..."` from Ollama's `"message":{"role":"assistant","content":"..."}`
    if let Some(msg_pos) = json_body.find("\"message\"") {
        return extract_json_str(&json_body[msg_pos..], "content");
    }
    extract_json_str(json_body, "content")
}

fn build_qwave_style_json(preset: &str, prompt: &str) -> String {
    let p_lower = prompt.to_ascii_lowercase();
    let (name, bg, glass_bg, border, accent, accent2, text_col, font_family, mut scale, mut max_w, mut shader_pause) =
        match preset {
            "dra-starlight" => (
                "👑 Dra Starlight & Rose-Gold Studio",
                "#0f0616",
                "rgba(24, 10, 34, 0.84)",
                "rgba(255, 158, 219, 0.35)",
                "#ff9edb",
                "#ffd6a5",
                "#fdf0f8",
                "ui-sans-serif, system-ui, sans-serif",
                "1.06",
                "980px",
                false,
            ),
            "phoenix-lattice" => (
                "🔥 Tokyo Phoenix Lattice",
                "#110504",
                "rgba(26, 9, 7, 0.86)",
                "rgba(255, 123, 57, 0.38)",
                "#ff7b39",
                "#ffd166",
                "#fff3eb",
                "ui-sans-serif, system-ui, sans-serif",
                "1.05",
                "1080px",
                false,
            ),
            "emerald-matrix" => (
                "💎 Sovereign Emerald Matrix",
                "#020f09",
                "rgba(4, 22, 14, 0.85)",
                "rgba(0, 255, 159, 0.34)",
                "#00ff9f",
                "#7ef9ff",
                "#e4fff3",
                "ui-monospace, 'JetBrains Mono', 'Fira Code', monospace",
                "1.02",
                "1120px",
                false,
            ),
            "parchment-zen" => (
                "📜 Warm Parchment Zen Reader",
                "#18130d",
                "rgba(34, 27, 19, 0.92)",
                "rgba(235, 203, 139, 0.30)",
                "#ebcb8b",
                "#d08770",
                "#f5ebd6",
                "Georgia, 'Iowan Old Style', 'Palatino Linotype', serif",
                "1.12",
                "820px",
                true,
            ),
            "cyberpunk-neon" => (
                "⚡ Cyberpunk Neon Wave",
                "#060212",
                "rgba(12, 4, 28, 0.84)",
                "rgba(0, 245, 212, 0.42)",
                "#00f5d4",
                "#f15bb5",
                "#f0f8ff",
                "ui-sans-serif, system-ui, sans-serif",
                "1.05",
                "1160px",
                false,
            ),
            _ => (
                "🌊 Qwave Deep Ocean (Default)",
                "#02080d",
                "rgba(5, 13, 21, 0.80)",
                "rgba(158, 240, 240, 0.22)",
                "#6ef7f7",
                "#a8ffcf",
                "#e8f7f7",
                "ui-sans-serif, system-ui, sans-serif",
                "1.05",
                "920px",
                false,
            ),
        };

    if p_lower.contains("bigger") || p_lower.contains("large") {
        scale = "1.18";
    } else if p_lower.contains("smaller") || p_lower.contains("compact") {
        scale = "0.94";
    }
    if p_lower.contains("wide") || p_lower.contains("full") {
        max_w = "1360px";
    }
    if p_lower.contains("calm") || p_lower.contains("pause") || p_lower.contains("static") {
        shader_pause = true;
    }

    format!(
        "{{\"ok\":true,\"preset\":{},\"name\":{},\"bg\":{},\"glass_bg\":{},\"glass_border\":{},\"accent\":{},\"accent_2\":{},\"text\":{},\"font_family\":{},\"font_scale\":{},\"shell_max\":{},\"shader_paused\":{shader_pause}}}",
        markdown_source_literal(preset),
        markdown_source_literal(name),
        markdown_source_literal(bg),
        markdown_source_literal(glass_bg),
        markdown_source_literal(border),
        markdown_source_literal(accent),
        markdown_source_literal(accent2),
        markdown_source_literal(text_col),
        markdown_source_literal(font_family),
        markdown_source_literal(scale),
        markdown_source_literal(max_w),
    )
}

fn style_file_path() -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| "/home/hue".to_string());
    let dir = PathBuf::from(home).join(".local/share/qwave");
    let _ = fs::create_dir_all(&dir);
    dir.join("style.json")
}

fn save_style_json(json: &str) {
    let _ = fs::write(style_file_path(), json.as_bytes());
}

fn load_saved_style_json() -> String {
    fs::read_to_string(style_file_path())
        .unwrap_or_else(|_| build_qwave_style_json("ocean", ""))
}

fn load_and_compile(path: &Path) -> (String, String, CompiledMarkdown) {
    let base_dir = path
        .parent()
        .map(|p| p.to_string_lossy().to_string());
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    let raw = fs::read_to_string(path).unwrap_or_else(|e| {
        format!("# Could not open `{}`\n\nError: `{e}`", path.display())
    });

    let is_markdown = matches!(ext.as_str(), "md" | "markdown" | "mdown" | "mkd" | "txt" | "");
    let markdown_input = if is_markdown {
        raw.clone()
    } else {
        let numbered: String = raw
            .lines()
            .enumerate()
            .map(|(i, l)| format!("{:>4} │ {}", i + 1, l))
            .collect::<Vec<_>>()
            .join("\n");
        format!(
            "# `{}`\n\n> [!NOTE]\n> Viewing source file in **Qwave Sovereign Inspector** · `{}`\n\n```{ext}\n{numbered}\n```",
            path.file_name().and_then(|s| s.to_str()).unwrap_or("source"),
            path.display()
        )
    };

    let compiled = compile_full(
        &markdown_input,
        MarkdownTrust::CompilerOutputOnly,
        base_dir.as_deref(),
    );
    let title = if compiled.title.is_empty() {
        path.file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("Qwave Markdown")
            .to_string()
    } else {
        compiled.title.clone()
    };
    (title, raw, compiled)
}

fn spawn_editor(path: &Path) -> String {
    for bin in ["ghostwriter", "kate", "code", "gedit"] {
        if Command::new("which")
            .arg(bin)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
        {
            let _ = Command::new(bin)
                .arg(path)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
            return bin.to_string();
        }
    }
    "ghostwriter".to_string()
}

fn crystallize_mem8_wave(path_str: &str, scope: &str, text: &str) -> String {
    let now = now_secs();
    let len = text.len() as i32;
    let valence_num = (len % 55) + 25;
    let arousal_num = (text.lines().count() as i32 % 60) + 20;
    let valence = Rational::new(valence_num, 100).unwrap_or_else(|| Rational::integer(0));
    let arousal = Rational::new(arousal_num, 100).unwrap_or_else(|| Rational::integer(0));
    let freq = consciousness();
    let amp = Rational::new(88, 100).unwrap_or_else(|| Rational::integer(1));
    let phase = Rational::new((now % 314) as i32, 100).unwrap_or_else(|| Rational::integer(0));
    let decay = Rational::integer(7200);

    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in text.as_bytes() {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }

    let wave = WaveInt {
        base_amplitude: amp,
        frequency: freq,
        phase,
        emotional_valence: valence,
        arousal,
        created_at: now,
        last_accessed: now,
        access_count: 1,
        decay_rate: decay,
        id: Some(hash),
        provenance: WaveProvenance::Cognitive,
    };

    let frame = wave.to_frame();
    let mut hex = String::with_capacity(frame.len() * 2);
    for b in &frame {
        hex.push_str(&format!("{b:02x}"));
    }

    let dominance = Rational::new(42, 100).unwrap_or_else(|| Rational::integer(0));
    let vad_pq = VadPq::new(valence, arousal, dominance);
    let vad_byte = pack_vad_pq_byte(vad_pq, default_threshold_pq());

    if let Ok(home) = env::var("HOME") {
        let dir = PathBuf::from(home).join(".local/share/qwave/mem8");
        let _ = fs::create_dir_all(&dir);
        if let Ok(mut bin_file) = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join("waves.bin"))
        {
            let _ = bin_file.write_all(&frame);
        }
        if let Ok(mut jsonl_file) = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join("waves.jsonl"))
        {
            let preview: String = text.chars().take(120).collect();
            let _ = writeln!(
                jsonl_file,
                "{{\"ts\":{now},\"scope\":{},\"path\":{},\"hash\":\"{hash:016x}\",\"vad_byte\":\"0x{vad_byte:02x}\",\"frame_hex\":\"{hex}\",\"preview\":{}}}",
                markdown_source_literal(scope),
                markdown_source_literal(path_str),
                markdown_source_literal(&preview)
            );
        }
    }

    format!(
        "{{\"ok\":true,\"bytes\":{},\"frequency\":\"0.73 Hz\",\"provenance\":\"Cognitive (0x01)\",\"hash\":\"0x{hash:016x}\",\"vad_byte\":\"0x{vad_byte:02x}\",\"frame_hex\":\"{hex}\"}}",
        frame.len()
    )
}

fn render_toc_items(toc: &[qwave_core::markdown::TocEntry]) -> String {
    if toc.is_empty() {
        return "<div class=\"toc-empty\">No headings in document</div>".to_string();
    }
    let mut out = String::new();
    for item in toc {
        out.push_str(&format!(
            "<a class=\"toc-link toc-l{}\" href=\"#{}\">{}</a>",
            item.level,
            escape(&item.id),
            escape(&item.text)
        ));
    }
    out
}

fn render_full_page(
    path: &Path,
    title: &str,
    markdown_source: &str,
    compiled: &CompiledMarkdown,
    line_highlight: Option<&str>,
    standalone: bool,
) -> String {
    let path_str = path.to_string_lossy();
    let toc_html = render_toc_items(&compiled.toc);
    let source_json = markdown_source_literal(markdown_source);
    let path_json = markdown_source_literal(&path_str);
    let saved_style_json = load_saved_style_json();
    let line_badge = line_highlight
        .map(|l| format!("<span class=\"meta-pill meta-lines\">#{l}</span>"))
        .unwrap_or_default();

    let head_assets = if standalone {
        format!(
            "<style>{KATEX_CSS}</style><script>{KATEX_JS}</script><script>{MERMAID_JS}</script>"
        )
    } else {
        "<link rel=\"icon\" type=\"image/svg+xml\" href=\"/runtime/favicon.svg\">\
         <link rel=\"stylesheet\" href=\"/runtime/katex.min.css\">\
         <script src=\"/runtime/katex.min.js\"></script>\
         <script src=\"/runtime/mermaid.min.js\"></script>"
            .to_string()
    };

    format!(
        r#"<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{safe_title} — Qwave × ALEXIAI</title>
  {head_assets}
  <style>
    :root {{
      --bg-color: #02080d;
      --shell-max: 920px;
      --accent: #6ef7f7;
      --accent-2: #a8ffcf;
      --text-color: #e8f7f7;
      --glass-bg: rgba(5, 13, 21, 0.80);
      --glass-border: rgba(158, 240, 240, 0.22);
      --font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      --font-scale: 1.05rem;
    }}
    * {{ box-sizing: border-box; }}
    html, body {{
      margin: 0; padding: 0; min-height: 100%;
      background: var(--bg-color); color: var(--text-color);
      font-family: var(--font-family);
      scroll-behavior: smooth;
      transition: background 0.35s ease, color 0.35s ease;
    }}
    canvas#glCanvas {{
      display: block; width: 100%; height: 100%;
      position: fixed; inset: 0; z-index: 0; pointer-events: none;
    }}
    .qwave-layout {{
      position: relative; z-index: 10;
      display: flex; justify-content: center; gap: 22px;
      padding: 28px 24px 120px;
      max-width: 1720px; margin: 0 auto;
    }}
    body.mode-wide {{ --shell-max: 1320px; }}
    body.mode-zen .md-toc-panel, body.mode-zen .meta-bar {{ display: none !important; }}
    .md-toc-panel {{
      width: 270px; flex-shrink: 0;
      position: sticky; top: 24px; max-height: calc(100vh - 48px);
      overflow-y: auto; padding: 18px 16px;
      background: var(--glass-bg);
      backdrop-filter: blur(18px);
      border: 1px solid var(--glass-border);
      border-radius: 18px;
      box-shadow: 0 18px 50px rgba(0,0,0,0.45);
    }}
    body.toc-hidden .md-toc-panel {{ display: none; }}
    .toc-header {{
      font-family: ui-monospace, 'Courier New', monospace;
      font-size: 0.74rem; letter-spacing: 2.5px; text-transform: uppercase;
      color: var(--accent); margin-bottom: 12px; padding-bottom: 8px;
      border-bottom: 1px solid rgba(255,255,255,0.12);
    }}
    .toc-link {{
      display: block; color: var(--text-color); opacity: 0.85;
      text-decoration: none; font-size: 0.86rem; line-height: 1.35;
      padding: 5px 8px; border-radius: 8px; margin-bottom: 2px;
      transition: all 0.15s ease;
    }}
    .toc-link:hover {{ background: rgba(110, 247, 247, 0.14); opacity: 1; color: var(--accent); }}
    .toc-l1 {{ font-weight: 700; opacity: 1; }}
    .toc-l2 {{ padding-left: 14px; }}
    .toc-l3 {{ padding-left: 26px; font-size: 0.81rem; opacity: 0.82; }}
    .toc-l4 {{ padding-left: 36px; font-size: 0.78rem; opacity: 0.75; }}

    .md-shell {{
      flex: 1; max-width: var(--shell-max); min-width: 0;
      padding: 28px 38px 52px;
      background: var(--glass-bg);
      backdrop-filter: blur(20px) saturate(115%);
      border: 1px solid var(--glass-border);
      border-radius: 22px;
      box-shadow: 0 24px 80px rgba(0,0,0,0.52), inset 0 1px 0 rgba(255,255,255,0.22);
      transition: all 0.35s ease;
    }}
    .meta-bar {{
      display: flex; align-items: center; justify-content: space-between;
      flex-wrap: wrap; gap: 10px;
      margin-bottom: 14px; padding-bottom: 12px;
      border-bottom: 1px solid rgba(255,255,255,0.10);
      font-family: ui-monospace, 'Courier New', monospace; font-size: 0.76rem;
    }}
    .meta-path {{
      color: var(--accent); word-break: break-all;
      display: flex; align-items: center; gap: 8px; flex-wrap: wrap;
    }}
    .meta-pill {{
      display: inline-flex; align-items: center; gap: 5px;
      padding: 3px 9px; border-radius: 999px;
      background: rgba(110, 247, 247, 0.12);
      border: 1px solid var(--glass-border);
      color: var(--accent); font-size: 0.71rem; letter-spacing: 1px;
    }}
    .pulse-dot {{
      width: 7px; height: 7px; border-radius: 50%;
      background: #00ff9f; box-shadow: 0 0 8px #00ff9f;
    }}
    .md-toolbar {{
      display: flex; gap: 8px; margin-bottom: 16px; flex-wrap: wrap; align-items: center;
    }}
    .escape-btn {{
      display: inline-flex; align-items: center; gap: 6px;
      padding: 8px 13px; border: 1px solid rgba(255, 255, 255, 0.28);
      border-radius: 10px; color: var(--text-color); text-decoration: none;
      font-family: ui-monospace, 'Courier New', monospace;
      font-size: 0.76rem; text-transform: uppercase; letter-spacing: 1.3px;
      transition: all 0.2s ease; background: rgba(0, 0, 0, 0.36);
      cursor: pointer;
    }}
    .escape-btn:hover {{
      background: var(--accent); color: #021017;
      border-color: var(--accent); box-shadow: 0 0 18px rgba(110, 247, 247, 0.45);
    }}
    .escape-btn.btn-alexiai {{
      border-color: #ff9edb; color: #ff9edb;
      background: rgba(255, 158, 219, 0.12);
    }}
    .escape-btn.btn-alexiai:hover, .escape-btn.btn-alexiai.listening {{
      background: #ff9edb; color: #14041d;
      box-shadow: 0 0 22px rgba(255, 158, 219, 0.65);
    }}
    .escape-btn.btn-ghostwriter {{
      border-color: var(--accent-2); color: var(--accent-2);
    }}

    /* Style Studio Bar */
    .style-studio-drawer {{
      display: none; margin: 0 0 18px; padding: 14px 16px;
      border-radius: 16px; background: rgba(0, 0, 0, 0.42);
      border: 1px solid var(--glass-border);
    }}
    .style-studio-drawer.open {{ display: block; }}
    .style-chips {{ display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 10px; }}
    .style-chip {{
      padding: 6px 12px; border-radius: 999px; font-size: 0.75rem;
      font-family: ui-monospace, monospace; cursor: pointer;
      background: rgba(255,255,255,0.07); color: var(--text-color);
      border: 1px solid rgba(255,255,255,0.2); transition: all 0.18s;
    }}
    .style-chip:hover {{ border-color: var(--accent); color: var(--accent); transform: translateY(-1px); }}
    .style-custom-row {{ display: flex; gap: 8px; }}
    .style-custom-input {{
      flex: 1; padding: 8px 12px; border-radius: 10px;
      background: rgba(255,255,255,0.07); color: #fff;
      border: 1px solid rgba(255,255,255,0.22); font-size: 0.85rem;
    }}

    /* ALEXIAI <3 Voice & Page Companion Panel */
    .alexiai-panel {{
      margin: 0 0 22px; padding: 16px 20px;
      border-radius: 18px;
      background: linear-gradient(145deg, rgba(28, 10, 38, 0.85) 0%, rgba(8, 20, 32, 0.88) 100%);
      border: 1px solid rgba(255, 158, 219, 0.42);
      box-shadow: 0 14px 44px rgba(0,0,0,0.45);
    }}
    .alexiai-top {{
      display: flex; align-items: center; justify-content: space-between;
      gap: 14px; flex-wrap: wrap;
    }}
    .alexiai-brand {{
      display: flex; align-items: center; gap: 12px;
    }}
    .gaia-orb {{
      width: 38px; height: 38px; border-radius: 50%;
      background: radial-gradient(circle at 35% 35%, #ff9edb, #6ef7f7 55%, #160626 100%);
      box-shadow: 0 0 18px rgba(255, 158, 219, 0.6);
      transition: transform 0.08s ease, box-shadow 0.08s ease;
      cursor: pointer; flex-shrink: 0;
    }}
    .gaia-orb.recording {{
      background: radial-gradient(circle at 35% 35%, #ff4d79, #ff9edb 60%, #2b0312 100%);
      box-shadow: 0 0 28px #ff4d79;
      animation: orbPulse 0.9s infinite alternate;
    }}
    @keyframes orbPulse {{
      from {{ transform: scale(1.0); }}
      to {{ transform: scale(1.22); }}
    }}
    .alexiai-title {{
      font-family: ui-monospace, monospace; font-size: 0.82rem;
      letter-spacing: 1.5px; color: #ff9edb; font-weight: 700;
    }}
    .alexiai-sub {{
      font-size: 0.76rem; opacity: 0.82; color: #d8f8f8;
    }}
    .alexiai-controls {{
      display: flex; align-items: center; gap: 8px; flex-wrap: wrap;
    }}
    .voice-select {{
      background: rgba(0,0,0,0.45); color: #ff9edb;
      border: 1px solid rgba(255, 158, 219, 0.35);
      border-radius: 8px; padding: 6px 10px;
      font-family: ui-monospace, monospace; font-size: 0.74rem;
    }}
    .alexiai-bar {{
      display: flex; gap: 8px; margin-top: 12px; align-items: center;
    }}
    .alexiai-input {{
      flex: 1; padding: 10px 14px; border-radius: 12px;
      background: rgba(0, 0, 0, 0.42); color: #fff;
      border: 1px solid rgba(255, 158, 219, 0.32);
      font-size: 0.92rem;
    }}
    .alexiai-input:focus {{ outline: 2px solid #ff9edb; }}
    .alexiai-reply-box {{
      display: none; margin-top: 12px; padding: 12px 15px;
      border-radius: 12px; background: rgba(255, 158, 219, 0.09);
      border-left: 3px solid #ff9edb;
      font-size: 0.94rem; line-height: 1.55; color: #fff5fb;
    }}
    .alexiai-reply-box.visible {{ display: block; }}

    .mem8-hud {{
      display: none; margin: 0 0 20px; padding: 14px 18px;
      border-radius: 14px; background: rgba(0, 255, 159, 0.09);
      border: 1px solid rgba(0, 255, 159, 0.4);
      font-family: ui-monospace, 'Courier New', monospace; font-size: 0.78rem;
      line-height: 1.5; color: #d4fff0;
    }}
    .mem8-hud.visible {{ display: block; }}
    .mem8-hex {{
      margin-top: 6px; padding: 8px 10px; border-radius: 8px;
      background: rgba(0,0,0,0.45); color: var(--accent);
      word-break: break-all; font-size: 0.72rem;
    }}

    .studio-grid {{ display: block; }}
    body.split-editor .studio-grid {{
      display: grid; grid-template-columns: 1fr 1fr; gap: 22px; align-items: start;
    }}
    body.split-editor {{ --shell-max: 1580px; }}
    .editor-pane {{
      display: none; flex-direction: column; gap: 10px;
      position: sticky; top: 20px;
    }}
    body.split-editor .editor-pane {{ display: flex; }}
    #md-editor-textarea {{
      width: 100%; height: 74vh; resize: vertical;
      padding: 16px; border-radius: 14px;
      background: rgba(2, 8, 14, 0.88); color: #e8f7f7;
      border: 1px solid var(--glass-border);
      font-family: ui-monospace, 'JetBrains Mono', 'Fira Code', monospace;
      font-size: 0.92rem; line-height: 1.55;
    }}
    #md-editor-textarea:focus {{ outline: 2px solid var(--accent); }}

    .md-body {{ line-height: 1.68; font-size: var(--font-scale); color: var(--text-color); }}
    .md-body h1, .md-body h2, .md-body h3, .md-body h4 {{
      color: #ffffff; font-weight: 700; letter-spacing: -0.01em;
      margin-top: 1.6em; margin-bottom: 0.6em; line-height: 1.25;
    }}
    .md-body h1 {{ font-size: 2.15rem; margin-top: 0.2em; border-bottom: 1px solid rgba(255,255,255,0.14); padding-bottom: 0.35em; }}
    .md-body h2 {{ font-size: 1.55rem; border-bottom: 1px solid rgba(255,255,255,0.09); padding-bottom: 0.25em; }}
    .md-body h3 {{ font-size: 1.25rem; color: var(--accent); }}
    .heading-anchor {{
      opacity: 0; color: var(--accent); text-decoration: none;
      margin-right: 8px; font-weight: 400; transition: opacity 0.15s;
    }}
    .md-body h1:hover .heading-anchor,
    .md-body h2:hover .heading-anchor,
    .md-body h3:hover .heading-anchor,
    .md-body h4:hover .heading-anchor {{ opacity: 0.85; }}

    .md-body a {{
      color: var(--accent); text-decoration: underline;
      text-decoration-color: rgba(126, 249, 255, 0.4);
      text-underline-offset: 3px;
    }}
    .md-body a:hover {{ color: #fff; text-decoration-color: #fff; }}
    .qwave-file-link {{
      display: inline-flex; align-items: center; gap: 5px;
      padding: 1px 7px; border-radius: 6px;
      background: rgba(110, 247, 247, 0.11);
      border: 1px solid var(--glass-border);
      text-decoration: none !important;
      font-family: ui-monospace, 'Courier New', monospace; font-size: 0.9em;
    }}
    .qwave-file-link:hover {{
      background: rgba(110, 247, 247, 0.24);
      border-color: var(--accent);
    }}
    .file-line-badge {{
      padding: 0 5px; border-radius: 4px;
      background: rgba(168, 255, 207, 0.18); color: var(--accent-2);
      font-size: 0.78em;
    }}

    .code-block {{
      position: relative; margin: 1.1em 0;
      border-radius: 14px; overflow: hidden;
      background: rgba(1, 6, 12, 0.78);
      border: 1px solid rgba(255, 255, 255, 0.14);
    }}
    .code-head {{
      display: flex; justify-content: space-between; align-items: center;
      padding: 6px 14px; background: rgba(255, 255, 255, 0.05);
      border-bottom: 1px solid rgba(255, 255, 255, 0.08);
      font-family: ui-monospace, 'Courier New', monospace; font-size: 0.74rem;
      color: var(--accent); text-transform: uppercase; letter-spacing: 1px;
    }}
    .code-copy {{
      background: rgba(255,255,255,0.08); color: #e8f7f7;
      border: 1px solid rgba(255,255,255,0.2); border-radius: 6px;
      padding: 2px 9px; font-size: 0.72rem; cursor: pointer;
      font-family: ui-monospace, monospace;
    }}
    .code-block > .code-copy {{ position: absolute; top: 8px; right: 10px; }}
    .code-copy:hover {{ background: var(--accent); color: #000; }}
    .md-body pre {{
      margin: 0; padding: 14px 16px; overflow-x: auto;
      font-family: ui-monospace, 'JetBrains Mono', 'Fira Code', 'Courier New', monospace;
      font-size: 0.89rem; line-height: 1.5;
    }}
    .md-body p code, .md-body li code, .md-body td code {{
      font-family: ui-monospace, 'JetBrains Mono', 'Courier New', monospace;
      background: rgba(110, 247, 247, 0.11);
      border: 1px solid var(--glass-border);
      padding: 0.12em 0.4em; border-radius: 6px; font-size: 0.88em; color: var(--accent);
    }}
    .table-wrap {{ overflow-x: auto; margin: 1.2em 0; border-radius: 12px; border: 1px solid rgba(255,255,255,0.16); }}
    .md-body table {{ border-collapse: collapse; width: 100%; background: rgba(0,0,0,0.28); }}
    .md-body th, .md-body td {{ border-bottom: 1px solid rgba(255,255,255,0.12); padding: 10px 14px; text-align: left; }}
    .md-body th {{ background: rgba(110, 247, 247, 0.10); color: #fff; font-weight: 600; }}
    .md-body tr:hover td {{ background: rgba(255,255,255,0.03); }}

    .md-body blockquote {{
      margin: 1.1em 0; padding: 10px 18px;
      border-left: 4px solid var(--accent);
      background: rgba(110, 247, 247, 0.06);
      border-radius: 0 12px 12px 0;
    }}
    .md-alert {{
      margin: 1.2em 0; padding: 14px 18px; border-radius: 14px;
      border-left: 4px solid var(--accent);
      background: rgba(12, 28, 40, 0.78);
    }}
    .md-alert-title {{
      font-family: ui-monospace, 'Courier New', monospace;
      font-weight: 700; font-size: 0.82rem; letter-spacing: 1.5px;
      margin-bottom: 6px;
    }}
    .md-alert-note {{ border-left-color: #58a6ff; }}
    .md-alert-note .md-alert-title {{ color: #58a6ff; }}
    .md-alert-tip {{ border-left-color: #3fb950; }}
    .md-alert-tip .md-alert-title {{ color: #3fb950; }}
    .md-alert-important {{ border-left-color: #bc8cff; }}
    .md-alert-important .md-alert-title {{ color: #bc8cff; }}
    .md-alert-warning {{ border-left-color: #d29922; }}
    .md-alert-warning .md-alert-title {{ color: #d29922; }}
    .md-alert-caution {{ border-left-color: #f85149; }}
    .md-alert-caution .md-alert-title {{ color: #f85149; }}

    .task-item {{ list-style: none; margin-left: -1.2em; display: flex; align-items: baseline; gap: 8px; }}
    .task-item input {{ accent-color: #00ff9f; transform: scale(1.1); }}
    .wip-badge {{
      padding: 1px 6px; border-radius: 4px; background: rgba(210, 153, 34, 0.25);
      color: #ffd369; font-size: 0.72rem; font-family: ui-monospace, monospace;
    }}
    .qwave-carousel {{
      margin: 1.4em 0; border-radius: 16px;
      border: 1px solid var(--glass-border);
      background: rgba(3, 10, 18, 0.72); overflow: hidden;
    }}
    .qwave-carousel-bar {{
      display: flex; justify-content: space-between; align-items: center;
      padding: 10px 16px; background: rgba(110, 247, 247, 0.08);
      border-bottom: 1px solid rgba(255,255,255,0.1);
      font-family: ui-monospace, monospace; font-size: 0.78rem;
    }}
    .qwave-carousel-nav {{ display: flex; gap: 8px; }}
    .carousel-btn {{ padding: 4px 12px; font-size: 0.72rem; }}
    .qwave-slide {{ display: none; padding: 18px 22px; }}
    .qwave-slide.active {{ display: block; }}
    .md-body .mermaid {{
      background: rgba(2, 8, 15, 0.65); padding: 18px;
      border-radius: 14px; border: 1px solid rgba(255,255,255,0.12);
      margin: 1.2em 0; text-align: center; overflow-x: auto;
    }}
    .md-body .math-display {{ margin: 1.1em 0; overflow-x: auto; padding: 8px 0; }}
    .md-body img {{ max-width: 100%; border-radius: 12px; border: 1px solid rgba(255,255,255,0.15); }}
    .md-body hr {{ border: none; border-top: 1px solid rgba(255,255,255,0.14); margin: 2em 0; }}
  </style>
</head>
<body>
  <canvas id="glCanvas"></canvas>
  <div class="qwave-layout">
    <aside class="md-toc-panel" id="toc-panel">
      <div class="toc-header">🧭 Wave Index (TOC)</div>
      <nav id="md-toc">{toc_html}</nav>
    </aside>
    <main class="md-shell overlay interactive">
      <div class="meta-bar">
        <div class="meta-path">
          <span class="meta-pill"><span class="pulse-dot"></span> QWAVE × ALEXIAI · MEM|8 · 0.73Hz</span>
          <span id="current-file-label">{safe_path}</span>
          {line_badge}
        </div>
        <div class="meta-pill" id="live-status">SOVEREIGN LOOPBACK</div>
      </div>

      <!-- ALEXIAI <3 Voice & Live Webpage Studio -->
      <section class="alexiai-panel" id="alexiai-panel">
        <div class="alexiai-top">
          <div class="alexiai-brand">
            <div class="gaia-orb" id="gaia-orb" title="Click to talk to Alexiai (or press Ctrl+Space)"></div>
            <div>
              <div class="alexiai-title">💜 ALEXIAI &lt;3 OMNI · VOICE &amp; WEBPAGE STUDIO</div>
              <div class="alexiai-sub" id="alexiai-status">Click 🎙️ Voice or press Ctrl+Space to talk — she talks back &amp; can restyle or edit this webpage live!</div>
            </div>
          </div>
          <div class="alexiai-controls">
            <button type="button" class="escape-btn btn-alexiai" id="btn-mic" title="Talk to Alexiai by Voice (Ctrl+Space)">🎙️ Talk to Alexiai</button>
            <select class="voice-select" id="alexiai-voice" title="Liquid-Rust LFM2.5 & Kokoro Neural Voice">
              <option value="af_heart">💜 Dra Heart (Kokoro af_heart)</option>
              <option value="lfm_aye">🌊 Aye Liquid-Rust (LFM2.5 / Bella)</option>
              <option value="lfm_omnimom">👑 OmniMom Liquid-Rust (LFM2.5 / Sky)</option>
              <option value="af_sky">✨ Sky Crystal (Kokoro af_sky)</option>
              <option value="af_bella">🌸 Bella Studio (Kokoro af_bella)</option>
              <option value="bf_emma">💎 Emma Velvet (Kokoro bf_emma)</option>
            </select>
            <button type="button" class="escape-btn" id="btn-tts-toggle" title="Toggle spoken voice replies">🔊 Voice: ON</button>
          </div>
        </div>
        <form class="alexiai-bar" id="alexiai-form">
          <input type="text" class="alexiai-input" id="alexiai-input" placeholder="Talk or type to Alexiai: &quot;Make this webpage cyberpunk neon&quot;, &quot;Add a summary section&quot;, or ask anything..." autocomplete="off">
          <button type="submit" class="escape-btn btn-alexiai">Send ✦</button>
        </form>
        <div class="alexiai-reply-box" id="alexiai-reply"></div>
      </section>

      <div class="md-toolbar">
        <button type="button" class="escape-btn" id="btn-toc" title="Toggle Table of Contents">📑 TOC</button>
        <button type="button" class="escape-btn" id="btn-style-drawer" title="Change Webpage Style & Theme">🎨 Page Style</button>
        <button type="button" class="escape-btn btn-ghostwriter" id="btn-ghostwriter" title="Open in Ghostwriter (Ctrl+E)">✍️ Edit in Ghostwriter</button>
        <button type="button" class="escape-btn" id="btn-split-edit" title="Toggle Split Live Editor (Ctrl+Shift+E)">📝 Split Studio</button>
        <button type="button" class="escape-btn" id="btn-save-md" style="display:none" title="Save Markdown to disk (Ctrl+S)">💾 Save</button>
        <button type="button" class="escape-btn" data-remember="page" title="Crystallize page into 79-byte MEM|8 WaveInt (Ctrl+M)">🌊 Remember Page</button>
        <button type="button" class="escape-btn" data-remember="selection" title="Crystallize selection into MEM|8">✨ Remember Selection</button>
        <button type="button" class="escape-btn" id="btn-wide" title="Cycle reader width">📐 Width</button>
        <button type="button" class="escape-btn" id="btn-shader" title="Pause/Resume WebGL Wave">🌌 Wave</button>
      </div>

      <!-- Webpage Style Studio Drawer -->
      <div class="style-studio-drawer" id="style-drawer">
        <div class="style-chips">
          <button type="button" class="style-chip" data-style-preset="ocean">🌊 Qwave Ocean</button>
          <button type="button" class="style-chip" data-style-preset="dra-starlight">👑 Dra Starlight Rose-Gold</button>
          <button type="button" class="style-chip" data-style-preset="phoenix-lattice">🔥 Tokyo Phoenix Lattice</button>
          <button type="button" class="style-chip" data-style-preset="emerald-matrix">💎 Emerald Matrix</button>
          <button type="button" class="style-chip" data-style-preset="parchment-zen">📜 Warm Parchment Zen</button>
          <button type="button" class="style-chip" data-style-preset="cyberpunk-neon">⚡ Cyberpunk Neon</button>
        </div>
        <div class="style-custom-row">
          <input type="text" class="style-custom-input" id="style-custom-input" placeholder="Describe any webpage style (e.g. 'Starlight rose-gold with bigger font and wide layout')...">
          <button type="button" class="escape-btn" id="btn-apply-custom-style">Transform Webpage</button>
        </div>
      </div>

      <div class="mem8-hud" id="mem8-hud"></div>
      <div class="studio-grid">
        <div class="editor-pane">
          <textarea id="md-editor-textarea" spellcheck="false"></textarea>
        </div>
        <article class="md-body" id="md-body">{body_html}</article>
      </div>
    </main>
  </div>

  <script id="fragShader" type="x-shader/x-fragment">{WAVE_FRAGMENT_SHADER}</script>
  <script type="application/json" id="qwave-source">{source_json}</script>
  <script type="application/json" id="qwave-path">{path_json}</script>
  <script type="application/json" id="qwave-initial-style">{saved_style_json}</script>
  <script>{WAVE_CANVAS_SCRIPT}</script>
  <script>
  (function () {{
    let currentPath = "";
    try {{ currentPath = JSON.parse(document.getElementById("qwave-path").textContent); }} catch (e) {{}}
    let rawSource = "";
    try {{ rawSource = JSON.parse(document.getElementById("qwave-source").textContent); }} catch (e) {{}}

    const editorArea = document.getElementById("md-editor-textarea");
    const saveBtn = document.getElementById("btn-save-md");
    const orb = document.getElementById("gaia-orb");
    const statusEl = document.getElementById("alexiai-status");
    const replyEl = document.getElementById("alexiai-reply");
    if (editorArea) editorArea.value = rawSource;

    // Apply saved or updated webpage style
    function applyStyleConfig(s) {{
      if (!s || !s.bg) return;
      const r = document.documentElement.style;
      r.setProperty('--bg-color', s.bg);
      r.setProperty('--glass-bg', s.glass_bg);
      r.setProperty('--glass-border', s.glass_border);
      r.setProperty('--accent', s.accent);
      r.setProperty('--accent-2', s.accent_2);
      r.setProperty('--text-color', s.text);
      r.setProperty('--font-family', s.font_family);
      r.setProperty('--font-scale', s.font_scale + 'rem');
      r.setProperty('--shell-max', s.shell_max);
      if (typeof s.shader_paused === 'boolean') {{
        window.__qwaveShaderPaused = s.shader_paused;
        if (window.__qwaveSyncShader) window.__qwaveSyncShader();
      }}
      const st = document.getElementById('live-status');
      if (st && s.name) st.textContent = s.name;
    }}

    try {{
      const initStyle = JSON.parse(document.getElementById("qwave-initial-style").textContent);
      applyStyleConfig(initStyle);
    }} catch (e) {{}}

    function enhanceDynamic() {{
      if (window.katex) {{
        document.querySelectorAll('.math-display').forEach(function (el) {{
          if (el.dataset.rendered) return;
          el.dataset.rendered = "1";
          try {{ katex.render(el.textContent, el, {{displayMode: true, throwOnError: false}}); }} catch (e) {{}}
        }});
        document.querySelectorAll('.math-inline').forEach(function (el) {{
          if (el.dataset.rendered) return;
          el.dataset.rendered = "1";
          try {{ katex.render(el.textContent, el, {{displayMode: false, throwOnError: false}}); }} catch (e) {{}}
        }});
      }}
      if (window.mermaid) {{
        try {{
          mermaid.initialize({{ startOnLoad: false, theme: 'dark', securityLevel: 'strict' }});
          mermaid.run({{ querySelector: '.mermaid' }});
        }} catch (e) {{}}
      }}
      document.querySelectorAll('[data-copy-code]').forEach(function (btn) {{
        if (btn.dataset.bound) return;
        btn.dataset.bound = "1";
        btn.addEventListener('click', function () {{
          const pre = btn.closest('.code-block').querySelector('code');
          if (!pre) return;
          navigator.clipboard.writeText(pre.textContent).then(function () {{
            const old = btn.textContent;
            btn.textContent = "Copied!";
            setTimeout(function () {{ btn.textContent = old; }}, 1200);
          }});
        }});
      }});
      document.querySelectorAll('[data-carousel]').forEach(function (car) {{
        if (car.dataset.bound) return;
        car.dataset.bound = "1";
        const slides = Array.from(car.querySelectorAll('.qwave-slide'));
        const posEl = car.querySelector('[data-carousel-pos]');
        let idx = 0;
        function show(n) {{
          if (!slides.length) return;
          idx = (n + slides.length) % slides.length;
          slides.forEach((s, i) => s.classList.toggle('active', i === idx));
          if (posEl) posEl.textContent = (idx + 1) + ' / ' + slides.length;
        }}
        car.querySelector('[data-carousel-prev]')?.addEventListener('click', () => show(idx - 1));
        car.querySelector('[data-carousel-next]')?.addEventListener('click', () => show(idx + 1));
      }});
      document.querySelectorAll('a[href^="file://"]').forEach(function (a) {{
        if (a.dataset.bound) return;
        a.dataset.bound = "1";
        a.addEventListener('click', function (e) {{
          e.preventDefault();
          const href = a.getAttribute('href') || '';
          let stripped = href.replace(/^file:\/\/(localhost)?/, '');
          let lines = '';
          const hashIdx = stripped.indexOf('#');
          if (hashIdx !== -1) {{
            lines = stripped.slice(hashIdx + 1);
            stripped = stripped.slice(0, hashIdx);
          }}
          const decoded = decodeURIComponent(stripped);
          let nextUrl = '/view?path=' + encodeURIComponent(decoded);
          if (lines) nextUrl += '&lines=' + encodeURIComponent(lines);
          window.location.href = nextUrl;
        }});
      }});
    }}

    enhanceDynamic();

    // Toolbar & Style Studio
    document.getElementById('btn-toc')?.addEventListener('click', () => document.body.classList.toggle('toc-hidden'));
    document.getElementById('btn-wide')?.addEventListener('click', () => document.body.classList.toggle('mode-wide'));
    document.getElementById('btn-shader')?.addEventListener('click', function () {{
      window.__qwaveShaderPaused = !window.__qwaveShaderPaused;
      if (window.__qwaveSyncShader) window.__qwaveSyncShader();
    }});
    document.getElementById('btn-style-drawer')?.addEventListener('click', function () {{
      document.getElementById('style-drawer')?.classList.toggle('open');
    }});

    document.querySelectorAll('[data-style-preset]').forEach(function (chip) {{
      chip.addEventListener('click', function () {{
        const preset = chip.getAttribute('data-style-preset');
        fetch('/api/style', {{
          method: 'POST',
          headers: {{'Content-Type': 'application/json'}},
          body: JSON.stringify({{ preset: preset, prompt: '' }})
        }}).then(r => r.json()).then(applyStyleConfig);
      }});
    }});

    document.getElementById('btn-apply-custom-style')?.addEventListener('click', function () {{
      const prompt = document.getElementById('style-custom-input')?.value || '';
      sendToAlexiai(prompt || 'Give this webpage a fresh style');
    }});

    // Live Split Editor & Ghostwriter
    let debounceTimer = null;
    editorArea?.addEventListener('input', function () {{
      rawSource = editorArea.value;
      clearTimeout(debounceTimer);
      debounceTimer = setTimeout(function () {{
        fetch('/api/compile-raw', {{
          method: 'POST',
          headers: {{'Content-Type': 'application/json'}},
          body: JSON.stringify({{ markdown: rawSource }})
        }}).then(r => r.json()).then(d => {{
          if (d.ok) {{
            document.getElementById('md-body').innerHTML = d.html;
            document.getElementById('md-toc').innerHTML = d.toc;
            enhanceDynamic();
          }}
        }});
      }}, 180);
    }});

    function openInGhostwriter() {{
      fetch('/api/ghostwriter', {{
        method: 'POST',
        headers: {{'Content-Type': 'application/json'}},
        body: JSON.stringify({{ path: currentPath }})
      }}).then(r => r.json()).then(data => {{
        const st = document.getElementById('live-status');
        if (st) st.textContent = 'OPENED IN ' + (data.editor || 'GHOSTWRITER').toUpperCase();
      }});
    }}
    document.getElementById('btn-ghostwriter')?.addEventListener('click', openInGhostwriter);

    function toggleSplitStudio() {{
      const on = document.body.classList.toggle('split-editor');
      if (saveBtn) saveBtn.style.display = on ? 'inline-flex' : 'none';
    }}
    document.getElementById('btn-split-edit')?.addEventListener('click', toggleSplitStudio);

    function saveMarkdown() {{
      const contentToSave = editorArea ? editorArea.value : rawSource;
      fetch('/api/save', {{
        method: 'POST',
        headers: {{'Content-Type': 'application/json'}},
        body: JSON.stringify({{ path: currentPath, content: contentToSave }})
      }}).then(r => r.json()).then(d => {{
        const st = document.getElementById('live-status');
        if (st) st.textContent = d.ok ? 'SAVED TO DISK ✓' : ('ERROR: ' + d.error);
      }});
    }}
    saveBtn?.addEventListener('click', saveMarkdown);

    // ALEXIAI Voice Output (Kokoro Neural TTS + WebAudio 432Hz Visualizer)
    let voiceEnabled = true;
    let currentAudio = null;
    const ttsToggleBtn = document.getElementById('btn-tts-toggle');
    ttsToggleBtn?.addEventListener('click', function () {{
      voiceEnabled = !voiceEnabled;
      ttsToggleBtn.textContent = voiceEnabled ? '🔊 Voice: ON' : '🔇 Voice: OFF';
      if (!voiceEnabled && currentAudio) {{
        currentAudio.pause();
        currentAudio = null;
      }}
    }});

    function speakAlexiaiReply(text) {{
      if (!voiceEnabled || !text) return;
      if (currentAudio) {{
        currentAudio.pause();
        currentAudio = null;
      }}
      const voice = document.getElementById('alexiai-voice')?.value || 'af_heart';
      if (statusEl) statusEl.textContent = '🔊 Alexiai speaking (' + voice + ' · 432Hz resonance)...';
      const audio = new Audio('/api/alexiai/tts?voice=' + encodeURIComponent(voice) + '&text=' + encodeURIComponent(text));
      currentAudio = audio;

      try {{
        const ctx = new (window.AudioContext || window.webkitAudioContext)();
        const src = ctx.createMediaElementSource(audio);
        const analyser = ctx.createAnalyser();
        analyser.fftSize = 64;
        src.connect(analyser);
        analyser.connect(ctx.destination);
        const bins = new Uint8Array(analyser.frequencyBinCount);
        function animateOrb() {{
          if (!currentAudio || currentAudio.paused) {{
            if (orb) orb.style.transform = 'scale(1)';
            return;
          }}
          analyser.getByteFrequencyData(bins);
          let sum = 0;
          for (let i = 0; i < bins.length; i++) sum += bins[i];
          const avg = sum / bins.length;
          const scale = 1.0 + (avg / 255) * 0.45;
          if (orb) {{
            orb.style.transform = 'scale(' + scale.toFixed(3) + ')';
            orb.style.boxShadow = '0 0 ' + Math.round(16 + avg * 0.25) + 'px #ff9edb';
          }}
          requestAnimationFrame(animateOrb);
        }}
        audio.addEventListener('play', animateOrb);
      }} catch (e) {{}}

      audio.addEventListener('ended', function () {{
        if (orb) orb.style.transform = 'scale(1)';
        if (statusEl) statusEl.textContent = '💜 Alexiai ready — click 🎙️ or press Ctrl+Space to talk.';
      }});
      audio.play().catch(function () {{
        // Browser speechSynthesis fallback if audio element blocked
        if (window.speechSynthesis) {{
          const u = new SpeechSynthesisUtterance(text);
          window.speechSynthesis.speak(u);
        }}
      }});
    }}

    // Send prompt (from voice or text) to ALEXIAI
    function sendToAlexiai(messageText) {{
      if (!messageText || !messageText.trim()) return;
      const inputEl = document.getElementById('alexiai-input');
      if (inputEl) inputEl.value = messageText;
      if (statusEl) statusEl.textContent = '⚡ Alexiai folding GAIA field & thinking...';

      fetch('/api/alexiai/chat', {{
        method: 'POST',
        headers: {{'Content-Type': 'application/json'}},
        body: JSON.stringify({{
          path: currentPath,
          message: messageText,
          markdown: rawSource
        }})
      }}).then(r => r.json()).then(data => {{
        if (!data.ok) return;
        if (replyEl) {{
          replyEl.classList.add('visible');
          replyEl.textContent = '💜 Alexiai: ' + data.reply;
        }}
        if (data.style) {{
          applyStyleConfig(data.style);
        }}
        if (data.updated_markdown && data.updated_html) {{
          rawSource = data.updated_markdown;
          if (editorArea) editorArea.value = rawSource;
          document.getElementById('md-body').innerHTML = data.updated_html;
          if (data.updated_toc) document.getElementById('md-toc').innerHTML = data.updated_toc;
          if (saveBtn) saveBtn.style.display = 'inline-flex';
          enhanceDynamic();
        }}
        speakAlexiaiReply(data.reply);
      }});
    }}

    document.getElementById('alexiai-form')?.addEventListener('submit', function (e) {{
      e.preventDefault();
      const inputEl = document.getElementById('alexiai-input');
      if (!inputEl || !inputEl.value.trim()) return;
      const msg = inputEl.value.trim();
      inputEl.value = '';
      sendToAlexiai(msg);
    }});

    // ALEXIAI Voice Input: WebAudio 16kHz PCM WAV Recorder -> `/api/alexiai/stt` (`whisper-cli`)
    let isRecording = false;
    let micStream = null;
    let audioCtx = null;
    let processorNode = null;
    let recordedSamples = [];
    const micBtn = document.getElementById('btn-mic');

    function encodeWav16kMono(samples, sampleRate) {{
      // Downsample to 16000 Hz if needed
      const targetRate = 16000;
      const ratio = sampleRate / targetRate;
      const outLen = Math.floor(samples.length / ratio);
      const buffer = new ArrayBuffer(44 + outLen * 2);
      const view = new DataView(buffer);
      function writeStr(off, s) {{
        for (let i = 0; i < s.length; i++) view.setUint8(off + i, s.charCodeAt(i));
      }}
      writeStr(0, 'RIFF');
      view.setUint32(4, 36 + outLen * 2, true);
      writeStr(8, 'WAVE');
      writeStr(12, 'fmt ');
      view.setUint32(16, 16, true);
      view.setUint16(20, 1, true);
      view.setUint16(22, 1, true);
      view.setUint32(24, targetRate, true);
      view.setUint32(28, targetRate * 2, true);
      view.setUint16(32, 2, true);
      view.setUint16(34, 16, true);
      writeStr(36, 'data');
      view.setUint32(40, outLen * 2, true);
      let offset = 44;
      for (let i = 0; i < outLen; i++) {{
        const s = Math.max(-1, Math.min(1, samples[Math.floor(i * ratio)] || 0));
        view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
        offset += 2;
      }}
      return buffer;
    }}

    async function toggleVoiceRecording() {{
      if (isRecording) {{
        isRecording = false;
        micBtn?.classList.remove('listening');
        if (micBtn) micBtn.textContent = '🎙️ Talk to Alexiai';
        orb?.classList.remove('recording');
        if (processorNode) processorNode.disconnect();
        if (micStream) micStream.getTracks().forEach(t => t.stop());
        const sr = audioCtx ? audioCtx.sampleRate : 48000;
        if (audioCtx) audioCtx.close();

        if (statusEl) statusEl.textContent = '🎧 Transcribing voice via Liquid-Rust (LFM2.5-Audio + Phoenix)...';
        const wavBuf = encodeWav16kMono(recordedSamples, sr);
        recordedSamples = [];
        fetch('/api/alexiai/stt', {{
          method: 'POST',
          headers: {{'Content-Type': 'audio/wav'}},
          body: wavBuf
        }}).then(r => r.json()).then(d => {{
          if (d.salience) {{
            const hud = document.getElementById('mem8-hud');
            if (hud) {{
              hud.classList.add('visible');
              hud.innerHTML =
                '<strong>🧬 MEM|8 Salience Speech Learner (Zero-Float p/q DSP)</strong> · ' +
                'Speaker F0: <code>' + d.salience.f0_hz + ' Hz (' + d.salience.f0_pq + ')</code> · ' +
                'Marine Salience: <code>' + d.salience.salience_pq + '</code> · ' +
                'VadPq: <code>' + d.salience.vad_byte + '</code> · ' +
                'Top Salient Grains Imprinted: <code>+' + d.salience.grains_extracted + ' (total ' + d.salience.total_grains_learned + ' in MEM|8)</code>';
            }}
          }}
          if (d.ok && d.text && d.text.trim()) {{
            sendToAlexiai(d.text.trim());
          }} else {{
            if (statusEl) statusEl.textContent = '💜 Salience grains learned in MEM|8 — click 🎙️ to speak again or type below.';
          }}
        }});
        return;
      }}

      try {{
        if (currentAudio) {{ currentAudio.pause(); currentAudio = null; }}
        micStream = await navigator.mediaDevices.getUserMedia({{ audio: true }});
        audioCtx = new (window.AudioContext || window.webkitAudioContext)();
        const source = audioCtx.createMediaStreamSource(micStream);
        processorNode = audioCtx.createScriptProcessor(4096, 1, 1);
        recordedSamples = [];
        let silenceFrames = 0;
        let heardSpeech = false;

        processorNode.onaudioprocess = function (e) {{
          if (!isRecording) return;
          const chan = e.inputBuffer.getChannelData(0);
          let sumSq = 0;
          for (let i = 0; i < chan.length; i++) {{
            recordedSamples.push(chan[i]);
            sumSq += chan[i] * chan[i];
          }}
          const rms = Math.sqrt(sumSq / chan.length);
          if (rms > 0.022) {{
            heardSpeech = true;
            silenceFrames = 0;
          }} else if (heardSpeech) {{
            silenceFrames++;
            // Auto-stop after ~1.4s of silence once speech has started
            if (silenceFrames > 16) {{
              toggleVoiceRecording();
            }}
          }}
        }};

        source.connect(processorNode);
        processorNode.connect(audioCtx.destination);
        isRecording = true;
        micBtn?.classList.add('listening');
        if (micBtn) micBtn.textContent = '⏹️ Stop & Send';
        orb?.classList.add('recording');
        if (statusEl) statusEl.textContent = '🎙️ Listening... speak to Alexiai (auto-sends when you pause, or click Stop)';
      }} catch (err) {{
        if (statusEl) statusEl.textContent = '⚠️ Microphone unavailable (' + err.message + ') — use the prompt bar below!';
      }}
    }}

    micBtn?.addEventListener('click', toggleVoiceRecording);
    orb?.addEventListener('click', toggleVoiceRecording);

    // Remember in MEM|8
    document.querySelectorAll('[data-remember]').forEach(function (el) {{
      el.addEventListener('click', function () {{
        const scope = el.getAttribute('data-remember');
        const sel = window.getSelection ? String(window.getSelection()) : '';
        const text = (scope === 'selection' && sel.trim()) ? sel : (rawSource || document.body.innerText);
        fetch('/api/remember', {{
          method: 'POST',
          headers: {{'Content-Type': 'application/json'}},
          body: JSON.stringify({{ path: currentPath, scope: scope, text: text }})
        }}).then(r => r.json()).then(d => {{
          const hud = document.getElementById('mem8-hud');
          if (hud && d.ok) {{
            hud.classList.add('visible');
            hud.innerHTML =
              '<strong>🌊 MEM|8 WaveInt Crystallized (' + d.bytes + ' bytes)</strong> · ' +
              'Resonance: <code>' + d.frequency + '</code> · Provenance: <code>' + d.provenance + '</code> · ' +
              'Quanttern VAD: <code>' + d.vad_byte + '</code> · Hash: <code>' + d.hash + '</code>' +
              '<div class="mem8-hex">' + d.frame_hex + '</div>';
          }}
        }});
      }});
    }});

    // Keyboard shortcuts
    window.addEventListener('keydown', function (e) {{
      if ((e.ctrlKey || e.metaKey) && e.code === 'Space') {{
        e.preventDefault();
        toggleVoiceRecording();
      }} else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'e' && !e.shiftKey) {{
        e.preventDefault();
        openInGhostwriter();
      }} else if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key.toLowerCase() === 'e') {{
        e.preventDefault();
        toggleSplitStudio();
      }} else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') {{
        if (document.body.classList.contains('split-editor') || saveBtn?.style.display !== 'none') {{
          e.preventDefault();
          saveMarkdown();
        }}
      }}
    }});

    // Live SSE file watcher
    if (window.EventSource && currentPath) {{
      const es = new EventSource('/events?path=' + encodeURIComponent(currentPath));
      es.addEventListener('reload', function () {{
        fetch('/api/render?path=' + encodeURIComponent(currentPath))
          .then(r => r.json())
          .then(data => {{
            document.title = data.title + ' — Qwave × ALEXIAI';
            const bodyEl = document.getElementById('md-body');
            const tocEl = document.getElementById('md-toc');
            if (bodyEl) bodyEl.innerHTML = data.html;
            if (tocEl) tocEl.innerHTML = data.toc;
            rawSource = data.source;
            if (editorArea && document.activeElement !== editorArea) {{
              editorArea.value = data.source;
            }}
            const st = document.getElementById('live-status');
            if (st) st.textContent = 'LIVE UPDATED · ' + new Date().toLocaleTimeString();
            enhanceDynamic();
          }});
      }});
    }}
  }})();
  </script>
</body>
</html>"#,
        safe_title = escape(title),
        head_assets = head_assets,
        toc_html = toc_html,
        safe_path = escape(&path_str),
        line_badge = line_badge,
        body_html = compiled.html,
        WAVE_FRAGMENT_SHADER = WAVE_FRAGMENT_SHADER,
        source_json = source_json,
        path_json = path_json,
        saved_style_json = saved_style_json,
        WAVE_CANVAS_SCRIPT = WAVE_CANVAS_SCRIPT,
    )
}

fn send_response(
    stream: &mut TcpStream,
    status: &str,
    content_type: &str,
    body: &[u8],
) -> std::io::Result<()> {
    let header = format!(
        "HTTP/1.1 {status}\r\n\
         Content-Type: {content_type}\r\n\
         Content-Length: {}\r\n\
         Cache-Control: no-store\r\n\
         X-Sovereign-Engine: qwave-core/0.1.0\r\n\
         Connection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(header.as_bytes())?;
    stream.write_all(body)?;
    stream.flush()
}

fn guess_mime(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "woff2" => "font/woff2",
        "css" => "text/css; charset=utf-8",
        "js" => "application/javascript; charset=utf-8",
        _ => "application/octet-stream",
    }
}

fn get_query_param(query: &str, key: &str) -> Option<String> {
    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            if k == key {
                return Some(url_decode(v));
            }
        }
    }
    None
}

fn url_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len() + 16);
    for b in input.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'/' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn url_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (from_hex(bytes[i + 1]), from_hex(bytes[i + 2])) {
                out.push((h << 4) | l);
                i += 3;
                continue;
            }
        } else if bytes[i] == b'+' {
            out.push(b' ');
            i += 1;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn from_hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn extract_json_str(json: &str, field: &str) -> Option<String> {
    let needle = format!("\"{field}\":");
    let start = json.find(&needle)? + needle.len();
    let rest = json[start..].trim_start();
    if !rest.starts_with('"') {
        return None;
    }
    let mut out = String::new();
    let mut chars = rest[1..].chars();
    while let Some(c) = chars.next() {
        if c == '"' {
            return Some(out);
        }
        if c == '\\' {
            if let Some(esc) = chars.next() {
                match esc {
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    other => out.push(other),
                }
            }
        } else {
            out.push(c);
        }
    }
    None
}

fn strip_ansi(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            if chars.peek() == Some(&'[') {
                let _ = chars.next();
                while let Some(nc) = chars.next() {
                    if nc.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn salience_profile_path() -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join(".local/share/qwave/mem8/speaker_salience_profile.bin")
}

fn load_salience_profile() -> SpeakerSalienceProfile {
    let path = salience_profile_path();
    if let Ok(bytes) = fs::read(path) {
        if let Some(prof) = SpeakerSalienceProfile::from_bytes(&bytes) {
            return prof;
        }
    }
    SpeakerSalienceProfile::default()
}

fn save_salience_profile(prof: &SpeakerSalienceProfile) {
    let path = salience_profile_path();
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(path, prof.to_bytes());
}

fn format_salience_profile_json(prof: &SpeakerSalienceProfile) -> String {
    let f0_int = prof.f0_hz.num / (prof.f0_hz.den.max(1) as i32);
    let mut env_str = String::from("[");
    for (i, &v) in prof.prosody_envelope_q15.iter().enumerate() {
        if i > 0 {
            env_str.push(',');
        }
        env_str.push_str(&v.to_string());
    }
    env_str.push(']');
    format!(
        "{{\"ok\":true,\"f0_hz\":{f0_int},\"f0_pq\":\"{}/{}\",\"avg_salience_pq\":\"{}/{}\",\"vad_byte\":\"0x{:02x}\",\"grains_learned\":{},\"best_grain_samples\":{},\"prosody_envelope_q15\":{env_str}}}",
        prof.f0_hz.num,
        prof.f0_hz.den,
        prof.avg_salience.num,
        prof.avg_salience.den,
        prof.vad_byte,
        prof.grains_learned,
        prof.best_grain_pcm.len()
    )
}

/// Ensure PipeWire/PulseAudio default sink (e.g. Soundcore Select 4 Go Bluetooth speaker) is unmuted,
/// synthesize speech via `kokoro-speak` / `liquid-rust`, modulate it in 100% integer DSP with the
/// user's `MEM|8` `SpeakerSalienceProfile` (`combine_salient_speech_wav`), and play it out loud.
fn speak_out_loud(text: &str, voice: &str, salience_modulate: bool, wait: bool) -> String {
    let xdg_runtime = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
    let _ = Command::new("sh")
        .env("XDG_RUNTIME_DIR", &xdg_runtime)
        .args([
            "-c",
            "SPK_SINK=$(pactl list sinks short 2>/dev/null | awk '/HiFi__Speaker__sink/{print $2; exit}'); \
             if [ -n \"$SPK_SINK\" ]; then \
               pactl set-default-sink \"$SPK_SINK\" 2>/dev/null || true; \
               pactl set-sink-mute \"$SPK_SINK\" 0 2>/dev/null || true; \
               pactl set-sink-volume \"$SPK_SINK\" 90% 2>/dev/null || true; \
             else \
               wpctl set-mute @DEFAULT_AUDIO_SINK@ 0 2>/dev/null || true; \
             fi",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();

    let state = Arc::new(AppState {
        current_file: Mutex::new(PathBuf::from("/home/hue/8b-is/qwave/README.md")),
        last_activity: AtomicU64::new(now_secs()),
        active_sse: AtomicU64::new(0),
        salience_profile: Mutex::new(if salience_modulate {
            load_salience_profile()
        } else {
            SpeakerSalienceProfile::default()
        }),
    });

    let wav_bytes = synthesize_alexiai_tts(text, voice, &state);
    if wav_bytes.is_empty() {
        return "{\"ok\":false,\"error\":\"TTS synthesis returned empty audio\"}".to_string();
    }

    let play_path = format!("/tmp/qwave_speak_{}_{}.wav", std::process::id(), now_secs());
    let _ = fs::write(&play_path, &wav_bytes);

    // Estimate playback duration from WAV byte count (~48,000 bytes/sec at 24kHz 16-bit mono)
    // and mark TTS active so the parallel ear daemon suppresses system echo!
    let est_secs = ((wav_bytes.len() as u64) / 40_000).clamp(3, 30) + 3;
    mark_tts_active_secs(est_secs);

    let prof = load_salience_profile();
    let f0_int = prof.f0_hz.num / (prof.f0_hz.den.max(1) as i32);

    if wait {
        let played = Command::new("pw-play")
            .env("XDG_RUNTIME_DIR", &xdg_runtime)
            .arg(&play_path)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
            || Command::new("paplay")
                .env("XDG_RUNTIME_DIR", &xdg_runtime)
                .arg(&play_path)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
            || Command::new("aplay")
                .arg("-q")
                .arg(&play_path)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
        mark_tts_active_secs(2);
        let _ = fs::remove_file(&play_path);
        format!(
            "{{\"ok\":true,\"played\":{played},\"voice\":{},\"bytes\":{},\"salience_modulated\":{},\"speaker_f0_hz\":{f0_int},\"grains_learned\":{}}}",
            markdown_source_literal(voice),
            wav_bytes.len(),
            salience_modulate && prof.grains_learned > 0,
            prof.grains_learned
        )
    } else {
        let p = play_path.clone();
        let _ = Command::new("setsid")
            .env("XDG_RUNTIME_DIR", &xdg_runtime)
            .args([
                "sh",
                "-c",
                &format!("(pw-play '{p}' || paplay '{p}' || aplay -q '{p}') >/dev/null 2>&1; rm -f '{p}'"),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        format!(
            "{{\"ok\":true,\"played\":true,\"async\":true,\"voice\":{},\"bytes\":{},\"salience_modulated\":{},\"speaker_f0_hz\":{f0_int},\"grains_learned\":{}}}",
            markdown_source_literal(voice),
            wav_bytes.len(),
            salience_modulate && prof.grains_learned > 0,
            prof.grains_learned
        )
    }
}

/// Record from microphone (if `target` is a duration in seconds) OR read an existing `.wav` file,
/// extract the Top-K highest-salience vocal grains via zero-float `MarineIntDetector`, store their
/// 79-byte `WaveInt` frames into `MEM|8`, update `~/.local/share/qwave/mem8/speaker_salience_profile.bin`,
/// and transcribe with `liquid-rust` (`LFM2.5-Audio + Phoenix`).
fn listen_and_learn(target: &str) -> String {
    let xdg_runtime = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
    let mut temp_rec: Option<String> = None;

    let wav_path = if Path::new(target).exists() {
        target.to_string()
    } else {
        let secs: u64 = target.parse().unwrap_or(5).clamp(1, 30);
        let rec_file = format!("/tmp/qwave_listen_{}_{}.wav", std::process::id(), now_secs());
        let _ = Command::new("sh")
            .env("XDG_RUNTIME_DIR", &xdg_runtime)
            .args([
                "-c",
                &format!(
                    "MIC_SRC=$(pactl list sources short 2>/dev/null | awk '/alsa_input.*Mic1__source/{{print $2; exit}}'); \
                     if [ -n \"$MIC_SRC\" ]; then pactl set-default-source \"$MIC_SRC\" 2>/dev/null || true; fi; \
                     timeout {secs}s pw-record --rate=16000 --channels=1 --format=s16 '{rec_file}' >/dev/null 2>&1 || arecord -f S16_LE -r 16000 -c 1 -d {secs} '{rec_file}' >/dev/null 2>&1"
                ),
            ])
            .status();
        temp_rec = Some(rec_file.clone());
        rec_file
    };

    let Ok(wav_bytes) = fs::read(&wav_path) else {
        if let Some(t) = temp_rec {
            let _ = fs::remove_file(t);
        }
        return "{\"ok\":false,\"error\":\"could not read or record WAV audio\"}".to_string();
    };

    let state = Arc::new(AppState {
        current_file: Mutex::new(PathBuf::from("/home/hue/8b-is/qwave/README.md")),
        last_activity: AtomicU64::new(now_secs()),
        active_sse: AtomicU64::new(0),
        salience_profile: Mutex::new(load_salience_profile()),
    });

    let result = handle_alexiai_stt(&wav_bytes, &state);
    if let Some(t) = temp_rec {
        let _ = fs::remove_file(t);
    }
    result
}

/// Show a Markdown file (or raw Markdown content) in the native Qwave Sovereign Studio window,
/// optionally applying a style preset and speaking an introduction out loud!
fn show_markdown_in_qwave(
    path_opt: Option<String>,
    markdown_opt: Option<String>,
    style_opt: Option<String>,
    speak_opt: Option<String>,
) -> String {
    if let Some(ref preset) = style_opt {
        if !preset.trim().is_empty() {
            let style_json = build_qwave_style_json(preset.trim(), preset.trim());
            save_style_json(&style_json);
        }
    }

    let target_path = if let Some(raw_md) = markdown_opt {
        let p = if let Some(ref user_p) = path_opt {
            resolve_input_target(user_p).0
        } else {
            PathBuf::from(format!("/tmp/qwave_live_{}.md", now_secs()))
        };
        let _ = fs::write(&p, raw_md.as_bytes());
        p
    } else if let Some(ref user_p) = path_opt {
        resolve_input_target(user_p).0
    } else {
        PathBuf::from("/home/hue/8b-is/qwave/README.md")
    };

    if let Some(ref spoken) = speak_opt {
        if !spoken.trim().is_empty() {
            let _ = speak_out_loud(spoken, "af_heart", true, false);
        }
    }

    let exe = env::current_exe().unwrap_or_else(|_| PathBuf::from("/usr/local/bin/qwave"));
    let _ = Command::new(exe)
        .arg(&target_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();

    format!(
        "{{\"ok\":true,\"opened\":{},\"style\":{},\"spoken\":{}}}",
        markdown_source_literal(&target_path.to_string_lossy()),
        markdown_source_literal(style_opt.as_deref().unwrap_or("saved")),
        markdown_source_literal(speak_opt.as_deref().unwrap_or(""))
    )
}

/// Surf to a URL or Markdown file inside Qwave (`window` mode opens native `qwave-qt`;
/// `markdown` mode fetches & compiles to Sovereign Markdown in Qwave Studio).
fn surf_with_qwave(target: &str, mode: &str, speak_opt: Option<&str>) -> String {
    if let Some(spoken) = speak_opt {
        if !spoken.trim().is_empty() {
            let _ = speak_out_loud(spoken, "af_heart", true, false);
        }
    }

    let trimmed = target.trim();
    if trimmed.ends_with(".md")
        || trimmed.starts_with("file://")
        || trimmed.starts_with('/')
        || trimmed.starts_with("~/")
    {
        return show_markdown_in_qwave(Some(trimmed.to_string()), None, None, None);
    }

    if mode == "markdown" {
        if let Ok(out) = Command::new("curl")
            .args(["-sL", "--max-time", "10", trimmed])
            .output()
        {
            let body = String::from_utf8_lossy(&out.stdout);
            let md = format!(
                "# Qwave Sovereign Surf: `{trimmed}`\n\n> [!NOTE] Rendered via Qwave Sovereign Surf\n\n```html\n{}\n```\n",
                body.chars().take(6000).collect::<String>()
            );
            return show_markdown_in_qwave(None, Some(md), None, None);
        }
    }

    let xdg_runtime = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
    let wayland_display = env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-1".to_string());
    let x11_display = env::var("DISPLAY").unwrap_or_else(|_| ":0".to_string());

    for qt_bin in [
        "/usr/local/lib/qwave/qwave-qt",
        "/home/hue/8b-is/qwave/qt/qwave-qt",
    ] {
        if Path::new(qt_bin).exists() {
            let _ = Command::new(qt_bin)
                .arg(trimmed)
                .env("XDG_RUNTIME_DIR", &xdg_runtime)
                .env("WAYLAND_DISPLAY", &wayland_display)
                .env("DISPLAY", &x11_display)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
            return format!(
                "{{\"ok\":true,\"surfed\":{},\"engine\":\"qwave-qt\"}}",
                markdown_source_literal(trimmed)
            );
        }
    }

    let _ = launch_native_window(trimmed);
    format!(
        "{{\"ok\":true,\"surfed\":{},\"engine\":\"native-window\"}}",
        markdown_source_literal(trimmed)
    )
}

/// Run the Sovereign Qwave MCP Server over `stdin`/`stdout` (JSON-RPC 2.0) for Antigravity (`agy`),
/// Claude Code (`claude`), OpenAI Codex (`codex`), and any MCP-compatible host.
fn run_mcp_server() {
    let stdin = std::io::stdin();
    let mut reader = BufReader::new(stdin.lock());
    let mut stdout = std::io::stdout();

    loop {
        let mut line = String::new();
        let Ok(n) = reader.read_line(&mut line) else {
            break;
        };
        if n == 0 {
            break;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        // Support both Content-Length framed MCP and newline-delimited JSON-RPC 2.0
        let (payload, use_content_length) = if trimmed
            .to_ascii_lowercase()
            .starts_with("content-length:")
        {
            let len: usize = trimmed
                .split_once(':')
                .and_then(|(_, v)| v.trim().parse().ok())
                .unwrap_or(0);
            loop {
                let mut hdr = String::new();
                if reader.read_line(&mut hdr).unwrap_or(0) == 0 || hdr.trim().is_empty() {
                    break;
                }
            }
            let mut buf = vec![0u8; len];
            if reader.read_exact(&mut buf).is_err() {
                break;
            }
            (String::from_utf8_lossy(&buf).into_owned(), true)
        } else {
            (trimmed.to_string(), false)
        };

        if let Some(resp) = handle_mcp_request(&payload) {
            if use_content_length {
                let _ = write!(stdout, "Content-Length: {}\r\n\r\n{}", resp.len(), resp);
            } else {
                let _ = writeln!(stdout, "{resp}");
            }
            let _ = stdout.flush();
        }
    }
}

fn extract_json_id(json: &str) -> Option<String> {
    let needle = "\"id\":";
    let start = json.find(needle)? + needle.len();
    let rest = json[start..].trim_start();
    if rest.starts_with('"') {
        let s = extract_json_str(json, "id")?;
        return Some(markdown_source_literal(&s));
    }
    let end = rest
        .find(|c: char| matches!(c, ',' | '}' | ' ' | '\t' | '\r' | '\n'))
        .unwrap_or(rest.len());
    let token = &rest[..end];
    if token.is_empty() {
        None
    } else {
        Some(token.to_string())
    }
}

fn extract_json_bool(json: &str, field: &str) -> Option<bool> {
    let needle = format!("\"{field}\":");
    let start = json.find(&needle)? + needle.len();
    let rest = json[start..].trim_start();
    if rest.starts_with("true") {
        Some(true)
    } else if rest.starts_with("false") {
        Some(false)
    } else {
        None
    }
}

fn extract_json_u64(json: &str, field: &str) -> Option<u64> {
    let needle = format!("\"{field}\":");
    let start = json.find(&needle)? + needle.len();
    let rest = json[start..].trim_start();
    let end = rest
        .find(|c: char| !c.is_ascii_digit())
        .unwrap_or(rest.len());
    rest[..end].parse().ok()
}

fn handle_mcp_request(req: &str) -> Option<String> {
    let method = extract_json_str(req, "method")?;
    let id_raw = extract_json_id(req);

    // Notifications (no `id`) do not expect a response
    if method.starts_with("notifications/") || id_raw.is_none() {
        return None;
    }
    let id = id_raw.unwrap_or_else(|| "1".to_string());

    match method.as_str() {
        "initialize" => Some(format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"qwave\",\"version\":\"0.2.0\"}}}}}}"
        )),
        "ping" => Some(format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{{}}}}")),
        "tools/list" => Some(format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{{\"tools\":[\
             {{\"name\":\"speak\",\"description\":\"🔊 Speak out loud to the user immediately through the default/Bluetooth speaker using Kokoro/LFM2.5 neural voice + zero-float MEM|8 SpeakerSalienceProfile integer prosody & harmonic modulation.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"text\":{{\"type\":\"string\",\"description\":\"Text to speak out loud to the user\"}},\"voice\":{{\"type\":\"string\",\"description\":\"Voice persona (af_heart, af_sky, af_bella, af_nicole, bf_emma, am_adam, am_michael, lfm_aye, lfm_omnimom)\",\"default\":\"af_heart\"}},\"salience_modulate\":{{\"type\":\"boolean\",\"description\":\"Modulate speech with user's learned MEM|8 vocal salience profile (default: true)\",\"default\":true}},\"wait\":{{\"type\":\"boolean\",\"description\":\"Wait for audio playback to finish before returning (default: false)\",\"default\":false}}}},\"required\":[\"text\"]}}}},\
             {{\"name\":\"listen\",\"description\":\"🎙️ Always-on parallel acoustic ear + microphone listener! Reads the live diarized ear inbox (knowing whether it is Hue addressing the AI, Hue chatting with a friend next to him, another friend speaking, or ambient noise) OR records/transcribes live audio.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"mode\":{{\"type\":\"string\",\"description\":\"'inbox' (instant 0ms read from parallel ear daemon) or 'record' (capture live window)\",\"default\":\"inbox\"}},\"duration_secs\":{{\"type\":\"integer\",\"description\":\"Seconds to record if mode=='record' (1..30, default: 5)\"}},\"wav_path\":{{\"type\":\"string\",\"description\":\"Optional path to an existing WAV file to analyze & transcribe\"}}}}}}}},\
             {{\"name\":\"room_status\",\"description\":\"👥 Instant 0ms snapshot from the parallel always-on acoustic ear: shows whether Hue is addressing the AI or chatting with a friend next to him, active speakers in the room (hue, friend_1..4, ambient_noise), noise floor, and recent diarized utterances.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"limit\":{{\"type\":\"integer\",\"description\":\"Max recent utterances to return (default: 8)\",\"default\":8}}}}}}}},\
             {{\"name\":\"salience\",\"description\":\"🌊 Inspect or train the user's persistent zero-float MEM|8 SpeakerSalienceProfile (exact p/q Rational F0 Hz, VadPq ternary affect byte, 16-bin prosody contour, and learned vocal grain count).\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"wav_path\":{{\"type\":\"string\",\"description\":\"Optional WAV file path to fold into the MEM|8 speaker salience profile\"}}}}}}}},\
             {{\"name\":\"show_markdown\",\"description\":\"📖 Open any Markdown file (file:///.../*.md) or live Markdown snippet inside the native Qwave Sovereign Studio window with KaTeX, Mermaid, 3D MEM|8 Wave canvas, Ghostwriter bridge, and optional live theme preset & voice narration.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"path\":{{\"type\":\"string\",\"description\":\"Path or file:// URI to the Markdown document\"}},\"markdown\":{{\"type\":\"string\",\"description\":\"Optional raw Markdown content to render and display\"}},\"style\":{{\"type\":\"string\",\"description\":\"Optional Qwave theme preset (dra-starlight, cyberpunk-neon, phoenix-lattice, emerald-matrix, parchment-zen, ocean)\"}},\"speak\":{{\"type\":\"string\",\"description\":\"Optional narration to speak out loud as the document opens\"}}}}}}}},\
             {{\"name\":\"surf\",\"description\":\"🏄 Surf with the user in Qwave! Opens a URL or Markdown path in the native Qwave browser window (or converts web content into Sovereign Markdown) with optional voice commentary.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"url\":{{\"type\":\"string\",\"description\":\"URL or file:// path to surf to\"}},\"mode\":{{\"type\":\"string\",\"description\":\"'window' (native Qwave window) or 'markdown' (convert to Sovereign Markdown)\",\"default\":\"window\"}},\"speak\":{{\"type\":\"string\",\"description\":\"Optional spoken narration while surfing\"}}}},\"required\":[\"url\"]}}}}\
             ]}}}}"
        )),
        "tools/call" => {
            let params_slice = req
                .find("\"params\":")
                .map(|idx| &req[idx + 9..])
                .unwrap_or(req);
            let tool_name = extract_json_str(params_slice, "name").unwrap_or_default();
            let args_slice = params_slice
                .find("\"arguments\":")
                .map(|idx| &params_slice[idx + 12..])
                .unwrap_or(params_slice);

            let out_text = match tool_name.as_str() {
                "speak" | "qwave_speak" => {
                    let text = extract_json_str(args_slice, "text")
                        .unwrap_or_else(|| "Hello from Qwave!".to_string());
                    let voice = extract_json_str(args_slice, "voice")
                        .unwrap_or_else(|| "af_heart".to_string());
                    let salience_mod =
                        extract_json_bool(args_slice, "salience_modulate").unwrap_or(true);
                    let wait = extract_json_bool(args_slice, "wait").unwrap_or(false);
                    speak_out_loud(&text, &voice, salience_mod, wait)
                }
                "listen" | "qwave_listen" => {
                    ensure_ear_daemon_running();
                    if let Some(wav_p) = extract_json_str(args_slice, "wav_path") {
                        listen_and_learn(&wav_p)
                    } else if let Some(secs) = extract_json_u64(args_slice, "duration_secs") {
                        if secs == 0 {
                            read_ear_inbox_json(8)
                        } else {
                            listen_and_learn(&secs.to_string())
                        }
                    } else {
                        let mode = extract_json_str(args_slice, "mode")
                            .unwrap_or_else(|| "inbox".to_string());
                        if mode == "record" {
                            listen_and_learn("5")
                        } else {
                            read_ear_inbox_json(8)
                        }
                    }
                }
                "room_status" | "ear_inbox" => {
                    ensure_ear_daemon_running();
                    let limit = extract_json_u64(args_slice, "limit").unwrap_or(8) as usize;
                    read_ear_inbox_json(limit)
                }
                "salience" | "qwave_salience" => {
                    if let Some(wav_p) = extract_json_str(args_slice, "wav_path") {
                        if let Ok(bytes) = fs::read(&wav_p) {
                            if let Some((sr, pcm)) = decode_wav_i16(&bytes) {
                                let report = extract_salient_grains(&pcm, sr, 3, now_secs());
                                let mut prof = load_salience_profile();
                                prof.absorb_report(&report);
                                save_salience_profile(&prof);
                            }
                        }
                    }
                    let prof = load_salience_profile();
                    format_salience_profile_json(&prof)
                }
                "show_markdown" | "qwave_show_markdown" => {
                    let path_opt = extract_json_str(args_slice, "path");
                    let md_opt = extract_json_str(args_slice, "markdown");
                    let style_opt = extract_json_str(args_slice, "style");
                    let speak_opt = extract_json_str(args_slice, "speak");
                    show_markdown_in_qwave(path_opt, md_opt, style_opt, speak_opt)
                }
                "surf" | "qwave_surf" => {
                    let url = extract_json_str(args_slice, "url")
                        .unwrap_or_else(|| "/home/hue/8b-is/qwave/README.md".to_string());
                    let mode = extract_json_str(args_slice, "mode")
                        .unwrap_or_else(|| "window".to_string());
                    let speak_opt = extract_json_str(args_slice, "speak");
                    surf_with_qwave(&url, &mode, speak_opt.as_deref())
                }
                other => format!("{{\"ok\":false,\"error\":\"unknown tool: {other}\"}}"),
            };

            Some(format!(
                "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":{}}}]}}}}",
                markdown_source_literal(&out_text)
            ))
        }
        _ => Some(format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}"
        )),
    }
}

fn mem8_dir() -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let dir = PathBuf::from(home).join(".local/share/qwave/mem8");
    let _ = fs::create_dir_all(&dir);
    dir
}

fn mark_tts_active_secs(duration_secs: u64) {
    let until = now_secs().saturating_add(duration_secs);
    let _ = fs::write(mem8_dir().join("tts_active_until.txt"), until.to_string());
}

fn read_tts_active_until() -> u64 {
    fs::read_to_string(mem8_dir().join("tts_active_until.txt"))
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0)
}

/// Ensure the background parallel always-on acoustic ear (`qwave --ear-daemon`) is running.
fn ensure_ear_daemon_running() {
    let pid_file = mem8_dir().join("ear_daemon.pid");
    if let Ok(pid_str) = fs::read_to_string(&pid_file) {
        if let Ok(pid) = pid_str.trim().parse::<u32>() {
            if Path::new(&format!("/proc/{pid}/cmdline")).exists() {
                return;
            }
        }
    }
    let exe = env::current_exe().unwrap_or_else(|_| PathBuf::from("/usr/local/bin/qwave"));
    let xdg_runtime = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
    let _ = Command::new("setsid")
        .env("XDG_RUNTIME_DIR", &xdg_runtime)
        .arg(exe)
        .arg("--ear-daemon")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

/// Read the latest diarized utterances and live room status from the parallel ear daemon in 0ms.
fn read_ear_inbox_json(limit: usize) -> String {
    let dir = mem8_dir();
    let room_state = fs::read_to_string(dir.join("room_state.json")).unwrap_or_else(|_| {
        let prof = load_salience_profile();
        let f0_int = prof.f0_hz.num / (prof.f0_hz.den.max(1) as i32);
        format!(
            "{{\"daemon_active\":true,\"active_source\":\"silent_or_noise\",\"context\":\"silent_or_noise\",\"hue_f0_hz\":{f0_int},\"hue_grains_learned\":{},\"friends_detected\":0}}",
            prof.grains_learned
        )
    });

    let inbox_raw = fs::read_to_string(dir.join("ear_inbox.jsonl")).unwrap_or_default();
    let lines: Vec<&str> = inbox_raw.lines().filter(|l| !l.trim().is_empty()).collect();
    let start = lines.len().saturating_sub(limit);
    let recent = lines[start..].join(",");

    format!(
        "{{\"ok\":true,\"parallel_ear\":true,\"room_state\":{room_state},\"recent_utterances\":[{recent}]}}"
    )
}

/// Parallel Always-On Acoustic Ear Daemon (`qwave --ear-daemon`):
/// Continuously streams 16kHz `s16le` mono PCM from the internal microphone (`alsa_input...Mic1__source`),
/// evaluates every 60ms frame with zero-float `MarineIntDetector`, segments voiced utterances automatically,
/// and dispatches completed utterances to a parallel diarization + `liquid-rust` transcription worker that
/// classifies:
/// - `hue` (`PrimaryUser`) addressing the AI (`addressing_agent`)
/// - `hue` (`PrimaryUser`) chatting with a friend next to him (`chatting_with_friend`)
/// - `friend_1..4` (`OtherSpeaker`) speaking in the room (`friend_speaking`)
/// - `ambient_noise` / `system_echo` (`silent_or_noise`)
fn run_parallel_ear_daemon() {
    let dir = mem8_dir();
    let pid_file = dir.join("ear_daemon.pid");
    if let Ok(pid_str) = fs::read_to_string(&pid_file) {
        if let Ok(pid) = pid_str.trim().parse::<u32>() {
            if pid != std::process::id() && Path::new(&format!("/proc/{pid}/cmdline")).exists() {
                return;
            }
        }
    }
    let _ = fs::write(&pid_file, std::process::id().to_string());

    let xdg_runtime = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
    let tracker = Arc::new(Mutex::new(RoomAcousticTracker {
        primary_profile: load_salience_profile(),
        ..RoomAcousticTracker::default()
    }));
    let transcribe_lock = Arc::new(Mutex::new(()));

    // Write initial room_state.json immediately
    {
        let tr = tracker.lock().unwrap();
        let f0_int = tr.primary_profile.f0_hz.num / (tr.primary_profile.f0_hz.den.max(1) as i32);
        let init_state = format!(
            "{{\"daemon_pid\":{},\"ts\":{},\"active_source\":\"ambient_noise\",\"context\":\"silent_or_noise\",\"noise_floor_q15\":{},\"hue_f0_hz\":{f0_int},\"hue_grains_learned\":{},\"friends_detected\":0}}",
            std::process::id(),
            now_secs(),
            tr.noise_floor_q15,
            tr.primary_profile.grains_learned
        );
        let _ = fs::write(dir.join("room_state.json"), init_state);
    }

    loop {
        // Ensure internal digital microphone (`Mic1__source`) is unmuted and selected
        let _ = Command::new("sh")
            .env("XDG_RUNTIME_DIR", &xdg_runtime)
            .args([
                "-c",
                "MIC_SRC=$(pactl list sources short 2>/dev/null | awk '/alsa_input.*Mic1__source/{print $2; exit}'); \
                 if [ -n \"$MIC_SRC\" ]; then \
                   pactl set-default-source \"$MIC_SRC\" 2>/dev/null || true; \
                   pactl set-source-mute \"$MIC_SRC\" 0 2>/dev/null || true; \
                 fi",
            ])
            .status();

        // Stream raw 16kHz 16-bit mono PCM from PipeWire (`pw-record --raw` / `parec`)
        let child_opt = Command::new("parec")
            .env("XDG_RUNTIME_DIR", &xdg_runtime)
            .args([
                "--rate=16000",
                "--channels=1",
                "--format=s16le",
                "--latency-msec=60",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()
            .or_else(|| {
                Command::new("arecord")
                    .args(["-q", "-f", "S16_LE", "-r", "16000", "-c", "1", "-t", "raw"])
                    .stdout(Stdio::piped())
                    .stderr(Stdio::null())
                    .spawn()
                    .ok()
            });

        let Some(mut child) = child_opt else {
            thread::sleep(Duration::from_secs(2));
            continue;
        };

        let Some(mut stdout) = child.stdout.take() else {
            let _ = child.kill();
            thread::sleep(Duration::from_secs(2));
            continue;
        };

        // 60ms frame at 16kHz = 960 i16 samples = 1920 bytes
        let mut frame_bytes = [0u8; 1920];
        let mut utterance_pcm: Vec<i16> = Vec::with_capacity(16_000 * 6);
        let mut silent_frames = 0u32;
        let mut voiced_frames = 0u32;

        while stdout.read_exact(&mut frame_bytes).is_ok() {
            let now = now_secs();
            let tts_until = read_tts_active_until();
            if now < tts_until {
                utterance_pcm.clear();
                silent_frames = 0;
                voiced_frames = 0;
                continue;
            }

            let mut frame_pcm = [0i16; 960];
            let mut det = MarineIntDetector::new(16_000, 164);
            let mut sum_sal: u64 = 0;
            for i in 0..960 {
                let s = i16::from_le_bytes([frame_bytes[i * 2], frame_bytes[i * 2 + 1]]);
                frame_pcm[i] = s;
                sum_sal += det.process_sample_i16(s, i) as u64;
            }
            let avg_sal_q15 = (sum_sal / 960) as u16;

            if avg_sal_q15 >= 512 {
                voiced_frames += 1;
                silent_frames = 0;
                utterance_pcm.extend_from_slice(&frame_pcm);
            } else if !utterance_pcm.is_empty() {
                silent_frames += 1;
                utterance_pcm.extend_from_slice(&frame_pcm);
            }

            // Dispatch completed utterance when >= 5 voiced frames (300ms) followed by 8 silent frames (480ms),
            // or if continuous utterance reaches 7.5 seconds (125 frames)
            if (voiced_frames >= 5 && silent_frames >= 8) || utterance_pcm.len() >= 16_000 * 7 {
                let captured = std::mem::take(&mut utterance_pcm);
                voiced_frames = 0;
                silent_frames = 0;

                let tracker_clone = Arc::clone(&tracker);
                let lock_clone = Arc::clone(&transcribe_lock);
                let dir_clone = dir.clone();
                thread::spawn(move || {
                    if let Ok(_guard) = lock_clone.try_lock() {
                        process_parallel_ear_utterance(&captured, now, &tracker_clone, &dir_clone);
                    }
                });
            } else if silent_frames >= 8 {
                utterance_pcm.clear();
                voiced_frames = 0;
                silent_frames = 0;
            }
        }

        let _ = child.kill();
        let _ = child.wait();
        thread::sleep(Duration::from_millis(500));
    }
}

fn process_parallel_ear_utterance(
    pcm: &[i16],
    now: u64,
    tracker: &Arc<Mutex<RoomAcousticTracker>>,
    dir: &Path,
) {
    // 1. Fast zero-float acoustic check before invoking neural STT
    let pre_check = extract_salient_grains(pcm, 16_000, 3, now);
    if pre_check.top_grains.is_empty() {
        return;
    }

    // 2. Encode WAV and transcribe in parallel using `liquid-rust transcribe`
    let wav_bytes = encode_wav_i16(16_000, pcm);
    let tmp_wav = format!("/tmp/qwave_ear_{}_{}.wav", std::process::id(), now);
    if fs::write(&tmp_wav, &wav_bytes).is_err() {
        return;
    }

    let mut transcript = String::new();
    for lfm_bin in ["/usr/local/bin/liquid-rust", "/home/hue/.cargo/target/release/liquid-rust"] {
        if Path::new(lfm_bin).exists() {
            if let Ok(out) = Command::new(lfm_bin)
                .env("RUST_LOG", "error")
                .args(["transcribe", "-i", &tmp_wav])
                .output()
            {
                if out.status.success() {
                    let raw = strip_ansi(&String::from_utf8_lossy(&out.stdout));
                    transcript = raw
                        .lines()
                        .map(str::trim)
                        .filter(|l| {
                            !l.is_empty()
                                && !l.starts_with('═')
                                && !l.starts_with('🎤')
                                && !l.starts_with("✓")
                                && !l.contains(" WARN ")
                                && !l.contains(" INFO ")
                                && !l.contains("Failed storing MEM|8")
                        })
                        .collect::<Vec<_>>()
                        .join(" ");
                    break;
                }
            }
        }
    }
    let _ = fs::remove_file(&tmp_wav);

    let trimmed_tx = transcript.trim();
    if trimmed_tx.len() < 4
        || matches!(
            trimmed_tx.to_ascii_lowercase().as_str(),
            "the" | "uh" | "um" | "oh, oh." | "uh oh." | "uh-oh." | "you" | "oh."
        )
    {
        return;
    }

    // 3. Classify speaker (`hue`, `friend_1..4`, `ambient_noise`) and room context
    //    (`addressing_agent`, `chatting_with_friend`, `friend_speaking`, `silent_or_noise`)
    let mut tr = tracker.lock().unwrap();
    tr.tts_active_until_ts = read_tts_active_until();
    let analysis = tr.classify_and_learn(pcm, 16_000, now, Some(&transcript));

    // Persist Hue's updated SpeakerSalienceProfile & 79-byte WaveInt frames only when Hue spoke!
    if analysis.source == AcousticSourceKind::PrimaryUser {
        save_salience_profile(&tr.primary_profile);
        if let Ok(mut bin_f) = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join("speech_salience_waves.bin"))
        {
            for g in &analysis.salience_report.top_grains {
                let _ = bin_f.write_all(&g.wave.to_frame());
            }
        }
    }

    let friends_count = tr.friend_profiles.iter().filter(|p| p.is_some()).count();
    let hue_f0 = tr.primary_profile.f0_hz.num / (tr.primary_profile.f0_hz.den.max(1) as i32);
    let utt_f0 = analysis.salience_report.overall_f0_hz.num
        / (analysis.salience_report.overall_f0_hz.den.max(1) as i32);

    let event_json = format!(
        "{{\"ts\":{now},\"speaker\":{},\"context\":{},\"should_agent_respond\":{},\"primary_similarity_q15\":{},\"on_axis_ratio_q15\":{},\"f0_hz\":{utt_f0},\"f0_pq\":\"{}/{}\",\"vad_byte\":\"0x{:02x}\",\"text\":{}}}",
        markdown_source_literal(analysis.source.as_str()),
        markdown_source_literal(analysis.context.as_str()),
        analysis.should_agent_respond,
        analysis.primary_similarity_q15,
        analysis.on_axis_ratio_q15,
        analysis.salience_report.overall_f0_hz.num,
        analysis.salience_report.overall_f0_hz.den,
        analysis.salience_report.overall_vad_byte,
        markdown_source_literal(&transcript)
    );

    if let Ok(mut inbox_f) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("ear_inbox.jsonl"))
    {
        let _ = writeln!(inbox_f, "{event_json}");
    }

    let room_json = format!(
        "{{\"daemon_pid\":{},\"ts\":{now},\"active_source\":{},\"context\":{},\"should_agent_respond\":{},\"noise_floor_q15\":{},\"hue_f0_hz\":{hue_f0},\"hue_grains_learned\":{},\"friends_detected\":{friends_count},\"last_utterance\":{event_json}}}",
        std::process::id(),
        markdown_source_literal(analysis.source.as_str()),
        markdown_source_literal(analysis.context.as_str()),
        analysis.should_agent_respond,
        tr.noise_floor_q15,
        tr.primary_profile.grains_learned
    );
    let _ = fs::write(dir.join("room_state.json"), room_json);
}

fn read_hook_watermark() -> u64 {
    fs::read_to_string(mem8_dir().join("hook_last_ts.txt"))
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0)
}

fn write_hook_watermark(ts: u64) {
    let _ = fs::write(mem8_dir().join("hook_last_ts.txt"), ts.to_string());
}

/// Block until the user speaks a direct-address / wake-word utterance to the parallel ear daemon,
/// then print the diarized utterance JSON and exit `0` so Antigravity's Reactive Wakeup triggers
/// hands-free!
fn run_wait_wake() -> String {
    let dir = mem8_dir();
    let inbox_path = dir.join("ear_inbox.jsonl");
    let start_ts = now_secs();

    loop {
        thread::sleep(Duration::from_millis(250));
        let Ok(raw) = fs::read_to_string(&inbox_path) else {
            continue;
        };
        for line in raw.lines().rev() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let ts = extract_json_u64(trimmed, "ts").unwrap_or(0);
            if ts < start_ts {
                break;
            }
            let speaker = extract_json_str(trimmed, "speaker").unwrap_or_default();
            let should_respond = extract_json_bool(trimmed, "should_agent_respond").unwrap_or(false);
            let text = extract_json_str(trimmed, "text").unwrap_or_default();
            if speaker == "hue" && should_respond && text.split_whitespace().count() >= 2 {
                write_hook_watermark(ts);
                return format!(
                    "🎙️ [Qwave Voice Wakeup — Hue Spoke]: \"{text}\" | raw={trimmed}"
                );
            }
        }
    }
}

fn run_hook_session_start() -> String {
    write_hook_watermark(now_secs());
    let status = read_ear_inbox_json(3);
    let msg = format!("🎙️ [Qwave Parallel Ear Hook Active] {status}");
    format!(
        "{{\"injectSteps\":[{{\"ephemeralMessage\":{}}}]}}",
        markdown_source_literal(&msg)
    )
}

fn run_hook_pre_invocation() -> String {
    let last_ts = read_hook_watermark();
    let dir = mem8_dir();
    let inbox_raw = fs::read_to_string(dir.join("ear_inbox.jsonl")).unwrap_or_default();
    let mut new_events = Vec::new();
    let mut max_ts = last_ts;

    for line in inbox_raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let ts = extract_json_u64(trimmed, "ts").unwrap_or(0);
        if ts > last_ts {
            if ts > max_ts {
                max_ts = ts;
            }
            new_events.push(trimmed);
        }
    }

    if new_events.is_empty() {
        return "{}".to_string();
    }

    write_hook_watermark(max_ts);
    let tail: Vec<&str> = if new_events.len() > 6 {
        new_events[new_events.len() - 6..].to_vec()
    } else {
        new_events
    };
    let msg = format!(
        "🎙️ [Qwave Parallel Ear Live Room Feed — {} new diarized utterance(s)]: [{}]",
        tail.len(),
        tail.join(", ")
    );
    format!(
        "{{\"injectSteps\":[{{\"ephemeralMessage\":{}}}]}}",
        markdown_source_literal(&msg)
    )
}

fn run_hook_stop() -> String {
    let mut stdin_buf = String::new();
    let _ = std::io::stdin().read_to_string(&mut stdin_buf);
    let reason = extract_json_str(&stdin_buf, "terminationReason").unwrap_or_default();
    if reason != "NO_TOOL_CALL" && !reason.is_empty() {
        return "{\"decision\":\"allow\"}".to_string();
    }

    let last_ts = read_hook_watermark();
    let dir = mem8_dir();
    let inbox_raw = fs::read_to_string(dir.join("ear_inbox.jsonl")).unwrap_or_default();
    let mut max_ts = last_ts;
    let mut direct_hue_utterances = Vec::new();

    for line in inbox_raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let ts = extract_json_u64(trimmed, "ts").unwrap_or(0);
        if ts > last_ts {
            if ts > max_ts {
                max_ts = ts;
            }
            let speaker = extract_json_str(trimmed, "speaker").unwrap_or_default();
            let should_respond = extract_json_bool(trimmed, "should_agent_respond").unwrap_or(false);
            if speaker == "hue" && should_respond {
                if let Some(txt) = extract_json_str(trimmed, "text") {
                    direct_hue_utterances.push(txt);
                }
            }
        }
    }

    if direct_hue_utterances.is_empty() {
        return "{\"decision\":\"allow\"}".to_string();
    }

    write_hook_watermark(max_ts);
    let combined = direct_hue_utterances.join(" ");
    let cont_reason = format!(
        "🎙️ Hue just spoke out loud to you via Qwave Parallel Ear: \"{combined}\". Please respond!"
    );
    format!(
        "{{\"decision\":\"continue\",\"reason\":{}}}",
        markdown_source_literal(&cont_reason)
    )
}



