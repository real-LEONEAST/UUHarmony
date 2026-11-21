//! A PC-side file receiver scoped to the locally authorized download folder.

use super::*;
use std::collections::{HashSet, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{self, ErrorKind};
use std::sync::atomic::AtomicBool;

const VIRTUAL_ROOT: &str = "C:/UUHarmony";
const TEMP_PREFIX: &str = ".uu-partial-";
const MAX_FILES: usize = 1024;
const MAX_TASKS: usize = 16;
const MAX_FILE_LIST: u64 = 512 * 1024;
const MAX_LIST_RESPONSE: usize = 192 * 1024;
static ACTIVE: Mutex<Option<Inbox>> = Mutex::new(None);
static ENABLED: AtomicBool = AtomicBool::new(false);
static COMMAND: AtomicU64 = AtomicU64::new(0);
static NEXT_PEER: AtomicU64 = AtomicU64::new(1);
static NEXT_TEMP: AtomicU64 = AtomicU64::new(1);

pub(super) struct Session(u64);

impl Session {
    pub(super) fn new() -> Self {
        Self(NEXT_PEER.fetch_add(1, Ordering::Relaxed))
    }

    pub(super) fn handle(&self, case: u32, fields: &[WireField]) -> Option<(u32, Enc)> {
        let mut active = ACTIVE.lock().unwrap();
        dispatch(active.as_mut(), self.0, case, fields)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let tasks = ACTIVE.lock().unwrap().as_mut().and_then(|inbox| inbox.peers.remove(&self.0));
        drop(tasks);
    }
}

pub(crate) fn enabled() -> bool {
    ENABLED.load(Ordering::Acquire)
}

pub(crate) fn advertised_path() -> &'static str {
    if enabled() { VIRTUAL_ROOT } else { "" }
}

pub(crate) fn command() -> u64 {
    COMMAND.fetch_add(1, Ordering::AcqRel) + 1
}

#[cfg(not(target_env = "ohos"))]
pub(crate) fn set(root: Option<&Path>, ticket: u64) -> io::Result<()> {
    let root = root.map(|path| -> io::Result<InboxDirectory> {
        fs::create_dir_all(path)?;
        if !fs::symlink_metadata(path)?.is_dir() { return Err(ErrorKind::PermissionDenied.into()); }
        Ok(InboxDirectory {path: path.canonicalize()?})
    }).transpose()?;
    change_inbox(root, String::new(), ticket)
}

#[cfg(target_env = "ohos")]
pub(crate) fn set_authorized(root: Option<File>, location: String, ticket: u64) -> io::Result<()> {
    let root = root.map(|file| {
        if !file.metadata()?.is_dir() { return Err(io::Error::from(ErrorKind::PermissionDenied)); }
        Ok(InboxDirectory::from_file(file))
    }).transpose()?;
    change_inbox(root, location, ticket)
}

fn change_inbox(root: Option<InboxDirectory>, location: String, ticket: u64) -> io::Result<()> {
    let previous = {
        let mut active = ACTIVE.lock().unwrap();
        if COMMAND.load(Ordering::Acquire) != ticket { return Err(ErrorKind::Interrupted.into()); }
        match root {
            Some(root) => {
                if active.is_none() {
                    *active = Some(Inbox { root, location, peers: HashMap::new() });
                }
                ENABLED.store(true, Ordering::Release);
                None
            }
            None => {
                ENABLED.store(false, Ordering::Release);
                active.take()
            }
        }
    };
    drop(previous);
    Ok(())
}

pub(crate) fn disable() {
    let previous = {
        let mut active = ACTIVE.lock().unwrap();
        command();
        ENABLED.store(false, Ordering::Release);
        active.take()
    };
    drop(previous);
}

struct InboxDirectory {
    #[cfg(not(target_env = "ohos"))]
    path: PathBuf,
    #[cfg(target_env = "ohos")]
    file: File,
}

#[cfg(target_env = "ohos")]
impl InboxDirectory {
    fn from_file(file: File) -> Self { Self {file} }

    fn fd(&self) -> libc::c_int {
        use std::os::fd::AsRawFd;
        self.file.as_raw_fd()
    }

    fn create(&self, name: &str) -> io::Result<File> {
        use std::os::fd::FromRawFd;
        let name = std::ffi::CString::new(name)?;
        let fd = unsafe { libc::openat(self.fd(), name.as_ptr(), libc::O_WRONLY | libc::O_CREAT |
            libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC, 0o600) };
        if fd < 0 { return Err(io::Error::last_os_error()); }
        Ok(unsafe { File::from_raw_fd(fd) })
    }

    fn remove(&self, name: &str) {
        if let Ok(name) = std::ffi::CString::new(name) {
            unsafe { libc::unlinkat(self.fd(), name.as_ptr(), 0); }
        }
    }

