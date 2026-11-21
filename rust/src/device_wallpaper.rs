//! Private publication URLs from the signed-in own-device list only.
//! NOS download-domain evidence and restrictive policy: docs/DEVICE-WALLPAPER.md.
use super::*;
#[derive(Clone)]pub(crate) struct WallpaperSource{url:String,pub revision:String}
pub(crate) fn trusted(value:&str)->bool{
 if value.len()>4096||!value.is_ascii()||value.bytes().any(|b|b<=32||b==127||b==b'\\'||b==b'#'){return false}
 let Some((host,object))=value.strip_prefix("https://").and_then(|s|s.split_once('/'))else{return false};
 let label=|s:&str|!s.is_empty()&&s.len()<=63&&s.bytes().all(|b|b.is_ascii_lowercase()||b.is_ascii_digit()||b==b'-')&&!s.starts_with('-')&&!s.ends_with('-');
 // Publication origins are checked separately from provenance: this function is
 // only called for wallpaper_url in the authenticated own-device list.
 let origin=host.strip_suffix(".nosdn.127.net").is_some_and(label)
  ||host.strip_suffix(".res.netease.com").is_some_and(label)
  ||(host.strip_suffix(".fp.ps.netease.com").is_some_and(label)&&object.starts_with("file/")&&object.split('?').next().is_some_and(|p|p.len()>5))
  ||(host=="nos.netease.com"&&object.split('?').next().is_some_and(|p|p.split('/').filter(|s|!s.is_empty()).count()>=2));
 if !origin{return false}
 let path=object.split('?').next().unwrap_or("");
 !path.is_empty()&&path.split('/').all(|p|p!=".."&&p!=".")&&!path.to_ascii_lowercase().contains("%2e")
}
pub(crate) fn source(c:&Core,dev:&Value)->Option<WallpaperSource>{
 let url=dev["wallpaper_url"].as_str().filter(|s|trusted(s))?;
 let mut mac=Hmac::<Sha256>::new_from_slice(c.id.client_id.as_bytes()).ok()?;
 mac.update(b"UUHarmony/wallpaper/v1\0");mac.update(url.as_bytes());
 Some(WallpaperSource{url:url.to_owned(),revision:hex::encode(mac.finalize().into_bytes())})
}
pub(crate) fn metadata_state(c:&Core,dev:&Value)->&'static str{if dev["wallpaper_url"].as_str().is_none_or(|s|s.is_empty()){return "none"}if source(c,dev).is_some(){"available"}else{"source_blocked"}}
pub(crate) fn collect(c:&Core,devices:&[Value])->BTreeMap<String,WallpaperSource>{
 let mut result=BTreeMap::new();let mut seen=std::collections::BTreeSet::new();let mut conflict=std::collections::BTreeSet::new();
 for dev in devices{let Some(key)=crate::devices::key(c,dev)else{continue};let value=source(c,dev);if !seen.insert(key.clone()){
  if result.get(&key).map(|s:&WallpaperSource|s.revision.as_str())!=value.as_ref().map(|s|s.revision.as_str()){conflict.insert(key.clone());}
 }else if let Some(value)=value{result.insert(key,value);}}
 for key in conflict{result.remove(&key);}result
}
impl Core{
 pub(crate) fn wallpaper_account_key(&self)->String{
  if !self.logged()||self.account.user_id.is_empty(){return String::new()}
  let Ok(mut mac)=Hmac::<Sha256>::new_from_slice(self.id.client_id.as_bytes())else{return String::new()};
  mac.update(b"UUHarmony/wallpaper/account/v1\0");mac.update(self.account.user_id.as_bytes());hex::encode(mac.finalize().into_bytes())
 }
 pub(crate) fn resolve_wallpaper(&self,v:&Value)->Value{
  if !self.logged()||self.suspended{return json!({"error":"wallpaper_foreground_account_required"})}
  let Some(key)=v["deviceKey"].as_str()else{return json!({"error":"wallpaper_identity_required"})};
  let Some(source)=self.wallpapers.get(key).filter(|s|v["revision"]==s.revision&&self.devices.iter().any(|r|r["key"]==key&&r["wallpaperRevision"]==s.revision))else{return json!({"error":"wallpaper_source_changed"})};
  // A dedicated explicit resolver only. The normal auth view never contains URLs.
  json!({"url":source.url,"revision":source.revision})
 }
}
#[cfg(test)]mod tests{
 use super::*;
 #[test]fn wallpaper_disk_namespace_is_account_and_install_scoped_without_identity_leak(){
  let mut c=Core::default();c.id.client_id="synthetic-install".into();c.account.token="synthetic-token".into();c.account.user_id="synthetic-private-user-a".into();
  let first=c.wallpaper_account_key();assert_eq!(first.len(),64);assert_eq!(first,c.wallpaper_account_key());assert!(!first.contains("synthetic"));
  c.account.user_id="synthetic-private-user-b".into();assert_ne!(first,c.wallpaper_account_key());c.account.user_id="synthetic-private-user-a".into();c.id.client_id="other-install".into();assert_ne!(first,c.wallpaper_account_key());
  c.account=Account::default();assert!(c.wallpaper_account_key().is_empty());
 }
 #[test]fn wallpaper_only_documented_download_origin_is_accepted(){
  for u in ["https://synthetic.nosdn.127.net/object.png?signature=private","https://synthetic.res.netease.com/asset/image.png","https://synthetic.fp.ps.netease.com/file/object-id","https://nos.netease.com/bucket/image.jpg"]{assert!(trusted(u))}
  for u in ["http://synthetic.nosdn.127.net/a","https://fp.ps.netease.com/file/a","https://127.0.0.1/a","https://a.nosdn.127.net.evil/a","https://a.b.nosdn.127.net/a","https://a.nosdn.127.net:443/a","https://user@a.nosdn.127.net/a","https://a.nosdn.127.net/../a","https://a.nosdn.127.net/%2e%2e/a","https://a.nosdn.127.net/a#secret","https://a.nosdn.127.net/"]{assert!(!trusted(u),"{u}")}
 }
 #[test]fn wallpaper_private_projection_correlation_removal_and_logout(){
  let mut c=Core::default();c.id.client_id="synthetic-install".into();c.account.token="synthetic-account".into();
  let row=json!({"device_id":"private-device","name":"Synthetic","platform":1,"status":"CONNECTED","wallpaper_url":"https://synthetic.nosdn.127.net/object.png?secret=not-for-view"});
  c.pending=Some((1,"devices".into()));c.response(json!({"id":1,"httpStatus":200,"body":json!({"code":0,"data":{"my_binded_devices":[row.clone()]}}).to_string()}));
  let view=c.view().to_string();assert!(!view.contains("not-for-view"));assert!(!view.contains("nosdn"));assert!(!view.contains("private-device"));
  let key=c.devices[0]["key"].clone();let revision=c.devices[0]["wallpaperRevision"].clone();
  assert!(c.resolve_wallpaper(&json!({"deviceKey":key,"revision":revision}))["url"].is_string());
  assert!(c.resolve_wallpaper(&json!({"deviceKey":key,"revision":"old"}))["error"].is_string());
  c.suspended=true;assert!(c.resolve_wallpaper(&json!({"deviceKey":key,"revision":revision}))["error"].is_string());c.suspended=false;
  let mut other=row.clone();other["wallpaper_url"]=json!("https://synthetic.nosdn.127.net/other.png");assert!(collect(&c,&[row,other]).is_empty());
  c.call(json!({"op":"logout"}));assert!(c.wallpapers.is_empty());assert!(c.resolve_wallpaper(&json!({"deviceKey":key,"revision":revision}))["error"].is_string());
 }
}
