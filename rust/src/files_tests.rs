use super::*;
fn response(f:&mut FileState,out:&[Outbound],case:u32,body:Vec<u8>)->Vec<Outbound>{assert_eq!(out.len(),1);f.sent(out[0].request_id,true,100);f.on_packet(FILE,&rpc(out[0].request_id,true,case,&body),101).unwrap()}
fn row(kind:u64,nm:&str,p:&str,size:u64)->Vec<u8>{let mut b=vec![];wire::int(1,kind,&mut b);wire::bytes(2,nm.as_bytes(),&mut b);wire::int(3,size,&mut b);wire::bytes(5,p.as_bytes(),&mut b);b}
fn listed(rows:Vec<Vec<u8>>)->FileState{let mut f=FileState::default();let out=f.prepare(&json!({"op":"list","path":"/safe","foreground":true,"confirmed":true}),0).unwrap();let mut b=id(f.task,0);wire::int(4,1,&mut b);let mut list=vec![];for row in rows{wire::bytes(1,&row,&mut list)}wire::bytes(5,&compressed(&list).unwrap(),&mut b);assert!(response(&mut f,&out,7,b).is_empty());assert_eq!(f.state,"complete");f}
fn host(f:&mut FileState,rid:u64,case:u32,body:Vec<u8>)->Vec<Outbound>{f.on_packet(FILE,&rpc(rid,false,case,&body),200).unwrap()}
fn downloading(size:u64)->FileState{let mut f=listed(vec![row(4,"a.bin","/safe/a.bin",size)]);let out=f.prepare(&json!({"op":"download","path":"/safe/a.bin","foreground":true,"confirmed":true}),102).unwrap();let mut info=nested(1,b"a.bin");wire::int(2,size,&mut info);let mut b=id(f.task,0);wire::int(2,1,&mut b);wire::bytes(3,&info,&mut b);response(&mut f,&out,2,b);let mut b=id(f.task,1);wire::int(3,size,&mut b);assert_eq!(host(&mut f,900,3,b).len(),1);f}
fn block(f:&mut FileState,k:u64,data:&[u8])->Vec<Outbound>{let mut b=id(f.task,1);wire::int(2,k,&mut b);wire::bytes(3,data,&mut b);host(f,901+k,4,b)}
fn write_next(f:&mut FileState)->Vec<Outbound>{let c=f.read_chunk();assert_eq!(c["available"],true);f.prepare(&json!({"op":"download_written","generation":f.generation,"task":f.task,"token":c["token"],"bytes":c["bytes"]}),210).unwrap()}
#[test]
fn download_labeled_manifest_replays_early_zero_index_start() {
    let mut f = listed(vec![row(4, "a.bin", "/safe/a.bin", 6)]);
    let request = f.prepare(&json!({"op":"download","path":"/safe/a.bin","foreground":true,"confirmed":true}), 102).unwrap();
    let mut start = id(f.task, 0);
    wire::int(3, 6, &mut start);
    assert!(host(&mut f, 900, 3, start).is_empty());
    let mut file = nested(1, b"folder/a.bin");
    wire::int(2, 6, &mut file);
    let mut manifest = id(f.task, 0);
    wire::int(2, 1, &mut manifest);
    wire::bytes(3, &file, &mut manifest);
    wire::bytes(4, b"folder", &mut manifest);
    wire::bytes(5, b"", &mut manifest);
    assert_eq!(response(&mut f, &request, 2, manifest).len(), 1);
    let mut data = id(f.task, 0);
    wire::bytes(3, b"abcdef", &mut data);
    host(&mut f, 901, 4, data);
    assert_eq!(write_next(&mut f).len(), 1);
    let mut end = id(f.task, 0);
    wire::int(2, 1, &mut end);
    assert_eq!(host(&mut f, 902, 9, end).len(), 1);
    let mut end = id(f.task, u64::MAX);
    wire::int(2, 1, &mut end);
    host(&mut f, 903, 9, end);
    assert_eq!(f.state, "download_save_ready");
    assert_eq!(f.done, 6);
}
#[test]
fn one_based_sender_can_wait_for_first_block_ack() {
    let mut f = downloading(6);
    block(&mut f, 1, b"abc");
    assert_eq!(f.read_chunk()["available"], false);
    f.tick(549);
    assert_eq!(f.read_chunk()["available"], false);
    f.tick(550);
    assert_eq!(write_next(&mut f).len(), 1);
    block(&mut f, 2, b"def");
    assert_eq!(write_next(&mut f).len(), 1);
    assert_eq!(f.done, 6);
}
#[test]fn windows_text_channel_directory_reply_is_correlated_and_keeps_drive_roots(){
 let mut f=FileState::default();let out=f.prepare(&json!({"op":"list","path":"","foreground":true,"confirmed":true}),0).unwrap();f.sent(out[0].request_id,true,1);
 assert_eq!(text(blob(blob(&out[0].data,21).unwrap(),8).and_then(|b|blob(b,10)).unwrap(),2).unwrap(),":/");assert!(path(":/").is_err());
 let mut b=id(f.task,0);wire::bytes(2,b":/",&mut b);wire::int(4,1,&mut b);wire::bytes(3,&row(3,"本地磁盘 C:","C:\\",0),&mut b);wire::bytes(3,&row(0,"桌面","C:\\Users\\test\\Desktop",0),&mut b);
 f.on_packet(TEXT,&rpc(out[0].request_id+1,true,7,&b),2).unwrap();assert_eq!(f.state,"listing");
 f.on_packet(TEXT,&rpc(out[0].request_id,true,7,&b),3).unwrap();assert_eq!(f.state,"complete");assert_eq!(f.entries[0]["path"],"C:\\");assert_eq!(f.snapshot()["directory"],"");
 let out=f.prepare(&json!({"op":"list","path":"C:\\","foreground":true,"confirmed":true}),4).unwrap();f.sent(out[0].request_id,true,5);
 let mut b=id(f.task,0);wire::bytes(2,b"C:\\",&mut b);wire::int(4,1,&mut b);wire::bytes(3,&row(0,"Users","C:\\Users",0),&mut b);
 f.on_packet(TEXT,&rpc(out[0].request_id,true,7,&b),6).unwrap();assert_eq!(f.state,"complete");assert_eq!(f.entries[0]["name"],"Users");
}
#[test]fn confirmation_paths_and_safe_integer_limits(){
 let mut f=FileState::default();assert!(f.prepare(&json!({"op":"list","path":"~/"}),0).is_err());
 for p in ["C:/a/../b","C:/a\0x","C:/a:stream","C:relative","//server/x","/x/./a"]{assert!(path(p).is_err(),"{p:?}")}
 for p in ["~/","C:\\Users\\Public","/tmp"]{assert!(path(p).is_ok(),"{p:?}")}
 for nm in ["../x","a/b","a:b","NUL","a.","CON.txt","LPT1"]{assert!(name(nm).is_err())}
 let f=listed(vec![row(4,"a.bin","/safe/a.bin",12)]);assert!(f.snapshot().get("base64").is_none());assert_eq!(f.snapshot()["observedOnWindows"],Value::Null);
}
#[test]fn listing_correlates_and_rejects_malicious_entries(){
 let mut f=FileState::default();let out=f.prepare(&json!({"op":"list","path":"/safe","foreground":true,"confirmed":true}),0).unwrap();let mut b=id(f.task,0);wire::int(4,1,&mut b);wire::bytes(3,&row(4,"escape","/safe/../escape",1),&mut b);
 assert!(f.on_packet(FILE,&rpc(out[0].request_id+1,true,7,&b),1).unwrap().is_empty());assert_eq!(f.state,"listing");response(&mut f,&out,7,b);assert_eq!(f.state,"failed");assert!(f.entries.is_empty());
 let mut f=FileState::default();let out=f.prepare(&json!({"op":"list","path":"/safe","foreground":true,"confirmed":true}),0).unwrap();let mut b=id(f.task,0);wire::int(4,1,&mut b);wire::bytes(3,&row(4,"huge","/safe/huge",JS_MAX+1),&mut b);response(&mut f,&out,7,b);assert_eq!(f.state,"failed");
}
#[test]fn upload_preflight_skip_strategy_and_correlated_progress(){
 let mut f=listed(vec![]);let out=f.prepare(&json!({"op":"upload","directory":"/safe","name":"new.bin","size":3,"modified":100,"confirmed":true,"foreground":true}),102).unwrap();let mut b=id(f.task,0);wire::int(4,1,&mut b);let out=response(&mut f,&out,7,b);
 let r=blob(&out[0].data,21).unwrap();let req=blob(blob(r,8).unwrap(),1).unwrap();assert_eq!(uint(req,4),3);assert!(blob(req,5).is_none());
 let mut b=id(f.task,0);wire::int(3,1,&mut b);let out=response(&mut f,&out,1,b);let mut b=id(f.task,1);wire::int(3,1,&mut b);response(&mut f,&out,3,b);assert_eq!(f.state,"upload_ready");
 let out=f.prepare(&json!({"op":"upload_chunk","task":f.task,"generation":f.generation,"offset":0,"base64":STANDARD.encode(b"abc")}),103).unwrap();assert_eq!(f.done,0);let mut b=id(f.task,1);wire::int(2,0,&mut b);wire::int(3,1,&mut b);wire::int(4,3,&mut b);let out=response(&mut f,&out,4,b);assert_eq!(f.done,3);assert!(!f.remote_done);let mut b=id(f.task,1);wire::int(2,1,&mut b);response(&mut f,&out,6,b);assert_eq!(f.state,"complete");assert!(f.remote_done);
}
#[test]fn upload_existing_name_stops_before_receive_request(){let mut f=listed(vec![]);let out=f.prepare(&json!({"op":"upload","directory":"/safe","name":"same.bin","size":3,"modified":0,"confirmed":true,"foreground":true}),102).unwrap();let mut b=id(f.task,0);wire::int(4,1,&mut b);wire::bytes(3,&row(4,"SAME.bin","/safe/SAME.bin",2),&mut b);let out=response(&mut f,&out,7,b);assert_eq!(f.state,"failed");assert_eq!(f.error.as_deref(),Some("remote_name_exists_no_overwrite"));assert!(out.iter().all(|o|blob(blob(&o.data,21).unwrap(),8).and_then(|x|blob(x,1)).is_none()));}
#[test]fn download_one_based_short_file_and_commit_ack(){
 let mut f=downloading(6);assert!(block(&mut f,1,b"ab").is_empty());assert!(!f.read_chunk()["available"].as_bool().unwrap());block(&mut f,3,b"ef");block(&mut f,2,b"cd");
 assert!(f.snapshot().get("base64").is_none());let c=f.read_chunk();assert_eq!(c,f.read_chunk());assert_eq!(STANDARD.decode(c["base64"].as_str().unwrap()).unwrap(),b"ab");let old=f.token;assert_eq!(write_next(&mut f).len(),1);assert_eq!(f.done,2);assert!(f.prepare(&json!({"op":"download_written","task":f.task,"generation":f.generation,"token":old,"bytes":2}),210).is_err());write_next(&mut f);write_next(&mut f);
 let mut end=id(f.task,1);wire::int(2,1,&mut end);assert_eq!(host(&mut f,920,9,end).len(),1);let mut end=id(f.task,u64::MAX);wire::int(2,1,&mut end);host(&mut f,921,9,end);assert_eq!(f.state,"download_save_ready");assert!(!f.local_saved);f.prepare(&json!({"op":"download_saved","task":f.task,"generation":f.generation}),220).unwrap();assert_eq!(f.state,"complete");
}
#[test]fn download_splits_64k_and_zero_based_out_of_order(){let size=64*1024;let mut f=downloading(size as u64+2);block(&mut f,1,b"ef");block(&mut f,0,&vec![42;size]);assert_eq!(f.read_chunk()["bytes"],CHUNK);assert!(write_next(&mut f).is_empty());assert_eq!(f.done,CHUNK as u64);assert_eq!(write_next(&mut f).len(),1);assert_eq!(write_next(&mut f).len(),1);assert_eq!(f.done,size as u64+2);}
#[test]fn download_empty_file_requires_remote_end_and_local_save(){let mut f=downloading(0);let mut b=id(f.task,1);wire::int(2,1,&mut b);host(&mut f,930,9,b);let mut b=id(f.task,u64::MAX);wire::int(2,1,&mut b);host(&mut f,931,9,b);assert_eq!(f.state,"download_save_ready");assert!(!f.local_saved);}
#[test]fn download_binary_utf8_content_survives_reordering_and_chunk_boundaries(){
 let expected:Vec<u8>="中文传输\0\r\n".as_bytes().iter().copied().cycle().take(MAX_BLOCK+CHUNK+17).collect();
 let mut f=downloading(expected.len() as u64);
 // Receive a later network block first; it must not reach the local writer early.
 block(&mut f,1,&expected[MAX_BLOCK..]);assert_eq!(f.read_chunk()["available"],false);
 block(&mut f,0,&expected[..MAX_BLOCK]);let mut actual=Vec::new();
 while f.read_chunk()["available"]==true{
  let c=f.read_chunk();assert_eq!(c["offset"],actual.len());
  actual.extend(STANDARD.decode(c["base64"].as_str().unwrap()).unwrap());write_next(&mut f);
 }
 assert_eq!(actual,expected);assert_eq!(f.done,expected.len() as u64);assert!(!f.local_saved);
}
#[test]fn cancel_rejects_late_packets_and_requires_cleanup(){let mut f=downloading(4);block(&mut f,0,b"ab");let g=f.generation;let task=f.task;let out=f.prepare(&json!({"op":"cancel","generation":g}),201).unwrap();assert!(out.len()>=2);assert_ne!(f.generation,g);assert_eq!(f.blocks.len(),0);assert!(f.prepare(&json!({"op":"download_written","task":task,"generation":g,"token":1,"bytes":2}),202).is_err());let mut b=id(task,1);wire::int(2,1,&mut b);wire::bytes(3,b"cd",&mut b);let out=host(&mut f,940,4,b);assert_eq!(out.len(),1);let r=blob(&out[0].data,22).unwrap();assert_eq!(uint(blob(blob(r,4).unwrap(),4).unwrap(),3),7);f.tick(3202);assert!(f.requires_reconnect);f.disconnect();assert!(!f.read_chunk()["available"].as_bool().unwrap());}
#[test]fn bounded_queue_send_deadline_and_disconnect_generation(){let mut f=downloading(18);for k in 1..=16{block(&mut f,k,b"x");}assert_eq!(f.blocks.len(),16);assert!(!block(&mut f,17,b"x").is_empty());assert_eq!(f.state,"failed");assert!(f.blocks.is_empty());let mut f=FileState::default();f.prepare(&json!({"op":"list","path":"~/","foreground":true,"confirmed":true}),0).unwrap();assert!(f.tick(2001).is_empty());assert_eq!(f.state,"failed");let old=f.generation;f.disconnect();assert_ne!(f.generation,old);assert!(f.entries.is_empty());}
#[test]fn remote_directory_report_replaces_home_alias(){
 let mut f=FileState::default();let out=f.prepare(&json!({"op":"list","path":"~/","foreground":true,"confirmed":true}),0).unwrap();let mut b=id(f.task,0);wire::int(4,1,&mut b);wire::bytes(2,b"C:\\Users\\Actual",&mut b);wire::bytes(3,&row(0,"Downloads","C:\\Users\\Actual\\Downloads",0),&mut b);response(&mut f,&out,7,b);assert_eq!(f.state,"complete");assert_eq!(f.snapshot()["directory"],"C:\\Users\\Actual");assert_eq!(f.entries[0]["path"],"C:\\Users\\Actual\\Downloads");
}
#[test]fn virtual_root_accepts_reported_drive_only(){
 let mut f=FileState::default();let out=f.prepare(&json!({"op":"list","path":"","foreground":true,"confirmed":true}),0).unwrap();let mut b=id(f.task,0);wire::int(4,1,&mut b);wire::bytes(2,b"",&mut b);wire::bytes(3,&row(3,"C drive","C:\\",0),&mut b);response(&mut f,&out,7,b);assert_eq!(f.state,"complete");assert_eq!(f.entries[0]["path"],"C:\\");assert!(f.prepare(&json!({"op":"upload","directory":"","name":"x.bin","size":0,"modified":0,"confirmed":true,"foreground":true}),102).is_err());
}
#[test]fn upload_refuses_changed_remote_directory_report(){
 let mut f=listed(vec![]);let out=f.prepare(&json!({"op":"upload","directory":"/safe","name":"x.bin","size":0,"modified":0,"confirmed":true,"foreground":true}),102).unwrap();let mut b=id(f.task,0);wire::int(4,1,&mut b);wire::bytes(2,b"/other",&mut b);response(&mut f,&out,7,b);assert_eq!(f.state,"failed");assert_eq!(f.error.as_deref(),Some("upload_directory_changed"));
}
#[test]fn remote_receive_directory_metadata_is_validated_and_separate_from_browser(){
 let mut f=listed(vec![]);let mut body=vec![];wire::bytes(1,b"C:\\Users\\Actual\\Downloads",&mut body);let message=wire::envelope(1,26,&body);f.observe_metadata(&message);assert_eq!(f.snapshot()["remoteDownloadPath"],"C:\\Users\\Actual\\Downloads");assert_eq!(f.snapshot()["directory"],"/safe");let mut invalid=vec![];wire::bytes(1,b"C:\\safe\\..\\escape",&mut invalid);f.observe_metadata(&wire::envelope(2,26,&invalid));assert_eq!(f.snapshot()["remoteDownloadPath"],"C:\\Users\\Actual\\Downloads");f.disconnect();assert_eq!(f.snapshot()["remoteDownloadPath"],"");
}
#[test]fn official_shortcut_directory_and_file_link_entries_keep_reported_targets(){
 let mut f=FileState::default();let out=f.prepare(&json!({"op":"list","path":"/safe","foreground":true,"confirmed":true}),0).unwrap();let mut b=id(f.task,0);wire::int(4,1,&mut b);wire::bytes(2,b"/safe",&mut b);wire::bytes(3,&row(2,"Desktop","C:\\Users\\Actual\\Desktop",0),&mut b);wire::bytes(3,&row(5,"linked.bin","C:\\Other\\linked.bin",3),&mut b);response(&mut f,&out,7,b);assert_eq!(f.state,"complete");assert_eq!(f.entries.len(),2);assert_eq!(f.entries[0]["kind"],2);assert_eq!(f.entries[0]["path"],"C:\\Users\\Actual\\Desktop");let out=f.prepare(&json!({"op":"download","path":"C:\\Other\\linked.bin","foreground":true,"confirmed":true}),102).unwrap();assert_eq!(out.len(),1);assert_eq!(f.state,"download_accept");
}
#[test]fn confirmed_cancel_response_releases_cleanup_for_same_session_retry(){
 let mut f=downloading(4);let out=f.prepare(&json!({"op":"cancel","generation":f.generation}),201).unwrap();let cancel=out.iter().find(|o|blob(&o.data,21).and_then(|r|blob(r,8)).and_then(|r|blob(r,9)).is_some()).unwrap();let old=f.cleanup.unwrap().0;let mut b=id(old,1);wire::int(2,1,&mut b);f.on_packet(FILE,&rpc(cancel.request_id,true,6,&b),202).unwrap();assert!(!f.snapshot()["cleanupPending"].as_bool().unwrap());f.tick(4000);assert!(!f.requires_reconnect);assert!(f.prepare(&json!({"op":"list","path":"","foreground":true,"confirmed":true}),4001).is_ok());
}
#[test]fn directory_failure_can_retry_and_legal_sctp_response_is_not_limited_to_block_size(){
 let mut f=FileState::default();let out=f.prepare(&json!({"op":"list","path":"/missing","foreground":true,"confirmed":true}),0).unwrap();let mut b=id(f.task,0);wire::int(4,9,&mut b);response(&mut f,&out,7,b);assert_eq!(f.state,"failed");assert!(!f.requires_reconnect);
 let out=f.prepare(&json!({"op":"list","path":"/safe","foreground":true,"confirmed":true}),102).unwrap();let mut b=id(f.task,0);wire::int(4,1,&mut b);wire::bytes(2,b"/safe",&mut b);wire::bytes(3,&row(4,"a.bin","/safe/a.bin",1),&mut b);wire::bytes(99,&vec![42;70*1024],&mut b);response(&mut f,&out,7,b);assert_eq!(f.state,"complete");assert_eq!(f.entries.len(),1);
}