    fn stat(&self, name: &str) -> io::Result<libc::stat> {
        let name = std::ffi::CString::new(name)?;
        let mut stat = std::mem::MaybeUninit::uninit();
        if unsafe { libc::fstatat(self.fd(), name.as_ptr(), stat.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { stat.assume_init() })
    }

    fn exists(&self, name: &str) -> bool { self.stat(name).is_ok() }

    fn entries(&self) -> io::Result<Vec<(String, bool, u64, u64)>> {
        let fd = unsafe { libc::openat(self.fd(), c".".as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC) };
        if fd < 0 { return Err(io::Error::last_os_error()); }
        let stream = unsafe { libc::fdopendir(fd) };
        if stream.is_null() {
            let error = io::Error::last_os_error();
            unsafe { libc::close(fd); }
            return Err(error);
        }
        let result = (|| {
            let mut entries = Vec::new();
            loop {
                unsafe { *libc::__errno_location() = 0; }
                let item = unsafe { libc::readdir(stream) };
                if item.is_null() {
                    let error = io::Error::last_os_error();
                    if error.raw_os_error() == Some(0) { return Ok(entries); }
                    return Err(error);
                }
                let Ok(name) = (unsafe { std::ffi::CStr::from_ptr((*item).d_name.as_ptr()) }).to_str() else { continue };
                if !safe_name(name) { continue; }
                let stat = match self.stat(name) {
                    Ok(stat) => stat,
                    Err(error) if error.kind() == ErrorKind::NotFound => continue,
                    Err(error) => return Err(error),
                };
                let kind = stat.st_mode & libc::S_IFMT;
                if kind != libc::S_IFREG && kind != libc::S_IFDIR { continue; }
                entries.push((name.to_owned(), kind == libc::S_IFDIR, stat.st_size.max(0) as u64, stat.st_mtime.max(0) as u64));
                if entries.len() > MAX_FILES { return Err(ErrorKind::InvalidData.into()); }
            }
        })();
        unsafe { libc::closedir(stream); }
        result
    }
}

#[cfg(not(target_env = "ohos"))]
impl InboxDirectory {
    fn create(&self, name: &str) -> io::Result<File> {
        OpenOptions::new().write(true).create_new(true).open(self.path.join(name))
    }
    fn remove(&self, name: &str) { let _ = fs::remove_file(self.path.join(name)); }
    fn exists(&self, name: &str) -> bool { fs::symlink_metadata(self.path.join(name)).is_ok() }
    fn entries(&self) -> io::Result<Vec<(String, bool, u64, u64)>> {
        let mut entries = Vec::new();
        for item in fs::read_dir(&self.path)? {
            let item = item?;
            let filename = item.file_name();
            let Some(name) = filename.to_str().filter(|name| safe_name(name)) else { continue };
            let stat = fs::symlink_metadata(item.path())?;
            if !stat.is_file() && !stat.is_dir() { continue; }
            entries.push((name.to_owned(), stat.is_dir(), stat.len(), unix_secs(stat.modified())));
            if entries.len() > MAX_FILES { return Err(ErrorKind::InvalidData.into()); }
        }
        Ok(entries)
    }
}

struct Inbox {
    root: InboxDirectory,
    location: String,
    peers: HashMap<u64, PeerUploads>,
}

#[derive(Default)]
struct PeerUploads {
    tasks: HashMap<u64, Upload>,
    recently_finished: VecDeque<u64>,
}

struct Upload {
    names: Vec<(Vec<String>, String, u64)>,
    open: HashMap<u64, Pending>,
    finished: HashSet<u64>,
}

struct Pending {
    directory: InboxDirectory,
    file: Option<File>,
    temp: String,
    leaf: String,
    size: u64,
    written: u64,
    next_block: Option<u64>,
}

impl Pending {
    fn new(directory: InboxDirectory, leaf: &str, size: u64) -> io::Result<Self> {
        for _ in 0..32 {
            let unique = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
            let temp = format!("{TEMP_PREFIX}{}-{unique}", std::process::id());
            match directory.create(&temp) {
                Ok(file) => return Ok(Self { directory, file: Some(file), temp, leaf: leaf.to_owned(), size, written: 0, next_block: None }),
                Err(e) if e.kind() == ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e),
            }
        }
        Err(ErrorKind::AlreadyExists.into())
    }

    fn block(&mut self, number: u64, data: &[u8]) -> Result<(), u64> {
        if self.next_block.map_or(number > 1, |next| number != next) || data.is_empty() {
            return Err(FT_PROTOCOL);
        }
        let total = self.written.checked_add(data.len() as u64).filter(|n| *n <= self.size).ok_or(FT_PROTOCOL)?;
        let file = self.file.as_mut().ok_or(FT_PROTOCOL)?;
        file.write_all(data).map_err(|e| io_error(&e))?;
        self.written = total;
        self.next_block = number.checked_add(1);
        Ok(())
    }

