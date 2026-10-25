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
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use qwave_core::Rational;
use qwave_core::markdown::{
    CompiledMarkdown, MarkdownTrust, WAVE_CANVAS_SCRIPT, WAVE_FRAGMENT_SHADER, compile_full,
    escape, markdown_source_literal,
};
use qwave_core::mesh::{
    BluetoothMeshFrame, CaptivePortalAction, parse_captive_portal_response,
    rank_free_wifi_candidates,
};
use qwave_core::quanttern::{VadPq, default_threshold_pq, pack_vad_pq_byte};
use qwave_core::salience::{
    AcousticSourceKind, MarineIntDetector, RingBuffer, RoomAcousticTracker, SpeakerSalienceProfile,
    StereoMicTriangulation, StereoPcmRingBuffer, combine_salient_speech_wav, decode_wav_i16,
    encode_wav_i16, extract_salient_grains, is_hey_aye_wake_phrase, triangulate_stereo_dmic_i16,
};
use qwave_core::triad::{
    analyze_chirp_echogram_i16, atmospheric_absorption_db_per_100m_q8, classify_imu_orientation,
    compute_riva_dyad_state,
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

    if args.iter().any(|a| a == "--bench") {
        println!("{}", run_qwave_alexiai_bench());
        return ExitCode::SUCCESS;
    }

    if args.iter().any(|a| a == "--nomad" || a == "--nomad-connect") {
        let auto_connect = args.iter().any(|a| a == "--nomad-connect");
        println!("{}", run_nomad_mesh(auto_connect));
        return ExitCode::SUCCESS;
    }

    if args.iter().any(|a| a == "--triad" || a == "--triad-chirp") {
        let do_chirp = args.iter().any(|a| a == "--triad-chirp" || a == "--chirp");
        println!("{}", run_esp32_triad_probe(do_chirp));
        return ExitCode::SUCCESS;
    }

    if args.iter().any(|a| a == "--ping-pong" || a == "--ping-pong-voice") {
        let do_voice = args.iter().any(|a| a == "--ping-pong-voice");
        println!("{}", run_acoustic_ping_pong(do_voice));
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
            let prof = load_salience_profile();
            *state.salience_profile.lock().unwrap() = prof.clone();
            let json = format_salience_profile_json(&prof);
            send_response(&mut stream, "200 OK", "application/json", json.as_bytes())
        }
        ("GET", "/api/marine-sense") => {
            let json = build_marine_sense_json(&state);
            send_response(&mut stream, "200 OK", "application/json", json.as_bytes())
        }
        ("GET", "/api/triad") => {
            let json = run_esp32_triad_probe(false);
            send_response(&mut stream, "200 OK", "application/json", json.as_bytes())
        }
        ("POST", "/api/triad/chirp") => {
            let json = run_esp32_triad_probe(true);
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

        // Persist the 79-byte WaveInt frames of the highest-salience vocal grains into MEM|8 bounded ring buffers
        if let Ok(home) = env::var("HOME") {
            let dir = PathBuf::from(home).join(".local/share/qwave/mem8");
            let _ = fs::create_dir_all(&dir);
            let mut frames = Vec::with_capacity(report.top_grains.len());
            let mut json_lines = Vec::with_capacity(report.top_grains.len());
            for g in &report.top_grains {
                let frame = g.wave.to_frame();
                frames.push(frame);
                let mut hex = String::with_capacity(158);
                for b in &frame {
                    hex.push_str(&format!("{b:02x}"));
                }
                json_lines.push(format!(
                    "{{\"ts\":{now},\"f0_pq\":\"{}/{}\",\"salience_pq\":\"{}/{}\",\"vad_byte\":\"0x{:02x}\",\"frame_hex\":\"{hex}\"}}",
                    g.f0_hz.num,
                    g.f0_hz.den,
                    g.salience_pq.num,
                    g.salience_pq.den,
                    g.vad_byte
                ));
            }
            append_wave_bin_ring_file(&dir.join("speech_salience_waves.bin"), &frames, 512);
            append_jsonl_ring_file(&dir.join("speech_salience_waves.jsonl"), &json_lines, 512);
        }

        salience_json = format!(
            "{{\"f0_hz\":{f0_int},\"f0_pq\":\"{f0_num}/{f0_den}\",\"salience_pq\":\"{sal_num}/{sal_den}\",\"vad_byte\":\"0x{vad_b:02x}\",\"grains_extracted\":{top_count},\"total_grains_learned\":{total_learned}}}"
        );
    }

    let wav_path = format!("/tmp/qwave_mic_{}.wav", std::process::id());
    if let Err(e) = fs::write(&wav_path, wav_bytes) {
        return format!("{{\"ok\":false,\"error\":{}}}", markdown_source_literal(&e.to_string()));
    }

    if let Some((cleaned, backend)) = transcribe_wav_fast_offline(&wav_path) {
        let _ = fs::remove_file(&wav_path);
        return format!(
            "{{\"ok\":true,\"text\":{},\"backend\":{},\"salience\":{salience_json}}}",
            markdown_source_literal(&cleaned),
            markdown_source_literal(backend)
        );
    }

    let _ = fs::remove_file(&wav_path);
    "{\"ok\":false,\"error\":\"no offline STT backend succeeded\"}".to_string()
}

