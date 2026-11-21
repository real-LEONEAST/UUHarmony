//! Typed C boundary for the HarmonyOS app; no process exit or signal handlers.
mod unified;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use tokio::sync::watch;
static CONFIG: OnceLock<String> = OnceLock::new();
static WIDTH: AtomicU32 = AtomicU32::new(0);
static HEIGHT: AtomicU32 = AtomicU32::new(0);
static STREAM_SIZE: AtomicU64 = AtomicU64::new(0);
static CAPTURE_REQUESTS: AtomicU32 = AtomicU32::new(0);
static CURSOR_REQUESTS: AtomicU32 = AtomicU32::new(0);
static ONLINE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub(crate) fn set_online(online:bool) { ONLINE.store(online,Ordering::Release); }
#[no_mangle] pub extern "C" fn uu_host_online()->bool { ONLINE.load(Ordering::Acquire) }
#[no_mangle]
pub extern "C" fn uu_host_receiving_files() -> bool {
    crate::file_trans::inbox::enabled()
}
#[no_mangle]
pub extern "C" fn uu_host_receive_command() -> u64 {
    crate::file_trans::inbox::command()
}
#[no_mangle]
pub unsafe extern "C" fn uu_host_set_receiving_files(enabled: bool, ticket: u64, descriptor: i32, root: *const std::ffi::c_char) -> i32 {
    if !enabled {
        return if crate::file_trans::inbox::set_authorized(None, String::new(), ticket).is_ok() { 0 } else { -1 };
    }
    if !uu_host_online() || root.is_null() || descriptor < 0 { return -1; }
    let Ok(path) = std::ffi::CStr::from_ptr(root).to_str() else { return -1; };
    if !(path.starts_with('/') || path.starts_with("file://")) || path.len() > 4095 { return -1; }
    use std::os::fd::FromRawFd;
    let fd = libc::fcntl(descriptor, libc::F_DUPFD_CLOEXEC, 0);
    if fd < 0 { return -1; }
    let directory = std::fs::File::from_raw_fd(fd);
    match crate::file_trans::inbox::set_authorized(Some(directory), path.to_owned(), ticket) {
        Ok(()) if uu_host_online() => 0,
        _ => -1,
    }
}