    fn publish(mut self, location: &str, branch: &[String]) -> Result<(), u64> {
        let file = self.file.take().ok_or(FT_PROTOCOL)?;
        let metadata = file.metadata().map_err(|e| io_error(&e))?;
        if self.written != self.size || metadata.len() != self.size {
            return Err(FT_IO);
        }
        file.sync_all().map_err(|e| io_error(&e))?;
        drop(file);
        // The temp and destination are in the same directory, enabling atomic no-replace
        // publication of a completely written and synced file.
        let destination = Path::new(&self.leaf);
        for index in 0..10_000 {
            let name = match index {
                0 => self.leaf.clone(),
                _ => {
                    let stem = destination.file_stem().and_then(|s| s.to_str()).ok_or(FT_IO)?;
                    let suffix = destination.extension().and_then(|s| s.to_str()).map_or(String::new(), |s| format!(".{s}"));
                    let number = format!(" ({index})");
                    let max = 255usize.saturating_sub(suffix.len() + number.len());
                    let mut end = stem.len().min(max);
                    while !stem.is_char_boundary(end) { end -= 1; }
                    format!("{}{number}{suffix}", &stem[..end])
                }
            };
            match publish_exclusive(&self.directory, &self.temp, &name) {
                Ok(()) => {
                    #[cfg(target_env = "ohos")]
                    if let Err(error) = record_receipt(&metadata, location, branch, &name) {
                        log::warn!("Transfer file published; history write failed: {:?}", error.kind());
                    }
                    #[cfg(not(target_env = "ohos"))]
                    let _ = (location, branch);
                    return Ok(());
                }
                Err(e) if e.kind() == ErrorKind::AlreadyExists => {}
                Err(e) => return Err(io_error(&e)),
            }
        }
        Err(FT_IO)
    }
}

#[cfg(target_env = "ohos")]
fn record_receipt(metadata: &fs::Metadata, location: &str, branch: &[String], name: &str) -> io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let Some(root) = crate::ohos::transfer_history_path() else { return Err(ErrorKind::NotFound.into()); };
    fs::create_dir_all(&root)?;
    if !fs::symlink_metadata(&root)?.is_dir() { return Err(ErrorKind::PermissionDenied.into()); }
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .map_err(io::Error::other)?;
    let id = format!("pc-{}-{}-{}", now.as_nanos(), std::process::id(), NEXT_TEMP.fetch_add(1, Ordering::Relaxed));
    let fingerprint = format!("{}:{}:{}:{}:{}", metadata.dev(), metadata.ino(), metadata.len(),
        metadata.mtime(), metadata.mtime_nsec());
    let entry = serde_json::json!({"id":id,"direction":"receive","name":name,"size":metadata.len(),
        "time":now.as_millis() as u64,"state":"complete","root":location,"branch":branch,"fingerprint":fingerprint});
    let temporary = root.join(format!(".{id}"));
    let result = (|| {
        let mut file = OpenOptions::new().write(true).create_new(true).open(&temporary)?;
        serde_json::to_writer(&mut file, &entry).map_err(io::Error::other)?;
        file.sync_all()?;
        fs::rename(&temporary, root.join(format!("{id}.json")))
    })();
    if result.is_err() { let _ = fs::remove_file(&temporary); }
    result
}

impl Drop for Pending {
    fn drop(&mut self) {
        drop(self.file.take());
        self.directory.remove(&self.temp);
    }
}

fn publish_exclusive(directory: &InboxDirectory, from: &str, to: &str) -> io::Result<()> {
    #[cfg(target_env = "ohos")]
    {
        let from = std::ffi::CString::new(from)?;
        let to = std::ffi::CString::new(to)?;
        let fd = directory.fd();
        // API 26 NDK libc exports renameat2. Older kernel/filesystem implementations
        // may reject the flag, in which case hard-link publication is also exclusive.
        if unsafe { libc::renameat2(fd, from.as_ptr(), fd,
            to.as_ptr(), libc::RENAME_NOREPLACE) } == 0 { return Ok(()); }
        let error = io::Error::last_os_error();
        if !matches!(error.raw_os_error(), Some(libc::ENOSYS | libc::EINVAL | libc::EOPNOTSUPP)) {
            return Err(error);
        }
        if unsafe { libc::linkat(fd, from.as_ptr(), fd, to.as_ptr(), 0) } == 0 { return Ok(()); }
        Err(io::Error::last_os_error())
    }
    #[cfg(not(target_env = "ohos"))]
    fs::hard_link(directory.path.join(from), directory.path.join(to))
}

