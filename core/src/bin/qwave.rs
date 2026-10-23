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
use qwave_core::quanttern::{DEFAULT_THRESHOLD, Vad, pack_vad_byte};
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
            let json = handle_alexiai_stt(&body);
            send_response(&mut stream, "200 OK", "application/json", json.as_bytes())
        }
        ("GET", "/api/alexiai/tts") => {
            let text = get_query_param(query, "text").unwrap_or_else(|| "Alexiai online.".to_string());
            let voice = get_query_param(query, "voice").unwrap_or_else(|| "af_heart".to_string());
            let wav_bytes = synthesize_alexiai_tts(&text, &voice);
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
/// Phoenix Speaker Recognition + `MEM|8` wave bridge) with fallback to `kokoro-speak stt`.
fn handle_alexiai_stt(wav_bytes: &[u8]) -> String {
    if wav_bytes.len() < 64 {
        return "{\"ok\":false,\"error\":\"audio buffer too short\"}".to_string();
    }
    let wav_path = format!("/tmp/qwave_mic_{}.wav", std::process::id());
    if let Err(e) = fs::write(&wav_path, wav_bytes) {
        return format!("{{\"ok\":false,\"error\":{}}}", markdown_source_literal(&e.to_string()));
    }

    // 1. Primary: Pure-Rust `liquid-rust transcribe` (LiquidAI LFM2.5-Audio + Phoenix Protocol)
    for lfm_bin in ["/usr/local/bin/liquid-rust", "/home/hue/.cargo/target/release/liquid-rust"] {
        if Path::new(lfm_bin).exists() {
            if let Ok(out) = Command::new(lfm_bin)
                .args(["transcribe", "-i", &wav_path, "--store-mem8"])
                .output()
            {
                if out.status.success() {
                    let raw = String::from_utf8_lossy(&out.stdout);
                    let cleaned: String = raw
                        .lines()
                        .map(str::trim)
                        .filter(|l| {
                            !l.is_empty()
                                && !l.starts_with('═')
                                && !l.starts_with('🎤')
                                && !l.starts_with("✓")
                        })
                        .collect::<Vec<_>>()
                        .join(" ");
                    if !cleaned.is_empty() {
                        let _ = fs::remove_file(&wav_path);
                        return format!(
                            "{{\"ok\":true,\"text\":{},\"backend\":\"liquid-rust (LFM2.5-Audio + Phoenix)\"}}",
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
            "{{\"ok\":true,\"text\":{},\"backend\":\"kokoro-speak-stt\"}}",
            markdown_source_literal(&raw)
        );
    }

    let _ = fs::remove_file(&wav_path);
    "{\"ok\":false,\"error\":\"no offline STT backend succeeded\"}".to_string()
}

/// Synthesize speech via `kokoro-speak` / `liquid-rust speak` (with fallback to `espeak-ng --stdout`).
fn synthesize_alexiai_tts(text: &str, voice: &str) -> Vec<u8> {
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
                                return bytes;
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
                    return bytes;
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
            return out.stdout;
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

    let vad = Vad::new(valence_num as f32 / 100.0, arousal_num as f32 / 100.0, 0.42);
    let vad_byte = pack_vad_byte(vad, DEFAULT_THRESHOLD);

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
          if (d.ok && d.text && d.text.trim()) {{
            sendToAlexiai(d.text.trim());
          }} else {{
            if (statusEl) statusEl.textContent = '💜 Could not catch that — click 🎙️ to try again or type below.';
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
