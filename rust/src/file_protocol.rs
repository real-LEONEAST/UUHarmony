//! Minimal UU FTP wire shapes adapted from uu-remote-linux 6bf05a (GPL-3.0-only).
//! No filesystem or transport dependency; no paths or contents are logged.
use crate::protocol::{decode_wire, WireValue};
use crate::wire;
use std::io::{Read, Write};
pub const CONTROL:usize=0;
pub const TEXT:usize=1;
pub const FILE:usize=3;
pub const CHUNK:usize=32*1024;
// Keep space for the RPC envelope within the 256 KiB packet limit. The local
// writer continues to consume at most CHUNK bytes per request.
pub const MAX_BLOCK:usize=255*1024;
pub const JS_MAX:u64=9_007_199_254_740_991;
pub fn uint(b:&[u8],n:u32)->u64 {decode_wire(b).ok().and_then(|f|f.into_iter().find_map(|f|match(f.number,f.value){(k,WireValue::Varint(v)) if k==n=>Some(v),_=>None})).unwrap_or(0)}
pub fn blob(b:&[u8],n:u32)->Option<&[u8]>{decode_wire(b).ok()?.into_iter().find_map(|f|match(f.number,f.value){(k,WireValue::Bytes(v)) if k==n=>Some(v),_=>None})}
pub fn text(b:&[u8],n:u32)->Result<String,String>{String::from_utf8(blob(b,n).unwrap_or_default().to_vec()).map_err(|_|"invalid_utf8".into())}
pub fn all(b:&[u8],n:u32)->Result<Vec<&[u8]>,String>{Ok(decode_wire(b).map_err(|_|"invalid_protobuf")?.into_iter().filter_map(|f|match(f.number,f.value){(k,WireValue::Bytes(v))if k==n=>Some(v),_=>None}).collect())}
pub fn nested(n:u32,b:&[u8])->Vec<u8>{let mut o=vec![];wire::bytes(n,b,&mut o);o}
pub fn id(task:u64,index:u64)->Vec<u8>{let mut o=vec![];wire::int(1,task,&mut o);wire::int(2,index,&mut o);nested(1,&o)}
pub fn rpc(rid:u64,response:bool,case:u32,body:&[u8])->Vec<u8>{let mut h=vec![];wire::int(1,rid,&mut h);let mut o=nested(1,&h);wire::bytes(if response{4}else{8},&nested(case,body),&mut o);wire::envelope(rid,if response{22}else{21},&o)}
pub fn compressed(b:&[u8])->Result<Vec<u8>,String>{let mut z=flate2::write::ZlibEncoder::new(Vec::new(),flate2::Compression::default());z.write_all(b).map_err(|_|"compression_failed")?;z.finish().map_err(|_|"compression_failed".into())}
pub fn expanded(b:&[u8])->Result<Vec<u8>,String>{let mut o=vec![];flate2::read::ZlibDecoder::new(b).take(1024*1024+1).read_to_end(&mut o).map_err(|_|"invalid_directory_compression")?;if o.len()>1024*1024{return Err("directory_expansion_limit".into())}Ok(o)}
pub fn name(s:&str)->Result<(),String>{
 if s.is_empty()||s.len()>255||s=="."||s==".."||s.ends_with(['.',' '])||s.chars().any(|c|c<' '||"/\\:*?\"<>|".contains(c)){return Err("unsafe_remote_name".into())}
 let base=s.split('.').next().unwrap_or("").to_ascii_uppercase();
 if ["CON","PRN","AUX","NUL","CLOCK$"].contains(&base.as_str())||((base.starts_with("COM")||base.starts_with("LPT"))&&base.len()==4&&matches!(base.as_bytes()[3],b'1'..=b'9')){return Err("reserved_remote_name".into())}Ok(())
}
/// Read paths permit drive roots/home, but never traversal, ADS, device or UNC paths.
pub fn path(s:&str)->Result<(),String>{
 if s.is_empty()||s.len()>4096||s.chars().any(|c|c<' '||"*?\"<>|".contains(c)){return Err("unsafe_remote_path".into())}
 let p=s.replace('\\',"/");if p.starts_with("//"){return Err("unsafe_remote_path".into())}
 for (i,c) in p.chars().enumerate(){if c==':'&&!(i==1&&p.as_bytes()[0].is_ascii_alphabetic()){return Err("remote_ads_rejected".into())}}
 if p.contains(':')&&p.as_bytes().get(2)!=Some(&b'/'){return Err("drive_relative_rejected".into())}
 for part in p.split('/').filter(|s|!s.is_empty()){if part==".."||part=="."{return Err("remote_traversal_rejected".into())}}
 Ok(())
}
pub fn join(dir:&str,n:&str)->Result<String,String>{path(dir)?;name(n)?;for (i,part) in dir.replace('\\',"/").split('/').filter(|s|!s.is_empty()).enumerate(){if !(i==0&&(part=="~"||(part.len()==2&&part.ends_with(':')))){name(part)?;}}let sep=if dir.contains('\\'){'\\'}else{'/'};Ok(format!("{}{}{}",dir,if dir.ends_with(['/','\\']){String::new()}else{sep.to_string()},n))}
pub fn same_path(a:&str,b:&str)->bool{let norm=|s:&str|s.replace('\\',"/").trim_end_matches('/').to_string();let(a,b)=(norm(a),norm(b));if a.as_bytes().get(1)==Some(&b':')||b.as_bytes().get(1)==Some(&b':'){a.eq_ignore_ascii_case(&b)}else{a==b}}