fn safe_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 255 && name != "." && name != ".." &&
        !name.to_ascii_lowercase().starts_with(TEMP_PREFIX) &&
        !name.ends_with(['.', ' ']) &&
        !name.chars().any(|c| c.is_control() || "/\\:*?\"<>|".contains(c))
}

fn relative_parts(relative: &str) -> Result<Vec<&str>, u64> {
    if relative.is_empty() { return Ok(Vec::new()); }
    let parts: Vec<_> = relative.split('/').collect();
    if parts.len() > 32 || !parts.iter().all(|p| safe_name(p)) {
        return Err(FT_PERMISSION);
    }
    Ok(parts)
}

fn virtual_parts(normalized: &str) -> Result<Vec<&str>, u64> {
    let raw = normalized.trim_end_matches('/');
    if matches!(raw, "" | "~" | ":") || raw.eq_ignore_ascii_case("C:") {
        return Ok(Vec::new());
    }
    // All accepted forms are aliases inside this inbox. The actual sandbox path
    // is never accepted or disclosed to the peer.
    let raw = raw.strip_prefix("C:/").or_else(|| raw.strip_prefix("c:/"))
        .or_else(|| raw.strip_prefix(":/")).or_else(|| raw.strip_prefix("~/"))
        .or_else(|| raw.strip_prefix('/')).unwrap_or(raw);
    let mut parts = relative_parts(raw)?;
    if parts.first().is_some_and(|part| part.eq_ignore_ascii_case("UUHarmony")) {
        parts.remove(0);
    }
    Ok(parts)
}

#[cfg(target_env = "ohos")]
fn directory(root: &InboxDirectory, parts: &[&str], create: bool) -> Result<InboxDirectory, u64> {
    use std::os::fd::{AsRawFd, FromRawFd};
    let mut current = root.file.try_clone().map_err(|e| io_error(&e))?;
    for part in parts {
        let leaf = std::ffi::CString::new(*part).map_err(|_| FT_PERMISSION)?;
        if create && unsafe { libc::mkdirat(current.as_raw_fd(), leaf.as_ptr(), 0o700) } < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != ErrorKind::AlreadyExists { return Err(io_error(&error)); }
        }
        let fd = unsafe { libc::openat(current.as_raw_fd(), leaf.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC) };
        if fd < 0 { return Err(io_error(&io::Error::last_os_error())); }
        current = unsafe { File::from_raw_fd(fd) };
    }
    Ok(InboxDirectory::from_file(current))
}

#[cfg(not(target_env = "ohos"))]
fn directory(root: &InboxDirectory, parts: &[&str], create: bool) -> Result<InboxDirectory, u64> {
    let mut path = root.path.clone();
    for part in parts {
        path.push(part);
        if create {
            match fs::create_dir(&path) {
                Ok(()) => {}
                Err(e) if e.kind() == ErrorKind::AlreadyExists => {}
                Err(e) => return Err(io_error(&e)),
            }
        }
        if !fs::symlink_metadata(&path).map_err(|e| io_error(&e))?.is_dir() {
            return Err(FT_PERMISSION);
        }
    }
    Ok(InboxDirectory {path})
}

fn list(inbox: &Inbox, requested: &str) -> Result<Vec<Enc>, u64> {
    let normalized = requested.replace('\\', "/");
    if matches!(normalized.as_str(), "" | ":" | ":/") {
        return Ok(vec![entry(FT_DIR_DRIVE, "UUHarmony", 0, 0, VIRTUAL_ROOT)]);
    }
    let parts = virtual_parts(&normalized)?;
    let dir = directory(&inbox.root, &parts, false)?;
    let branch = if parts.is_empty() { VIRTUAL_ROOT.to_owned() } else { format!("{VIRTUAL_ROOT}/{}", parts.join("/")) };
    let mut entries = Vec::new();
    for (name, is_directory, size, modified) in dir.entries().map_err(|e| io_error(&e))? {
        entries.push(entry(if is_directory { FT_DIR } else { FT_FILE }, &name, size, modified, &format!("{branch}/{name}")));
    }
    Ok(entries)
}

fn incoming_files(fields: &[WireField]) -> Result<Vec<FileInfo>, u64> {
    let inline = get_all(fields, 3);
    if !inline.is_empty() {
        return inline.into_iter().map(|item| FileInfo::parse(item).ok_or(FT_PROTOCOL)).collect();
    }
    let Some(encoded) = get_bytes(fields, 6).filter(|data| !data.is_empty()) else { return Ok(Vec::new()) };
    let parse = |bytes| {
        let fields = decode_wire(bytes).map_err(|_| FT_PROTOCOL)?;
        get_all(&fields, 1).into_iter().map(|item| FileInfo::parse(item).ok_or(FT_PROTOCOL)).collect()
    };
    let mut decoded = Vec::new();
    if flate2::read::ZlibDecoder::new(encoded).take(MAX_FILE_LIST + 1).read_to_end(&mut decoded).is_ok() {
        if decoded.len() as u64 > MAX_FILE_LIST { return Err(FT_PROTOCOL); }
        return parse(&decoded);
    }
    // Some clients send uncompressed FileList despite list compression negotiation.
    parse(encoded)
}

