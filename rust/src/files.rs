//! Offline-testable file transfer state machine; never opens local paths.
//! Protocol adapted from uu-remote-linux 6bf05a (GPL-3.0-only).
use crate::{file_protocol::*,wire};
use base64::{Engine,engine::general_purpose::STANDARD};
use serde_json::{json,Value};
use std::{collections::BTreeMap,sync::atomic::{AtomicU64,Ordering}};
static NEXT:AtomicU64=AtomicU64::new(10_000_000);
fn next()->u64{NEXT.fetch_add(1,Ordering::Relaxed)}
#[derive(Debug)]pub struct Outbound{pub channel:usize,pub request_id:u64,pub data:Vec<u8>}
#[derive(Clone,Debug)]struct Pending{rid:u64,expected:u32,stage:&'static str,deadline:u64,sent:bool}
#[derive(Debug)]struct Block{rid:u64,data:Vec<u8>,used:usize}
#[derive(Debug)]pub struct FileState{
 generation:u64,task:u64,state:&'static str,mode:&'static str,error:Option<String>,
 download_path:String,directory:String,target:String,name:String,total:u64,done:u64,modified:u64,
 entries:Vec<Value>,listed:String,pending:Option<Pending>,last_at:u64,
 sent_count:u64,ack_count:u64,remote_done:bool,local_saved:bool,
 block:u64,upload_len:u64,blocks:BTreeMap<u64,Block>,next_block:Option<u64>,
 opened:bool,file_end:Option<u64>,file_ended:bool,task_end:bool,token:u64,
 download_index:u64,early_start:Option<Vec<u8>>,base_deadline:Option<u64>,
 cleanup:Option<(u64,u64)>,cleanup_request:Option<u64>,requires_reconnect:bool,
}
pub type Files=FileState;
impl Default for FileState{fn default()->Self{Self{
 generation:next(),task:0,state:"idle",mode:"",error:None,download_path:String::new(),directory:String::new(),target:String::new(),name:String::new(),total:0,done:0,modified:0,
 entries:vec![],listed:String::new(),pending:None,last_at:0,sent_count:0,ack_count:0,remote_done:false,local_saved:false,
 block:0,upload_len:0,blocks:BTreeMap::new(),next_block:None,opened:false,file_end:None,file_ended:false,task_end:false,token:next(),cleanup:None,cleanup_request:None,requires_reconnect:false,
 download_index:1,early_start:None,base_deadline:None,
}}}
fn s<'a>(v:&'a Value,k:&str)->Result<&'a str,String>{v[k].as_str().ok_or_else(||format!("missing_{k}"))}
fn n(v:&Value,k:&str)->Result<u64,String>{v[k].as_u64().filter(|n|*n<=JS_MAX).ok_or_else(||format!("invalid_{k}"))}
fn code(b:&[u8],field:u32)->Result<(),String>{if uint(b,field)==1{Ok(())}else{Err(format!("remote_file_error_{}",uint(b,field)))}}
impl FileState{
 pub fn observe_metadata(&mut self,data:&[u8]){if let Some(body)=blob(data,26){if let Ok(reported)=text(body,1){if path(&reported).is_ok(){self.download_path=reported;}}}}
 fn busy(&self)->bool{!matches!(self.state,"idle"|"complete"|"failed"|"canceled"|"disconnected")}
 fn request(&mut self,case:u32,body:Vec<u8>,expected:u32,stage:&'static str,now:u64)->Vec<Outbound>{let rid=next();self.pending=Some(Pending{rid,expected,stage,deadline:now.saturating_add(2000),sent:false});self.state=stage;vec![Outbound{channel:CONTROL,request_id:rid,data:rpc(rid,false,case,&body)}]}
 fn reply(&self,rid:u64,case:u32,body:Vec<u8>)->Outbound{Outbound{channel:CONTROL,request_id:rid,data:rpc(rid,true,case,&body)}}
 fn identity(&self,v:&Value)->Result<(),String>{if n(v,"task")?!=self.task||n(v,"generation")?!=self.generation{return Err("stale_file_generation".into())}Ok(())}
 fn start(&mut self,mode:&'static str,now:u64){self.generation=next();self.task=next();self.state="preparing";self.mode=mode;self.error=None;self.pending=None;self.total=0;self.done=0;self.block=0;self.upload_len=0;self.blocks.clear();self.next_block=None;self.opened=false;self.file_end=None;self.file_ended=false;self.task_end=false;self.remote_done=false;self.local_saved=false;self.token=next();self.last_at=now;self.sent_count=0;self.ack_count=0;self.download_index=1;self.early_start=None;self.base_deadline=None;}
 fn directory_request(&mut self,path:&str,stage:&'static str,now:u64)->Vec<Outbound>{let mut b=id(self.task,0);let remote=if path.is_empty(){":/"}else{path};wire::bytes(2,remote.as_bytes(),&mut b);self.request(10,b,7,stage,now)}
 fn fail(&mut self,e:&str,now:u64)->Vec<Outbound>{self.error=Some(e.into());let out=self.abort(now);self.state="failed";out}
 fn abort(&mut self,now:u64)->Vec<Outbound>{
  let mut out=vec![];let active=self.busy();self.pending=None;
  if active&&(self.mode=="upload"||self.mode=="download"){
   let index=if self.mode=="download"{self.download_index}else{1};
   for (&block,b) in &self.blocks{let mut r=id(self.task,index);wire::int(2,block,&mut r);wire::int(3,7,&mut r);out.push(self.reply(b.rid,4,r));}
   if let Some(rid)=self.file_end{let mut r=id(self.task,index);wire::int(2,7,&mut r);out.push(self.reply(rid,6,r));}
   let mut b=id(self.task,index);wire::int(2,7,&mut b);let rid=next();out.push(Outbound{channel:CONTROL,request_id:rid,data:rpc(rid,false,9,&b)});
   self.cleanup=Some((self.task,now.saturating_add(3000)));self.cleanup_request=Some(rid);
  }
  self.blocks.clear();self.early_start=None;self.base_deadline=None;self.file_end=None;self.token=next();self.generation=next();out
 }
 /// All starts require explicit foreground and UI confirmation. Local URIs are never accepted.
 pub fn prepare(&mut self,v:&Value,now:u64)->Result<Vec<Outbound>,String>{
  let op=s(v,"op")?;
  if op=="cancel"{if let Some(g)=v["generation"].as_u64(){if g!=self.generation{return Err("stale_file_generation".into())}}let out=self.abort(now);self.state="canceled";return Ok(out)}
  if matches!(op,"list"|"download"|"upload"){
   if self.requires_reconnect||self.cleanup.is_some(){return Err("file_session_requires_reconnect".into())}
   if self.busy(){return Err("file_operation_busy".into())}
   if v["foreground"]!=true||v["confirmed"]!=true{return Err("foreground_confirmation_required".into())}
   if v.get("localPath").is_some()||v.get("uri").is_some(){return Err("local_path_not_allowed".into())}
   if let Some(g)=v["generation"].as_u64(){if g!=self.generation{return Err("stale_file_generation".into())}}
   match op{
    "list"=>{let p=s(v,"path")?;if !p.is_empty(){path(p)?;}self.start("list",now);self.directory=p.into();return Ok(self.directory_request(p,"listing",now))},
    "download"=>{let p=s(v,"path")?;path(p)?;let entry=self.entries.iter().find(|e|matches!(e["kind"].as_u64(),Some(4|5))&&e["path"]==p).ok_or("download_requires_listed_file")?;let size=n(entry,"size")?;let filename=s(entry,"name")?.to_string();self.start("download",now);self.total=size;self.name=filename;self.target=p.into();let mut b=id(self.task,0);wire::bytes(2,p.as_bytes(),&mut b);return Ok(self.request(2,b,2,"download_accept",now))},
    "upload"=>{let dir=s(v,"directory")?;let filename=s(v,"name")?;let target=join(dir,filename)?;if !same_path(dir,&self.listed){return Err("upload_requires_listed_directory".into())}let size=n(v,"size")?;let modified=n(v,"modified")?;self.start("upload",now);self.directory=dir.into();self.target=target;self.name=filename.into();self.total=size;self.modified=modified;return Ok(self.directory_request(dir,"upload_preflight",now))},_=>unreachable!()
   }
  }
  self.identity(v)?;self.last_at=now;
  match op{
   "upload_chunk"=>{
    if self.mode!="upload"||self.state!="upload_ready"||self.pending.is_some(){return Err("upload_not_ready".into())}
    if n(v,"offset")?!=self.done{return Err("upload_offset_mismatch".into())}
    let b64=s(v,"base64")?;if b64.len()>((CHUNK+2)/3)*4{return Err("upload_chunk_limit".into())}
    let bytes=STANDARD.decode(b64).map_err(|_|"invalid_base64")?;if bytes.is_empty()||bytes.len()>CHUNK||self.done+bytes.len() as u64>self.total{return Err("invalid_upload_size".into())}
    self.upload_len=bytes.len() as u64;let mut b=id(self.task,1);wire::int(2,self.block,&mut b);wire::bytes(3,&bytes,&mut b);Ok(self.request(4,b,4,"upload_block",now))
   },
   "download_written"=>{
    if self.mode!="download"||self.blocks.is_empty(){return Err("download_not_ready".into())}
    if n(v,"token")?!=self.token{return Err("stale_download_chunk".into())}
    let key=self.next_block.ok_or("download_order_unknown")?;
    let b=self.blocks.get_mut(&key).ok_or("download_gap")?;let length=(b.data.len()-b.used).min(CHUNK);if n(v,"bytes")?!=length as u64{return Err("download_write_size_mismatch".into())}
    b.used+=length;self.done+=length as u64;self.token=next();let mut out=vec![];
    if b.used==b.data.len(){let b=self.blocks.remove(&key).unwrap();let mut r=id(self.task,self.download_index);wire::int(2,key,&mut r);wire::int(3,1,&mut r);wire::int(4,b.data.len() as u64,&mut r);out.push(self.reply(b.rid,4,r));self.next_block=key.checked_add(1);}
    out.extend(self.finish_download(now)?);Ok(out)
   },
   "download_saved"=>{if self.state!="download_save_ready"||!self.remote_done||self.done!=self.total{return Err("download_not_complete".into())}self.local_saved=true;self.state="complete";Ok(vec![])},
   _=>Err("unknown_file_operation".into())
  }
 }
 /// Caller reports each actual DC send result; preparing a packet is not a successful send.
 pub fn sent(&mut self,rid:u64,ok:bool,now:u64){if ok{self.sent_count+=1;}
  if let Some(p)=self.pending.as_mut(){if p.rid==rid{if ok{p.sent=true;p.deadline=now.saturating_add(30_000);}else{self.error=Some("file_send_failed".into());self.state="failed";self.requires_reconnect=true;self.pending=None;self.blocks.clear();self.generation=next();}}}
  if !ok{self.error=Some("file_send_failed".into());self.state="failed";self.requires_reconnect=true;self.blocks.clear();self.pending=None;self.generation=next();}
 }
 fn parse_entries(&self,b:&[u8])->Result<Vec<Value>,String>{
  code(b,4)?;let expanded=blob(b,5).map(expanded).transpose()?;let rows=if let Some(ref e)=expanded{all(e,1)?}else{all(b,3)?};if rows.len()>2048{return Err("directory_entry_limit".into())}
  rows.into_iter().map(|r|{let kind=uint(r,1);let nm=text(r,2)?;let p=text(r,5)?;path(&p)?;
   // Windows virtual-root folders have localized display labels (e.g. Desktop),
   // distinct from their real absolute path. Labels never become upload names.
   let root_alias=self.directory.is_empty()&&[0,2].contains(&kind);
   if kind!=3{if root_alias{if nm.is_empty()||nm.len()>512||nm.chars().any(|c|c<' '){return Err("invalid_root_label".into())}}else{name(&nm)?;}if ![2,5].contains(&kind)&&!root_alias{let base=p.trim_end_matches(['/','\\']).rsplit(['/','\\']).next().unwrap_or("");if base!=nm{return Err("directory_entry_path_mismatch".into())}if !self.directory.is_empty()&&self.directory!="~/"&&self.directory!="~\\"&&!same_path(&join(&self.directory,&nm)?,&p){return Err("directory_entry_outside_parent".into())}}}
   else {let root=p.replace('\\',"/");if root!="/"&&!(root.len()==3&&root.as_bytes()[0].is_ascii_alphabetic()&&root.ends_with(":/")){return Err("invalid_drive_entry".into())}}
   let size=uint(r,3);let modified=uint(r,4);if size>JS_MAX||modified>JS_MAX{return Err("file_size_outside_js_safe_range".into())}if ![0,2,3,4,5].contains(&kind){return Err("unsupported_file_entry".into())}
   Ok(json!({"kind":kind,"name":nm,"size":size,"modified":modified,"path":p}))
  }).collect()
 }
 fn upload_begin(&mut self,now:u64)->Result<Vec<Outbound>,String>{
  if self.entries.iter().any(|e|e["name"].as_str().is_some_and(|n|n.eq_ignore_ascii_case(&self.name))){return Err("remote_name_exists_no_overwrite".into())}
  let mut info=nested(1,self.name.as_bytes());wire::int(2,self.total,&mut info);wire::int(3,self.modified,&mut info);
  let mut b=id(self.task,0);wire::bytes(2,self.directory.as_bytes(),&mut b);wire::bytes(3,&info,&mut b);
  // FOS_SKIP=3. Never request overwrite(1), duplicate(2), resume(4), folder creation or deletion.
  wire::int(4,3,&mut b);wire::bytes(6,&compressed(&nested(1,&info))?,&mut b);wire::bytes(7,format!("harmony-{}-{}",self.generation,self.task).as_bytes(),&mut b);
  Ok(self.request(1,b,1,"upload_accept",now))
 }
 fn upload_end(&mut self,now:u64)->Vec<Outbound>{let mut b=id(self.task,1);wire::int(2,1,&mut b);self.request(9,b,6,"upload_finish",now)}
 fn response(&mut self,data:&[u8],now:u64)->Result<Vec<Outbound>,String>{
  let Some(r)=blob(data,22)else{return Ok(vec![])};let rid=blob(r,1).map(|h|uint(h,1)).unwrap_or(0);
  if self.cleanup_request==Some(rid){if let Some((task,_))=self.cleanup{if let Some(result)=blob(r,4).and_then(|f|blob(f,6)){let matches=blob(result,1).is_some_and(|id|uint(id,1)==task);if matches&&[1,7].contains(&uint(result,2)){self.cleanup=None;self.cleanup_request=None;return Ok(vec![])}}}}
  let Some(p)=self.pending.clone().filter(|p|p.rid==rid)else{return Ok(vec![])};
  let b=blob(r,4).and_then(|f|blob(f,p.expected)).ok_or("unexpected_file_response")?;
  // List response task-id is not consistently present on official hosts; request-id remains mandatory.
  if p.expected!=7{let tid=blob(b,1).ok_or("missing_file_task")?;if uint(tid,1)!=self.task{return Err("file_response_task_mismatch".into())}if matches!(p.stage,"upload_start"|"upload_block"|"upload_finish")&&uint(tid,2)!=1{return Err("file_response_index_mismatch".into())}}
  self.pending=None;self.ack_count+=1;self.last_at=now;
  if matches!(p.stage,"listing"|"upload_preflight")&&blob(b,2).is_some(){let mut reported=text(b,2)?;if p.stage=="listing"&&reported==":/"{reported.clear();}if !reported.is_empty(){path(&reported)?;}if p.stage=="upload_preflight"&&!same_path(&reported,&self.directory){return Err("upload_directory_changed".into())}self.directory=reported;}
  match p.stage{
   "listing"=>{self.entries=self.parse_entries(b)?;self.listed=self.directory.clone();self.remote_done=true;self.state="complete";Ok(vec![])},
   "upload_preflight"=>{self.entries=self.parse_entries(b)?;self.listed=self.directory.clone();self.upload_begin(now)},
   "upload_accept"=>{code(b,3)?;let mut b=id(self.task,1);wire::int(3,self.total,&mut b);Ok(self.request(3,b,3,"upload_start",now))},
   "upload_start"=>{code(b,3)?;if uint(b,2)!=0||uint(b,4)!=0{return Err("remote_exists_or_resume_refused".into())}if self.total==0{Ok(self.upload_end(now))}else{self.state="upload_ready";Ok(vec![])}},
   "upload_block"=>{code(b,3)?;if uint(b,2)!=self.block||uint(b,4)!=self.upload_len{return Err("upload_ack_mismatch".into())}self.done+=self.upload_len;self.block+=1;self.upload_len=0;if self.done==self.total{Ok(self.upload_end(now))}else{self.state="upload_ready";Ok(vec![])}},
   "upload_finish"=>{code(b,2)?;self.remote_done=true;self.state="complete";Ok(vec![])},
   "download_accept"=>{code(b,2)?;
    let inline=all(b,3)?;
    let expanded=if inline.is_empty(){blob(b,5).filter(|bytes|!bytes.is_empty()).map(expanded).transpose()?}else{None};
    let rows=if let Some(ref e)=expanded{all(e,1)?}else{inline};
    if rows.len()!=1{return Err("single_file_required".into())}
    let f=rows[0];let nm=text(f,1)?;
    // The manifest may include a source folder or a relative path. Only the
    // previously listed basename determines the local destination.
    let leaf=nm.rsplit(['/','\\']).next().unwrap_or("");
    name(leaf)?;
    if leaf!=self.name||uint(f,2)!=self.total{return Err("download_manifest_changed".into())}
    self.state="downloading";
    match self.early_start.take(){Some(packet)=>self.host_request(&packet,now),None=>Ok(vec![])}
   },_=>Err("invalid_file_stage".into())
  }
 }
 fn finish_download(&mut self,_now:u64)->Result<Vec<Outbound>,String>{
  let mut out=vec![];
  if self.file_end.is_some(){if self.next_block.is_none(){self.next_block=self.blocks.keys().next().copied();}
   if self.blocks.is_empty(){if self.done!=self.total{return Err("incomplete_download".into())}let rid=self.file_end.take().unwrap();let mut b=id(self.task,self.download_index);wire::int(2,1,&mut b);out.push(self.reply(rid,6,b));self.file_ended=true;}
   else if self.next_block.is_some_and(|k|!self.blocks.contains_key(&k)){return Err("download_block_gap".into())}
  }
  if self.task_end&&self.file_ended&&self.blocks.is_empty(){self.remote_done=true;self.state="download_save_ready";}Ok(out)
 }
 fn host_request(&mut self,data:&[u8],now:u64)->Result<Vec<Outbound>,String>{
  let Some(r)=blob(data,21)else{return Ok(vec![])};let Some(ftp)=blob(r,8)else{return Ok(vec![])};let rid=blob(r,1).map(|h|uint(h,1)).unwrap_or(0);
  let cases=all_cases(ftp)?;if cases.len()!=1{return Err("ambiguous_file_request".into())}let(case,b)=cases[0];let tid=blob(b,1).ok_or("missing_file_task")?;let task=uint(tid,1);let index=uint(tid,2);
  if let Some((old,_))=self.cleanup{if task==old{if case==9&&index==u64::MAX{self.cleanup=None;self.cleanup_request=None;return Ok(vec![])}let mut r=nested(1,tid);if case==4{wire::int(2,uint(b,2),&mut r)}wire::int(if case==9{2}else{3},7,&mut r);return Ok(vec![self.reply(rid,if case==9{6}else{case},r)])}}
  if task!=self.task||self.mode!="download"||matches!(self.state,"failed"|"canceled"|"disconnected"|"complete"){return Ok(vec![])}
  self.last_at=now;
  if self.state=="download_accept"&&case==3&&self.early_start.is_none()&&data.len()<=4096{
   self.early_start=Some(data.to_vec());return Ok(vec![])
  }
  if self.state!="downloading"{return Err("download_request_before_manifest".into())}
  let mut reply=id(task,index);
  match case{
   3=>{if index>1||self.opened||uint(b,3)!=self.total{return Err("invalid_download_start".into())}self.download_index=index;self.opened=true;wire::int(3,1,&mut reply);Ok(vec![self.reply(rid,3,reply)])},
   4=>{let block=uint(b,2);let bytes=blob(b,3).ok_or("missing_download_bytes")?;
    if index!=self.download_index||!self.opened||self.file_end.is_some()||block>=JS_MAX||bytes.is_empty()||bytes.len()>MAX_BLOCK||self.blocks.len()>=16||self.blocks.contains_key(&block)||self.next_block.is_some_and(|k|block<k){return Err("download_window_or_block_invalid".into())}
    let queued:u64=self.blocks.values().map(|b|(b.data.len()-b.used) as u64).sum();if self.done+queued+bytes.len() as u64>self.total{return Err("download_size_overflow".into())}
    self.blocks.insert(block,Block{rid,data:bytes.to_vec(),used:0});
    if self.next_block.is_none(){
      if block==0||self.done+queued+bytes.len() as u64==self.total{
        let first=self.blocks.keys().next().copied().unwrap();
        if first>1{return Err("download_invalid_block_base".into())}
        self.next_block=Some(first);self.base_deadline=None;
      }else if block==1{self.base_deadline=Some(now.saturating_add(350));}
    }
    Ok(vec![])
   },
   9=>{code(b,2)?;if index==u64::MAX{if self.task_end{return Err("duplicate_task_end".into())}self.task_end=true;self.finish_download(now)}else{if index!=self.download_index||!self.opened||self.file_end.is_some()||self.file_ended{return Err("invalid_download_end".into())}self.file_end=Some(rid);self.finish_download(now)}},
   _=>Err("unsupported_download_request".into())
  }
 }
 /// Safe for CONTROL/FILE callbacks. Unrelated packets and stale request ids are ignored.
 pub fn on_packet(&mut self,channel:usize,data:&[u8],now:u64)->Result<Vec<Outbound>,String>{
  if ![CONTROL,TEXT,FILE].contains(&channel){return Ok(vec![])}self.observe_metadata(data);
  if blob(data,21).is_none()&&blob(data,22).is_none(){return Ok(vec![])}
  if data.len()>256*1024{return Ok(self.fail("file_packet_limit",now))}
  let r=if blob(data,22).is_some(){self.response(data,now)}else{self.host_request(data,now)};
  match r{Ok(out)=>Ok(out),Err(e)=>Ok(self.fail(&e,now))}
 }
 pub fn tick(&mut self,now:u64)->Vec<Outbound>{
  if self.next_block.is_none()&&self.base_deadline.is_some_and(|deadline|now>=deadline)&&self.blocks.contains_key(&1){
   self.next_block=Some(1);self.base_deadline=None;
  }
  if self.cleanup.is_some_and(|(_,at)|now>=at){self.cleanup=None;self.cleanup_request=None;self.requires_reconnect=true;}
  if self.pending.as_ref().is_some_and(|p|now>=p.deadline){return self.fail("file_send_or_response_timeout",now)}
  if self.busy()&&now.saturating_sub(self.last_at)>=30_000{return self.fail("file_transfer_timeout",now)}vec![]
 }
 /// Metadata only. Prepared/sent/correlated ACK/remote completion/local save are distinct.
 pub fn snapshot(&self)->Value{json!({"generation":self.generation,"task":self.task,"state":self.state,"mode":self.mode,"error":self.error,"remoteDownloadPath":self.download_path,"directory":self.listed,"name":self.name,"transferred":self.done,"total":self.total,"sentMessages":self.sent_count,"correlatedAcks":self.ack_count,"remoteComplete":self.remote_done,"localSaved":self.local_saved,"observedOnWindows":Value::Null,"needUploadChunk":self.state=="upload_ready","downloadAvailable":self.next_block.is_some_and(|k|self.blocks.contains_key(&k)),"entries":self.entries,"requiresReconnect":self.requires_reconnect,"cleanupPending":self.cleanup.is_some(),"pendingBlocks":self.blocks.len(),"chunkBytes":CHUNK})}
 pub fn poll(&self)->Value{self.snapshot()}
 /// Explicit read only; stable token until matching written confirmation (safe retries).
 pub fn read_chunk(&self)->Value{
  let Some(k)=self.next_block else{return json!({"available":false,"generation":self.generation,"task":self.task})};let Some(b)=self.blocks.get(&k)else{return json!({"available":false,"generation":self.generation,"task":self.task})};
  let bytes=&b.data[b.used..(b.used+CHUNK).min(b.data.len())];json!({"available":true,"generation":self.generation,"task":self.task,"token":self.token,"offset":self.done,"bytes":bytes.len(),"base64":STANDARD.encode(bytes)})
 }
 pub fn disconnect(&mut self){self.download_path.clear();self.blocks.clear();self.entries.clear();self.listed.clear();self.pending=None;self.cleanup=None;self.cleanup_request=None;self.state="disconnected";self.error=None;self.generation=next();self.token=next();self.requires_reconnect=true;}
}
fn all_cases(b:&[u8])->Result<Vec<(u32,&[u8])>,String>{Ok(crate::protocol::decode_wire(b).map_err(|_|"invalid_file_request")?.into_iter().filter_map(|f|match f.value{crate::protocol::WireValue::Bytes(b)if matches!(f.number,3|4|9)=>Some((f.number,b)),_=>None}).collect())}
#[cfg(test)]#[path="files_tests.rs"]mod tests;
