import { picker, fileIo, fileUri } from '@kit.CoreFileKit';
import filesNative from 'libuufiles.so';
import { systemShare } from '@kit.ShareKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { addTransferRecord } from '../pc/PcTransferHistory';

export interface FileEntry {kind:number;name:string;size:number;modified:number;path:string;}
export interface FilesEvent {op:string;path?:string;directory?:string;name?:string;size?:number;modified?:number;foreground?:boolean;confirmed?:boolean;generation?:number;task?:number;offset?:number;base64?:string;token?:number;bytes?:number;}
export interface FilesCommand {op:string;event?:FilesEvent;}
export interface FilesStatus {remoteDownloadPath?:string;generation:number;task:number;state:string;mode:string;directory:string;name:string;transferred:number;total:number;sentMessages:number;correlatedAcks:number;remoteComplete:boolean;localSaved:boolean;needUploadChunk:boolean;downloadAvailable:boolean;entries:FileEntry[];error?:string;requiresReconnect?:boolean;cleanupPending?:boolean;}
interface FileChunk {available:boolean;generation:number;task:number;token:number;offset:number;bytes:number;base64:string;error?:string;}
interface SavedDownload {path:string;name:string;size:number;}
export interface UploadChoice {directory:string;name:string;size:number;modified:number;}
const BLOCK:number=32768;
const MAX_SAFE:number=9007199254740991;
function safeLocalName(name:string):boolean {
  return !!name&&name.length<=255&&!/[\\/:*?"<>|\x00-\x1f]/.test(name)&&name!=='.'&&name!=='..'&&!name.startsWith('.uu-partial-');
}
function failureText(reason:string):string {
  const code=/^[a-z0-9_]{1,80}$/.test(reason)?reason:'local_file_io';
  if(code.includes('timeout')){return '文件请求超时，请重试。';}
  if(code==='download_name_exists_no_overwrite'||code==='remote_name_exists_no_overwrite'){return '目标目录已有同名文件，请另选目录或重命名。';}
  if(code==='download_manifest_changed'){return '远端文件名称或大小已变化，请刷新目录后再试。';}
  if(code==='download_directory_required'||code==='download_publish_failed'||code==='download_exclusive_create_unavailable'){
    return '无法写入当前目录，请检查权限、可用空间或选择其他目录。';
  }
  return '文件操作未完成（'+code+'）。';
}

// UI invokes picker only in foreground. URI capabilities and descriptors never cross the Rust bridge.
export class RemoteFiles {
  status:FilesStatus={generation:0,task:0,state:'idle',mode:'',directory:'',name:'',transferred:0,total:0,sentMessages:0,correlatedAcks:0,remoteComplete:false,localSaved:false,needUploadChunk:false,downloadAvailable:false,entries:[]};
  text:string='远端目录尚未读取';
  choice:UploadChoice|undefined=undefined;
  private send:(c:FilesCommand)=>Promise<string>;
  private observer:((s:FilesStatus,text:string)=>void)|undefined=undefined;
  private context:common.UIAbilityContext|undefined=undefined;
  private input:fileIo.File|undefined=undefined;
  private output:number|undefined=undefined;
  private outputDirectory:fileIo.File|undefined=undefined;
  private temporaryName:string='';
  private destinationName:string='';
  private destinationFolder:string='';
  private destinationBranch:string[]=[];
  private historyEnabled:boolean=false;
  private lastHistoryTask:string='';
  private pendingAppPath:string='';
  private completedDownload:SavedDownload|undefined=undefined;
  get savedDownloadName():string{return this.completedDownload?this.completedDownload.name:'';}
  private epoch:number=0;
  private timer:number=-1;
  private locked:boolean=false;
  private active:Promise<void>=Promise.resolve();
  private foreground:boolean=false;
  private disposed:boolean=false;
  private uploading:boolean=false;
  private downloading:boolean=false;
  private localOffset:number=0;
  private base64:util.Base64Helper=new util.Base64Helper();
  constructor(send:(c:FilesCommand)=>Promise<string>){this.send=send;}
  setContext(context:common.UIAbilityContext):void{this.context=context;}
  enableHistory():void{this.historyEnabled=true;}
  private async record(state:FilesStatus, result:string, folder:string='', fingerprint:string='', branch:string[]=[]):Promise<void>{
    const context=this.context;
    if(!this.historyEnabled||!context||!state.name||!['upload','download'].includes(state.mode)){return;}
    const id=state.task+':'+result;
    if(this.lastHistoryTask===id){return;}
    this.lastHistoryTask=id;
    try{await addTransferRecord(context,state.mode==='upload'?'send':'receive',state.name,state.total,result,folder,fingerprint,branch);}
    catch(_){hilog.warn(0x0303,'UUFiles','transfer_history_write_failed');}
  }
  observe(fn:((s:FilesStatus,text:string)=>void)|undefined):void{this.observer=fn;this.emit();}
  setForeground(value:boolean):void{this.foreground=value;if(!value){this.cancel();}}
  private emit():void{if(this.observer){this.observer(this.status,this.text);}}
  private current(run:number):void{if(run!==this.epoch||this.disposed||!this.foreground){throw new Error('file_ui_generation_changed');}}
  private picker():picker.DocumentViewPicker{if(!this.context){throw new Error('file_picker_context_required');}return new picker.DocumentViewPicker(this.context);}
  private stopTimer():void{if(this.timer>=0){clearInterval(this.timer);this.timer=-1;}}
  private watch():void{this.stopTimer();this.timer=setInterval(()=>{this.refresh();},120);}
  private async closeFiles():Promise<void>{
    const a=this.input;const b=this.output;const directory=this.outputDirectory;const temporary=this.temporaryName;
    this.input=undefined;this.output=undefined;this.outputDirectory=undefined;this.temporaryName='';this.destinationName='';this.destinationFolder='';this.destinationBranch=[];
    this.pendingAppPath='';this.choice=undefined;this.uploading=false;this.downloading=false;
    if(a){await fileIo.close(a).catch(()=>{});}
    if(b!==undefined){await fileIo.close(b).catch(()=>{});}
    if(directory){
      if(temporary){try{filesNative.finishTemporary(directory.fd,temporary);}catch(_){hilog.warn(0x0303,'UUFiles','temporary_cleanup_failed');}}
      await fileIo.close(directory).catch(()=>{});
    }
  }
  private async command(event:FilesEvent,run:number):Promise<void>{this.current(run);const raw=await this.send({op:'peer_files_prepare',event:event});this.current(run);const state=JSON.parse(raw) as FilesStatus;if(state.state){this.status=state;this.emit();}if(state.error){throw new Error(state.error);}if(!state.state){throw new Error('invalid_file_status');}}
  private async statusOnly(run:number):Promise<void>{this.current(run);const raw=await this.send({op:'peer_files_status'});this.current(run);const state=JSON.parse(raw) as FilesStatus;if(!state.state){throw new Error(state.error||'invalid_file_status');}this.status=state;this.text=state.error?failureText(state.error):state.requiresReconnect?'文件通道需要重新连接，请重试。':state.mode==='list'?(state.state==='complete'?'远端目录已读取':'正在读取远端目录…'):state.state==='complete'?'文件传输已完成':`${state.transferred}/${state.total} 字节`;this.emit();}
  private idle(allowChoice:boolean=false):void{if((this.choice&&!allowChoice)||this.uploading||this.downloading||!['idle','complete','failed','canceled','disconnected'].includes(this.status.state)){throw new Error('file_operation_busy');}}
  private work(fn:(run:number)=>Promise<void>):Promise<void>{
    if(this.locked||this.disposed||!this.foreground){return Promise.resolve();}this.locked=true;const run=this.epoch;
    this.active=(async()=>{try{await fn(run);}catch(error){if(run===this.epoch){
      this.stopTimer();const reason=error instanceof Error?error.message:'file_operation_failed';
      try{const current=JSON.parse(await this.send({op:'peer_files_status'})) as FilesStatus;if(current.state){this.status=current;}
        if(!['idle','complete','failed','canceled','disconnected'].includes(this.status.state)){const stopped=JSON.parse(await this.send({op:'peer_files_prepare',event:{op:'cancel',generation:this.status.generation}})) as FilesStatus;if(stopped.state){this.status=stopped;}}
      }catch(_){}
      if(!this.choice||this.uploading||this.downloading||reason==='upload_file_changed'){await this.closeFiles();}
      hilog.warn(0x0303,'UUFiles','stage=%{public}s error=%{public}s',this.status.mode,/^[a-z0-9_]{1,80}$/.test(reason)?reason:'local_file_io');
      if(this.status.state==='failed'){await this.record(this.status,'failed');}
      this.text=failureText(reason)+(this.status.requiresReconnect?' 请重新连接文件通道。':'');
      this.emit();
    }}finally{this.locked=false;}})();return this.active;
  }
  async list(path:string=''):Promise<void>{return this.work(async(run:number)=>{this.idle(true);await this.statusOnly(run);this.idle(true);await this.command({op:'list',path:path,foreground:true,confirmed:true,generation:this.status.generation},run);this.watch();});}
  // The system picker is local: no network status/list request can delay it.
  async selectUpload(directory:string='',media:boolean=false):Promise<void>{return this.work(async(run:number)=>{
    if(this.choice||this.uploading||this.downloading){throw new Error('file_operation_busy');}
    const options=new picker.DocumentSelectOptions();options.maxSelectNumber=1;options.selectMode=picker.DocumentSelectMode.FILE;
    let uris:string[]=[];
    if(media){const context=this.context;if(!context){throw new Error('file_picker_context_required');}const photoOptions=new picker.PhotoSelectOptions();photoOptions.MIMEType=picker.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;photoOptions.maxSelectNumber=1;const result=await new picker.PhotoViewPicker(context).select(photoOptions);uris=result.photoUris;}else{uris=await this.picker().select(options);}this.current(run);if(uris.length!==1){return;}const uri=uris[0];if(!uri.startsWith('file://')){throw new Error('invalid_picker_uri');}
    const file=await fileIo.open(uri,fileIo.OpenMode.READ_ONLY);if(run!==this.epoch||!this.foreground){await fileIo.close(file);return;}this.input=file;
    const stat=await fileIo.stat(file.fd);this.current(run);if(!stat.isFile()||!Number.isSafeInteger(stat.size)||stat.size<0||stat.size>MAX_SAFE){throw new Error('upload_regular_safe_size_required');}
    const name=new fileUri.FileUri(uri).name;if(!name||name.length>255||/[\\/:*?"<>|\x00-\x1f]/.test(name)||name==='.'||name==='..'){throw new Error('unsafe_upload_name');}
    this.choice={directory:directory,name:name,size:stat.size,modified:Math.max(0,Math.floor(stat.mtime))};
    this.text='已选择 '+name+'，请选择并确认电脑接收目录。';this.emit();
  });}
  async selectLocalUpload(path:string,name:string,directory:string):Promise<void>{return this.work(async(run:number)=>{
    this.idle();
    if(!safeLocalName(name)){throw new Error('unsafe_upload_name');}
    const file=await fileIo.open(path,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
    this.input=file;this.current(run);
    const stat=await fileIo.stat(file.fd);this.current(run);
    if(!stat.isFile()||!Number.isSafeInteger(stat.size)||stat.size<0){throw new Error('upload_regular_safe_size_required');}
    this.choice={directory:directory,name:name,size:stat.size,modified:Math.max(0,Math.floor(stat.mtime))};
    this.emit();
  });}
  setUploadDirectory(directory:string):boolean{const choice=this.choice;if(!choice||!directory||this.status.state!=='complete'||this.status.mode!=='list'||directory!==this.status.directory){return false;}choice.directory=directory;this.text='已选择 '+choice.name+'，发送到：'+directory;this.emit();return true;}

  // Lead UI calls this only from the explicit upload confirmation action.
  async confirmUpload():Promise<void>{return this.work(async(run:number)=>{
    const choice=this.choice;const file=this.input;if(!choice||!file||!choice.directory){throw new Error('upload_selection_required');}
    await this.statusOnly(run);const stat=await fileIo.stat(file.fd);this.current(run);if(stat.size!==choice.size){throw new Error('upload_file_changed');}
    await this.command({op:'upload',directory:choice.directory,name:choice.name,size:choice.size,modified:choice.modified,foreground:true,confirmed:true,generation:this.status.generation},run);
    this.choice=undefined;this.localOffset=0;this.uploading=true;this.watch();
  });}
  // Only an authorized directory FD reaches native atomic exclusive creation.
  async download(entry:FileEntry,saveInApp:boolean=false,destination:string='',authorizedRoot:string=''):Promise<void>{return this.work(async(run:number)=>{
    this.idle();await this.statusOnly(run);
    const selected=this.status.entries.find((item:FileEntry)=>(item.kind===4||item.kind===5)&&item.path===entry.path&&item.name===entry.name&&item.size===entry.size);
    if(!selected){throw new Error('download_requires_listed_file');}
    const generation=this.status.generation;
    if(!safeLocalName(selected.name)){throw new Error('unsafe_remote_name');}
    this.destinationName=selected.name;
    let folder=destination;
    if(!folder&&!saveInApp&&canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')){
      const options=new picker.DocumentSelectOptions();options.maxSelectNumber=1;options.selectMode=picker.DocumentSelectMode.FOLDER;
      this.text=`选择保存目录；将新建 ${selected.name}，同名文件拒绝覆盖。`;this.emit();
      const uris=await this.picker().select(options);this.current(run);if(uris.length!==1){return;}
      if(!uris[0].startsWith('file://')){throw new Error('invalid_picker_uri');}
      folder=uris[0];
    }
    if(!folder){
      const context=this.context;if(!context){throw new Error('file_context_required');}
      // Trusted application-owned path only. Never reinterpret a document-provider URI.
      folder=context.filesDir+'/received';
      if(!await fileIo.access(folder)){await fileIo.mkdir(folder);}
      this.pendingAppPath=folder+'/'+selected.name;
      this.text=`将 ${selected.name} 保存到应用内接收文件；完成后可通过系统分享保存到其他应用。同名拒绝覆盖。`;this.emit();
    }
    this.current(run);
    const root=authorizedRoot.replace(/\/+$/,'');
    const nested=!!root&&(folder===root||folder.startsWith(root+'/'));
    this.destinationFolder=nested?authorizedRoot:folder;
    this.destinationBranch=nested?folder.slice(root.length).split('/').filter((name:string)=>!!name)
      .map((name:string)=>root.startsWith('file://')?decodeURIComponent(name):name):[];
    const directory=await fileIo.open(folder,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
    this.outputDirectory=directory;this.current(run);
    if(!(await fileIo.stat(directory.fd)).isDirectory()){throw new Error('download_directory_required');}
    this.current(run);
    const temporary='.uu-partial-'+util.generateRandomUUID();
    this.output=filesNative.createExclusive(directory.fd,temporary);
    this.temporaryName=temporary;
    this.current(run);this.localOffset=0;this.downloading=true;
    await this.command({op:'download',path:selected.path,foreground:true,confirmed:true,generation:generation},run);this.watch();
  });}
  async refresh():Promise<void>{return this.work(async(run:number)=>{
    await this.statusOnly(run);const state=this.status;
    if(state.error||state.requiresReconnect||['failed','canceled','disconnected'].includes(state.state)){this.stopTimer();if(state.error){hilog.warn(0x0303,'UUFiles','stage=%{public}s error=%{public}s',state.mode,/^[a-z0-9_]{1,80}$/.test(state.error)?state.error:'local_file_io');}if(state.state==='failed'){await this.record(state,'failed');}if(!this.choice||this.uploading||this.downloading){await this.closeFiles();}this.emit();return;}
    if(this.uploading&&state.needUploadChunk){
      const file=this.input;if(!file||this.localOffset!==state.transferred){throw new Error('upload_local_offset_mismatch');}
      const wanted=Math.min(BLOCK,state.total-this.localOffset);if(wanted<=0){throw new Error('invalid_upload_remaining');}const buffer=new ArrayBuffer(wanted);const count=await fileIo.read(file.fd,buffer,{length:wanted});this.current(run);if(count!==wanted){throw new Error('upload_short_read');}
      const encoded=this.base64.encodeToStringSync(new Uint8Array(buffer));await this.command({op:'upload_chunk',generation:state.generation,task:state.task,offset:state.transferred,base64:encoded},run);this.localOffset+=count;
    }
    if(this.downloading&&state.downloadAvailable){
      const raw=await this.send({op:'peer_files_read'});this.current(run);const chunk=JSON.parse(raw) as FileChunk;
      if(chunk.error){throw new Error(chunk.error);}if(chunk.available){
        if(chunk.generation!==state.generation||chunk.task!==state.task||chunk.offset!==this.localOffset||chunk.bytes<=0||chunk.bytes>BLOCK||chunk.base64.length>43692){throw new Error('invalid_download_chunk');}
        const decoded=this.base64.decodeSync(chunk.base64);if(decoded.byteLength!==chunk.bytes){throw new Error('download_decode_size_mismatch');}const file=this.output;if(file===undefined){throw new Error('save_descriptor_closed');}
        let written=0;while(written<decoded.byteLength){const part=decoded.slice(written);const count=await fileIo.write(file,part.buffer,{length:part.byteLength});this.current(run);if(count<=0||count>part.byteLength){throw new Error('download_short_write');}written+=count;}
        await this.command({op:'download_written',generation:chunk.generation,task:chunk.task,token:chunk.token,bytes:chunk.bytes},run);this.localOffset+=written;
      }
    }
    if(this.downloading&&this.status.state==='download_save_ready'){
      const file=this.output;const directory=this.outputDirectory;
      if(file===undefined||!directory||this.localOffset!==this.status.total||(await fileIo.stat(file)).size!==this.status.total){throw new Error('download_save_size_mismatch');}
      await fileIo.fsync(file);this.current(run);await fileIo.close(file);this.output=undefined;this.current(run);
      const fingerprint=filesNative.finishTemporary(directory.fd,this.temporaryName,this.destinationName);
      this.temporaryName='';
      await this.record(this.status,'complete',this.destinationFolder,fingerprint,this.destinationBranch);
      await this.command({op:'download_saved',generation:this.status.generation,task:this.status.task},run);
      const committed=JSON.parse(await this.send({op:'peer_files_status'})) as FilesStatus;this.current(run);
      if(this.pendingAppPath&&committed.state==='complete'&&committed.localSaved){this.completedDownload={path:this.pendingAppPath,name:committed.name,size:committed.total};this.text='已保存到应用内接收文件：'+committed.name+'；可点系统分享另存到其他应用。';this.emit();}
    }
    if(this.status.state==='complete'){this.stopTimer();if(this.status.mode==='upload'&&this.uploading){await this.record(this.status,'complete');}if(!this.choice){await this.closeFiles();}}
  });}
  // Share only the privately recorded, fsynced/closed and protocol-committed download.
  // There is no caller-controlled path, URI, directory or partial-file export API.
  async shareSavedDownload():Promise<void>{return this.work(async(run:number)=>{
    const saved=this.completedDownload;const context=this.context;
    if(!saved||!context){throw new Error('completed_download_required');}
    if(!canIUse('SystemCapability.Collaboration.SystemShare')){this.text='文件已保存在应用内；此设备不支持系统分享。';this.emit();return;}
    const file=await fileIo.open(saved.path,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
    try{this.current(run);const stat=await fileIo.stat(file.fd);this.current(run);if(!stat.isFile()||stat.size!==saved.size){throw new Error('saved_download_changed');}}
    finally{await fileIo.close(file);}
    this.current(run);
    const record:systemShare.SharedRecord={utd:'general.file',uri:fileUri.getUriFromPath(saved.path),title:saved.name};
    const data=new systemShare.SharedData(record);const controller=new systemShare.ShareController(data);
    const options:systemShare.ShareControllerOptions={};
    this.text='已请求系统分享所选完成文件；是否另存由系统和目标应用确认。';this.emit();
    await controller.show(context,options);
  });}
  async cancel():Promise<void>{const previous=this.active;this.epoch++;const run=this.epoch;this.stopTimer();const generation=this.status.generation;const raw=await this.send({op:'peer_files_prepare',event:{op:'cancel',generation:generation}}).catch(()=>'');await previous;await this.closeFiles();if(run!==this.epoch){return;}if(raw){const state=JSON.parse(raw) as FilesStatus;if(state.state){this.status=state;}}this.text=this.status.requiresReconnect?'已停止本机传输，请重新连接文件通道。':'已取消传输。';this.emit();}
  async connectionLost():Promise<void>{this.epoch++;this.stopTimer();await this.active;const choice=this.choice;if(choice&&!this.uploading&&!this.downloading){choice.directory='';}else{await this.closeFiles();}this.status.state='disconnected';this.status.mode='';this.status.entries=[];this.status.requiresReconnect=true;this.status.error=undefined;this.text=choice?'文件连接已中断；已保留 '+choice.name+'，重新连接后请确认接收目录。':'文件连接已中断，未完成的传输请重新选择后重试。';this.emit();}
  async disconnect():Promise<void>{this.foreground=false;this.epoch++;this.stopTimer();await this.active;await this.closeFiles();this.status.state='disconnected';this.text='连接已断开，文件资源已释放';this.emit();}
  async dispose():Promise<void>{this.disposed=true;await this.disconnect();this.observer=undefined;this.context=undefined;}
}