fn start_upload(inbox: &mut Inbox, peer: u64, id: TaskId, fields: &[WireField]) -> Result<Vec<FileInfo>, u64> {
    let files = incoming_files(fields)?;
    if files.len() > MAX_FILES || id.task == 0 { return Err(FT_PROTOCOL); }
    let uploads = inbox.peers.entry(peer).or_default();
    if uploads.tasks.contains_key(&id.task) || uploads.tasks.len() >= MAX_TASKS {
        return Err(FT_PROTOCOL);
    }
    let selected = get_text(fields, 2).replace('\\', "/");
    let selected_parts = virtual_parts(&selected)?;
    let parent = directory(&inbox.root, &selected_parts, false)?;
    let folder = get_text(fields, 5).replace('\\', "/");
    let folder = relative_parts(&folder)?;
    let mut paths = Vec::with_capacity(files.len());
    for file in &files {
        let relative = file.rel_path.replace('\\', "/");
        let parts = relative_parts(&relative)?;
        let (name, branch) = parts.split_last().ok_or(FT_PERMISSION)?;
        let lead = if parts.starts_with(&folder) { &[][..] } else { folder.as_slice() };
        let local = [lead, branch].concat();
        directory(&parent, &local, true)?;
        let branch = selected_parts.iter().chain(&local).map(|part| (*part).to_owned()).collect();
        paths.push((branch, (*name).to_owned(), file.size));
    }
    if files.is_empty() {
        if folder.is_empty() { return Err(FT_PROTOCOL); }
        directory(&parent, &folder, true)?;
        mark_finished(uploads, id.task);
    } else {
        uploads.tasks.insert(id.task, Upload { names: paths, open: HashMap::new(), finished: HashSet::new() });
    }
    Ok(files)
}

fn mark_finished(peer: &mut PeerUploads, task: u64) {
    peer.tasks.remove(&task);
    if peer.recently_finished.len() >= MAX_TASKS { peer.recently_finished.pop_front(); }
    peer.recently_finished.push_back(task);
}

fn ask(root: &InboxDirectory, task: &mut Upload, index: u64, size: u64) -> Result<(), u64> {
    let slot = usize::try_from(index).ok().and_then(|i| i.checked_sub(1)).ok_or(FT_PROTOCOL)?;
    let (branch, leaf, expected) = task.names.get(slot).ok_or(FT_PROTOCOL)?;
    if *expected != size || task.finished.contains(&index) { return Err(FT_PROTOCOL); }
    if let std::collections::hash_map::Entry::Vacant(entry) = task.open.entry(index) {
        let parts: Vec<&str> = branch.iter().map(String::as_str).collect();
        let target = directory(root, &parts, false)?;
        entry.insert(Pending::new(target, leaf, size).map_err(|e| io_error(&e))?);
    }
    Ok(())
}

fn finish(peer: &mut PeerUploads, id: TaskId, error: u64, location: &str) -> Result<(), u64> {
    if id.index == u64::MAX {
        return if error != 0 && error != FT_SUCCEEDED {
            peer.tasks.remove(&id.task);
            Err(error)
        } else if peer.recently_finished.contains(&id.task) { Ok(()) } else { Err(FT_PROTOCOL) };
    }
    let task = peer.tasks.get_mut(&id.task).ok_or(FT_PROTOCOL)?;
    let pending = task.open.remove(&id.index).ok_or(FT_PROTOCOL)?;
    if error != 0 && error != FT_SUCCEEDED { return Err(error); }
    let slot = usize::try_from(id.index).ok().and_then(|index| index.checked_sub(1)).ok_or(FT_PROTOCOL)?;
    let (branch, _, _) = task.names.get(slot).ok_or(FT_PROTOCOL)?;
    pending.publish(location, branch)?;
    task.finished.insert(id.index);
    if task.finished.len() == task.names.len() { mark_finished(peer, id.task); }
    Ok(())
}

