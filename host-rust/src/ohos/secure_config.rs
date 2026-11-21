//! Host identity and credentials use the application Asset store.
use std::path::PathBuf;
use std::sync::OnceLock;
const MAX_CONFIG: usize = 32 * 1024;
extern "C" {
    fn uu_host_config_read(data: *mut u8, capacity: usize) -> i32;
    fn uu_host_config_write(data: *const u8, length: usize) -> i32;
}
pub fn path() -> PathBuf {
    std::env::var_os("UU_CONFIG").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("host/config.json"))
}
pub fn read_fresh() -> Result<Option<serde_json::Value>, String> {
    let mut bytes = vec![0u8; MAX_CONFIG];
    let size = unsafe { uu_host_config_read(bytes.as_mut_ptr(), bytes.len()) };
    if size < 0 { return Err("安全存储暂不可用，请解锁电脑后重试".into()); }
    if size == 0 { return Ok(None); }
    if size as usize > bytes.len() { return Err("配置长度异常".into()); }
    serde_json::from_slice(&bytes[..size as usize]).map(Some).map_err(|_| "登录信息格式异常".into())
}
pub fn file() -> Result<Option<&'static serde_json::Value>, String> {
    static CONFIG: OnceLock<Result<Option<serde_json::Value>, String>> = OnceLock::new();
    CONFIG.get_or_init(read_fresh).as_ref().map(|v| v.as_ref()).map_err(Clone::clone)
}
pub fn write(value: &serde_json::Value) -> Result<PathBuf, String> {
    if !value.is_object() { return Err("配置格式异常".into()); }
    let bytes = serde_json::to_vec(value).map_err(|_| "配置格式异常")?;
    if bytes.len() > MAX_CONFIG { return Err("登录信息过长".into()); }
    if unsafe { uu_host_config_write(bytes.as_ptr(), bytes.len()) } != 0 { return Err("无法保存登录信息，请解锁电脑后重试".into()); }
    Ok(path())
}
pub fn ffmpeg_root() -> Option<PathBuf> { None }
#[cfg(test)]
pub(crate) fn test_env_lock() -> &'static std::sync::Mutex<()> {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(()); &LOCK
}