pub(crate) fn transfer_history_path() -> Option<std::path::PathBuf> {
    let config = std::path::Path::new(CONFIG.get()?);
    Some(config.parent()?.parent()?.join("uu-transfer-history"))
}
#[no_mangle] pub extern "C" fn uu_host_capture_requests()->u32 { CAPTURE_REQUESTS.load(Ordering::Acquire) }
#[no_mangle]
pub extern "C" fn uu_host_wants_embedded_cursor() -> bool {
    CURSOR_REQUESTS.load(Ordering::Acquire) > 0
}
struct CaptureLease(bool);
impl CaptureLease {
    fn new(embedded_cursor: bool) -> Self {
        if embedded_cursor { CURSOR_REQUESTS.fetch_add(1, Ordering::AcqRel); }
        CAPTURE_REQUESTS.fetch_add(1, Ordering::AcqRel);
        Self(embedded_cursor)
    }
}
impl Drop for CaptureLease {
    fn drop(&mut self) {
        CAPTURE_REQUESTS.fetch_sub(1, Ordering::AcqRel);
        if self.0 { CURSOR_REQUESTS.fetch_sub(1, Ordering::AcqRel); }
    }
}
static STOP: Mutex<Option<watch::Sender<bool>>> = Mutex::new(None);
static TASK: Mutex<Option<tokio::task::JoinHandle<()>>> = Mutex::new(None);
fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .expect("HarmonyOS runtime")
    })
}
extern "C" {
    fn uu_platform_log(level: i32, text: *const libc::c_char);
    fn uu_login_clear();
    fn uu_input_authorized() -> bool;
    fn uu_video_config(fps: u32, kbps: u32) -> i32;
    fn uu_video_poll(data: *mut u8, capacity: usize) -> i32;
    fn uu_video_request_idr();
    fn uu_media_state()->i32;
    fn uu_media_output_size() -> u64;
    fn uu_platform_status(text: *const libc::c_char);
}
pub(crate) fn status(text: &str) {
    if let Ok(text) = std::ffi::CString::new(text) {
        unsafe {
            uu_platform_status(text.as_ptr());
        }
    }
}
pub fn dimensions() -> (u32, u32) {
    (
        WIDTH.load(Ordering::Acquire),
        HEIGHT.load(Ordering::Acquire),
    )
}
// Update stream metadata while stopped; this never changes display modes.
#[no_mangle]
pub extern "C" fn uu_host_set_dimensions(width: u32, height: u32) -> i32 {
    uu_host_set_display(width, height, 0, 0)
}
#[no_mangle]
pub extern "C" fn uu_host_set_display(width: u32, height: u32, stream_width: u32, stream_height: u32) -> i32 {
    let task = TASK.lock().unwrap();
    if width == 0 || height == 0 || width > 8192 || height > 8192 ||
        stream_width > width || stream_height > height ||
        (stream_width == 0) != (stream_height == 0) ||
        task.as_ref().is_some_and(|t| !t.is_finished()) {
        return -1;
    }
    WIDTH.store(width, Ordering::Release);
    HEIGHT.store(height, Ordering::Release);
    STREAM_SIZE.store((u64::from(stream_width) << 32) | u64::from(stream_height), Ordering::Release);
    0
}
#[no_mangle]
pub extern "C" fn uu_host_stream_size() -> u64 {
    STREAM_SIZE.load(Ordering::Acquire)
}
pub fn stream_size() -> Option<(u32, u32)> {
    let size = uu_host_stream_size();
    (size != 0).then_some(((size >> 32) as u32, size as u32))
}
pub fn actual_stream_size() -> Option<(u32, u32)> {
    let size = unsafe { uu_media_output_size() };
    (size != 0).then_some(((size >> 32) as u32, size as u32))
}
pub fn capture_fps_limit() -> u32 {
    if stream_size().is_some() { 30 } else { 60 }
}
#[no_mangle]
pub unsafe extern "C" fn uu_host_init(path: *const libc::c_char, width: u32, height: u32,
    language: *const libc::c_char) -> i32 {
    if path.is_null() || language.is_null() || width == 0 || height == 0 || width > 16384 || height > 16384 {
        return -1;
    }
    let Ok(path) = std::ffi::CStr::from_ptr(path).to_str() else {
        return -1;
    };
    let Ok(language) = std::ffi::CStr::from_ptr(language).to_str() else { return -1; };
    if !matches!(language, "zh" | "en") { return -1; }
    // Install process settings once, before creating any runtime threads.
    let configured = CONFIG.get_or_init(|| {
        std::env::set_var("UU_CONFIG", path);
        std::env::set_var("UU_LANG", language);
        std::env::set_var("UU_REMOTE_ASSIST", "1");
        std::env::set_var("UU_LOGIN_WINDOW", "0");
        std::env::set_var("UU_AUDIO", "0");
        std::env::set_var("UU_DESKTOP_RESIZE", "0");
        path.to_owned()
    });
    if configured != path {
        return -1;
    }
    let _ = log::set_logger(&LOGGER);
    log::set_max_level(log::LevelFilter::Info);
    WIDTH.store(width, Ordering::Release);
    HEIGHT.store(height, Ordering::Release);
    status(crate::i18n::s("准备就绪", "Ready"));
    0
}
#[no_mangle]
pub extern "C" fn uu_host_login() -> i32 {
    let mut task = TASK.lock().unwrap();
    if task.as_ref().is_some_and(|t| !t.is_finished()) {
        return -1;
    }
    *task = Some(runtime().spawn(async {
        let ui = crate::login_ui::LoginUi::attached();
        match crate::login::flow(&ui).await {
            Ok(_) => {
                unsafe {
                    uu_login_clear();
                }
                status(crate::i18n::s("已登录，可以开始共享", "Signed in, ready to share"));
            }
            Err(_) => status(crate::i18n::s("登录失败，请刷新二维码重试", "Sign-in failed. Refresh the QR code to retry.")),
        }
    }));
    0
}
#[no_mangle]
pub extern "C" fn uu_host_logged_in() -> bool {
    crate::config::read_fresh()
        .ok()
        .and_then(|f| crate::auth::Credentials::load(f.as_ref()).ok())
        .is_some()
}
#[no_mangle]
pub unsafe extern "C" fn uu_host_publish_cover(data: *const u8, size: usize) -> i32 {
    if data.is_null() || size == 0 || size > 2 * 1024 * 1024 || !uu_host_online() { return -1; }
    static UPLOAD: Mutex<()> = Mutex::new(());
    let Ok(_upload) = UPLOAD.try_lock() else { return -1; };
    let credentials = || crate::config::read_fresh()
        .and_then(|file| crate::auth::Credentials::load(file.as_ref())).ok();
    let Some(current) = credentials().filter(|value| !value.user_id.is_empty() && !value.device_id.is_empty()) else {
        return -1;
    };
    let auth = crate::auth::UUAuthClient::new(current);
    let chosen = std::slice::from_raw_parts(data, size).to_vec();
    let active = || uu_host_online() && credentials().is_some_and(|value|
        value.user_id == auth.creds.user_id && value.device_id == auth.creds.device_id);
    match runtime().block_on(crate::wallpaper::publish_selected(&auth, chosen, active)) {
        Ok(()) => 0,
        Err(stage) => {
            log::warn!("Selected device cover synchronization failed: stage={stage}");
            -2
        }
    }
}
#[no_mangle]
pub extern "C" fn uu_host_start() -> i32 {
    if !uu_host_logged_in() {
        return -1;
    }
    let mut task = TASK.lock().unwrap();
    if task.as_ref().is_some_and(|t| !t.is_finished()) {
        return -2;
    }
    let (stop, mut shutdown) = watch::channel(false);
    *STOP.lock().unwrap() = Some(stop.clone());
    *task = Some(runtime().spawn(async move {
        struct OnlineReset;
        impl Drop for OnlineReset {fn drop(&mut self){set_online(false);crate::file_trans::inbox::disable();}}
        let _online_reset=OnlineReset;
        let capture = match crate::capture::ScreenCapture::new() { Ok(c) => Arc::new(c), Err(_) => { status(crate::i18n::s("屏幕初始化失败", "Display initialization failed")); return; } };
        let input = Arc::new(crate::input::InputInjector::new());
        let sessions = Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new()));
        let mut serving_shutdown = shutdown.clone();
        let credentials = match crate::config::read_fresh().and_then(|file| crate::auth::Credentials::load(file.as_ref())) {
            Ok(credentials) => credentials,
            Err(_) => { status(crate::i18n::s("登录已失效，请重新扫码", "Sign-in expired. Scan a new QR code.")); return; }
        };
        let client = Arc::new(crate::auth::UUAuthClient::new(credentials.clone()));
        let session = match crate::assist::Assist::start_account(client, credentials) {
            Ok(session) => session,
            Err(_) => { status(crate::i18n::s("远程协助初始化失败，请重新开始共享", "Assistance initialization failed. Restart sharing.")); return; }
        };
        let (mut commands, command_worker) = session.commands(stop);
        let mut assist = Some(session);
        let pointer = input.start_pointer_worker();
        status(crate::i18n::s("正在连接 UU 服务…", "Connecting to UU…"));
        let success = tokio::select! {
            r = crate::serve(capture, input.clone(), &mut serving_shutdown, &mut assist, &mut commands, sessions.clone()) => r,
            _ = shutdown.changed() => Ok(()),
        }.is_ok();
        command_worker.abort();
        let _ = command_worker.await;
        input.shutdown(); pointer.abort();
        for (_, peer) in sessions.lock().await.drain() { crate::close_peer(&peer.pc).await; }
        if let Some(session) = assist.as_mut() {
            session.allowed = false;
            let _ = tokio::time::timeout(std::time::Duration::from_secs(5), session.cancel()).await;
        }
        status(if success { crate::i18n::s("共享已停止", "Sharing stopped") }
            else { crate::i18n::s("连接失败，请停止后重试", "Connection failed. Stop sharing and retry.") });
    }));
    0
}
#[no_mangle]
pub extern "C" fn uu_host_stop() {
    set_online(false);
    crate::file_trans::inbox::disable();
    if let Some(stop) = STOP.lock().unwrap().take() {
        let _ = stop.send(true);
    } else if let Some(task) = TASK.lock().unwrap().take() {
        task.abort();
    }
}
pub struct Encoder {
    buffer: Vec<u8>,
    _lease: CaptureLease,
}
impl Encoder {
    pub async fn open(_: (u32, u32), fps: u32, kbps: u32, embedded_cursor: bool) -> Result<Self, String> {
        // Publishing a room never starts capture. A real desktop stream owns
        // this cancellable demand lease; ArkUI requests system consent on demand.
        let lease=CaptureLease::new(embedded_cursor);
        let until=std::time::Instant::now()+std::time::Duration::from_secs(30);
        loop {
            match unsafe{uu_media_state()} {
                0=>break,
                -2|1|2|3|4|10=>return Err("HarmonyOS capture denied or ended".into()),
                _=>(),
            }
            if std::time::Instant::now()>=until{return Err("HarmonyOS capture consent timed out".into());}
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        let code = unsafe { uu_video_config(fps.min(60), kbps) };
        if code != 0 {
            return Err(format!("HarmonyOS encoder setup failed: {code}"));
        }
        Ok(Self {
            buffer: vec![0; 8 * 1024 * 1024],
            _lease:lease,
        })
    }
    pub fn request_idr(&self) {
        unsafe {
            uu_video_request_idr();
        }
    }
    pub fn poll(&mut self) -> Result<Option<Vec<u8>>, String> {
        let size = unsafe { uu_video_poll(self.buffer.as_mut_ptr(), self.buffer.len()) };
        if size < 0 {
            return Err(format!("HarmonyOS capture stopped: {size}"));
        }
        if size == 0 {
            return Ok(None);
        }
        Ok(Some(self.buffer[..size as usize].to_vec()))
    }
}

pub fn input_permission() -> crate::system_metrics::Permission {
    if unsafe { uu_input_authorized() } {
        crate::system_metrics::Permission::Allow
    } else {
        crate::system_metrics::Permission::Reject
    }
}

struct PlatformLogger;
static LOGGER: PlatformLogger = PlatformLogger;
impl log::Log for PlatformLogger {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        metadata.level() <= log::Level::Info
    }
    fn log(&self, record: &log::Record<'_>) {
        if self.enabled(record.metadata()) {
            if let Ok(text) = std::ffi::CString::new(format!("{}", record.args())) {
                unsafe {
                    uu_platform_log(record.level() as i32, text.as_ptr());
                }
            }
        }
    }
    fn flush(&self) {}
}