fn dispatch(inbox: Option<&mut Inbox>, peer: u64, case: u32, fields: &[WireField]) -> Option<(u32, Enc)> {
    let id = TaskId::parse(fields);
    let id_body = || Enc::default().msg(1, id.enc());
    let error = |result: Result<(), u64>| result.err().unwrap_or(FT_SUCCEEDED);
    let (reply, response) = match case {
        10 => {
            let requested = get_text(fields, 2);
            let mut body = id_body().text(2, &requested);
            let result = inbox.ok_or(FT_PERMISSION).and_then(|inbox| list(inbox, &requested)).and_then(|entries| {
                let plain = entries.iter().fold(Enc::default(), |list, entry| list.bytes(1, &entry.0));
                let compressed = zlib(&plain.0);
                if compressed.len() > MAX_LIST_RESPONSE { return Err(FT_IO); }
                if plain.0.len() + compressed.len() < MAX_LIST_RESPONSE {
                    for entry in entries { body = std::mem::take(&mut body).msg(3, entry); }
                }
                body = std::mem::take(&mut body).bytes(5, &compressed);
                Ok(())
            });
            (7, body.uint(4, error(result)))
        }
        11 => {
            let requested = get_text(fields, 1);
            let normalized = requested.replace('\\', "/");
            let dir = inbox.and_then(|x| directory(&x.root, &virtual_parts(&normalized).ok()?, false).ok());
            let mut body = Enc::default().text(1, &requested);
            for name in get_all(fields, 2) {
                let Ok(name) = std::str::from_utf8(name) else { continue };
                if !safe_name(name) { continue; }
                let exists = dir.as_ref().is_some_and(|d| d.exists(name));
                body = body.msg(2, Enc::default().text(1, name).boolean(2, exists));
            }
            (8, body)
        }
        1 => {
            let mut body = id_body();
            let result = inbox.ok_or(FT_PERMISSION).and_then(|inbox| start_upload(inbox, peer, id, fields));
            match result {
                Ok(files) => {
                    for file in files { body = body.msg(2, file.enc()); }
                    (1, body.uint(3, FT_SUCCEEDED))
                }
                Err(code) => (1, body.uint(3, code)),
            }
        }
        3 => {
            let result = inbox.ok_or(FT_PERMISSION).and_then(|i| {
                let task = i.peers.get_mut(&peer).and_then(|p| p.tasks.get_mut(&id.task)).ok_or(FT_PROTOCOL)?;
                ask(&i.root, task, id.index, get_uint(fields, 3))
            });
            (3, id_body().uint(3, error(result)))
        }
        4 => {
            let block = get_uint(fields, 2);
            let data = get_bytes(fields, 3).unwrap_or_default();
            let result = inbox.ok_or(FT_PERMISSION)
                .and_then(|i| i.peers.get_mut(&peer).and_then(|p| p.tasks.get_mut(&id.task)).ok_or(FT_PROTOCOL))
                .and_then(|task| {
                    let result = task.open.get_mut(&id.index).ok_or(FT_PROTOCOL).and_then(|file| file.block(block, data));
                    if result.is_err() { task.open.remove(&id.index); }
                    result
                });
            let code = error(result);
            (4, id_body().uint(2, block).uint(3, code).uint(4, if code == FT_SUCCEEDED { data.len() as u64 } else { 0 }))
        }
        9 => {
            let result = inbox.ok_or(FT_PERMISSION).and_then(|i| {
                let uploads = i.peers.get_mut(&peer).ok_or(FT_PROTOCOL)?;
                finish(uploads, id, get_uint(fields, 2), &i.location)
            });
            (6, id_body().uint(2, error(result)))
        }
        12 => {
            let result = inbox.ok_or(FT_PERMISSION).map(|i| { i.peers.remove(&peer); });
            (5, Enc::default().uint(1, error(result)))
        }
        // This platform exposes a receive-only inbox. Other desktop file operations
        // must never reach the Linux host filesystem implementation.
        2 => (2, id_body().uint(2, FT_PERMISSION)),
        8 => (6, id_body().uint(2, FT_PERMISSION)),
        5 | 6 | 7 => (5, Enc::default().uint(1, FT_PERMISSION)),
        _ => return None,
    };
    Some((reply, response))
}

#[cfg(test)]
mod tests {
    use super::*;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    struct Fixture {
        parent: PathBuf,
        root: PathBuf,
        _lock: std::sync::MutexGuard<'static, ()>,
    }

    impl Fixture {
        fn new() -> Self {
            let lock = TEST_LOCK.lock().unwrap_or_else(|error| error.into_inner());
            disable();
            let nonce = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
            let parent = std::env::temp_dir().join(format!("uu-inbox-pc-{}-{nonce}", std::process::id()));
            fs::create_dir(&parent).unwrap();
            let root = parent.join("uu-received");
            Self { parent, root, _lock: lock }
        }
        fn enable(&self) {
            set(Some(&self.root), command()).unwrap();
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            disable();
            let _ = fs::remove_dir_all(&self.parent);
        }
    }

    fn id(task: u64, index: u64) -> Enc {
        Enc::default().msg(1, TaskId { task, index }.enc())
    }

    fn call(session: &Session, request: u32, body: Enc, response: u32, error_field: u32) -> u64 {
        let (case, reply) = session.handle(request, &decode_wire(&body.0).unwrap()).unwrap();
        assert_eq!(case, response);
        get_uint(&decode_wire(&reply.0).unwrap(), error_field)
    }