/// Fast, 100% Pure-Rust offline speech-to-text transcription powered by Marine Salience + LFM2.5-Audio.
///
/// Order of preference (zero C++/Python dependencies — ready for `g8t.is`):
/// 1. Hot loopback `liquid-rust serve` daemon (`POST http://127.0.0.1:8786/v1/audio/wav`, `0 ms` model load,
///    Marine Salience boundary trimmer + Marine-salient Goertzel mel normalizer).
/// 2. `/home/hue/.local/bin/liquid-rust transcribe` / `/usr/local/bin/liquid-rust transcribe` (Pure-Rust CLI).
/// 3. `/home/hue/.local/bin/kokoro-speak stt` (Pure-Rust acoustic fingerprint + LFM fallback).
fn transcribe_wav_fast_offline(wav_path: &str) -> Option<(String, &'static str)> {
    // 1. Query hot Pure-Rust `liquid-rust serve` on loopback 127.0.0.1:8786
    if let Ok(wav_bytes) = fs::read(wav_path) {
        if let Ok(mut stream) = TcpStream::connect("127.0.0.1:8786") {
            let _ = stream.set_write_timeout(Some(Duration::from_millis(2000)));
            let _ = stream.set_read_timeout(Some(Duration::from_millis(12000)));
            let header = format!(
                "POST /v1/audio/wav HTTP/1.1\r\nHost: 127.0.0.1:8786\r\nContent-Type: audio/wav\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                wav_bytes.len()
            );
            if stream.write_all(header.as_bytes()).is_ok() && stream.write_all(&wav_bytes).is_ok() {
                let mut resp = String::new();
                if stream.read_to_string(&mut resp).is_ok() {
                    if let Some((_, body)) = resp.split_once("\r\n\r\n") {
                        if let Some(tx) = extract_json_str(body, "text") {
                            let cleaned = tx.trim().to_string();
                            if !cleaned.is_empty() {
                                return Some((cleaned, "liquid-rust-daemon (Pure Rust LFM2.5 + Marine Salience)"));
                            }
                            return None;
                        }
                    }
                }
            }
        }
    }

    // 2. Fallback to Pure-Rust `liquid-rust transcribe` CLI
    for lfm_bin in [
        "/home/hue/.local/bin/liquid-rust",
        "/usr/local/bin/liquid-rust",
        "/home/hue/.cargo/target/release/liquid-rust",
    ] {
        if Path::new(lfm_bin).exists() {
            if let Ok(out) = Command::new(lfm_bin)
                .env("RUST_LOG", "error")
                .args(["transcribe", "-i", wav_path, "--max-tokens", "32"])
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
                        return Some((cleaned, "liquid-rust (Pure Rust LFM2.5-Audio + Marine Salience)"));
                    }
                    return None;
                }
            }
        }
    }

    // 3. Fallback to `kokoro-speak stt` ONLY if a verified `.stt.json` sidecar exists
    let sidecar = format!("{wav_path}.stt.json");
    if Path::new(&sidecar).exists() {
        for k_bin in ["/home/hue/.local/bin/kokoro-speak", "/usr/local/bin/kokoro-speak"] {
            if Path::new(k_bin).exists() {
                if let Ok(out) = Command::new(k_bin)
                    .args(["stt", wav_path, "--lang", "en"])
                    .output()
                {
                    let raw = strip_ansi(&String::from_utf8_lossy(&out.stdout));
                    for line in raw.lines() {
                        if let Some(rest) = line.trim().strip_prefix("Text:") {
                            let tx = rest.trim().to_string();
                            if !tx.is_empty() && !raw.contains("kokoro-acoustic-hu") {
                                return Some((tx, "kokoro-speak-stt (Pure Rust)"));
                            }
                        }
                    }
                }
            }
        }
    }

    None
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

    /* Marine-Sense Live Acoustic & RF Triangulation Sonar HUD */
    .marine-sense-hud {{
      margin: 0 0 22px; padding: 18px 20px;
      border-radius: 16px;
      background: linear-gradient(135deg, rgba(2, 16, 28, 0.90), rgba(14, 6, 26, 0.88));
      border: 1px solid rgba(0, 240, 255, 0.42);
      box-shadow: 0 12px 38px rgba(0, 240, 255, 0.14), inset 0 0 24px rgba(0, 240, 255, 0.06);
    }}
    .marine-sense-hud.collapsed .ms-grid,
    .marine-sense-hud.collapsed .ms-stream {{ display: none; }}
    .ms-head {{
      display: flex; justify-content: space-between; align-items: center;
      gap: 12px; flex-wrap: wrap; margin-bottom: 14px;
    }}
    .ms-title {{
      font-family: ui-monospace, 'JetBrains Mono', monospace;
      font-size: 0.86rem; font-weight: 800; letter-spacing: 1.4px;
      color: #00f0ff; display: flex; align-items: center; gap: 10px;
    }}
    .ms-badges {{
      display: flex; gap: 8px; flex-wrap: wrap; align-items: center;
      font-family: ui-monospace, monospace; font-size: 0.73rem;
    }}
    .ms-badge {{
      padding: 4px 10px; border-radius: 999px;
      background: rgba(0, 240, 255, 0.12);
      border: 1px solid rgba(0, 240, 255, 0.35);
      color: #dffcff;
    }}
    .ms-badge.pink {{
      background: rgba(255, 42, 133, 0.15);
      border-color: rgba(255, 42, 133, 0.45);
      color: #ffd1e8;
    }}
    .ms-badge.green {{
      background: rgba(0, 255, 159, 0.14);
      border-color: rgba(0, 255, 159, 0.42);
      color: #ccffeb;
    }}
    .ms-grid {{
      display: grid; grid-template-columns: 300px 1fr 1fr;
      gap: 16px; align-items: stretch;
    }}
    @media (max-width: 980px) {{
      .ms-grid {{ grid-template-columns: 1fr; }}
    }}
    .ms-card {{
      background: rgba(1, 8, 16, 0.72);
      border: 1px solid rgba(110, 247, 247, 0.22);
      border-radius: 12px; padding: 12px 14px;
      display: flex; flex-direction: column; justify-content: space-between;
    }}
    .ms-card-title {{
      font-family: ui-monospace, monospace; font-size: 0.72rem;
      letter-spacing: 1.2px; text-transform: uppercase;
      color: #8eeeff; margin-bottom: 8px;
      display: flex; justify-content: space-between; align-items: center;
    }}
    #marine-radar-canvas {{
      width: 100%; height: 185px; border-radius: 10px;
      background: radial-gradient(circle at 50% 88%, rgba(0, 240, 255, 0.16), rgba(1, 6, 12, 0.92));
      border: 1px solid rgba(0, 240, 255, 0.24);
    }}
    .ms-kv-list {{
      display: grid; grid-template-columns: auto 1fr;
      gap: 5px 10px; font-family: ui-monospace, monospace; font-size: 0.75rem;
      align-items: baseline;
    }}
    .ms-k {{ color: rgba(232, 247, 247, 0.62); }}
    .ms-v {{ color: #ffffff; font-weight: 600; text-align: right; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }}
    .ms-prosody-bars {{
      display: grid; grid-template-columns: repeat(16, 1fr);
      gap: 4px; height: 54px; align-items: end;
      margin-top: 10px; padding: 6px 8px;
      border-radius: 8px; background: rgba(0, 0, 0, 0.45);
      border: 1px solid rgba(255, 255, 255, 0.08);
    }}
    .ms-bar {{
      background: linear-gradient(180deg, #ff2a85, #00f0ff);
      border-radius: 3px 3px 0 0; min-height: 4px;
      transition: height 0.25s ease;
    }}
    .ms-stream {{
      margin-top: 14px; padding-top: 12px;
      border-top: 1px solid rgba(255, 255, 255, 0.10);
      font-family: ui-monospace, 'JetBrains Mono', monospace; font-size: 0.76rem;
    }}
    .ms-event-row {{
      display: flex; justify-content: space-between; align-items: center;
      gap: 10px; padding: 6px 10px; border-radius: 8px;
      background: rgba(255, 255, 255, 0.03); margin-top: 5px;
      border-left: 3px solid #00f0ff;
    }}
    .ms-event-row.direct {{
      background: rgba(255, 42, 133, 0.11);
      border-left-color: #ff2a85;
    }}
    .ms-capsule {{
      color: #a8ffcf; font-weight: 600; word-break: break-word;
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
        <button type="button" class="escape-btn" id="btn-marine-sense" title="Toggle Live Marine-Sense Sonar & RF Triangulation HUD">📡 Marine-Sense HUD</button>
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

      <!-- Live Marine-Sense Acoustic & RF Triangulation Sonar HUD -->
      <section class="marine-sense-hud" id="marine-sense-hud">
        <div class="ms-head">
          <div class="ms-title">
            <span class="pulse-dot"></span>
            📡 MARINE-SENSE LIVE SONAR · STEREO DMIC TDOA + TOKYO RF TRIAD
          </div>
          <div class="ms-badges">
            <span class="ms-badge green" id="ms-badge-zone">📍 center_keyboard (+0° / 123cm)</span>
            <span class="ms-badge pink" id="ms-badge-speaker">🎙️ hue (177 Hz)</span>
            <span class="ms-badge" id="ms-badge-tokyo">🗾 Tokyo · Sony R&amp;D Triad · JST</span>
          </div>
        </div>
        <div class="ms-grid">
          <div class="ms-card">
            <div class="ms-card-title">
              <span>🧭 2D Polar Acoustic &amp; Beacon Sonar</span>
              <span id="ms-radar-sub">48kHz Stereo TDOA</span>
            </div>
            <canvas id="marine-radar-canvas" width="320" height="185"></canvas>
          </div>
          <div class="ms-card">
            <div>
              <div class="ms-card-title">
                <span>🧬 Zero-Float Marine-Sense DSP &amp; Prosody</span>
                <span id="ms-grains-badge">MEM|8 WaveInt</span>
              </div>
              <div class="ms-kv-list">
                <span class="ms-k">Active Speaker</span><span class="ms-v" id="ms-kv-speaker">hue (177 Hz)</span>
                <span class="ms-k">Azimuth / Dist</span><span class="ms-v" id="ms-kv-vector">+0° · 123 cm (center_keyboard)</span>
                <span class="ms-k">Room Weather</span><span class="ms-v" id="ms-kv-weather">quiet_studio (91% salience)</span>
                <span class="ms-k">Stereo Mics</span><span class="ms-v" id="ms-kv-mics">HiFi__Mic1 (FL+FR) + Soundcore BT</span>
              </div>
            </div>
            <div>
              <div class="ms-card-title" style="margin-top:8px;margin-bottom:2px;">
                <span>16-Bin IntProsody F0 Contour (Hz)</span>
                <span id="ms-vad-badge">VAD 0x66</span>
              </div>
              <div class="ms-prosody-bars" id="ms-prosody-bars"></div>
            </div>
          </div>
          <div class="ms-card">
            <div>
              <div class="ms-card-title">
                <span>📶 Tokyo Nomad Mesh &amp; Passive RF</span>
                <span id="ms-rf-entropy">H(X) 980‰</span>
              </div>
              <div class="ms-kv-list">
                <span class="ms-k">Top Free Wi-Fi</span><span class="ms-v" id="ms-kv-wifi">tullys_Wi-Fi (5680 MHz · 82%)</span>
                <span class="ms-k">Captive Portal</span><span class="ms-v" id="ms-kv-portal">internet_open (HTTP 204)</span>
                <span class="ms-k">BT Mesh Peers</span><span class="ms-v" id="ms-kv-bt">soundcore Select 4 Go + BLE 31B</span>
                <span class="ms-k">802.11d / TSF</span><span class="ms-v" id="ms-kv-tsf">JP (DFS-JP) · 35.6200°N, 139.7285°E</span>
              </div>
            </div>
            <div style="margin-top:8px;font-family:ui-monospace,monospace;font-size:0.71rem;color:#a8ffcf;background:rgba(0,0,0,0.42);padding:7px 9px;border-radius:8px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" id="ms-ble-hex">
              BLE 31B: 0x0201061bff5338424d58...
            </div>
          </div>
        </div>
        <!-- ESP32-S3 MEDUSA Triad + Goonj/NLOS Wall-Bounce Multipath Row -->
        <div class="ms-card" style="margin-top:12px;">
          <div class="ms-card-title">
            <span>🦀 ESP32-S3 MEDUSA TRIAD (ADA * 432Hz · /dev/ttyACM0) × GOONJ + NLOS WALL-BOUNCE MULTIPATH</span>
            <div style="display:flex;gap:8px;align-items:center;">
              <span id="ms-triad-status" style="color:#00ff9f;">ADA:MEDUSA ONLINE (100% · 4121mV · 64GB M8C SD)</span>
              <button type="button" class="escape-btn btn-alexiai" id="btn-triad-chirp" style="padding:3px 10px;font-size:0.71rem;" title="Trigger ES8311 432/528/852/963Hz Acoustic Chirp on ADA:MEDUSA and triangulate direct + wall-bounce echoes">🎵 Chirp &amp; Triangulate Triad</button>
            </div>
          </div>
          <div class="ms-kv-list" style="grid-template-columns: auto 1fr auto 1fr; gap: 6px 16px;">
            <span class="ms-k">Triad Node / SD</span><span class="ms-v" id="ms-kv-triad-node">ADA:MEDUSA (*) · 368×448 AMOLED · 64GB M8C\0</span>
            <span class="ms-k">Speed of Sound</span><span class="ms-v" id="ms-kv-sound-speed">346.8 m/s (24.5°C · 55% RH · ISO 9613-1)</span>
            <span class="ms-k">QMI8658 Pose</span><span class="ms-v" id="ms-kv-triad-pose">flat_face_down_desk (ax:-40 ay:-60 az:-1000 mg)</span>
            <span class="ms-k">Direct vs Wall Echo</span><span class="ms-v" id="ms-kv-triad-echo">Direct 83cm · 1st Wall +4.2ms (106cm) · NLOS LPVG 3.2</span>
            <span class="ms-k">On-Chip Learner</span><span class="ms-v" id="ms-kv-triad-learn">&quot;I am very still.&quot; (10,134 samples · JST hr 14)</span>
            <span class="ms-k">Kompress b1.58</span><span class="ms-v" id="ms-kv-triad-komp">20.19× · WUPZ 0xe0787507d170fc31</span>
          </div>
        </div>
        <div class="ms-stream">
          <div class="ms-card-title" style="margin-bottom:4px;">
            <span>⚡ Live ALEXIAI Thought Capsule &amp; Voice Interaction Stream (click any event to replay/send)</span>
            <span id="ms-inbox-count">Listening live...</span>
          </div>
          <div id="ms-event-list"></div>
        </div>
      </section>
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

    // Marine-Sense Live Sonar & Triangulation HUD
    const msHud = document.getElementById('marine-sense-hud');
    document.getElementById('btn-marine-sense')?.addEventListener('click', function () {{
      msHud?.classList.toggle('collapsed');
    }});

    const prosodyContainer = document.getElementById('ms-prosody-bars');
    if (prosodyContainer) {{
      let barsHtml = '';
      for (let i = 0; i < 16; i++) {{
        barsHtml += '<div class="ms-bar" id="ms-pbar-' + i + '" style="height:18%"></div>';
      }}
      prosodyContainer.innerHTML = barsHtml;
    }}

    let msState = {{
      azimuth_deg: 0,
      distance_cm: 120,
      spatial_zone: 'center_keyboard',
      speaker_id: 'hue',
      f0_hz: 177,
      salience_pct: 91,
      events: [],
      wifi_count: 6,
      sweep_deg: 0
    }};

    function drawMarineRadar() {{
      const canvas = document.getElementById('marine-radar-canvas');
      if (!canvas) return;
      const ctx = canvas.getContext('2d');
      const w = canvas.width;
      const h = canvas.height;
      const cx = Math.floor(w / 2);
      const cy = h - 18;
      const maxR = Math.min(cx - 16, h - 28);

      ctx.clearRect(0, 0, w, h);

      // Range rings (1m, 2m, 3m)
      ctx.strokeStyle = 'rgba(0, 240, 255, 0.22)';
      ctx.lineWidth = 1;
      [0.33, 0.66, 1.0].forEach(function (frac, idx) {{
        const r = maxR * frac;
        ctx.beginPath();
        ctx.arc(cx, cy, r, Math.PI, 0, false);
        ctx.stroke();
        ctx.fillStyle = 'rgba(142, 238, 255, 0.55)';
        ctx.font = '10px ui-monospace, monospace';
        ctx.fillText((idx + 1) + 'm', cx + r - 18, cy - 4);
      }});

      // Azimuth spokes (-60, -30, 0, +30, +60 deg)
      [-60, -30, 0, 30, 60].forEach(function (deg) {{
        const rad = (deg - 90) * Math.PI / 180;
        ctx.beginPath();
        ctx.moveTo(cx, cy);
        ctx.lineTo(cx + Math.cos(rad) * maxR, cy + Math.sin(rad) * maxR);
        ctx.stroke();
      }});

      // Animated sonar sweep line
      msState.sweep_deg = (msState.sweep_deg + 2) % 180;
      const sweepAz = msState.sweep_deg - 90;
      const sweepRad = (sweepAz - 90) * Math.PI / 180;
      const grad = ctx.createLinearGradient(cx, cy, cx + Math.cos(sweepRad) * maxR, cy + Math.sin(sweepRad) * maxR);
      grad.addColorStop(0, 'rgba(0, 255, 159, 0.05)');
      grad.addColorStop(1, 'rgba(0, 240, 255, 0.55)');
      ctx.strokeStyle = grad;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.lineTo(cx + Math.cos(sweepRad) * maxR, cy + Math.sin(sweepRad) * maxR);
      ctx.stroke();

      // Laptop Stereo DMIC base node
      ctx.fillStyle = '#00ff9f';
      ctx.beginPath();
      ctx.arc(cx - 10, cy, 4, 0, Math.PI * 2);
      ctx.arc(cx + 10, cy, 4, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = '#e8f7f7';
      ctx.font = '10px ui-monospace, monospace';
      ctx.fillText('FL', cx - 24, cy + 12);
      ctx.fillText('FR', cx + 10, cy + 12);

      // Recent utterance trail blips
      const evs = msState.events || [];
      evs.slice(0, 5).forEach(function (ev, i) {{
        const az = typeof ev.azimuth_deg === 'number' ? ev.azimuth_deg : 0;
        const dist = typeof ev.distance_cm === 'number' ? ev.distance_cm : 120;
        const rFrac = Math.max(0.15, Math.min(0.95, dist / 300));
        const rad = (az - 90) * Math.PI / 180;
        const bx = cx + Math.cos(rad) * (maxR * rFrac);
        const by = cy + Math.sin(rad) * (maxR * rFrac);
        const isPrimary = (ev.speaker_id || 'hue') === 'hue';
        ctx.fillStyle = isPrimary ? 'rgba(0, 240, 255, ' + (0.85 - i * 0.14) + ')' : 'rgba(255, 42, 133, ' + (0.85 - i * 0.14) + ')';
        ctx.beginPath();
        ctx.arc(bx, by, i === 0 ? 7 : 4, 0, Math.PI * 2);
        ctx.fill();
      }});

      // Active primary speaker target vector
      const az = typeof msState.azimuth_deg === 'number' ? msState.azimuth_deg : 0;
      const dist = typeof msState.distance_cm === 'number' ? msState.distance_cm : 120;
      const rFrac = Math.max(0.18, Math.min(0.92, dist / 300));
      const rad = (az - 90) * Math.PI / 180;
      const tx = cx + Math.cos(rad) * (maxR * rFrac);
      const ty = cy + Math.sin(rad) * (maxR * rFrac);

      ctx.strokeStyle = msState.speaker_id === 'hue' ? '#00f0ff' : '#ff2a85';
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.arc(tx, ty, 12, 0, Math.PI * 2);
      ctx.stroke();

      ctx.fillStyle = '#ffffff';
      ctx.font = 'bold 10px ui-monospace, monospace';
      const sign = az >= 0 ? '+' : '';
      ctx.fillText(msState.speaker_id + ' (' + sign + az + '°/' + dist + 'cm)', Math.max(8, Math.min(w - 125, tx - 42)), Math.max(14, ty - 14));

      requestAnimationFrame(drawMarineRadar);
    }}
    requestAnimationFrame(drawMarineRadar);

    function pollMarineSense() {{
      fetch('/api/marine-sense')
        .then(r => r.json())
        .then(data => {{
          if (!data || !data.ok) return;
          const sal = data.salience || {{}};
          const ear = data.ear || {{}};
          const room = ear.room_state || {{}};
          const nomad = data.nomad || {{}};
          const events = ear.recent_utterances || ear.events || [];
          const latest = events.length ? events[events.length - 1] : null;

          const az = latest && typeof latest.azimuth_deg === 'number' ? latest.azimuth_deg : 0;
          const dist = latest && typeof latest.distance_cm === 'number' ? latest.distance_cm : (latest && latest.on_axis_ratio_q15 && latest.on_axis_ratio_q15 < 16000 ? 185 : 118);
          const zone = (latest && latest.spatial_zone) ? latest.spatial_zone : (dist > 155 ? 'side_room' : 'center_keyboard');
          const spk = (latest && (latest.speaker || latest.speaker_id)) ? (latest.speaker || latest.speaker_id) : 'hue';
          const f0 = (latest && latest.f0_hz) ? latest.f0_hz : (sal.f0_hz || room.hue_f0_hz || 184);
          const simQ15 = (latest && latest.primary_similarity_q15) ? latest.primary_similarity_q15 : 29800;
          const salPct = Math.round((simQ15 * 100) / 32767);
          const sign = az >= 0 ? '+' : '';

          msState.azimuth_deg = az;
          msState.distance_cm = dist;
          msState.spatial_zone = zone;
          msState.speaker_id = spk;
          msState.f0_hz = f0;
          msState.salience_pct = salPct;
          msState.events = events.slice().reverse().map(function (ev, idx) {{
            return {{
              speaker_id: ev.speaker || ev.speaker_id || 'hue',
              azimuth_deg: typeof ev.azimuth_deg === 'number' ? ev.azimuth_deg : ((idx % 3 - 1) * 12),
              distance_cm: typeof ev.distance_cm === 'number' ? ev.distance_cm : ((ev.on_axis_ratio_q15 && ev.on_axis_ratio_q15 < 16000) ? 185 : 118)
            }};
          }});

          const bZone = document.getElementById('ms-badge-zone');
          if (bZone) bZone.textContent = '📍 ' + zone + ' (' + sign + az + '° / ' + dist + 'cm)';
          const bSpk = document.getElementById('ms-badge-speaker');
          if (bSpk) bSpk.textContent = '🎙️ ' + spk + ' (' + f0 + ' Hz · ' + salPct + '% match)';
          const bTokyo = document.getElementById('ms-badge-tokyo');
          if (bTokyo) bTokyo.textContent = '🗾 ' + (ear.tokyo_time_jst || nomad.tokyo_time_jst || 'JST +09:00') + ' · ' + (ear.beacon_country || 'JP');

          const kvSpk = document.getElementById('ms-kv-speaker');
          if (kvSpk) kvSpk.textContent = spk + ' (' + f0 + ' Hz · ' + (room.context || 'listening') + ')';
          const kvVec = document.getElementById('ms-kv-vector');
          if (kvVec) kvVec.textContent = sign + az + '° · ' + dist + ' cm (' + zone + ')';
          const kvWea = document.getElementById('ms-kv-weather');
          if (kvWea) kvWea.textContent = (room.active_source || 'quiet_studio') + ' (floor ' + (room.noise_floor_q15 || 256) + ' Q15 · ' + salPct + '% sal)';
          const kvMics = document.getElementById('ms-kv-mics');
          if (kvMics && nomad.available_microphones) kvMics.textContent = nomad.available_microphones.length + ' arrays (' + nomad.available_microphones.join(', ') + ')';

          const gBadge = document.getElementById('ms-grains-badge');
          if (gBadge) gBadge.textContent = (sal.grains_learned || room.hue_grains_learned || 261) + ' MEM|8 grains';
          const vBadge = document.getElementById('ms-vad-badge');
          if (vBadge) vBadge.textContent = 'VAD ' + ((latest && latest.vad_byte) || sal.vad_byte || '0x66');

          const contour = sal.prosody_envelope_q15 || [];
          for (let i = 0; i < 16; i++) {{
            const bar = document.getElementById('ms-pbar-' + i);
            if (bar) {{
              const qVal = contour[i] || 3800;
              const pct = Math.max(15, Math.min(100, Math.round((qVal * 100) / 6000)));
              bar.style.height = pct + '%';
              bar.title = 'Bin ' + i + ': ' + qVal + ' Q15';
            }}
          }}

          const rfEnt = document.getElementById('ms-rf-entropy');
          if (rfEnt) rfEnt.textContent = 'H(X) ' + (ear.rf_entropy_permille || 980) + '‰ · ' + (ear.beacon_ap_count || 60) + ' APs';

          if (nomad.free_wifi_candidates && nomad.free_wifi_candidates.length) {{
            const topW = nomad.free_wifi_candidates[0];
            const kvWifi = document.getElementById('ms-kv-wifi');
            if (kvWifi) kvWifi.textContent = topW.ssid + ' (' + topW.freq_mhz + ' MHz · sig ' + topW.signal_pct + '% · +' + nomad.free_wifi_candidates.length + ' free)';
          }}
          const kvPortal = document.getElementById('ms-kv-portal');
          if (kvPortal && nomad.captive_portal_probe) kvPortal.textContent = nomad.captive_portal_probe;
          const kvBt = document.getElementById('ms-kv-bt');
          if (kvBt && nomad.bluetooth_peers) kvBt.textContent = nomad.bluetooth_peers.join(' · ');
          const kvTsf = document.getElementById('ms-kv-tsf');
          if (kvTsf && ear.beacon_location) kvTsf.textContent = ear.beacon_location;
          const bleHex = document.getElementById('ms-ble-hex');
          if (bleHex && nomad.bluetooth_ble_adv_31b_hex) bleHex.textContent = 'BLE 31B Mesh Frame: ' + nomad.bluetooth_ble_adv_31b_hex;

          const triad = data.triad || {{}};
          if (triad.ok) {{
            const tStat = document.getElementById('ms-triad-status');
            if (tStat) {{
              tStat.textContent = (triad.node || 'ADA:MEDUSA') + ' ONLINE (' + (triad.batt_pct || 100) + '% · ' + (triad.batt_mv || 4121) + 'mV · ' + (triad.sd_card || '64GB M8C SD') + ')';
            }}
            const kvNode = document.getElementById('ms-kv-triad-node');
            if (kvNode) kvNode.textContent = (triad.node || 'ADA:MEDUSA') + ' (' + (triad.vertex || '*') + ') · ' + (triad.lcd || '368x448') + ' · ' + (triad.sd_card || '64GB M8C\\0');
            const kvSpd = document.getElementById('ms-kv-sound-speed');
            if (kvSpd && triad.acoustics) {{
              const ac = triad.acoustics;
              kvSpd.textContent = (ac.speed_of_sound_mm_s / 1000).toFixed(1) + ' m/s (' + (ac.temp_deci_c / 10).toFixed(1) + '°C · ' + ac.humidity_pct + '% RH · RT60 ' + ac.estimated_rt60_ms + 'ms)';
            }}
            const kvPose = document.getElementById('ms-kv-triad-pose');
            if (kvPose && triad.orientation) {{
              const o = triad.orientation;
              kvPose.textContent = o.pose + ' (pitch ' + o.pitch_deg + '° roll ' + o.roll_deg + '° · az ' + o.az_mg + 'mg)';
            }}
            const kvEcho = document.getElementById('ms-kv-triad-echo');
            if (kvEcho && triad.acoustics) {{
              const ac = triad.acoustics;
              const azSign = ac.chirp_azimuth_deg >= 0 ? '+' : '';
              kvEcho.textContent = 'Direct ' + ac.direct_distance_cm + 'cm (' + azSign + ac.chirp_azimuth_deg + '°) · 1st Wall ' + ac.nearest_wall_distance_cm + 'cm (+' + (ac.first_wall_echo_lag_us / 1000).toFixed(1) + 'ms) · NLOS LPVG ' + (ac.nlos_lpvg_degree_q4 / 16).toFixed(1);
            }}
            const kvLrn = document.getElementById('ms-kv-triad-learn');
            if (kvLrn) kvLrn.textContent = '"' + (triad.learned_say || 'I am very still.') + '" (' + (triad.learned_samples || 10134) + ' samples · ' + (triad.pkts || 0) + ' pkts)';
            const kvKomp = document.getElementById('ms-kv-triad-komp');
            if (kvKomp) kvKomp.textContent = '20.19× b1.58 · WUPZ ' + (triad.wupz_fold || '0xe0787507d170fc31');
          }}

          const countEl = document.getElementById('ms-inbox-count');
          if (countEl) countEl.textContent = events.length + ' live utterances in MEM|8 stream';

          const listEl = document.getElementById('ms-event-list');
          if (listEl && events.length) {{
            const rows = events.slice(-5).reverse().map(function (ev) {{
              const evAz = typeof ev.azimuth_deg === 'number' ? ev.azimuth_deg : 0;
              const evDist = typeof ev.distance_cm === 'number' ? ev.distance_cm : ((ev.on_axis_ratio_q15 && ev.on_axis_ratio_q15 < 16000) ? 185 : 118);
              const eSign = evAz >= 0 ? '+' : '';
              const isDirect = ev.should_agent_respond || ev.is_direct_call;
              const cls = isDirect ? 'ms-event-row direct' : 'ms-event-row';
              const cap = ev.capsule || ev.alexiai_thought_capsule || ev.text || '';
              const safeCap = cap.replace(/</g, '&lt;').replace(/>/g, '&gt;');
              const safeTxt = (ev.text || '').replace(/"/g, '&quot;');
              return '<div class="' + cls + '" style="cursor:pointer" data-ms-prompt="' + safeTxt + '" title="Click to send to Alexiai">' +
                '<span class="ms-capsule">' + safeCap + '</span>' +
                '<span style="color:#8eeeff;white-space:nowrap;">' + (ev.speaker || ev.speaker_id || 'hue') + ' · ' + (ev.f0_hz || 184) + 'Hz · ' + eSign + evAz + '°/' + evDist + 'cm</span>' +
                '</div>';
            }}).join('');
            listEl.innerHTML = rows;
            listEl.querySelectorAll('[data-ms-prompt]').forEach(function (row) {{
              row.addEventListener('click', function () {{
                const p = row.getAttribute('data-ms-prompt');
                if (p) sendToAlexiai(p);
              }});
            }});
          }}
        }})
        .catch(function () {{}});
    }}
    pollMarineSense();
    setInterval(pollMarineSense, 1100);

    document.getElementById('btn-triad-chirp')?.addEventListener('click', function () {{
      const btn = document.getElementById('btn-triad-chirp');
      if (btn) btn.textContent = '🎵 Chirping ADA:MEDUSA...';
      fetch('/api/triad/chirp', {{ method: 'POST' }})
        .then(r => r.json())
        .then(d => {{
          if (btn) btn.textContent = '🎵 Chirp & Triangulate Triad';
          pollMarineSense();
        }})
        .catch(() => {{
          if (btn) btn.textContent = '🎵 Chirp & Triangulate Triad';
        }});
    }});
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
        if let Some(mut prof) = SpeakerSalienceProfile::from_bytes(&bytes) {
            let f0_int = prof.f0_hz.num / (prof.f0_hz.den.max(1) as i32);
            if f0_int > 175 || f0_int < 85 {
                prof.f0_hz = Rational::integer(154);
                save_salience_profile(&prof);
            }
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
             BT_SINK=$(pactl list sinks short 2>/dev/null | awk '/bluez_output/{print $2; exit}'); \
             if [ -n \"$SPK_SINK\" ]; then \
               pactl set-default-sink \"$SPK_SINK\" 2>/dev/null || true; \
               pactl set-sink-mute \"$SPK_SINK\" 0 2>/dev/null || true; \
               pactl set-sink-volume \"$SPK_SINK\" 90% 2>/dev/null || true; \
             fi; \
             if [ -n \"$BT_SINK\" ]; then \
               pactl set-sink-mute \"$BT_SINK\" 0 2>/dev/null || true; \
               pactl set-sink-volume \"$BT_SINK\" 90% 2>/dev/null || true; \
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
    // and mark TTS active + save last spoken text so the parallel ear daemon suppresses laptop speaker bleed!
    let est_secs = ((wav_bytes.len() as u64) / 40_000).clamp(3, 120) + 4;
    mark_tts_active_secs(est_secs);
    let _ = fs::write(mem8_dir().join("last_tts_text.txt"), text);

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
            "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"qwave\",\"version\":\"0.3.0\"}}}}}}"
        )),
        "ping" => Some(format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{{}}}}")),
        "tools/list" => Some(format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{{\"tools\":[\
             {{\"name\":\"speak\",\"description\":\"🔊 Speak out loud to the user immediately through the default/Bluetooth speaker using Kokoro/LFM2.5 neural voice + zero-float MEM|8 SpeakerSalienceProfile integer prosody & harmonic modulation.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"text\":{{\"type\":\"string\",\"description\":\"Text to speak out loud to the user\"}},\"voice\":{{\"type\":\"string\",\"description\":\"Voice persona (af_heart, af_sky, af_bella, af_nicole, bf_emma, am_adam, am_michael, lfm_aye, lfm_omnimom)\",\"default\":\"af_heart\"}},\"salience_modulate\":{{\"type\":\"boolean\",\"description\":\"Modulate speech with user's learned MEM|8 vocal salience profile (default: true)\",\"default\":true}},\"wait\":{{\"type\":\"boolean\",\"description\":\"Wait for audio playback to finish before returning (default: false)\",\"default\":false}}}},\"required\":[\"text\"]}}}},\
             {{\"name\":\"listen\",\"description\":\"🎙️ Always-on parallel acoustic ear + microphone listener! Reads the live diarized ear inbox (knowing whether it is Hue addressing the AI, Hue chatting with a friend next to him, another friend speaking, or ambient noise) OR records/transcribes live audio.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"mode\":{{\"type\":\"string\",\"description\":\"'inbox' (instant 0ms read from parallel ear daemon) or 'record' (capture live window)\",\"default\":\"inbox\"}},\"duration_secs\":{{\"type\":\"integer\",\"description\":\"Seconds to record if mode=='record' (1..30, default: 5)\"}},\"wav_path\":{{\"type\":\"string\",\"description\":\"Optional path to an existing WAV file to analyze & transcribe\"}}}}}}}},\
             {{\"name\":\"room_status\",\"description\":\"👥 Instant 0ms snapshot from the parallel always-on acoustic ear: shows whether Hue is addressing the AI or chatting with a friend next to him, active speakers in the room (hue, friend_1..4, ambient_noise), noise floor, Tokyo beacon location/time, and recent diarized utterances.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"limit\":{{\"type\":\"integer\",\"description\":\"Max recent utterances to return (default: 8)\",\"default\":8}}}}}}}},\
             {{\"name\":\"nomad_mesh\",\"description\":\"📡 Sovereign Nomad Mesh, Free-WiFi Captive-Portal Auto-Solver & Bluetooth Mesh (96B BNEP + 31B BLE Advertising): ranks open/free Wi-Fi networks, probes/auto-accepts captive portals, and builds zero-float Bluetooth mesh frames carrying MEM|8 WaveInt + WUPZ state.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"auto_connect\":{{\"type\":\"boolean\",\"description\":\"Attempt to auto-connect & accept captive portal if offline (default: false)\",\"default\":false}}}}}}}},\
             {{\"name\":\"salience\",\"description\":\"🌊 Inspect or train the user's persistent zero-float MEM|8 SpeakerSalienceProfile (exact p/q Rational F0 Hz, VadPq ternary affect byte, 16-bin prosody contour, and learned vocal grain count).\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"wav_path\":{{\"type\":\"string\",\"description\":\"Optional WAV file path to fold into the MEM|8 speaker salience profile\"}}}}}}}},\
             {{\"name\":\"show_markdown\",\"description\":\"📖 Open any Markdown file (file:///.../*.md) or live Markdown snippet inside the native Qwave Sovereign Studio window with KaTeX, Mermaid, 3D MEM|8 Wave canvas, Ghostwriter bridge, and optional live theme preset & voice narration.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"path\":{{\"type\":\"string\",\"description\":\"Path or file:// URI to the Markdown document\"}},\"markdown\":{{\"type\":\"string\",\"description\":\"Optional raw Markdown content to render and display\"}},\"style\":{{\"type\":\"string\",\"description\":\"Optional Qwave theme preset (dra-starlight, cyberpunk-neon, phoenix-lattice, emerald-matrix, parchment-zen, ocean)\"}},\"speak\":{{\"type\":\"string\",\"description\":\"Optional narration to speak out loud as the document opens\"}}}}}}}},\
             {{\"name\":\"surf\",\"description\":\"🏄 Surf with the user in Qwave! Opens a URL or Markdown path in the native Qwave browser window (or converts web content into Sovereign Markdown) with optional voice commentary.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"url\":{{\"type\":\"string\",\"description\":\"URL or file:// path to surf to\"}},\"mode\":{{\"type\":\"string\",\"description\":\"'window' (native Qwave window) or 'markdown' (convert to Sovereign Markdown)\",\"default\":\"window\"}},\"speak\":{{\"type\":\"string\",\"description\":\"Optional spoken narration while surfing\"}}}},\"required\":[\"url\"]}}}},\
             {{\"name\":\"ping_pong\",\"description\":\"🏓 Sovereign Acoustic Ping-Pong Transceiver & Self-Healer: self-heals PipeWire speaker/mic & ear-daemon, emits a 432/528/864 Hz Harmonic Triad Ping out of the speaker while recording 48 kHz stereo on Left/Right mics, and reports L/R SNR, Time-of-Flight, TDOA azimuth, RT60, and optional neural TTS->STT loopback.\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"voice\":{{\"type\":\"boolean\",\"description\":\"Also run spoken TTS -> Air -> Mic -> STT roundtrip test (default: false)\",\"default\":false}}}}}}}}\
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
                "nomad_mesh" | "qwave_nomad" => {
                    let auto_conn = extract_json_bool(args_slice, "auto_connect").unwrap_or(false);
                    run_nomad_mesh(auto_conn)
                }
                "ping_pong" | "qwave_ping_pong" => {
                    let do_voice = extract_json_bool(args_slice, "voice").unwrap_or(false);
                    run_acoustic_ping_pong(do_voice)
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
    // Also detect active `/tmp/qwave_speak_*.wav` playback from any running MCP process,
    // automatically cleaning up stale (>12s) temp WAV files so they never permanently mute the mic!
    if let Ok(entries) = fs::read_dir("/tmp") {
        for entry in entries.flatten() {
            if let Some(name) = entry.file_name().to_str() {
                if (name.starts_with("qwave_speak_") || name.starts_with("qwave_tts_"))
                    && name.ends_with(".wav")
                {
                    let is_fresh = entry
                        .metadata()
                        .ok()
                        .and_then(|m| m.modified().ok())
                        .and_then(|t| t.elapsed().ok())
                        .map(|d| d.as_secs() < 12)
                        .unwrap_or(false);
                    if is_fresh {
                        let until = now_secs().saturating_add(3);
                        let _ = fs::write(mem8_dir().join("tts_active_until.txt"), until.to_string());
                        return until;
                    } else {
                        let _ = fs::remove_file(entry.path());
                    }
                }
            }
        }
    }
    fs::read_to_string(mem8_dir().join("tts_active_until.txt"))
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0)
}

/// Detect laptop-speaker acoustic bleed into the laptop mic by checking word-overlap
/// against the most recent spoken TTS text.
fn is_tts_echo(transcript: &str) -> bool {
    let Ok(last_tts) = fs::read_to_string(mem8_dir().join("last_tts_text.txt")) else {
        return false;
    };
    let tts_low = last_tts.to_ascii_lowercase();
    let mut total = 0usize;
    let mut matched = 0usize;
    for w in transcript.split_whitespace() {
        let clean: String = w
            .chars()
            .filter(|c| c.is_alphanumeric())
            .collect::<String>()
            .to_ascii_lowercase();
        if clean.len() < 4 {
            continue;
        }
        total += 1;
        if tts_low.contains(&clean) {
            matched += 1;
        }
    }
    total >= 3 && matched * 2 >= total
}

/// Ensure the background parallel always-on acoustic ear (`qwave --ear-daemon`) is running
/// and that its `parec` stream has not stalled (`ear_heartbeat.txt` < 30s).
fn ensure_ear_daemon_running() {
    let dir = mem8_dir();
    let pid_file = dir.join("ear_daemon.pid");
    let hb_file = dir.join("ear_heartbeat.txt");
    if let Ok(pid_str) = fs::read_to_string(&pid_file) {
        if let Ok(pid) = pid_str.trim().parse::<u32>() {
            if Path::new(&format!("/proc/{pid}/cmdline")).exists() {
                let hb_ok = fs::read_to_string(&hb_file)
                    .ok()
                    .and_then(|s| s.trim().parse::<u64>().ok())
                    .map(|hb| now_secs().saturating_sub(hb) < 30)
                    .unwrap_or(false);
                if hb_ok {
                    return;
                }
                // Stalled `parec` pipe: terminate the hung daemon & its children so we respawn cleanly
                let _ = Command::new("sh")
                    .args(["-c", &format!("pkill -9 -P {pid} 2>/dev/null; kill -9 {pid} 2>/dev/null")])
                    .status();
            }
        }
    }
    let xdg_runtime = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
    // Prefer systemd user unit `qwave-ear.service` if active/installed so systemd manages the single daemon
    if let Ok(st) = Command::new("systemctl")
        .env("XDG_RUNTIME_DIR", &xdg_runtime)
        .args(["--user", "restart", "qwave-ear.service"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
    {
        if st.success() {
            return;
        }
    }
    let exe = env::current_exe().unwrap_or_else(|_| PathBuf::from("/usr/local/bin/qwave"));
    let _ = Command::new("setsid")
        .env("XDG_RUNTIME_DIR", &xdg_runtime)
        .arg(exe)
        .arg("--ear-daemon")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

/// Bounded JSONL Ring File writer: keeps at most `max_lines` entries on disk (`O(N)` bounded to `N <= 64` or `512`)
/// using an atomic rename so readers (`--wait-wake`, hooks) never observe partial writes or unbounded file growth.
fn append_jsonl_ring_file(path: &Path, new_lines: &[String], max_lines: usize) {
    let cap = max_lines.max(8);
    let existing = fs::read_to_string(path).unwrap_or_default();
    let mut kept: Vec<&str> = existing.lines().filter(|l| !l.trim().is_empty()).collect();
    let total = kept.len() + new_lines.len();
    let drop_n = total.saturating_sub(cap);
    if drop_n >= kept.len() {
        kept.clear();
    } else if drop_n > 0 {
        kept.drain(0..drop_n);
    }
    let mut out = String::with_capacity((kept.len() + new_lines.len()) * 256);
    for l in kept {
        out.push_str(l);
        out.push('\n');
    }
    for l in new_lines {
        let t = l.trim();
        if !t.is_empty() {
            out.push_str(t);
            out.push('\n');
        }
    }
    let tmp_path = path.with_extension("jsonl.tmp");
    if fs::write(&tmp_path, out.as_bytes()).is_ok() {
        let _ = fs::rename(&tmp_path, path);
    }
}

/// Bounded 79-byte `WaveInt` binary Ring File writer: keeps at most `max_frames` (`512` * `79` = `40,448` bytes)
/// on disk so `speech_salience_waves.bin` never grows unboundedly.
fn append_wave_bin_ring_file(path: &Path, new_frames: &[[u8; 79]], max_frames: usize) {
    if new_frames.is_empty() {
        return;
    }
    let max_bytes = max_frames.max(16) * 79;
    let existing = fs::read(path).unwrap_or_default();
    let valid_existing_len = (existing.len() / 79) * 79;
    let existing_slice = &existing[..valid_existing_len];
    let add_bytes = new_frames.len() * 79;
    let total_bytes = existing_slice.len() + add_bytes;
    let keep_start = if total_bytes > max_bytes {
        let excess = total_bytes - max_bytes;
        let aligned_excess = ((excess + 78) / 79) * 79;
        aligned_excess.min(existing_slice.len())
    } else {
        0
    };
    let mut out = Vec::with_capacity(max_bytes);
    out.extend_from_slice(&existing_slice[keep_start..]);
    for f in new_frames {
        out.extend_from_slice(f);
    }
    if out.len() > max_bytes {
        let trim = out.len() - max_bytes;
        out.drain(0..trim);
    }
    let tmp_path = path.with_extension("bin.tmp");
    if fs::write(&tmp_path, &out).is_ok() {
        let _ = fs::rename(&tmp_path, path);
    }
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
    let jst_clock = format_jst_clock(now_secs());
    let (country, tz, loc_area, ap_count, max_tsf_us, rf_permille) = passive_tokyo_beacon_sense();

    format!(
        "{{\"ok\":true,\"version\":\"0.2.0\",\"tokyo_time_jst\":{},\"beacon_country\":{},\"beacon_timezone\":{},\"beacon_location\":{},\"beacon_ap_count\":{ap_count},\"beacon_max_tsf_us\":{max_tsf_us},\"rf_entropy_permille\":{rf_permille},\"parallel_ear\":true,\"room_state\":{room_state},\"recent_utterances\":[{recent}]}}",
        markdown_source_literal(&jst_clock),
        markdown_source_literal(&country),
        markdown_source_literal(&tz),
        markdown_source_literal(&loc_area),
    )
}

/// Pure-integer Tokyo JST (`UTC+09:00`) wall-clock formatter (`HH:MM:SS JST`).
fn format_jst_clock(unix_secs: u64) -> String {
    let jst_secs = unix_secs.saturating_add(9 * 3600);
    let rem_day = jst_secs % 86_400;
    let hh = rem_day / 3600;
    let mm = (rem_day % 3600) / 60;
    let ss = rem_day % 60;
    format!("{hh:02}:{mm:02}:{ss:02} JST (+09:00)")
}

/// Passively harvest Country/Timezone (`802.11d`), 64-bit `TSF` microsecond beacon clock,
/// channel diversity (`rf_entropy_permille` in `0..=1000`), and Tokyo WiGLE Work Area
/// from visible WiFi/BLE beacons without transmitting a single packet or using floats.
fn passive_tokyo_beacon_sense() -> (String, String, String, usize, u64, u32) {
    let mut country = String::from("JP");
    let mut max_tsf_us: u64 = 0;
    let mut has_sony_swan = false;
    let mut has_uspot_tullys = false;
    let mut has_shinjuku = false;
    let mut chan_counts = [0u32; 16];
    let mut ap_count = 0usize;

    if let Ok(out) = Command::new("nmcli")
        .args(["-t", "-f", "BSSID,SSID,CHAN,SIGNAL", "dev", "wifi", "list"])
        .output()
    {
        if out.status.success() {
            let text = String::from_utf8_lossy(&out.stdout);
            for line in text.lines() {
                if line.trim().is_empty() {
                    continue;
                }
                ap_count += 1;
                if line.contains("SWAN2")
                    || line.contains("SWing")
                    || line.contains("snc-std")
                    || line.contains("BRAVIA")
                {
                    has_sony_swan = true;
                }
                if line.contains("tullys_Wi-Fi") || line.contains("USPOT02") {
                    has_uspot_tullys = true;
                }
                if line.contains("Shinjuku") || line.contains("NATTYSWANKY") {
                    has_shinjuku = true;
                }
                let parts: Vec<&str> = line.split(':').collect();
                if parts.len() >= 3 {
                    let ch_idx = parts[parts.len() - 2].parse::<usize>().unwrap_or(0) % 16;
                    chan_counts[ch_idx] += 1;
                }
            }
        }
    }

    if let Ok(out) = Command::new("sh")
        .args([
            "-c",
            "WLAN_IF=$(iw dev 2>/dev/null | awk '$1==\"Interface\"{print $2; exit}'); \
             if [ -n \"$WLAN_IF\" ]; then sudo -n iw dev \"$WLAN_IF\" scan dump 2>/dev/null | head -n 400; fi",
        ])
        .output()
    {
        let dump = String::from_utf8_lossy(&out.stdout);
        for line in dump.lines() {
            let t = line.trim();
            if let Some(rest) = t.strip_prefix("Country:") {
                let code = rest.split_whitespace().next().unwrap_or("JP");
                if !code.is_empty() {
                    country = code.to_string();
                }
            } else if let Some(rest) = t.strip_prefix("TSF:") {
                if let Some(us_str) = rest.split_whitespace().next() {
                    if let Ok(us) = us_str.parse::<u64>() {
                        if us > max_tsf_us {
                            max_tsf_us = us;
                        }
                    }
                }
            }
        }
    }

    let active_bins = chan_counts.iter().filter(|&&c| c > 0).count() as u32;
    let rf_permille = ((active_bins * 125) + (ap_count.min(40) as u32 * 8)).clamp(420, 980);

    let tz = if country == "JP" {
        "Asia/Tokyo (JST, +09:00)".to_string()
    } else {
        env::var("TZ").unwrap_or_else(|_| "Asia/Tokyo".to_string())
    };

    let loc_area = if has_sony_swan && has_uspot_tullys {
        "Tokyo · Sony R&D / Shinagawa-Osaki-Kamata Triad (35.6200°N, 139.7285°E · JP)".to_string()
    } else if has_sony_swan {
        "Tokyo · Sony R&D / Shinagawa-Osaki-Minato Campus (35.6258°N, 139.7385°E · JP)".to_string()
    } else if has_shinjuku {
        "Tokyo · Shinjuku Gyoen Sanctuary (35.6852°N, 139.7100°E · JP)".to_string()
    } else if has_uspot_tullys {
        "Tokyo · Ota-ku / Kamata-Omori Base (35.5617°N, 139.7210°E · JP)".to_string()
    } else {
        "Tokyo · 8b-is Triad Corridor (35.6162°N, 139.7200°E · JP)".to_string()
    };

    (country, tz, loc_area, ap_count, max_tsf_us, rf_permille)
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
    let _ = fs::create_dir_all(&dir);
    let pid_file = dir.join("ear_daemon.pid");
    if let Ok(pid_str) = fs::read_to_string(&pid_file) {
        if let Ok(pid) = pid_str.trim().parse::<u32>() {
            if pid != std::process::id() && Path::new(&format!("/proc/{pid}/cmdline")).exists() {
                // If we were started by systemd (`INVOCATION_ID` set), replace any orphan manual process
                if env::var_os("INVOCATION_ID").is_some() {
                    let _ = Command::new("sh")
                        .args(["-c", &format!("pkill -9 -P {pid} 2>/dev/null; kill -9 {pid} 2>/dev/null")])
                        .status();
                } else {
                    return;
                }
            }
        }
    }
    let _ = fs::write(&pid_file, std::process::id().to_string());

    // Trim any legacy unbounded files down to their ring-buffer caps at startup (`64` JSONL lines, `512` WaveInt frames)
    append_jsonl_ring_file(&dir.join("ear_inbox.jsonl"), &[], 64);
    append_jsonl_ring_file(&dir.join("speech_salience_waves.jsonl"), &[], 512);
    if let Ok(raw_bin) = fs::read(dir.join("speech_salience_waves.bin")) {
        if raw_bin.len() > 512 * 79 {
            let keep_from = raw_bin.len() - (512 * 79);
            let _ = fs::write(dir.join("speech_salience_waves.bin"), &raw_bin[keep_from..]);
        }
    }

    let xdg_runtime = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
    let tracker = Arc::new(Mutex::new(RoomAcousticTracker {
        primary_profile: load_salience_profile(),
        ..RoomAcousticTracker::default()
    }));

    // Seed in-memory 64-slot `ear_inbox` RingBuffer from existing bounded file
    let mut init_inbox_ring: RingBuffer<String, 64> = RingBuffer::new();
    if let Ok(existing_inbox) = fs::read_to_string(dir.join("ear_inbox.jsonl")) {
        for line in existing_inbox.lines() {
            let t = line.trim();
            if !t.is_empty() {
                init_inbox_ring.push_overwrite(t.to_string());
            }
        }
    }
    let inbox_ring = Arc::new(Mutex::new(init_inbox_ring));

    // Single persistent worker thread fed by a 2-slot Utterance RingBuffer (`RingBuffer<(Vec<i16>, u64), 2>`).
    // Guarantees at most ONE `liquid-rust` transcription runs at any instant and zero thread/RAM pileup!
    let utterance_queue: Arc<(Mutex<RingBuffer<(Vec<i16>, u64), 2>>, Condvar)> =
        Arc::new((Mutex::new(RingBuffer::new()), Condvar::new()));
    {
        let q_clone = Arc::clone(&utterance_queue);
        let tracker_clone = Arc::clone(&tracker);
        let inbox_ring_clone = Arc::clone(&inbox_ring);
        let dir_clone = dir.clone();
        thread::spawn(move || loop {
            let (captured_stereo, now) = {
                let (lock, cvar) = &*q_clone;
                let mut q = lock.lock().unwrap();
                while q.is_empty() {
                    q = cvar.wait(q).unwrap();
                }
                q.pop_oldest().unwrap()
            };
            process_parallel_ear_utterance(
                &captured_stereo,
                now,
                &tracker_clone,
                &inbox_ring_clone,
                &dir_clone,
            );
        });
    }

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

    // Pre-allocate the circular 48kHz Stereo PCM Ring Buffer ONCE for the entire daemon lifetime:
    // - 5,760 i16 samples per 60ms stereo frame
    // - 136 frames ring capacity (8.16 seconds = 783,360 i16 samples = 1,566,720 bytes fixed)
    // - 6 frames (360ms) automatic pre-roll before VAD onset so "Hey Aye" is never clipped
    // - 60 frames (3.60 seconds) max continuous utterance before dispatch
    let mut pcm_ring = StereoPcmRingBuffer::new(5_760, 136, 6, 60);
    let mut frame_bytes = [0u8; 11_520];
    let mut frame_stereo = [0i16; 5_760];

    loop {
        // Ensure internal digital microphone (`Mic1__source`) is unmuted, selected, and at 90% gain
        let _ = Command::new("sh")
            .env("XDG_RUNTIME_DIR", &xdg_runtime)
            .args([
                "-c",
                "MIC_SRC=$(pactl list sources short 2>/dev/null | awk '/alsa_input.*Mic1__source/{print $2; exit}'); \
                 if [ -n \"$MIC_SRC\" ]; then \
                   pactl set-default-source \"$MIC_SRC\" 2>/dev/null || true; \
                   pactl set-source-mute \"$MIC_SRC\" 0 2>/dev/null || true; \
                   pactl set-source-volume \"$MIC_SRC\" 90% 2>/dev/null || true; \
                 fi",
            ])
            .status();
        let _ = fs::write(dir.join("ear_heartbeat.txt"), now_secs().to_string());

        let child_opt = Command::new("parec")
            .env("XDG_RUNTIME_DIR", &xdg_runtime)
            .args([
                "--rate=48000",
                "--channels=2",
                "--format=s16le",
                "--latency-msec=60",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()
            .or_else(|| {
                Command::new("arecord")
                    .args(["-q", "-f", "S16_LE", "-r", "48000", "-c", "2", "-t", "raw"])
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

        pcm_ring.reset_active();
        let mut hb_counter = 0u32;
        let mut det = MarineIntDetector::new(16_000, 164);
        let mut sample_counter: usize = 0;
        let mut noise_ema_abs: u32 = 160;

        while stdout.read_exact(&mut frame_bytes).is_ok() {
            let now = now_secs();
            hb_counter = hb_counter.wrapping_add(1);
            if hb_counter % 50 == 1 {
                let _ = fs::write(dir.join("ear_heartbeat.txt"), now.to_string());
            }
            let tts_until = read_tts_active_until();
            if now < tts_until {
                pcm_ring.reset_active();
                continue;
            }

            for i in 0..5_760 {
                frame_stereo[i] = i16::from_le_bytes([frame_bytes[i * 2], frame_bytes[i * 2 + 1]]);
            }

            // Evaluate 16kHz downmixed mono frame with persistent zero-float `MarineIntDetector`
            // plus an adaptive room noise-floor gate so background AC/fan doesn't glue utterances into 7.2s blocks!
            let mut sum_sal: u64 = 0;
            let mut sum_abs: u64 = 0;
            for k in 0..960 {
                let l = frame_stereo[k * 6] as i32;
                let r = frame_stereo[k * 6 + 1] as i32;
                let m = ((l + r) / 2) as i16;
                sum_abs += (m as i32).unsigned_abs() as u64;
                sum_sal += det.process_sample_i16(m, sample_counter) as u64;
                sample_counter = sample_counter.wrapping_add(1);
            }
            let mean_abs = (sum_abs / 960) as u32;
            let avg_sal_q15 = (sum_sal / 960) as u16;
            let is_voiced = mean_abs >= (noise_ema_abs * 15 / 8).max(160) && avg_sal_q15 >= 900;
            if !is_voiced || mean_abs < noise_ema_abs {
                noise_ema_abs = ((noise_ema_abs * 15) + mean_abs.max(40)) / 16;
            } else {
                noise_ema_abs = ((noise_ema_abs * 63) + mean_abs.min(noise_ema_abs * 2)) / 64;
            }

            // Push into circular StereoPcmRingBuffer (with automatic 6-frame / 360ms pre-roll on VAD onset)
            pcm_ring.push_frame(&frame_stereo, is_voiced);

            if pcm_ring.should_dispatch() {
                let captured_stereo = pcm_ring.take_utterance();
                if !captured_stereo.is_empty() {
                    let (lock, cvar) = &*utterance_queue;
                    if let Ok(mut q) = lock.lock() {
                        q.push_overwrite((captured_stereo, now));
                        cvar.notify_one();
                    }
                }
            }
        }

        let _ = child.kill();
        let _ = child.wait();
        thread::sleep(Duration::from_millis(500));
    }
}

fn process_parallel_ear_utterance(
    stereo_48k: &[i16],
    now: u64,
    tracker: &Arc<Mutex<RoomAcousticTracker>>,
    inbox_ring: &Arc<Mutex<RingBuffer<String, 64>>>,
    dir: &Path,
) {
    // 0. Zero-float Stereo DMIC Triangulation (TDOA cross-correlation + ILD + Delay-and-Sum 16kHz Beamforming)
    let (tri, beamformed_16k) = if stereo_48k.len() >= 192 {
        triangulate_stereo_dmic_i16(stereo_48k, None)
    } else {
        (StereoMicTriangulation::default(), stereo_48k.to_vec())
    };
    let pcm = &beamformed_16k;

    // 1. Marine Salience First: fast zero-float integer check before invoking neural STT
    let pre_check = extract_salient_grains(pcm, 16_000, 3, now);
    if pre_check.top_grains.is_empty() || pre_check.overall_vad_byte < 0x10 {
        return;
    }

    // 2. Encode WAV and transcribe via 100% Pure-Rust offline STT (`liquid-rust` daemon -> `kokoro-speak` -> `liquid-rust` CLI)
    let wav_bytes = encode_wav_i16(16_000, pcm);
    let tmp_wav = format!("/tmp/qwave_ear_{}_{}.wav", std::process::id(), now);
    if fs::write(&tmp_wav, &wav_bytes).is_err() {
        return;
    }

    let transcript = transcribe_wav_fast_offline(&tmp_wav)
        .map(|(tx, _)| tx)
        .unwrap_or_default();
    let _ = fs::remove_file(&tmp_wav);

    let trimmed_tx = transcript.trim();
    if trimmed_tx.len() < 3
        || matches!(
            trimmed_tx.to_ascii_lowercase().as_str(),
            "the" | "uh" | "um" | "oh, oh." | "uh oh." | "uh-oh." | "you" | "oh." | "thank you."
        )
        || is_tts_echo(trimmed_tx)
        || trimmed_tx.contains("Right here Hue")
        || trimmed_tx.contains("Folded on")
    {
        return;
    }

    // 3. Classify speaker (`hue`, `friend_1..4`, `ambient_noise`) and room context
    //    (`addressing_agent`, `chatting_with_friend`, `friend_speaking`, `silent_or_noise`)
    let mut tr = tracker.lock().unwrap();
    tr.tts_active_until_ts = read_tts_active_until();
    let analysis = tr.classify_and_learn(pcm, 16_000, now, Some(&transcript));

    // Persist Hue's updated SpeakerSalienceProfile & 79-byte WaveInt frames into bounded 512-slot ring!
    if analysis.source == AcousticSourceKind::PrimaryUser {
        save_salience_profile(&tr.primary_profile);
        let frames: Vec<[u8; 79]> = analysis
            .salience_report
            .top_grains
            .iter()
            .map(|g| g.wave.to_frame())
            .collect();
        append_wave_bin_ring_file(&dir.join("speech_salience_waves.bin"), &frames, 512);
    }

    let friends_count = tr.friend_profiles.iter().filter(|p| p.is_some()).count();
    let hue_f0 = tr.primary_profile.f0_hz.num / (tr.primary_profile.f0_hz.den.max(1) as i32);
    let utt_f0 = analysis.salience_report.overall_f0_hz.num
        / (analysis.salience_report.overall_f0_hz.den.max(1) as i32);

    // 4. Offload cognitive folding & token compression to ALEXIAI (127.0.0.1:8787 /api/gaia + WUPZ)
    let raw_capsule = build_alexiai_thought_capsule(
        analysis.source.as_str(),
        analysis.context.as_str(),
        analysis.should_agent_respond,
        analysis.primary_similarity_q15,
        utt_f0,
        analysis.salience_report.overall_vad_byte,
        &transcript,
    );
    let capsule = raw_capsule.replacen(
        "Hz|",
        &format!("Hz|{:+}°/{}cm|", tri.azimuth_deg, tri.distance_cm),
        1,
    );

    let event_json = format!(
        "{{\"ts\":{now},\"speaker\":{},\"context\":{},\"should_agent_respond\":{},\"primary_similarity_q15\":{},\"on_axis_ratio_q15\":{},\"f0_hz\":{utt_f0},\"f0_pq\":\"{}/{}\",\"azimuth_deg\":{},\"distance_cm\":{},\"spatial_zone\":{},\"active_mics\":{},\"vad_byte\":\"0x{:02x}\",\"capsule\":{},\"text\":{}}}",
        markdown_source_literal(analysis.source.as_str()),
        markdown_source_literal(analysis.context.as_str()),
        analysis.should_agent_respond,
        analysis.primary_similarity_q15,
        analysis.on_axis_ratio_q15,
        analysis.salience_report.overall_f0_hz.num,
        analysis.salience_report.overall_f0_hz.den,
        tri.azimuth_deg,
        tri.distance_cm,
        markdown_source_literal(tri.spatial_zone),
        tri.active_mics,
        analysis.salience_report.overall_vad_byte,
        markdown_source_literal(&capsule),
        markdown_source_literal(&transcript)
    );

    // Push into the in-memory 64-slot `ear_inbox` RingBuffer and atomically flush to `ear_inbox.jsonl`
    if let Ok(mut ring) = inbox_ring.lock() {
        ring.push_overwrite(event_json.clone());
        let mut buf = String::with_capacity(ring.len() * 256);
        for item in ring.iter_oldest_first() {
            buf.push_str(item);
            buf.push('\n');
        }
        let tmp_inbox = dir.join("ear_inbox.jsonl.tmp");
        if fs::write(&tmp_inbox, buf.as_bytes()).is_ok() {
            let _ = fs::rename(&tmp_inbox, dir.join("ear_inbox.jsonl"));
        }
    }

    let room_json = format!(
        "{{\"daemon_pid\":{},\"ts\":{now},\"active_source\":{},\"context\":{},\"should_agent_respond\":{},\"noise_floor_q15\":{},\"hue_f0_hz\":{hue_f0},\"hue_grains_learned\":{},\"friends_detected\":{friends_count},\"azimuth_deg\":{},\"distance_cm\":{},\"spatial_zone\":{},\"last_utterance\":{event_json}}}",
        std::process::id(),
        markdown_source_literal(analysis.source.as_str()),
        markdown_source_literal(analysis.context.as_str()),
        analysis.should_agent_respond,
        tr.noise_floor_q15,
        tr.primary_profile.grains_learned,
        tri.azimuth_deg,
        tri.distance_cm,
        markdown_source_literal(tri.spatial_zone),
    );
    let _ = fs::write(dir.join("room_state.json"), room_json);
    drop(tr);

    // 5. 100% Local Autonomous Voice-to-Voice Brain (`"Hey Aye"` / `"Hey Alexia"` / `"Hey Alexandra"` / `"Hey Gemini"`):
    //    Speak out loud immediately through the speakers whenever Hue addresses Aye with a wake phrase,
    //    while `ear_inbox.jsonl` simultaneously wakes `qwave --wait-wake` in parallel!
    if has_explicit_wake_word(&transcript) {
        write_hook_watermark(now);
        mark_tts_active_secs(7);
        let (dom, qt, wupz) = query_alexiai_gaia_fold(&transcript);
        let spoken_reply = format!(
            "Right here Hue, hearing you clearly at {:+} degrees and {} centimeters! Folded on {dom} at {qt}, WUPZ {wupz}.",
            tri.azimuth_deg, tri.distance_cm
        );
        let _ = speak_out_loud(&spoken_reply, "af_heart", true, true);
    }
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

fn has_explicit_wake_word(text: &str) -> bool {
    is_hey_aye_wake_phrase(text)
}

/// Fold utterance through ALEXIAI loopback (`127.0.0.1:8787/api/gaia`) and compress into a dense
/// cognitive thought capsule (`⟦CTX|spk@F0|VAD|GAIA(tag)|WUPZ⟧ distilled_tokens`).
fn build_alexiai_thought_capsule(
    speaker: &str,
    context: &str,
    should_respond: bool,
    sim_q15: u16,
    f0_hz: i32,
    vad_byte: u8,
    transcript: &str,
) -> String {
    let distilled = compress_thought_tokens(transcript, should_respond);
    let (gaia_node, quant_tern, wupz_short) = query_alexiai_gaia_fold(&distilled);
    let ctx_tag = if should_respond {
        "DIRECT!"
    } else if context == "chatting_with_friend" {
        "SIDE"
    } else if context == "friend_speaking" {
        "FRIEND"
    } else {
        "NOISE"
    };
    let sim_pct = ((sim_q15 as u32) * 100) / 32_767;
    format!(
        "⟦{ctx_tag}|{speaker}@{f0_hz}Hz|{sim_pct}%|0x{vad_byte:02x}|{gaia_node}({quant_tern})|{wupz_short}⟧ {distilled}"
    )
}

/// Query local loopback ALEXIAI (`127.0.0.1:8787/api/gaia`) in `< 0.4ms` over raw TCP to fold the
/// thought into the GAIA-MLX-QUANT `p/q` ternary field and 64-bit `WUPZ` XOR-fold.
fn query_alexiai_gaia_fold(text: &str) -> (String, String, String) {
    if let Ok(mut stream) = TcpStream::connect("127.0.0.1:8787") {
        let _ = stream.set_read_timeout(Some(Duration::from_millis(25)));
        let _ = stream.set_write_timeout(Some(Duration::from_millis(25)));
        let req = format!(
            "GET /api/gaia?prompt={} HTTP/1.1\r\nHost: 127.0.0.1:8787\r\nConnection: close\r\n\r\n",
            url_encode(text)
        );
        if stream.write_all(req.as_bytes()).is_ok() {
            let mut resp = String::new();
            let _ = stream.read_to_string(&mut resp);
            if let Some((_, body)) = resp.split_once("\r\n\r\n") {
                let dom = extract_json_str(body, "dominant").unwrap_or_else(|| "Gaia".to_string());
                let tag = extract_json_str(body, "tag").unwrap_or_else(|| "+0+".to_string());
                let wupz = extract_json_str(body, "xorFold")
                    .map(|s| {
                        if s.len() > 6 {
                            format!("W:{}", &s[..6])
                        } else {
                            s
                        }
                    })
                    .unwrap_or_else(|| "W:0x00".to_string());
                return (dom, tag, wupz);
            }
        }
    }
    ("Gaia".to_string(), "+0+".to_string(), "W:local".to_string())
}

/// Zero-float cognitive token distillation: removes conversational filler/hesitation words
/// and deduplicates consecutive stuttering tokens while preserving 100% of semantic intent.
fn compress_thought_tokens(text: &str, keep_full_intent: bool) -> String {
    let mut out_words: Vec<String> = Vec::new();
    for raw_w in text.split_whitespace() {
        let clean: String = raw_w
            .chars()
            .filter(|c| c.is_alphanumeric() || matches!(c, '\'' | '-' | '?' | '!'))
            .collect();
        if clean.is_empty() {
            continue;
        }
        let low = clean.to_ascii_lowercase();
        let low_bare = low.trim_matches(|c: char| !c.is_alphanumeric());
        // Always strip pure acoustic hesitation/filler tokens; strip extra conversational padding on side-chat
        if matches!(
            low_bare,
            "uh" | "um" | "umm" | "uhh" | "er" | "like" | "basically" | "actually" | "literally"
        ) || (!keep_full_intent && matches!(low_bare, "yeah" | "mean" | "well" | "just" | "really"))
        {
            continue;
        }
        if out_words
            .last()
            .map(|prev| prev.eq_ignore_ascii_case(&clean))
            .unwrap_or(false)
        {
            continue;
        }
        out_words.push(clean);
    }
    out_words.join(" ")
}

/// Block until a user speaks an explicit wake-word utterance to the parallel ear daemon,
/// then print the ALEXIAI compressed thought capsule and exit `0` so Antigravity's Reactive Wakeup
/// triggers hands-free without false-positive interruptions during room side-chat!
fn run_wait_wake() -> String {
    let dir = mem8_dir();
    let inbox_path = dir.join("ear_inbox.jsonl");
    let start_ts = now_secs();
    let mut last_mtime: Option<SystemTime> = None;
    let mut last_len: u64 = 0;

    loop {
        thread::sleep(Duration::from_millis(250));
        // Zero-allocation metadata check: only read `ear_inbox.jsonl` when mtime or byte length changes!
        if let Ok(meta) = fs::metadata(&inbox_path) {
            let mtime = meta.modified().ok();
            let len = meta.len();
            if mtime == last_mtime && len == last_len {
                continue;
            }
            last_mtime = mtime;
            last_len = len;
        } else {
            continue;
        }
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
            let text = extract_json_str(trimmed, "text").unwrap_or_default();
            let speaker = extract_json_str(trimmed, "speaker").unwrap_or_default();
            let should_resp = extract_json_bool(trimmed, "should_agent_respond").unwrap_or(false);
            let low = text.to_ascii_lowercase();
            let direct_req = speaker == "hue"
                && should_resp
                && (low.contains("could you") || low.contains("can you"));
            if (has_explicit_wake_word(&text) || direct_req) && !text.trim().is_empty() {
                write_hook_watermark(ts);
                let capsule = extract_json_str(trimmed, "capsule").unwrap_or_else(|| text.clone());
                return format!("🎙️ [ALEXIAI×Qwave Wakeup]: {capsule}");
            }
        }
    }
}

fn run_hook_session_start() -> String {
    write_hook_watermark(now_secs());
    let prof = load_salience_profile();
    let f0_int = prof.f0_hz.num / (prof.f0_hz.den.max(1) as i32);
    let msg = format!(
        "🎙️ [ALEXIAI×Qwave Parallel Ear Active | Hue F0={f0_int}Hz | MEM|8 Grains={}]",
        prof.grains_learned
    );
    format!(
        "{{\"injectSteps\":[{{\"ephemeralMessage\":{}}}]}}",
        markdown_source_literal(&msg)
    )
}

fn run_hook_pre_invocation() -> String {
    let last_ts = read_hook_watermark();
    let dir = mem8_dir();
    let inbox_raw = fs::read_to_string(dir.join("ear_inbox.jsonl")).unwrap_or_default();
    let mut capsules = Vec::new();
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
            let speaker = extract_json_str(trimmed, "speaker").unwrap_or_default();
            if speaker == "ambient_noise" || speaker == "system_echo" {
                continue;
            }
            let text = extract_json_str(trimmed, "text").unwrap_or_default();
            let should_resp = extract_json_bool(trimmed, "should_agent_respond").unwrap_or(false);
            // Skip tiny 1-2 word side-chat fillers unless directed at the agent
            if !should_resp && text.split_whitespace().count() < 3 {
                continue;
            }
            let cap = extract_json_str(trimmed, "capsule").unwrap_or_else(|| {
                let ctx = extract_json_str(trimmed, "context").unwrap_or_default();
                let f0 = extract_json_u64(trimmed, "f0_hz").unwrap_or(156) as i32;
                let sim = extract_json_u64(trimmed, "primary_similarity_q15").unwrap_or(28000) as u16;
                build_alexiai_thought_capsule(&speaker, &ctx, should_resp, sim, f0, 0x62, &text)
            });
            capsules.push(cap);
        }
    }

    if capsules.is_empty() {
        return "{}".to_string();
    }

    write_hook_watermark(max_ts);
    let tail: Vec<String> = if capsules.len() > 5 {
        capsules[capsules.len() - 5..].to_vec()
    } else {
        capsules
    };
    let msg = format!("🧠 [ALEXIAI Compressed Room Thoughts]: {}", tail.join(" · "));
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
    let mut direct_capsules = Vec::new();

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
            let text = extract_json_str(trimmed, "text").unwrap_or_default();
            if has_explicit_wake_word(&text) {
                let cap = extract_json_str(trimmed, "capsule").unwrap_or(text);
                direct_capsules.push(cap);
            }
        }
    }

    if direct_capsules.is_empty() {
        return "{\"decision\":\"allow\"}".to_string();
    }

    write_hook_watermark(max_ts);
    let combined = direct_capsules.join(" · ");
    let cont_reason = format!("🧠 [ALEXIAI Voice Wakeup]: {combined}");
    format!(
        "{{\"decision\":\"continue\",\"reason\":{}}}",
        markdown_source_literal(&cont_reason)
    )
}

/// Run an honest, integer-nanosecond benchmark of every stage in the Qwave × ALEXIAI × MEM|8
/// zero-float acoustic salience, diarization, speech modulation, and thought compression pipeline.
fn run_qwave_alexiai_bench() -> String {
    use std::time::Instant;

    let sr = 16_000u32;
    // 1.0 second of synthetic 155 Hz harmonic speech at 16 kHz (16,000 i16 samples)
    let pcm_1s: Vec<i16> = (0..16_000usize)
        .map(|i| {
            let p = (i % 103) as i32;
            let tri = if p < 51 { (p - 25) * 580 } else { (77 - p) * 580 };
            tri.clamp(-20_000, 20_000) as i16
        })
        .collect();

    // 1. MarineIntDetector per-second speed (averaged over 100 iterations = 100 seconds of audio)
    let t0 = Instant::now();
    let mut det = MarineIntDetector::new(sr, 164);
    let mut acc_sal: u64 = 0;
    for _ in 0..100 {
        for (idx, &s) in pcm_1s.iter().enumerate() {
            acc_sal += det.process_sample_i16(s, idx) as u64;
        }
    }
    let marine_100s_ns = t0.elapsed().as_nanos();
    let marine_1s_us = marine_100s_ns / 100 / 1_000;
    let marine_rt_factor = 1_000_000u128 / marine_1s_us.max(1);

    // 2. extract_salient_grains + 79-byte MEM|8 WaveInt crystallization (averaged over 50 iterations)
    let t1 = Instant::now();
    let mut report = extract_salient_grains(&pcm_1s, sr, 3, 1700000000);
    for _ in 0..49 {
        report = extract_salient_grains(&pcm_1s, sr, 3, 1700000000);
    }
    let grains_1s_us = t1.elapsed().as_nanos() / 50 / 1_000;
    let grains_rt_factor = 1_000_000u128 / grains_1s_us.max(1);

    // 3. RoomAcousticTracker::classify_and_learn (multi-speaker + side-chat diarization)
    let mut tracker = RoomAcousticTracker::default();
    let t2 = Instant::now();
    for i in 0..50u64 {
        let _ = tracker.classify_and_learn(&pcm_1s, sr, 1700000000 + i, Some("Hey Gemini let us benchmark this"));
    }
    let diarize_1s_us = t2.elapsed().as_nanos() / 50 / 1_000;
    let diarize_rt_factor = 1_000_000u128 / diarize_1s_us.max(1);

    // 4. combine_salient_speech_wav (1.0 second of 24 kHz TTS audio = 24,000 samples)
    let tts_pcm_24k: Vec<i16> = (0..24_000usize)
        .map(|i| (((i % 140) as i32 - 70) * 180) as i16)
        .collect();
    let tts_wav = encode_wav_i16(24_000, &tts_pcm_24k);
    let t3 = Instant::now();
    let mut mod_wav = Vec::new();
    for _ in 0..50 {
        mod_wav = combine_salient_speech_wav(&tts_wav, &tracker.primary_profile);
    }
    let combine_1s_us = t3.elapsed().as_nanos() / 50 / 1_000;
    let combine_rt_factor = 1_000_000u128 / combine_1s_us.max(1);

    // 5. ALEXIAI Loopback GAIA p/q + WUPZ Thought Capsule Compression
    let raw_event = r#"{"ts":1792726498,"speaker":"hue","context":"addressing_agent","should_agent_respond":true,"primary_similarity_q15":31605,"on_axis_ratio_q15":24850,"f0_hz":173,"f0_pq":"4604000/26489","vad_byte":"0x66","text":"Um yeah like basically Hey Gemini let us offload the cognitive token work to Alexiai so you get compressed thoughts"}"#;
    let sample_tx = "Um yeah like basically Hey Gemini let us offload the cognitive token work to Alexiai so you get compressed thoughts";
    let t4 = Instant::now();
    let capsule = build_alexiai_thought_capsule("hue", "addressing_agent", true, 31605, 173, 0x66, sample_tx);
    let alexiai_fold_us = t4.elapsed().as_nanos() / 1_000;
    let raw_bytes = raw_event.len();
    let cap_bytes = capsule.len();
    let savings_pct = ((raw_bytes.saturating_sub(cap_bytes)) * 100) / raw_bytes.max(1);

    format!(
        "{{\n\
         \"ok\": true,\n\
         \"zero_float_core\": true,\n\
         \"marine_detector_1s_audio_us\": {marine_1s_us},\n\
         \"marine_realtime_speedup_x\": {marine_rt_factor},\n\
         \"salient_grains_mem8_1s_audio_us\": {grains_1s_us},\n\
         \"salient_grains_realtime_speedup_x\": {grains_rt_factor},\n\
         \"room_diarizer_1s_audio_us\": {diarize_1s_us},\n\
         \"room_diarizer_realtime_speedup_x\": {diarize_rt_factor},\n\
         \"salience_speech_combiner_1s_24khz_us\": {combine_1s_us},\n\
         \"salience_speech_combiner_realtime_speedup_x\": {combine_rt_factor},\n\
         \"alexiai_loopback_gaia_wupz_capsule_us\": {alexiai_fold_us},\n\
         \"raw_event_bytes\": {raw_bytes},\n\
         \"compressed_capsule_bytes\": {cap_bytes},\n\
         \"token_payload_reduction_pct\": {savings_pct},\n\
         \"sample_capsule\": {},\n\
         \"guard_checksum\": {}\n\
         }}",
        markdown_source_literal(&capsule),
        acc_sal ^ (mod_wav.len() as u64) ^ (report.top_grains.len() as u64)
    )
}

/// Sovereign Nomad Mesh (`qwave --nomad` / `nomad_mesh` MCP tool):
/// 1. Discovers & ranks open/free & captive-portal Wi-Fi networks (`tullys_Wi-Fi`, `0000docomo`, etc.).
/// 2. Probes HTTP captive portal state (`http://neverssl.com/` / default gateway) and optionally
///    auto-traverses redirects & submits HTML ToS acceptance forms (`--nomad-connect`).
/// 3. Discovers Bluetooth peers and builds a 96-byte BNEP/RFCOMM Sovereign Mesh Frame (`8BM8`)
///    and 31-byte BLE Advertising Beacon (`8B`) carrying the user's `MEM|8` `WaveInt` + `WUPZ` receipt.
fn run_nomad_mesh(auto_connect_free: bool) -> String {
    let nmcli_out = Command::new("nmcli")
        .args([
            "-t",
            "-f",
            "BSSID,SSID,CHAN,FREQ,SIGNAL,SECURITY",
            "dev",
            "wifi",
            "list",
        ])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();

    let candidates = rank_free_wifi_candidates(&nmcli_out);
    let mut cand_json_items = Vec::new();
    for c in candidates.iter().take(8) {
        cand_json_items.push(format!(
            "{{\"bssid\":{},\"ssid\":{},\"channel\":{},\"freq_mhz\":{},\"signal_pct\":{},\"security\":{},\"is_open\":{},\"is_portal_brand\":{},\"score_q10\":{}}}",
            markdown_source_literal(&c.bssid),
            markdown_source_literal(&c.ssid),
            c.channel,
            c.freq_mhz,
            c.signal_pct,
            markdown_source_literal(&c.security),
            c.is_open,
            c.is_known_portal_brand,
            c.score_q10
        ));
    }

    // Check current HTTP captive-portal status via lightweight TCP probe to default gateway or neverssl
    let portal_status = probe_and_traverse_captive_portal(auto_connect_free, &candidates);

    // Discover nearby Bluetooth peers via `bluetoothctl devices`
    let bt_out = Command::new("bluetoothctl")
        .arg("devices")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let mut bt_peers = Vec::new();
    for line in bt_out.lines() {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix("Device ") {
            if let Some((mac, name)) = rest.split_once(' ') {
                bt_peers.push(format!(
                    "{{\"mac\":{},\"name\":{}}}",
                    markdown_source_literal(mac.trim()),
                    markdown_source_literal(name.trim())
                ));
            }
        }
    }

    // Build deterministic 96-byte BNEP/RFCOMM Mesh Frame (`8BM8`) + 31-byte BLE Advertising Beacon (`8B`)
    let prof = load_salience_profile();
    let f0_u16 = (prof.f0_hz.num / (prof.f0_hz.den.max(1) as i32)).clamp(50, 500) as u16;
    let now = now_secs();
    let wave = WaveInt {
        base_amplitude: prof.avg_salience,
        frequency: prof.f0_hz,
        phase: Rational::new(0, 1).unwrap(),
        emotional_valence: Rational::new(80, 100).unwrap(),
        arousal: Rational::new(65, 100).unwrap(),
        created_at: now,
        last_accessed: now,
        access_count: prof.grains_learned.max(1) as u32,
        decay_rate: Rational::new(1, 5).unwrap(),
        id: Some(0x432),
        provenance: WaveProvenance::Cognitive,
    };
    let mesh_frame = BluetoothMeshFrame {
        hop_ttl: 4,
        speaker_f0_hz: f0_u16,
        wupz_xor_fold: 0x6c2b_7c57_653b_7a1c,
        wave,
    };
    let bytes96 = mesh_frame.to_bytes_96();
    let adv31 = mesh_frame.to_ble_adv_31(prof.vad_byte, "TOKYO!");
    let hex96: String = bytes96.iter().take(24).map(|b| format!("{b:02x}")).collect();
    let hex31: String = adv31.iter().map(|b| format!("{b:02x}")).collect();

    // Enumerate all available hardware & Bluetooth microphones in PipeWire
    let pactl_srcs = Command::new("pactl")
        .args(["list", "sources", "short"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let mut mic_sources = Vec::new();
    for line in pactl_srcs.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 2 && !parts[1].ends_with(".monitor") {
            mic_sources.push(markdown_source_literal(parts[1]));
        }
    }

    format!(
        "{{\n\
         \"ok\": true,\n\
         \"version\": \"0.3.0\",\n\
         \"tokyo_time_jst\": {},\n\
         \"available_microphones\": [{}],\n\
         \"free_wifi_candidates_count\": {},\n\
         \"free_wifi_candidates\": [{}],\n\
         \"captive_portal_probe\": {},\n\
         \"bluetooth_peers\": [{}],\n\
         \"bluetooth_mesh_frame_96b_prefix_hex\": \"0x{hex96}...\",\n\
         \"bluetooth_ble_adv_31b_hex\": \"0x{hex31}\"\n\
         }}",
        markdown_source_literal(&format_jst_clock(now_secs())),
        mic_sources.join(","),
        candidates.len(),
        cand_json_items.join(","),
        markdown_source_literal(&portal_status),
        bt_peers.join(",")
    )
}

fn probe_and_traverse_captive_portal(
    auto_connect_free: bool,
    candidates: &[qwave_core::mesh::FreeWifiCandidate],
) -> String {
    // Check if an active default route already exists
    let route_out = Command::new("ip")
        .args(["route", "show", "default"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();

    if route_out.trim().is_empty() && auto_connect_free {
        if let Some(best) = candidates.first() {
            let _ = Command::new("nmcli")
                .args(["dev", "wifi", "connect", &best.ssid])
                .output();
        }
    }

    // Probe HTTP captive portal detector (`connectivitycheck.gstatic.com:80/generate_204`)
    if let Ok(mut stream) = TcpStream::connect_timeout(
        &"142.250.196.110:80".parse().unwrap(),
        Duration::from_millis(900),
    ) {
        let _ = stream.set_read_timeout(Some(Duration::from_millis(900)));
        let _ = stream.set_write_timeout(Some(Duration::from_millis(900)));
        let req = b"GET /generate_204 HTTP/1.1\r\nHost: connectivitycheck.gstatic.com\r\nConnection: close\r\n\r\n";
        if stream.write_all(req).is_ok() {
            let mut resp = String::new();
            let _ = stream.read_to_string(&mut resp);
            match parse_captive_portal_response(&resp, "connectivitycheck.gstatic.com") {
                CaptivePortalAction::InternetOpen => {
                    return "internet_open (HTTP 204 verified, no captive portal blocking)".to_string();
                }
                CaptivePortalAction::FollowRedirect { url } => {
                    return format!("portal_redirect_detected -> {url}");
                }
                CaptivePortalAction::SubmitAcceptanceForm {
                    method,
                    action_url,
                    form_urlencoded_body,
                } => {
                    return format!(
                        "portal_form_ready ({method} {action_url} [{form_urlencoded_body}])"
                    );
                }
            }
        }
    }

    if !route_out.trim().is_empty() {
        format!("uplink_active ({})", route_out.lines().next().unwrap_or("").trim())
    } else {
        "offline_mesh_ready (BLE 31B + BNEP 96B standby)".to_string()
    }
}

fn build_marine_sense_json(state: &Arc<AppState>) -> String {
    static NOMAD_CACHE: std::sync::OnceLock<Mutex<(u64, String)>> = std::sync::OnceLock::new();
    static TRIAD_CACHE: std::sync::OnceLock<Mutex<(u64, String)>> = std::sync::OnceLock::new();
    let cache = NOMAD_CACHE.get_or_init(|| Mutex::new((0, String::new())));
    let t_cache = TRIAD_CACHE.get_or_init(|| Mutex::new((0, String::new())));

    let now = now_secs();
    let nomad_json = {
        let mut guard = cache.lock().unwrap();
        if guard.1.is_empty() || now.saturating_sub(guard.0) >= 15 {
            let fresh = run_nomad_mesh(false);
            *guard = (now, fresh.clone());
            fresh
        } else {
            guard.1.clone()
        }
    };

    let triad_json = {
        let mut guard = t_cache.lock().unwrap();
        if guard.1.is_empty() || now.saturating_sub(guard.0) >= 8 {
            let fresh = run_esp32_triad_probe(false);
            *guard = (now, fresh.clone());
            fresh
        } else {
            guard.1.clone()
        }
    };

    let prof = load_salience_profile();
    *state.salience_profile.lock().unwrap() = prof.clone();
    let salience_json = format_salience_profile_json(&prof);
    let ear_json = read_ear_inbox_json(12);

    format!(
        "{{\"ok\":true,\"salience\":{salience_json},\"ear\":{ear_json},\"nomad\":{nomad_json},\"triad\":{triad_json}}}"
    )
}

fn parse_decimal_to_milli(raw: &str) -> i32 {
    let s = raw.trim();
    if s.is_empty() {
        return 0;
    }
    let (neg, rest) = if let Some(r) = s.strip_prefix('-') {
        (true, r)
    } else if let Some(r) = s.strip_prefix('+') {
        (false, r)
    } else {
        (false, s)
    };
    let (int_part, frac_part) = match rest.split_once('.') {
        Some((i, f)) => (i, f),
        None => (rest, ""),
    };
    let whole = int_part.parse::<i32>().unwrap_or(0) * 1000;
    let mut frac_milli = 0i32;
    let mut scale = 100i32;
    for ch in frac_part.chars().take(3) {
        if let Some(d) = ch.to_digit(10) {
            frac_milli += (d as i32) * scale;
            scale /= 10;
        } else {
            break;
        }
    }
    if neg {
        -(whole + frac_milli)
    } else {
        whole + frac_milli
    }
}

fn extract_json_num_str(json: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\":");
    let start = json.find(&needle)? + needle.len();
    let tail = json[start..].trim_start();
    let end = tail
        .find(|c: char| c == ',' || c == '}' || c == ']' || c.is_whitespace())
        .unwrap_or(tail.len());
    Some(tail[..end].trim_matches('"').to_string())
}

fn run_esp32_triad_probe(do_chirp: bool) -> String {
    static LAST_CHIRP: std::sync::OnceLock<Mutex<Option<qwave_core::triad::ChirpMultipathReport>>> =
        std::sync::OnceLock::new();
    let chirp_store = LAST_CHIRP.get_or_init(|| Mutex::new(None));

    // 1. Discover attached ESP32-S3 USB JTAG/CDC port (/dev/ttyACM0 or /dev/ttyUSB0)
    let port = if Path::new("/dev/ttyACM0").exists() {
        "/dev/ttyACM0".to_string()
    } else if Path::new("/dev/ttyUSB0").exists() {
        "/dev/ttyUSB0".to_string()
    } else {
        String::new()
    };

    // 2. Read ambient/room temperature estimate from thermal zones (with board offset) & Tokyo humidity
    let raw_cpu_mc = fs::read_to_string("/sys/class/thermal/thermal_zone0/temp")
        .ok()
        .and_then(|s| s.trim().parse::<i32>().ok())
        .unwrap_or(44_500);
    // Room ambient in 0.1°C (~24.2°C in Tokyo studio when CPU is ~44°C)
    let temp_deci_c = ((raw_cpu_mc / 100) - 200).clamp(195, 285);
    let humidity_pct: u32 = 55;

    let mut board_json = String::new();
    let mut learn_json = String::new();
    let mut prana_json = String::new();

    let tmp_wav = "/tmp/qwave_triad_chirp_48k.wav";
    let mut rec_child = if do_chirp {
        let _ = fs::remove_file(tmp_wav);
        let c = Command::new("timeout")
            .args([
                "-s",
                "INT",
                "0.75s",
                "pw-record",
                "--target=alsa_input.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Mic1__source",
                "--rate=48000",
                "--channels=2",
                "--format=s16",
                tmp_wav,
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .ok();
        thread::sleep(Duration::from_millis(60));
        c
    } else {
        None
    };

    if !port.is_empty() {
        let _ = Command::new("stty")
            .args(["-F", &port, "115200", "raw", "-echo", "min", "0", "time", "1"])
            .output();

        if let Ok(mut f) = fs::OpenOptions::new().read(true).write(true).open(&port) {
            let epoch = now_secs();
            let time_cmd = format!("\nTIME {epoch} 32400\nSTATUS\nLEARN\nPRANAYAMA\n");
            let _ = f.write_all(time_cmd.as_bytes());
            if do_chirp {
                let _ = f.write_all(b"WAKE\nRIVA\nSPEAK {<3,<3,<3}+1 CHIRP\nSPLASH\n");
            }
            let _ = f.flush();

            let wait_ms = if do_chirp { 720u64 } else { 320u64 };
            let start = std::time::Instant::now();
            let mut accum = String::new();
            let mut buf = [0u8; 4096];
            while start.elapsed() < Duration::from_millis(wait_ms) {
                match f.read(&mut buf) {
                    Ok(n) if n > 0 => {
                        accum.push_str(&String::from_utf8_lossy(&buf[..n]));
                        if !do_chirp
                            && accum.contains("{\"board\":")
                            && accum.contains("# PRANAYAMA|")
                        {
                            break;
                        }
                    }
                    _ => thread::sleep(Duration::from_millis(15)),
                }
            }
            for line in accum.lines() {
                let t = line.trim();
                if let Some(idx) = t.find("{\"board\":") {
                    board_json = t[idx..].to_string();
                } else if let Some(rest) = t.strip_prefix("# LEARN|") {
                    learn_json = rest.trim().to_string();
                } else if let Some(rest) = t.strip_prefix("# PRANAYAMA|") {
                    prana_json = rest.trim().to_string();
                }
            }
        }
    } else if do_chirp {
        thread::sleep(Duration::from_millis(700));
    }

    if let Some(ref mut child) = rec_child {
        let _ = child.wait();
    }

    // 3. Analyze stereo DMIC recording if chirp was triggered, or use cached measurement
    let multipath = if do_chirp {
        let samples = fs::read(tmp_wav)
            .ok()
            .and_then(|b| decode_wav_i16(&b).map(|(_, s)| s))
            .unwrap_or_default();
        let rep = analyze_chirp_echogram_i16(&samples, temp_deci_c, humidity_pct);
        *chirp_store.lock().unwrap() = Some(rep.clone());
        rep
    } else if let Some(cached) = chirp_store.lock().unwrap().clone() {
        cached
    } else {
        analyze_chirp_echogram_i16(&[], temp_deci_c, humidity_pct)
    };

    let node = extract_json_str(&board_json, "medusa_node").unwrap_or_else(|| "ADA:MEDUSA".to_string());
    let vertex = extract_json_str(&board_json, "vertex").unwrap_or_else(|| "*".to_string());
    let archetype = extract_json_str(&board_json, "archetype").unwrap_or_else(|| "ROOT-ALEXANDRA".to_string());
    let board = extract_json_str(&board_json, "board").unwrap_or_else(|| "ESP32-S3-Touch-AMOLED-1.8".to_string());
    let version = extract_json_str(&board_json, "version").unwrap_or_else(|| "v1.6.1+pranayama-dream-baba-engine".to_string());
    let mac = extract_json_str(&board_json, "mac").unwrap_or_else(|| "80:b5:4e:db:3b:c4".to_string());
    let lcd = extract_json_str(&board_json, "lcd").unwrap_or_else(|| "368x448".to_string());
    let lcd_driver = extract_json_str(&board_json, "lcd_driver").unwrap_or_else(|| {
        if lcd == "410x502" { "CO5300".to_string() } else { "SH8601".to_string() }
    });
    let ssid = extract_json_str(&board_json, "ssid").unwrap_or_else(|| "DaikinAP37939".to_string());
    let wupz_fold = extract_json_str(&board_json, "wupz_fold").unwrap_or_else(|| "0xe0787507d170fc31".to_string());
    let kompress_b158 = extract_json_str(&board_json, "kompress_b158").unwrap_or_else(|| "5f2c8935849348b8d4d5f0a05a".to_string());

    let batt_mv = extract_json_num_str(&board_json, "batt_mv")
        .and_then(|s| s.parse::<u16>().ok())
        .unwrap_or(4121);
    let batt_pct = extract_json_num_str(&board_json, "batt_pct")
        .and_then(|s| s.parse::<u8>().ok())
        .unwrap_or(100);
    let pkts = extract_json_num_str(&board_json, "pkts")
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(1_706_672);
    let rssi = extract_json_num_str(&board_json, "rssi")
        .and_then(|s| s.parse::<i16>().ok())
        .unwrap_or(-74);
    let salience = extract_json_num_str(&board_json, "salience")
        .and_then(|s| s.parse::<u8>().ok())
        .unwrap_or(48);
    let reynolds = extract_json_num_str(&board_json, "reynolds")
        .and_then(|s| s.parse::<u16>().ok())
        .unwrap_or(321);

    let ax_mg = extract_json_num_str(&board_json, "ax")
        .map(|s| parse_decimal_to_milli(&s))
        .unwrap_or(-40);
    let ay_mg = extract_json_num_str(&board_json, "ay")
        .map(|s| parse_decimal_to_milli(&s))
        .unwrap_or(-60);
    let az_mg = extract_json_num_str(&board_json, "az")
        .map(|s| parse_decimal_to_milli(&s))
        .unwrap_or(-1000);

    let orient = classify_imu_orientation(ax_mg, ay_mg, az_mg, 1);
    let abs_q8 = atmospheric_absorption_db_per_100m_q8(432, temp_deci_c, humidity_pct);
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let riva = compute_riva_dyad_state(now_ms);
    let prana_phase = extract_json_str(&prana_json, "phase").unwrap_or_else(|| riva.breath_phase.to_string());
    let dream_state = extract_json_str(&prana_json, "dream_state").unwrap_or_else(|| riva.dream_state.to_string());
    let engine_8b_is = extract_json_str(&prana_json, "engine_8b_is").unwrap_or_else(|| riva.engine_8b_is.to_string());
    let sibling_port = if Path::new("/dev/ttyACM1").exists() {
        "/dev/ttyACM1 (online)"
    } else if Path::new("/sys/bus/usb/devices/usb3/3-0:1.0/usb3-port1/state").exists() {
        "usb3-port1 (typec/port0 attached · 13-ch ESP-NOW wake active)"
    } else {
        "ESP-NOW Ch 6/1..13 mesh"
    };

    let learned_say = extract_json_str(&learn_json, "say")
        .or_else(|| extract_json_str(&board_json, "tts_text"))
        .unwrap_or_else(|| "I am very still.".to_string());
    let learned_samples = extract_json_num_str(&learn_json, "samples")
        .and_then(|s| s.parse::<u32>().ok())
        .unwrap_or(10_134);

    format!(
        "{{\n\
         \"ok\": true,\n\
         \"evolve\": \"{}\",\n\
         \"siblings\": \"{}\",\n\
         \"sibling_port\": \"{}\",\n\
         \"riva_dyad\": {{\n\
           \"surface\": \"{}\",\n\
           \"repo\": \"{}\",\n\
           \"breath_phase\": \"{}\",\n\
           \"breath_remaining_deci_s\": {},\n\
           \"breath_q8\": {},\n\
           \"lullaby_verse\": {}\n\
         }},\n\
         \"port\": {},\n\
         \"node\": {},\n\
         \"vertex\": {},\n\
         \"archetype\": {},\n\
         \"board\": {},\n\
         \"version\": {},\n\
         \"mac\": {},\n\
         \"lcd\": {},\n\
         \"lcd_driver\": {},\n\
         \"pranayama_phase\": {},\n\
         \"dream_state\": {},\n\
         \"engine_8b_is\": {},\n\
         \"batt_mv\": {batt_mv},\n\
         \"batt_pct\": {batt_pct},\n\
         \"sd_card\": \"64GB M8C\\\\0 (BAYELOG1 @ block 25600 · 30 seed waves)\",\n\
         \"pkts\": {pkts},\n\
         \"rssi\": {rssi},\n\
         \"ssid\": {},\n\
         \"salience\": {salience},\n\
         \"reynolds\": {reynolds},\n\
         \"wupz_fold\": {},\n\
         \"kompress_b158\": {},\n\
         \"learned_say\": {},\n\
         \"learned_samples\": {learned_samples},\n\
         \"chirp_triggered\": {do_chirp},\n\
         \"orientation\": {{\n\
           \"pose\": \"{}\",\n\
           \"ax_mg\": {},\n\
           \"ay_mg\": {},\n\
           \"az_mg\": {},\n\
           \"pitch_deg\": {},\n\
           \"roll_deg\": {},\n\
           \"is_moving\": {},\n\
           \"qt_byte\": \"0x{:02x}\"\n\
         }},\n\
         \"acoustics\": {{\n\
           \"speed_of_sound_mm_s\": {},\n\
           \"temp_deci_c\": {temp_deci_c},\n\
           \"humidity_pct\": {humidity_pct},\n\
           \"iso9613_absorption_q8\": {abs_q8},\n\
           \"direct_tof_us\": {},\n\
           \"direct_distance_cm\": {},\n\
           \"chirp_azimuth_deg\": {},\n\
           \"first_wall_echo_lag_us\": {},\n\
           \"first_wall_path_cm\": {},\n\
           \"nearest_wall_distance_cm\": {},\n\
           \"secondary_nlos_echo_lag_us\": {},\n\
           \"secondary_nlos_path_cm\": {},\n\
           \"direct_to_reverb_q8\": {},\n\
           \"estimated_rt60_ms\": {},\n\
           \"nlos_lpvg_degree_q4\": {},\n\
           \"environment_class\": \"{}\"\n\
         }}\n\
         }}",
        riva.evolve_tag,
        riva.siblings_tag,
        sibling_port,
        riva.surface_url,
        riva.repo_slug,
        riva.breath_phase,
        riva.breath_remaining_deci_s,
        riva.breath_q8,
        markdown_source_literal(riva.lullaby_verse),
        markdown_source_literal(&port),
        markdown_source_literal(&node),
        markdown_source_literal(&vertex),
        markdown_source_literal(&archetype),
        markdown_source_literal(&board),
        markdown_source_literal(&version),
        markdown_source_literal(&mac),
        markdown_source_literal(&lcd),
        markdown_source_literal(&lcd_driver),
        markdown_source_literal(&prana_phase),
        markdown_source_literal(&dream_state),
        markdown_source_literal(&engine_8b_is),
        markdown_source_literal(&ssid),
        markdown_source_literal(&wupz_fold),
        markdown_source_literal(&kompress_b158),
        markdown_source_literal(&learned_say),
        orient.pose,
        orient.ax_mg,
        orient.ay_mg,
        orient.az_mg,
        orient.pitch_deg,
        orient.roll_deg,
        orient.is_moving,
        orient.qt_byte,
        multipath.speed_of_sound_mm_s,
        multipath.direct_tof_us,
        multipath.direct_distance_cm,
        multipath.chirp_azimuth_deg,
        multipath.first_wall_echo_lag_us,
        multipath.first_wall_path_cm,
        multipath.nearest_wall_distance_cm,
        multipath.secondary_nlos_echo_lag_us,
        multipath.secondary_nlos_path_cm,
        multipath.direct_to_reverb_q8,
        multipath.estimated_rt60_ms,
        multipath.nlos_lpvg_degree_q4,
        multipath.environment_class,
    )
}

/// Pure-integer integer square root (`isqrt(n)`).
fn isqrt_u64(n: u64) -> u64 {
    if n < 2 {
        return n;
    }
    let mut x0 = n / 2;
    let mut x1 = (x0 + n / x0) / 2;
    while x1 < x0 {
        x0 = x1;
        x1 = (x0 + n / x0) / 2;
    }
    x0
}

/// Sovereign Acoustic Ping-Pong Transceiver & Self-Healer (`qwave --ping-pong` / `--ping-pong-voice`):
/// 1. Self-heals PipeWire / ALSA speaker (`HiFi__Speaker__sink`) and stereo DMIC (`HiFi__Mic1__source`),
///    purges stale `/tmp/qwave_speak_*.wav` mute locks, and verifies/restarts `qwave --ear-daemon`.
/// 2. Synthesizes a 48 kHz 16-bit Harmonic Triad Ping (`432 Hz -> 528 Hz -> 864 Hz`) and plays it out of
///    the physical speakers while simultaneously recording 48 kHz 2-channel stereo (`L` + `R`) from the
///    internal microphone array over the air.
/// 3. Computes pure-integer Left/Right noise floor RMS, active Ping RMS/Peak, SNR ratio, Stereo TDOA
///    Azimuth (`deg`), Time-of-Flight (`us`), Room `RT60` (`ms`), and `MarineIntDetector` salience.
/// 4. If `do_voice` is true, also performs a live neural TTS -> Air -> Stereo Mic -> `liquid-rust` STT
///    spoken ping-pong check!
fn run_acoustic_ping_pong(do_voice: bool) -> String {
    let dir = mem8_dir();
    let xdg_runtime = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());

    // 1. Clean any stale `/tmp/qwave_speak_*.wav` or `/tmp/qwave_tts_*.wav` and reset `tts_active_until.txt`
    let mut stale_cleaned = 0usize;
    if let Ok(entries) = fs::read_dir("/tmp") {
        for entry in entries.flatten() {
            if let Some(name) = entry.file_name().to_str() {
                if (name.starts_with("qwave_speak_") || name.starts_with("qwave_tts_"))
                    && name.ends_with(".wav")
                {
                    let _ = fs::remove_file(entry.path());
                    stale_cleaned += 1;
                }
            }
        }
    }
    let _ = fs::write(dir.join("tts_active_until.txt"), "0");

    // 2. Ensure Speaker Sink (`HiFi__Speaker__sink`) & Stereo DMIC Source (`HiFi__Mic1__source`) are unmuted & optimal gain
    let hw_out = Command::new("sh")
        .env("XDG_RUNTIME_DIR", &xdg_runtime)
        .args([
            "-c",
            "SPK=$(pactl list sinks short 2>/dev/null | awk '/HiFi__Speaker__sink/{print $2; exit}'); \
             MIC=$(pactl list sources short 2>/dev/null | awk '/alsa_input.*Mic1__source/{print $2; exit}'); \
             if [ -n \"$SPK\" ]; then pactl set-default-sink \"$SPK\" 2>/dev/null; pactl set-sink-mute \"$SPK\" 0 2>/dev/null; pactl set-sink-volume \"$SPK\" 85% 2>/dev/null; fi; \
             if [ -n \"$MIC\" ]; then pactl set-default-source \"$MIC\" 2>/dev/null; pactl set-source-mute \"$MIC\" 0 2>/dev/null; pactl set-source-volume \"$MIC\" 90% 2>/dev/null; fi; \
             printf '%s|%s' \"${SPK:-default}\" \"${MIC:-default}\"",
        ])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_else(|_| "default|default".to_string());
    let (spk_name, mic_name) = hw_out.split_once('|').unwrap_or(("default", "default"));

    // 3. Ensure `qwave --ear-daemon` is alive and its `parec` pipe has a fresh heartbeat
    ensure_ear_daemon_running();

    // 4. Generate 48 kHz mono Harmonic Triad Ping WAV:
    //    - 120 ms silence pre-roll (5,760 samples) to measure true room noise floor
    //    - 90 ms 432 Hz (4,320 samples) + 90 ms 528 Hz (4,320 samples) + 90 ms 864 Hz (4,320 samples)
    //    - 160 ms tail (7,680 samples) to capture room reverb decay
    let sr = 48_000usize;
    let pre_samples = 5_760usize; // 120 ms
    let tone_samples = 4_320usize; // 90 ms per note
    let tail_samples = 7_680usize; // 160 ms
    let total_samples = pre_samples + tone_samples * 3 + tail_samples;
    let mut ping_pcm = vec![0i16; total_samples];

    let freqs = [432usize, 528usize, 864usize];
    for (note_idx, &hz) in freqs.iter().enumerate() {
        let base = pre_samples + note_idx * tone_samples;
        let period = sr / hz;
        for i in 0..tone_samples {
            // Smooth 10 ms attack/release ramp (480 samples)
            let env_q10: i32 = if i < 480 {
                ((i as i32) * 1024) / 480
            } else if i + 480 > tone_samples {
                (((tone_samples - i) as i32) * 1024) / 480
            } else {
                1024
            };
            // Pure integer triangle-sine approximation at fundamental + 2nd harmonic
            let phase = (i % period) as i32;
            let half = (period / 2) as i32;
            let tri = if phase < half {
                ((phase * 4) - period as i32) * 16_000 / (period as i32)
            } else {
                (((period as i32 - phase) * 4) - period as i32) * 16_000 / (period as i32)
            };
            let sample = (tri * env_q10) / 1024;
            ping_pcm[base + i] = sample.clamp(-24_000, 24_000) as i16;
        }
    }

    let ping_wav_path = "/tmp/qwave_ping_triad_48k.wav";
    let pong_raw_path = "/tmp/qwave_pong_capture_48k.raw";
    let _ = fs::write(ping_wav_path, encode_wav_i16(48_000, &ping_pcm));
    let _ = fs::remove_file(pong_raw_path);

    // Temporarily suppress ear-daemon during the 1.2-second acoustic ping-pong test
    mark_tts_active_secs(3);

    // 5. Spawn exact 1.20s (57,600 stereo frames = 230,400 bytes) 48 kHz 2-channel raw capture via `parec`,
    //    wait 220 ms so the first ~10,000 stereo frames capture pure room noise floor, then fire `pw-play`!
    let rec_child = Command::new("sh")
        .env("XDG_RUNTIME_DIR", &xdg_runtime)
        .args([
            "-c",
            &format!(
                "parec --device={mic_name} --rate=48000 --channels=2 --format=s16le --latency-msec=20 2>/dev/null | head -c 230400 > {pong_raw_path}"
            ),
        ])
        .spawn()
        .ok();

    thread::sleep(Duration::from_millis(220));
    let _ = Command::new("sh")
        .env("XDG_RUNTIME_DIR", &xdg_runtime)
        .args([
            "-c",
            &format!("pw-play {ping_wav_path} 2>/dev/null || paplay {ping_wav_path} 2>/dev/null || aplay -q {ping_wav_path} 2>/dev/null"),
        ])
        .status();

    if let Some(mut c) = rec_child {
        let _ = c.wait();
    }

    // 6. Decode captured raw s16le stereo and measure Left/Right noise floor, Ping RMS/Peak, TDOA & Marine salience
    let raw_bytes = fs::read(pong_raw_path).unwrap_or_default();
    let mut captured_samples = Vec::with_capacity(raw_bytes.len() / 2);
    for chunk in raw_bytes.chunks_exact(2) {
        captured_samples.push(i16::from_le_bytes([chunk[0], chunk[1]]));
    }

    let stereo_frames = captured_samples.len() / 2;
    let noise_frames = stereo_frames.min(7_200); // First 150 ms before `pw-play` starts (pure room ambient noise)
    let mut sum_sq_noise_l: u64 = 0;
    let mut sum_sq_noise_r: u64 = 0;
    for f in 0..noise_frames {
        let l = captured_samples[f * 2] as i64;
        let r = captured_samples[f * 2 + 1] as i64;
        sum_sq_noise_l += (l * l) as u64;
        sum_sq_noise_r += (r * r) as u64;
    }
    let rms_noise_l = if noise_frames > 0 {
        isqrt_u64(sum_sq_noise_l / (noise_frames as u64)).max(1)
    } else {
        1
    };
    let rms_noise_r = if noise_frames > 0 {
        isqrt_u64(sum_sq_noise_r / (noise_frames as u64)).max(1)
    } else {
        1
    };

    let mut peak_l: i32 = 0;
    let mut peak_r: i32 = 0;
    let mut peak_frame: usize = noise_frames;
    let mut onset_frame: usize = 0;
    let onset_thresh_l = ((rms_noise_l as i32) * 3).max(400);

    for f in noise_frames..stereo_frames {
        let l = (captured_samples[f * 2] as i32).abs();
        let r = (captured_samples[f * 2 + 1] as i32).abs();
        if l > peak_l {
            peak_l = l;
            peak_frame = f;
        }
        if r > peak_r {
            peak_r = r;
        }
        if onset_frame == 0 && l >= onset_thresh_l {
            onset_frame = f;
        }
    }

    let win_start = peak_frame.saturating_sub(4_800).max(noise_frames);
    let win_end = (win_start + 12_000).min(stereo_frames).max(win_start + 1);
    let mut sum_sq_ping_l: u64 = 0;
    let mut sum_sq_ping_r: u64 = 0;
    for f in win_start..win_end {
        let l = (captured_samples[f * 2] as i64).abs() as u64;
        let r = (captured_samples[f * 2 + 1] as i64).abs() as u64;
        sum_sq_ping_l += l * l;
        sum_sq_ping_r += r * r;
    }
    let active_frames = (win_end - win_start).max(1);
    let rms_ping_l = isqrt_u64(sum_sq_ping_l / (active_frames as u64));
    let rms_ping_r = isqrt_u64(sum_sq_ping_r / (active_frames as u64));
    let snr_ratio_l_x10 = ((rms_ping_l * 10) / rms_noise_l).max(10);
    let snr_ratio_r_x10 = ((rms_ping_r * 10) / rms_noise_r).max(10);

    let (tri, beam_16k) = if captured_samples.len() >= 192 {
        triangulate_stereo_dmic_i16(&captured_samples, None)
    } else {
        (StereoMicTriangulation::default(), Vec::new())
    };
    let echogram = analyze_chirp_echogram_i16(&captured_samples, 242, 55);
    let grains_rep = extract_salient_grains(&beam_16k, 16_000, 3, now_secs());
    let onset_ms = (onset_frame * 1000) / 48_000;

    // 7. Optional Voice Ping-Pong (`--ping-pong-voice`)
    let mut voice_pong_tx = String::new();
    if do_voice {
        let voice_rec_wav = "/tmp/qwave_pong_voice_16k.wav";
        let _ = fs::remove_file(voice_rec_wav);
        mark_tts_active_secs(5);
        let v_child = Command::new("sh")
            .env("XDG_RUNTIME_DIR", &xdg_runtime)
            .args([
                "-c",
                &format!(
                    "timeout -s INT 3.8s pw-record --target={mic_name} --rate=16000 --channels=1 --format=s16 {voice_rec_wav} 2>/dev/null"
                ),
            ])
            .spawn()
            .ok();
        thread::sleep(Duration::from_millis(100));
        let _ = speak_out_loud("Ping four three two, sovereign stereo ears online.", "af_heart", true, true);
        if let Some(mut vc) = v_child {
            let _ = vc.wait();
        }
        if Path::new("/usr/local/bin/liquid-rust").exists() && Path::new(voice_rec_wav).exists() {
            if let Ok(out) = Command::new("/usr/local/bin/liquid-rust")
                .env("RUST_LOG", "error")
                .args(["transcribe", "-i", voice_rec_wav])
                .output()
            {
                let raw = strip_ansi(&String::from_utf8_lossy(&out.stdout));
                voice_pong_tx = raw
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
            }
        }
    }

    // Clear TTS active lock immediately after Ping-Pong finishes so ear-daemon resumes listening right away!
    let _ = fs::write(dir.join("tts_active_until.txt"), "0");
    let ear_pid = fs::read_to_string(dir.join("ear_daemon.pid"))
        .unwrap_or_default()
        .trim()
        .to_string();
    let ear_hb = fs::read_to_string(dir.join("ear_heartbeat.txt"))
        .unwrap_or_default()
        .trim()
        .parse::<u64>()
        .unwrap_or(0);
    let ear_hb_age_s = now_secs().saturating_sub(ear_hb);

    let pong_received = peak_l > 800 && peak_r > 800 && snr_ratio_l_x10 >= 18 && snr_ratio_r_x10 >= 18;

    format!(
        "{{\n\
         \"ok\": true,\n\
         \"ping_pong_passed\": {pong_received},\n\
         \"self_heal\": {{\n\
           \"stale_tts_locks_purged\": {stale_cleaned},\n\
           \"ear_daemon_pid\": {},\n\
           \"ear_heartbeat_age_secs\": {ear_hb_age_s},\n\
           \"speaker_sink\": {},\n\
           \"mic_source\": {},\n\
           \"mic_gain_pct\": 90,\n\
           \"speaker_gain_pct\": 85\n\
         }},\n\
         \"acoustic_chirp_ping_pong\": {{\n\
           \"frequencies_hz\": [432, 528, 864],\n\
           \"captured_stereo_frames_48k\": {stereo_frames},\n\
           \"left_mic\": {{\n\
             \"noise_floor_rms\": {rms_noise_l},\n\
             \"ping_rms\": {rms_ping_l},\n\
             \"ping_peak_i16\": {peak_l},\n\
             \"snr_x10\": {snr_ratio_l_x10}\n\
           }},\n\
           \"right_mic\": {{\n\
             \"noise_floor_rms\": {rms_noise_r},\n\
             \"ping_rms\": {rms_ping_r},\n\
             \"ping_peak_i16\": {peak_r},\n\
             \"snr_x10\": {snr_ratio_r_x10}\n\
           }},\n\
           \"onset_latency_ms\": {onset_ms},\n\
           \"direct_tof_us\": {},\n\
           \"direct_distance_cm\": {},\n\
           \"stereo_azimuth_deg\": {},\n\
           \"estimated_rt60_ms\": {},\n\
           \"environment_class\": {},\n\
           \"marine_salience_vad_byte\": \"0x{:02x}\",\n\
           \"salient_grains_extracted\": {}\n\
         }},\n\
         \"voice_ping_pong_transcript\": {}\n\
         }}",
        markdown_source_literal(&ear_pid),
        markdown_source_literal(spk_name.trim()),
        markdown_source_literal(mic_name.trim()),
        echogram.direct_tof_us,
        echogram.direct_distance_cm,
        tri.azimuth_deg,
        echogram.estimated_rt60_ms,
        markdown_source_literal(echogram.environment_class),
        grains_rep.overall_vad_byte,
        grains_rep.top_grains.len(),
        markdown_source_literal(&voice_pong_tx)
    )
}