    fn start(session: &Session, task: u64, dir: &str, name: &str, size: u64) -> u64 {
        let file = FileInfo { rel_path: name.to_owned(), size, modified: 0 };
        call(session, 1, id(task, 0).text(2, dir).msg(3, file.enc()), 1, 3)
    }

    fn ask_file(session: &Session, task: u64, size: u64) -> u64 {
        call(session, 3, id(task, 1).uint(3, size), 3, 3)
    }

    fn block(session: &Session, task: u64, sequence: u64, bytes: &[u8]) -> u64 {
        call(session, 4, id(task, 1).uint(2, sequence).bytes(3, bytes), 4, 3)
    }

    fn complete(session: &Session, task: u64, error: u64) -> u64 {
        call(session, 9, id(task, 1).uint(2, error), 6, 2)
    }

    #[test]
    fn advertises_virtual_destination_only_when_enabled() {
        let fixture = Fixture::new();
        let session = Session::new();
        assert_eq!(advertised_path(), "");
        assert_eq!(start(&session, 2, "C:/UUHarmony", "file.txt", 0), FT_PERMISSION);
        assert!(!fixture.root.exists());
        fixture.enable();
        assert_eq!(advertised_path(), "C:/UUHarmony");
        for requested in ["", ":/", ":\\"] {
            let fields = id(2, 0).text(2, requested);
            let (case, reply) = session.handle(10, &decode_wire(&fields.0).unwrap()).unwrap();
            assert_eq!(case, 7);
            let response = decode_wire(&reply.0).unwrap();
            assert_eq!(get_uint(&response, 4), FT_SUCCEEDED);
            let children = get_all(&response, 3);
            assert_eq!(children.len(), 1);
            let entry = decode_wire(children[0]).unwrap();
            assert_eq!(get_text(&entry, 5), VIRTUAL_ROOT);
            assert!(!String::from_utf8_lossy(&reply.0).contains(&fixture.root.to_string_lossy().to_string()));
        }
    }

    #[test]
    fn publishes_exact_bytes_after_complete_and_accepts_empty_file() {
        let fixture = Fixture::new();
        fixture.enable();
        let peer = Session::new();
        let compressed = list_data(&[FileInfo { rel_path: "中文.txt".into(), size: 6, modified: 0 }]);
        assert_eq!(call(&peer, 1, id(8, 0).text(2, "C:\\UUHarmony").bytes(6, &compressed), 1, 3), FT_SUCCEEDED);
        assert_eq!(ask_file(&peer, 8, 6), FT_SUCCEEDED);
        assert_eq!(block(&peer, 8, 0, b"abc"), FT_SUCCEEDED);
        assert_eq!(block(&peer, 8, 1, b"def"), FT_SUCCEEDED);
        assert!(!fixture.root.join("中文.txt").exists());
        assert_eq!(complete(&peer, 8, FT_SUCCEEDED), FT_SUCCEEDED);
        assert_eq!(fs::read(fixture.root.join("中文.txt")).unwrap(), b"abcdef");
        assert_eq!(call(&peer, 9, id(8, u64::MAX).uint(2, FT_SUCCEEDED), 6, 2), FT_SUCCEEDED);
        assert_eq!(start(&peer, 9, "C:/UUHarmony", "empty.txt", 0), FT_SUCCEEDED);
        assert_eq!(ask_file(&peer, 9, 0), FT_SUCCEEDED);
        assert_eq!(complete(&peer, 9, FT_SUCCEEDED), FT_SUCCEEDED);
        assert_eq!(fs::read(fixture.root.join("empty.txt")).unwrap(), b"");
        assert_eq!(fs::read_dir(&fixture.root).unwrap().count(), 2);
    }

    #[test]
    fn collision_creates_new_file_and_preserves_existing() {
        let fixture = Fixture::new();
        fixture.enable();
        fs::write(fixture.root.join("same.bin"), b"keep").unwrap();
        let first = Session::new();
        let second = Session::new();
        for peer in [&first, &second] {
            assert_eq!(start(peer, 3, "C:/", "same.bin", 3), FT_SUCCEEDED);
            assert_eq!(ask_file(peer, 3, 3), FT_SUCCEEDED);
            assert_eq!(block(peer, 3, 1, b"new"), FT_SUCCEEDED);
        }
        for peer in [&first, &second] { assert_eq!(complete(peer, 3, FT_SUCCEEDED), FT_SUCCEEDED); }
        assert_eq!(fs::read(fixture.root.join("same.bin")).unwrap(), b"keep");
        assert_eq!(fs::read(fixture.root.join("same (1).bin")).unwrap(), b"new");
        assert_eq!(fs::read(fixture.root.join("same (2).bin")).unwrap(), b"new");
    }

    #[test]
    fn traversal_and_unverifiable_destinations_are_rejected() {
        let fixture = Fixture::new();
        fixture.enable();
        let peer = Session::new();
        for unsafe_name in ["../outside", "..\\outside", "/outside", "C:\\outside", ".uu-partial-file", "foo/./outside"] {
            assert_eq!(start(&peer, 4, VIRTUAL_ROOT, unsafe_name, 1), FT_PERMISSION);
        }
        assert_eq!(start(&peer, 4, "D:/", "other.txt", 1), FT_PERMISSION);
        assert_eq!(start(&peer, 4, "C:/UUHarmony/../", "other.txt", 1), FT_PERMISSION);
        fs::write(fixture.root.join("existing.txt"), b"guard").unwrap();
        assert_ne!(start(&peer, 4, VIRTUAL_ROOT, "existing.txt/child.txt", 1), FT_SUCCEEDED);
        assert_eq!(call(&peer, 7, Enc::default().text(1, "existing.txt"), 5, 1), FT_PERMISSION);
        assert_eq!(fs::read(fixture.root.join("existing.txt")).unwrap(), b"guard");
        assert!(!fixture.parent.join("outside").exists());
    }

    #[test]
    fn rejects_last_ack_for_missing_or_incomplete_file() {
        let fixture = Fixture::new();
        fixture.enable();
        let peer = Session::new();
        assert_eq!(complete(&peer, 4, FT_SUCCEEDED), FT_PROTOCOL);
        assert_eq!(start(&peer, 4, "./", "size.txt", 2), FT_PERMISSION);
        assert_eq!(start(&peer, 4, VIRTUAL_ROOT, "size.txt", 2), FT_SUCCEEDED);
        assert_eq!(ask_file(&peer, 4, 1), FT_PROTOCOL);
        assert_eq!(ask_file(&peer, 4, 2), FT_SUCCEEDED);
        assert_eq!(block(&peer, 4, 1, b"a"), FT_SUCCEEDED);
        assert_eq!(complete(&peer, 4, FT_SUCCEEDED), FT_IO);
        assert!(!fixture.root.join("size.txt").exists());
        assert_eq!(fs::read_dir(&fixture.root).unwrap().count(), 0);
        assert_eq!(ask_file(&peer, 4, 2), FT_SUCCEEDED);
        assert_eq!(block(&peer, 4, 3, b"ab"), FT_PROTOCOL);
        assert_eq!(complete(&peer, 4, FT_SUCCEEDED), FT_PROTOCOL);
    }

    #[test]
    fn stop_discards_pending_file_and_rejects_old_block_after_reenable() {
        let fixture = Fixture::new();
        fixture.enable();
        let peer = Session::new();
        assert_eq!(start(&peer, 4, VIRTUAL_ROOT, "pending.txt", 2), FT_SUCCEEDED);
        assert_eq!(ask_file(&peer, 4, 2), FT_SUCCEEDED);
        assert_eq!(block(&peer, 4, 0, b"a"), FT_SUCCEEDED);
        let stale = command();
        disable();
        assert!(!enabled());
        assert!(set(Some(&fixture.root), stale).is_err());
        assert_eq!(block(&peer, 4, 1, b"b"), FT_PERMISSION);
        assert_eq!(fs::read_dir(&fixture.root).unwrap().count(), 0);
        fixture.enable();
        assert_eq!(complete(&peer, 4, FT_SUCCEEDED), FT_PROTOCOL);
        assert_eq!(block(&peer, 4, 1, b"b"), FT_PROTOCOL);
    }

    #[test]
    fn restart_ignores_old_temporaries_and_folders_receive_nested_files() {
        let fixture = Fixture::new();
        fixture.enable();
        let peer = Session::new();
        fs::write(fixture.root.join(".uu-partial-old-1"), b"partial").unwrap();
        let names = id(4, 0).text(2, VIRTUAL_ROOT);
        let (_, response) = peer.handle(10, &decode_wire(&names.0).unwrap()).unwrap();
        let listing = decode_wire(&response.0).unwrap();
        assert!(get_all(&listing, 3).is_empty());
        let file = FileInfo { rel_path: "nested\\child.txt".into(), size: 1, modified: 0 };
        assert_eq!(call(&peer, 1, id(4, 0).text(2, VIRTUAL_ROOT).text(5, "folder").msg(3, file.enc()), 1, 3), FT_SUCCEEDED);
        assert_eq!(ask_file(&peer, 4, 1), FT_SUCCEEDED);
        assert_eq!(block(&peer, 4, 0, b"b"), FT_SUCCEEDED);
        assert_eq!(complete(&peer, 4, FT_SUCCEEDED), FT_SUCCEEDED);
        assert_eq!(fs::read(fixture.root.join("folder/nested/child.txt")).unwrap(), b"b");
    }
}
