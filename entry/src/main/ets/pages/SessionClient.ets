import { RtpDiagnostics, logRtpDiagnostics } from './RtpDiagnostics';
import { MultiVideoClient, MultiSnapshot } from './MultiVideoClient';
import { windowsUnlockStatus, windowsUnlockEnroll, windowsUnlockSetEnabled, windowsUnlockDelete, windowsUnlockUse } from 'libs3c.so';
import { deviceLockRequest } from './DeviceLockRequest';
import micNative from 'libuumic.so';
import { AdvancedCommand, ClipboardEvent } from './AdvancedClient';
import { DisplayState, displayStatus, currentFrameReady } from './DisplayModel';
import { center, SettingRequest, SettingReply, NetworkSample, ConnectionInfo, DecoderSample } from './ControlCenter';
import { TabletEvent, TabletPoint } from './TabletTouch';
import { RemoteInput } from './MobileInput';
import { http, webSocket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { client } from './AuthClient';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { invoke, startVideo, stopVideo, hardStopVideo, videoStatus, videoMetrics, videoSlotMetrics, audioStop } from 'libs3c.so';
interface TabletWireEvent {type:string;points:TabletPoint[];}
export interface TerminalCommand {action:string;confirmed?:boolean;text?:string;cols?:number;rows?:number;session?:number;sessionToken?:number;cursor?:number;limit?:number;streamEpoch?:number|string;}
interface PrivacyWallpaperCommand {op:string;deviceKey:string;action:string;selectedType:string;presetId:string;}
interface SocketOpen {status:number;message:string;}
interface DisplayAction {action:string;id?:number;confirmed?:boolean;}
interface Action { kind: string; url?: string; headers?: Record<string,string>; text?: string; base64?: string; }
interface Status { state: string; message: string; }
interface Request { id:number;url:string;headers:Record<string,string>;body:string;timeoutMs:number;participantBinding?:string; }
interface RoomLeaveResponse { code:number; }
interface PendingPointer {event:RemoteInput;arrivedAt:number;}
interface Reply { assistFallback?:boolean; signal?:Status; actions?:Action[]; peerConfig?:Object; peerEvent?:Object; request?:Request; leaveRequest?:Request; error?:string; joinHttp?:number;joinCode?:number;joinPassed?:boolean;selectionValid?:boolean; harmonyHost?:boolean; }
interface VideoState {ready?:boolean;codec?:number;running?:boolean;released?:boolean;rendered?:number;decoded?:number;submitted?:number;width?:number;height?:number;error?:number;phase?:string;failureStage?:string|null;systemCode?:number|null;failureKind?:string|null;firstAccessUnit?:boolean;firstSps?:boolean;firstPps?:boolean;firstIdr?:boolean;codecName?:string;hardware?:boolean;reusable?:boolean;}
interface PortraitFrameStatus {screenId:number;width:number;height:number;seq:number;sent:boolean;ack:boolean|null;error:string|null;fallback:boolean;renderWidth?:number|null;renderHeight?:number|null;exactOutput?:boolean|null;withinBudget?:boolean|null;aspectCompatible?:boolean|null;}
interface LegacyCaptureCounters {epoch:number;packets:number;padding:number;payloadBytes:number;completeAus:number;accepted:number;queueRejected:number;noPicture:number;profileRejected:number;timestampRejected:number;oversizeRejected:number;otherNalRejected:number;metadataRejected:number;reassemblyPli:number;}
interface PeerReply {connectionInfo?:ConnectionInfo|null;rtpDiagnostics?:RtpDiagnostics;legacyCapture?:LegacyCaptureCounters|null;portraitSettings?:PortraitFrameStatus[];touchSupport?:number;touchQueryExhausted?:boolean;fileChannelOpen?:boolean;controlOpen?:boolean;echoReceived?:boolean;echoSent?:boolean;videoRequested?:boolean;mediaPackets?:number;accessUnits?:number;inputSent?:number;mediaError?:boolean; offer?:string; candidates?:Object[]; error?:string; iceState?:string;dtlsState?:string;connectionState?:string;answered?:boolean;closed?:boolean;weakReleased?:boolean;tracksObserved?:number;dataChannelsOpen?:number; }
interface EmptyIceConfig {iceServers:string[];}
interface FileDiagnostic {state?:string;error?:string;sentMessages?:number;correlatedAcks?:number;entries?:Object[];}
interface Candidate { candidate:string;sdpMid:string;sdpMLineIndex:number; }
interface Command {op:string;multiVideo?:boolean;renderSlot?:number;videoGeneration?:number;watch?:boolean;filesOnly?:boolean;catalogOnly?:boolean;lockOnly?:boolean;terminalOnly?:boolean;connectId?:string;connectCode?:string;legacy?:boolean;offerDelayMs?:number;text?:string;base64?:string;nowMs?:number;deviceKey?:string;confirmed?:boolean;id?:number;httpStatus?:number;body?:string;sdp?:string;candidate?:Object;config?:Object;event?:Object;viewerWidth?:number;viewerHeight?:number;viewerRefresh?:number;collectDiagnostics?:boolean;}
export interface WindowsUnlockReply {ok?:boolean;available?:boolean;enrolled?:boolean;enabled?:boolean;submissionAllowed?:boolean;reenrollmentRequired?:boolean;reason?:string;error?:string;sent?:boolean;}
class SessionClient {
  multi:MultiVideoClient|undefined=undefined;
  private videoCodecPreference:number=0; private roomCodec:number=0;
  private decoderOverride:number=-1;
  private codecRetrying:boolean=false;private codecRetryCancelled:boolean=false;private codecFallbackAttempted:boolean=false;
  private desktopOfferAt:number=0;
  private harmonyTargetKey:string='';
  private decoderPreference():number{return this.decoderOverride===1||this.isHarmonyTarget()?1:this.videoCodecPreference;}
  private isHarmonyTarget():boolean{return !!this.selected&&this.harmonyTargetKey===this.selected;}
  get separateWindowsAvailable():boolean{return !!this.selected&&this.selected!=='assistance'&&!this.isHarmonyTarget();}

  private primaryClosedWithSibling:boolean=false;
  private endedHiddenRoom:boolean=false;
  takeEndedHiddenRoom():boolean {if(!this.endedHiddenRoom||this.busy||this.closing){return false;}this.endedHiddenRoom=false;return true;}
  setVideoCodecPreference(value:number):void {if(!this.busy&&!this.closing){this.videoCodecPreference=value===0?0:1;}}
  get selectedVideoCodec():number{return this.roomCodec;}
  get hasEstablishedVideo():boolean{return this.busy&&!this.closing&&(this.multi?this.primaryEverFrame:this.legacyEverFrame);}
  private detachedScreens:number[]=[];
  registerDetachedScreen(id:number):void{if(!this.detachedScreens.includes(id)){this.detachedScreens.push(id);}}
  freeRendererSlot():number{const used=this.multi?.snapshot().streams.filter((r)=>r.open&&r.renderSlot!==null).map((r)=>r.renderSlot)||[];return [0,1,2].find((id:number)=>!used.includes(id))??-1;}
  legacyRetryAvailable:boolean=false;private primaryAttached:boolean=true;private multiRequested:boolean=false;private multiLogAt:number=0;private multiOpening:boolean=false;private primaryEverFrame:boolean=false;private legacyEverFrame:boolean=false;private preparedGeneration:number=0;private primarySlot:number=0;private transferredSlot:number=-1;private transferredScreen:number=-1;private primaryScreen:number=-1;private primaryClaiming:boolean=false;
  enableMultiVideo(value:boolean):void {if(!this.busy&&!this.closing&&!this.detailOwner){this.multiRequested=value;}}
  get multiMode():boolean{return this.multi!==undefined;}
  get primaryScreenId():number{return this.primaryScreen;}
  get primarySlotId():number{return this.primarySlot;}
  detachedReleased(screenId:number):void{this.detachedScreens=this.detachedScreens.filter((id:number)=>id!==screenId);if(this.primaryScreen<0){this.primaryAttached=false;}if(this.transferredScreen===screenId){this.transferredScreen=-1;this.transferredSlot=-1;}}
  get primarySurfaceAvailable():boolean{return !!this.surface;}
  private async pollMulti():Promise<void>{
    const multi=this.multi;if(!multi){return;}await multi.poll();const state=multi.snapshot();
    if(state.error){this.lastFailure=state.error;this.legacyRetryAvailable=true;return;}
    if(this.primaryAttached&&this.primaryScreen<0&&state.inventoryReceived&&state.screens.length&&!this.multiOpening&&this.surface){
      const candidates=state.screens.filter((screen)=>!this.detachedScreens.includes(screen.id));const reported=state.currentReported??state.captureReported;const primary=candidates.find((screen)=>screen.id===reported)||candidates.find((screen)=>screen.primary)||candidates[0];
      if(primary){this.primaryScreen=primary.id;this.multiOpening=true;const run=this.epoch;multi.open(primary.id,this.primarySlot,this.surface).catch(()=>{if(run===this.epoch&&this.multi===multi&&!this.closing){this.lastFailure='显示器解码器启动失败';}}).then(()=>{if(run===this.epoch&&this.multi===multi){this.multiOpening=false;}});}
    }
    if(Date.now()-this.multiLogAt>=1000){this.multiLogAt=Date.now();multi.log(state);}
    const stream=state.streams.find((item)=>item.screenId===this.primaryScreen);
    this.firstFrame=!this.multiOpening&&!!stream?.mappingConfirmed&&!!stream?.videoFrameObserved;
    if(stream&&stream.width>0&&stream.height>0){this.frameWidth=stream.width;this.frameHeight=stream.height;}
    if(this.firstFrame){this.primaryEverFrame=true;}
    this.videoText=this.firstFrame?'桌面画面已送显':this.multiOpening?'正在切换显示器，等待新画面':'准备显示画面';
    if(state.inventoryReceived){center.multiDisplay(state.screens,this.primaryScreen,this.firstFrame,stream?.error||'',
      this.firstFrame?stream?.width||0:0,this.firstFrame?stream?.height||0:0);}
    if(this.firstFrame&&!this.multiOpening&&this.windowActive&&this.foreground&&!this.inputPaused&&!this.watch&&!this.primaryClaiming&&!multi.isOwner(this.primaryScreen,'primary')){this.primaryClaiming=true;multi.claim(this.primaryScreen,'primary',()=>this.multi===multi&&this.windowActive&&this.foreground&&!this.inputPaused&&!this.watch&&this.firstFrame).then(()=>{this.primaryClaiming=false;},()=>{this.primaryClaiming=false;});}
  }
  async transferPrimary(surface:string):Promise<boolean>{const multi=this.multi,id=this.primaryScreen,run=this.epoch;if(!multi||id<0||!surface){return false;}this.releaseInputs();this.multiOpening=true;this.firstFrame=false;try{await multi.move(id,this.primarySlot,surface);if(run!==this.epoch||this.multi!==multi||this.closing){return false;}this.primaryScreen=-1;this.transferredScreen=id;this.transferredSlot=this.primarySlot;this.primarySlot=Math.max(0,this.freeRendererSlot());this.primaryAttached=true;this.firstFrame=false;return true;}catch(_){return false;}finally{if(run===this.epoch&&this.multi===multi){this.multiOpening=false;}}}
  async restoreTransferredPrimary(screenId:number):Promise<boolean>{
    const multi=this.multi,run=this.epoch,old=this.primaryScreen,oldSlot=this.primarySlot,detachedSlot=this.transferredSlot,surface=this.surface;
    if(!multi||!surface||this.transferredScreen!==screenId||this.multiOpening){return false;}
    this.releaseInputs();this.multiOpening=true;this.firstFrame=false;this.primaryScreen=-1;
    try{
      if(old>=0){await multi.close(old,oldSlot);}
      if(run!==this.epoch||this.multi!==multi||this.closing){return false;}
      await multi.move(screenId,detachedSlot,surface);
      if(run!==this.epoch||this.multi!==multi||this.closing){return false;}
      this.primaryClosedWithSibling=false;this.primarySlot=detachedSlot;this.transferredSlot=-1;this.transferredScreen=-1;this.primaryScreen=screenId;this.primaryAttached=true;return true;
    }catch(_){
      if(old>=0&&run===this.epoch&&this.multi===multi&&!this.closing){try{await multi.open(old,oldSlot,surface);if(run===this.epoch&&this.multi===multi&&!this.closing){this.primaryScreen=old;}}catch(_){this.lastFailure='显示器恢复失败，请断开后重试';}}
      return false;
    }finally{if(run===this.epoch&&this.multi===multi){this.multiOpening=false;}}
  }
  disconnectAllWindows():Promise<void>{this.primaryClosedWithSibling=true;return this.cancel('user_disconnect');}
  async closeMultiPrimary():Promise<void>{this.primaryClosedWithSibling=true;this.primaryAttached=false;const multi=this.multi,id=this.primaryScreen;if(!multi||id<0){return;}this.releaseInputs();this.primaryScreen=-1;this.firstFrame=false;try{await multi.close(id,this.primarySlot);}catch(_){} }
  async switchMultiPrimary(screenId:number):Promise<boolean>{
    const multi=this.multi,old=this.primaryScreen,surface=this.surface,run=this.epoch,slot=old<0?this.freeRendererSlot():this.primarySlot;if(!multi||!surface||slot<0||screenId===old||this.detachedScreens.includes(screenId)||!multi.snapshot().screens.some((row)=>row.id===screenId)){return false;}
    this.releaseInputs();this.firstFrame=false;this.multiOpening=true;this.primaryScreen=-1;this.show('正在切换显示器，等待新画面');
    try{if(old>=0){await multi.close(old,slot);}if(run!==this.epoch||this.multi!==multi||this.closing){return false;}await multi.open(screenId,slot,surface);if(run!==this.epoch||this.multi!==multi||this.closing){return false;}this.primaryScreen=screenId;this.primarySlot=slot;this.primaryAttached=true;return true;}
    catch(_){if(run!==this.epoch||this.multi!==multi||this.closing){return false;}try{if(old<0){return false;}await multi.open(old,slot,surface);if(run!==this.epoch||this.multi!==multi||this.closing){return false;}this.primaryScreen=old;if(this.lastFailure==='多屏协商未完成，可选择单窗口重试'){this.lastFailure='';this.legacyRetryAvailable=false;}}catch(_){if(run===this.epoch&&this.multi===multi&&!this.closing){this.lastFailure='显示器恢复失败，请断开后重试';}}return false;}finally{if(run===this.epoch&&this.multi===multi){this.multiOpening=false;}}
  }
  private unlockPending:boolean=false;
  private unlockAttemptEpoch:number=-1;
  windowsUnlockAllowed():boolean{return this.foreground&&this.windowActive&&this.busy&&!this.closing&&this.controlOpen&&this.controlEcho&&!this.watch&&!this.filesOnly&&!this.catalogOnly&&!this.lockOnly&&!this.terminalOnly&&!this.detailOwner&&this.selected.length>0&&this.selected!=='assistance';}
  async privacyWallpaperRequest(action:string,selectedType:string='',presetId:string=''):Promise<string>{
    if(!this.windowsUnlockAllowed()){return '{"error":"owned_desktop_required"}';}
    const run=this.epoch;const key=this.selected;let result='{"error":"session_changed"}';
    const command:PrivacyWallpaperCommand={op:'privacy_wallpaper_request',deviceKey:key,action:action,selectedType:selectedType,presetId:presetId};
    this.chain=this.chain.then(async()=>{if(run===this.epoch&&key===this.selected&&this.windowsUnlockAllowed()){result=await invoke(JSON.stringify(command));}}).catch(()=>{});
    await this.chain;return run===this.epoch&&key===this.selected?result:'{"error":"session_changed"}';
  }
  async windowsUnlock(action:string,password:string=''):Promise<WindowsUnlockReply>{
    if(!this.windowsUnlockAllowed()||this.unlockPending){return {error:'session_unavailable'};}
    const run=this.epoch;const key=this.selected;this.unlockPending=true;
    let result:WindowsUnlockReply={error:'session_changed'};
    this.chain=this.chain.then(async()=>{
      if(run!==this.epoch||key!==this.selected||!this.windowsUnlockAllowed()){return;}
      if(action==='use'){if(this.unlockAttemptEpoch===run){result={error:'already_attempted'};return;}this.unlockAttemptEpoch=run;}
      const raw=action==='status'?await windowsUnlockStatus():action==='enroll'?await windowsUnlockEnroll(password):action==='enable'?await windowsUnlockSetEnabled(true):action==='disable'?await windowsUnlockSetEnabled(false):action==='delete'?await windowsUnlockDelete():action==='use'?await windowsUnlockUse():'{"error":"invalid_action"}';
      if(run===this.epoch&&key===this.selected&&this.windowsUnlockAllowed()){result=JSON.parse(raw) as WindowsUnlockReply;}
    }).catch(()=>{result={error:'secure_storage_or_bridge_unavailable'};});
    try{await this.chain;return result;}finally{password='';this.unlockPending=false;}
  }

  filesOnly:boolean=false;catalogOnly:boolean=false;lockOnly:boolean=false;terminalOnly:boolean=false;
  async joinTerminalConfirmed(deviceKey:string):Promise<void>{if(this.busy||this.closing||this.detailOwner||!this.foreground||!this.windowActive||deviceKey!==this.selected){return;}this.terminalOnly=true;await this.joinConfirmed(deviceKey);}
  async joinCatalogConfirmed(deviceKey:string):Promise<void>{if(this.busy||this.closing||this.detailOwner||!this.foreground||deviceKey!==this.selected){return;}this.catalogOnly=true;await this.joinConfirmed(deviceKey);}
  async catalogCommand(command:AdvancedCommand):Promise<string>{if(this.filesOnly||this.detailOwner||this.watch||command.op!=='peer_catalog'||!this.foreground||!this.windowActive||!this.busy||this.closing||!this.controlOpen){return '{"error":"catalog_session_required"}';}const run=this.epoch;let result='{"error":"session_changed"}';this.chain=this.chain.then(async()=>{if(run===this.epoch&&!this.filesOnly&&!this.detailOwner&&!this.watch&&this.foreground&&this.windowActive&&!this.closing){result=await invoke(JSON.stringify(command));}}).catch(()=>{});await this.chain;return result;}
  async joinFilesConfirmed(deviceKey:string):Promise<void>{if(this.busy||this.closing||this.detailOwner||!this.foreground||deviceKey!==this.selected){return;}this.filesOnly=true;await this.joinConfirmed(deviceKey);}
  private fileDiagnostic:string='';
  async filesCommand(command:AdvancedCommand):Promise<string>{if(!this.filesOnly||!['peer_files_prepare','peer_files_status','peer_files_read'].includes(command.op)){return '{"error":"files_session_required"}';}const raw=await this.advancedCommand(command);if(command.op!=='peer_files_read'){try{const state=JSON.parse(raw) as FileDiagnostic;const summary='state='+(state.state||'')+' error='+(state.error||'')+' sent='+(state.sentMessages||0)+' acks='+(state.correlatedAcks||0)+' entries='+(state.entries?.length||0);if(summary!==this.fileDiagnostic){this.fileDiagnostic=summary;hilog.info(0x0303,'UUFiles','%{public}s',summary);}}catch(_){}}return raw;}
  private viewerWidth:number=0;private viewerHeight:number=0;private viewerRefresh:number=0;
  setViewerDisplay(width:number,height:number,refresh:number):void{this.viewerWidth=Math.floor(width);this.viewerHeight=Math.floor(height);this.viewerRefresh=Math.max(1,Math.round(refresh));}
  private detailOwner:number=0;private detailSerial:number=0;private detailLock:boolean=false;
  get detailSessionActive():boolean{return this.detailOwner!==0;}
  acquireDetailSession(lock:boolean):number{if(this.detailOwner||this.busy||this.closing){return 0;}this.detailOwner=++this.detailSerial;this.detailLock=lock;this.watch=true;this.inputPaused=true;this.notifyState();return this.detailOwner;}
  ownsDetailSession(owner:number):boolean{return owner>0&&this.detailOwner===owner;}
  async selectDetailDevice(owner:number,key:string,name:string):Promise<boolean>{if(!this.ownsDetailSession(owner)||this.busy||this.closing){return false;}const r=await this.command({op:'select_device',deviceKey:key});if(!this.ownsDetailSession(owner)||!r.selectionValid){return false;}this.selected=key;this.harmonyTargetKey=r.harmonyHost===true?key:'';this.deviceName=name;return true;}
  detailSurface(owner:number,id:string,width:number,height:number):void{if(this.ownsDetailSession(owner)){this.setSurface(id);this.setViewport(width,height);}}
  clearDetailSurface(owner:number,id:string):void{if(this.ownsDetailSession(owner)){this.surfaceDestroyed(id);}}
  async cancelDetailSession(owner:number):Promise<void>{if(this.ownsDetailSession(owner)&&(this.busy||this.closing||this.selected.length>0)){await this.cancel('user_cancel');}}
  async releaseDetailSession(owner:number):Promise<void>{if(!this.ownsDetailSession(owner)){return;}await this.cancelDetailSession(owner);if(this.ownsDetailSession(owner)){this.detailOwner=0;this.detailLock=false;this.watch=false;this.inputPaused=false;this.notifyState();}}
  async joinDetailLockConfirmed(owner:number,key:string):Promise<void>{if(!this.ownsDetailSession(owner)||!this.detailLock||this.busy||this.closing||!this.foreground||!this.windowActive||this.selected!==key){return;}this.lockOnly=true;await this.joinConfirmed(key);}
  private detailSettingAllowed(request:SettingRequest):boolean{return !this.detailOwner||(request.kind==='watch'&&request.enabled===true)||(this.detailLock&&request.kind==='lock_now'&&request.confirmed===true);}
  private advancedPending:number=0;
  private foreground:boolean=true;
  private windowActive:boolean=true;
  get windowFocused():boolean{return this.windowActive;}
  setWindowActive(value:boolean):void{
    if(value&&!this.foreground){return;}
    this.windowActive=value;if(value){return;}deviceLockRequest.cancel();this.releaseInputs();
    if(this.terminalOnly){this.show('窗口失焦：终端输入已暂停，会话仍保留。');return;}
    if(this.busy&&!this.closing&&this.peer){const run=this.epoch;const restore:Command={op:'peer_restore_privacy'};const event:TerminalCommand={action:'detach_selected'};const close:Command={op:'peer_terminal',event:event};this.chain=this.chain.then(async()=>{if(run!==this.epoch||!this.peer||this.closing){return;}await invoke(JSON.stringify(restore));await invoke(JSON.stringify(close));}).catch(()=>{});}
    this.show('窗口失焦：已撤销待执行锁屏，并请求恢复防窥与关闭终端。');
  }

  setForeground(value:boolean,activateWindow:boolean=true):void{this.foreground=value;if(!value||activateWindow){this.setWindowActive(value);}if(!value){try{micNative.stop();}catch(_){}const microphoneEvent:ClipboardEvent={action:'stop'};const microphone:AdvancedCommand={op:'peer_microphone',event:microphoneEvent};this.advancedCommand(microphone);try{audioStop();}catch(_){}if(this.peer){const event:ClipboardEvent={action:'disable'};const command:AdvancedCommand={op:'peer_clipboard',event:event};this.advancedCommand(command);}}}
  private advancedAllowed(command:AdvancedCommand):boolean {if(this.foreground){return true;}return (command.op==='peer_microphone'&&command.event!==undefined&&(command.event as ClipboardEvent).action==='stop')||command.op==='peer_clipboard'&&command.event!==undefined&&(command.event as ClipboardEvent).action==='disable';}
  async advancedCommand(command:AdvancedCommand):Promise<string>{
    if(this.detailOwner||!this.advancedAllowed(command)||!this.busy||this.closing||!this.controlOpen){return '{"error":"active_foreground_session_required"}';}
    if(!['peer_advanced','peer_clipboard','peer_files_prepare','peer_files_status','peer_files_read','peer_microphone'].includes(command.op)){return '{"error":"advanced_operation_not_allowed"}';}
    if(this.advancedPending>=8){return '{"error":"advanced_queue_limit"}';}this.advancedPending++;
    const switching=command.op==='peer_advanced'&&command.event!==undefined&&(command.event as DisplayAction).action==='switch_screen';
    const previousBlock=this.displayBlocked;if(switching){this.displayBlocked=true;this.releaseInputs();}
    const run=this.epoch;let result:string='{"error":"session_changed"}';this.chain=this.chain.then(async()=>{if(run!==this.epoch||this.closing||!this.peer||this.detailOwner||!this.advancedAllowed(command)){return;}result=await invoke(JSON.stringify(command));if(switching){const state=JSON.parse(result) as DisplayState;if(state.displayEpoch!==undefined){this.displayState(state);}else{this.displayBlocked=previousBlock;}}}).catch(()=>{result='{"error":"advanced_bridge_failed"}';});await this.chain;this.advancedPending=Math.max(0,this.advancedPending-1);return result;
  }
  private terminalPending:boolean=false;
  async terminalCommand(event:TerminalCommand,closing:boolean=false,current:()=>boolean=()=>true):Promise<string>{
    const terminalAction=event.action;const cleanup=closing&&(terminalAction==='close'||terminalAction==='detach_selected'||terminalAction==='detach');
    if(!current()||((!this.foreground||!this.windowActive||this.watch||this.detailOwner!==0)&&!cleanup)||!this.busy||this.closing||!this.controlOpen||(this.terminalPending&&!cleanup)){return '{"error":"terminal_session_unavailable"}';}
    const command:Command={op:'peer_terminal',event:event};
    const run=this.epoch;this.terminalPending=true;let result='{"error":"session_changed"}';
    this.chain=this.chain.then(async()=>{if(run!==this.epoch||!current()||!this.busy||this.closing||((!this.foreground||!this.windowActive||this.watch||this.detailOwner!==0)&&!cleanup)){return;}result=await invoke(JSON.stringify(command));}).catch(()=>{result='{"error":"terminal_bridge_failed"}';});
    try{await this.chain;return result;}finally{this.terminalPending=false;}
  }
  watch:boolean=false;inputPaused:boolean=false;displayBlocked:boolean=false;displayText:string='';private displayEpoch:number=0;private metricsAt:number=0;
  private displayState(state:DisplayState):void{if(state.displayEpoch!==this.displayEpoch){this.displayEpoch=state.displayEpoch;this.pendingPointer=undefined;this.inputGeneration++;this.resetInputObservers();}this.displayBlocked=state.inputBlocked;this.displayText=displayStatus(state);}
  pauseInput(value:boolean):void{this.inputPaused=value;if(value){this.releaseInputs();}}
  async setting(request:SettingRequest):Promise<string>{
    if(this.multi&&['resolution','quality','fps'].includes(request.kind)){return '{"error":"multi_screen_setting_unavailable"}';}
    if(this.filesOnly||this.catalogOnly||!this.detailSettingAllowed(request)){return '{"error":"detail_read_only_session"}';}
    if(!this.busy||!this.controlOpen||this.closing){return JSON.stringify({error:"control_not_open"});}
    if(["lock_now","reboot","shutdown","privacy"].includes(request.kind)&&(!this.foreground||!this.windowActive)){return '{"error":"active_foreground_session_required"}';}
    const run=this.epoch;if(request.kind==='watch'&&request.enabled){try{micNative.stop();}catch(_){}this.watch=true;this.releaseInputs();}
    const resolution=request.kind==='resolution';const previousBlock=this.displayBlocked;if(resolution){this.displayBlocked=true;this.releaseInputs();}
    let reply:string='{"error":"session_changed"}';
    this.chain=this.chain.then(async()=>{
      if(run!==this.epoch||!this.busy||this.closing||!this.detailSettingAllowed(request)||(["lock_now","reboot","shutdown","privacy"].includes(request.kind)&&(!this.foreground||!this.windowActive))){return;}
      reply=await invoke(JSON.stringify({op:"peer_setting",event:request}));
      if(run!==this.epoch||this.closing){reply='{"error":"session_changed"}';return;}
      const p=JSON.parse(reply) as SettingReply;
      if(resolution){if(p.display){this.displayState(p.display);}else if(!p.sent){this.displayBlocked=previousBlock;}}
      if(request.kind==='watch'&&p.localApplied){this.watch=!!p.watch;}
      hilog.info(0x0303,'UUS5','setting sent=%{public}d local=%{public}d',p.sent?1:0,p.localApplied?1:0);
    }).catch(()=>{reply='{"error":"setting_bridge_failed"}';});
    await this.chain;return reply;
  }
  private portraitStatus:PortraitFrameStatus[]=[];private lastFrameDiagnostic:string='';private lastReportDiagnostic:string='';private lastConfigDiagnostic:string='';private lastCaptureDiagnostic:string='';private lastRtpDiagnosticAt:number=0;private latestDisplay:DisplayState|undefined=undefined;
  private async readMetrics(run:number=this.epoch):Promise<void>{
    if(Date.now()-this.metricsAt<(this.displayBlocked?200:1000)||!this.peer||this.closing){return;}
    this.metricsAt=Date.now();
    const p=JSON.parse(await invoke(JSON.stringify({op:'peer_metrics'}))) as NetworkSample;
    if(run!==this.epoch){return;}
    const multi=this.multi;
    let v=JSON.parse(videoMetrics()) as DecoderSample;
    if(multi){
      const stream=multi.snapshot().streams.find((row)=>row.screenId===this.primaryScreen);
      if(stream&&stream.renderSlot!==null&&stream.generation!==null){
        v=JSON.parse(videoSlotMetrics(stream.renderSlot,stream.generation)) as DecoderSample;
      }
    }else{
      p.inputQueueMs=this.inputQueueMs;p.coalescedPointer=this.coalescedPointer;
      if(p.display){
        const setting=this.portraitStatus.find((item:PortraitFrameStatus)=>item.screenId===p.display?.selectedScreen);
        if(setting?.withinBudget!==undefined&&setting.withinBudget!==null){p.display.streamWithinBudget=setting.withinBudget;}
        p.display.streamFrameReceived=(v.rendered||0)>0&&v.renderedEpoch===p.display.displayEpoch&&v.videoEpoch===p.display.displayEpoch&&(v.width||0)>0&&(v.height||0)>0;
        this.latestDisplay=p.display;
        if(v.renderedEpoch===p.display.displayEpoch&&(v.width||0)>0&&(v.height||0)>0){
          this.frameWidth=v.width||this.frameWidth;this.frameHeight=v.height||this.frameHeight;this.displayState(p.display);
        }else{this.displayState(p.display);if(p.display.changeKind){this.displayBlocked=true;}}
      }
    }
    center.sample(p,v,this.frameWidth,this.frameHeight,!!multi);
    hilog.info(0x0303,'UUS5','metrics=%{public}s',JSON.stringify(p));
    hilog.info(0x0303,'UUS5','decoded_sample=%{public}s',JSON.stringify(v));
  }

  text:string='请选择自有 Windows 设备'; offlinePassed:boolean=true; selected:string=''; busy:boolean=false; offerDelayMs:number=0;
  connectionPhase:string='idle';lastConnectionSummary:string='';
  get generation():number{return this.epoch;}
  get appForeground():boolean{return this.foreground;}
  private fileChannelOpen:boolean=false;
  get filesReady():boolean{return this.controlOpen&&this.fileChannelOpen&&this.controlEcho;}
  controlEcho:boolean=false; touchSupport:number=0;
  controlOpen:boolean=false; videoText:string='桌面尚未连接';deviceName:string='';firstFrame:boolean=false;lastFailure:string='';diagnostic:string='尚无会话'; frameWidth:number=1280; frameHeight:number=720;
  private surface:string=''; private surfaceWidth:number=0;private surfaceHeight:number=0;private surfaceVersion:number=0;
  private videoTask:Promise<string>|undefined=undefined; private videoSettled:boolean=true;private closing:boolean=false; private lastHeartbeat:number=0; private lastSignalJson:string='';private preparingFailure:string='';
  setSurface(id:string):void {if(this.surface!==id){this.surfaceVersion++;}this.surface=id;hilog.info(0x0303,'UUP0','surface_ready=%{public}d',id.length>0?1:0);}
  setViewport(width:number,height:number):void {this.surfaceWidth=width;this.surfaceHeight=height;}
  clearPrimarySurface(id:string):void {if(this.surface===id){this.surface='';this.surfaceVersion++;this.primaryAttached=false;}}
  surfaceDestroyed(id:string):void {if(id!==this.surface){return;}this.surface='';this.surfaceVersion++;hilog.info(0x0303,'UUP0','surface_destroyed active=%{public}d',this.busy?1:0);if(this.busy&&!this.closing){hardStopVideo();this.cancel('surface_destroyed');}}
  get isClosing():boolean{return this.closing;}
  private videoFailure(v:VideoState,fallback:string):string{return 'video/'+(v.failureStage||v.phase||fallback)+' code='+(v.systemCode!==undefined&&v.systemCode!==null?v.systemCode:(v.error||0))+' kind='+(v.failureKind||'local');}
  private readVideo():VideoState {
    const v=JSON.parse(videoStatus()) as VideoState;
    if((v.width||0)>0){this.frameWidth=v.width||1280;this.frameHeight=v.height||720;}
    const metrics=JSON.parse(videoMetrics()) as DecoderSample;
    this.firstFrame=!v.released&&!v.error&&(!!v.ready||!!v.running)&&currentFrameReady(metrics.rendered||0,metrics.renderedEpoch,metrics.videoEpoch,this.displayEpoch,metrics.width||0,metrics.height||0,this.displayBlocked);
    if(this.firstFrame){this.frameWidth=metrics.width||this.frameWidth;this.frameHeight=metrics.height||this.frameHeight;}
    if(this.firstFrame&&this.busy&&this.peer&&this.answered){this.legacyEverFrame=true;}
    this.videoText=this.firstFrame?'桌面画面已送显':v.ready?'解码器就绪，等待远端画面':'准备显示画面';
    this.diagnostic='videoPhase='+(v.phase||'unknown')+' codec='+(v.codecName||'unknown')+' hardware='+(v.hardware===undefined?'unknown':v.hardware)+' submitted='+(v.submitted||0)+' decoded='+(v.decoded||0)+' rendered='+(v.rendered||0)+' SPS='+!!v.firstSps+' PPS='+!!v.firstPps+' IDR='+!!v.firstIdr+' size='+this.frameWidth+'x'+this.frameHeight+(v.failureStage?' firstFailure='+this.videoFailure(v,'native'):'');return v;
  }
  private initialFrameTimedOut():boolean {
    return !this.filesOnly&&!this.catalogOnly&&!this.lockOnly&&!this.terminalOnly&&!this.multi&&this.answered&&!this.legacyEverFrame&&Date.now()-this.answerAt>20000;
  }
  private async prepareVideo(run:number):Promise<boolean>{
    if(this.multi){const multi=this.multi;const until=Date.now()+5000;while(run===this.epoch&&(!this.surface||this.surfaceWidth<=0||this.surfaceHeight<=0)&&Date.now()<until){await new Promise<void>((resolve:()=>void)=>setTimeout(resolve,30));}if(run!==this.epoch){return false;}if(!this.surface||this.surfaceWidth<=0||this.surfaceHeight<=0){this.preparingFailure='video/surface_ready_timeout';return false;}const surface=this.surface,version=this.surfaceVersion;try{const generation=await multi.preparePrimary(surface,this.decoderPreference());if(run!==this.epoch||this.multi!==multi||version!==this.surfaceVersion||surface!==this.surface||!generation){await multi.dispose();this.preparingFailure='video/surface_generation_changed';return false;}this.preparedGeneration=generation;this.roomCodec=multi.actualCodec;return true;}catch(_){await multi.dispose();this.preparingFailure='video/primary_renderer_prepare_failed';return false;}}
    this.preparingFailure='';this.firstFrame=false;const previous=JSON.parse(videoStatus()) as VideoState;if(previous.reusable===false&&previous.phase==='cleanup_failed'){this.preparingFailure='video/cleanup_failed_restart_required code=-105 kind=local';return false;}if(!this.videoSettled){this.preparingFailure='video/previous_cleanup_pending code=-104 kind=local';return false;}this.show('正在等待远程桌面显示区域');
    const surfaceDeadline=Date.now()+5000;
    while(run===this.epoch&&(!this.surface||this.surfaceWidth<=0||this.surfaceHeight<=0)&&Date.now()<surfaceDeadline){await new Promise<void>((resolve:()=>void)=>setTimeout(resolve,30));}
    if(run!==this.epoch){return false;}
    if(!this.surface||this.surfaceWidth<=0||this.surfaceHeight<=0){this.preparingFailure='video/surface_ready_timeout code=-100 kind=local';return false;}
    const version=this.surfaceVersion;this.videoSettled=false;
    try{this.videoTask=startVideo(this.surface,this.decoderPreference()).then((raw:string)=>{this.videoSettled=true;const state=JSON.parse(raw) as VideoState;hilog.info(0x0303,'UUP0','video_release phase=%{public}s error=%{public}d first_failure=%{public}s code=%{public}d',state.phase||'released',state.error||0,state.failureStage||'none',state.systemCode||0);return raw;}).catch(()=>{this.videoSettled=true;return '{"error":-101,"failureStage":"napi_worker","failureKind":"local"}';});}
    catch(_){this.videoSettled=true;this.preparingFailure='video/napi_start code=-101 kind=local';return false;}
    const until=Date.now()+10000;
    while(run===this.epoch&&Date.now()<until){
      if(version!==this.surfaceVersion){this.preparingFailure='video/surface_generation_changed code=-102 kind=local';return false;}
      const v=this.readVideo();if(v.error||v.released){this.preparingFailure=this.videoFailure(v,'native_released');return false;}if(v.ready){if(v.codec!==1&&v.codec!==2){this.preparingFailure='video/codec_unconfirmed';return false;}this.roomCodec=v.codec;return true;}
      await new Promise<void>((resolve:()=>void)=>setTimeout(resolve,40));
    }
    if(run===this.epoch){const v=this.readVideo();this.preparingFailure=this.videoFailure(v,'initialize_timeout')+' deadline=10s';}return false;
  }
  private logDisplayFrame():void {
    const display=this.latestDisplay;if(!display){return;}
    const report=display.reportError;const reportKey=report?[report.action,report.errorCode,report.typeValue].join('/'):'none';
    if(reportKey!==this.lastReportDiagnostic){this.lastReportDiagnostic=reportKey;if(report){hilog.info(0x0303,'UUDisplayFrame','kind=1 action=%{public}d errorCode=%{public}d type=%{public}d actionKnown=%{public}d codeKnown=%{public}d typeKnown=%{public}d',report.action??-1,report.errorCode??-1,report.typeValue??-1,report.action===null||report.action===undefined?0:1,report.errorCode===null||report.errorCode===undefined?0:1,report.typeValue===null||report.typeValue===undefined?0:1);}}
    const config=display.captureConfigResponse;const configKey=config?[config.requestSeq,config.configFlag,config.errorCode].join('/'):'none';
    if(configKey!==this.lastConfigDiagnostic){this.lastConfigDiagnostic=configKey;if(config){hilog.info(0x0303,'UUDisplayFrame','kind=2 seq=%{public}d flag=%{public}d errorCode=%{public}d seqKnown=%{public}d flagKnown=%{public}d codeKnown=%{public}d',config.requestSeq??-1,config.configFlag??-1,config.errorCode??-1,config.requestSeq===null||config.requestSeq===undefined?0:1,config.configFlag===null||config.configFlag===undefined?0:1,config.errorCode===null||config.errorCode===undefined?0:1);}}
    const metrics=JSON.parse(videoMetrics()) as DecoderSample;
    const setting=this.portraitStatus.find((item:PortraitFrameStatus)=>item.screenId===display.selectedScreen);
    const ack=setting?.ack===true?1:setting?.ack===false?0:-1;const compatible=display.streamFrameCompatible?1:0;
    const error=display.displayError||setting?.error?1:0;const exact=display.resolutionMatched?1:0;
    const key=[display.displayEpoch,metrics.videoEpoch||0,metrics.renderedEpoch||0,setting?.seq||0,ack,setting?.sent?1:0,compatible,error,exact,metrics.width||0,metrics.height||0,setting?.withinBudget===true?1:setting?.withinBudget===false?0:-1].join('/');
    if(key===this.lastFrameDiagnostic){return;}this.lastFrameDiagnostic=key;
    hilog.info(0x0303,'UUDisplayFrame','epoch=%{public}d videoEpoch=%{public}d renderedEpoch=%{public}d screen=%{public}d seq=%{public}d sent=%{public}d ack=%{public}d compatible=%{public}d exact=%{public}d budget=%{public}d error=%{public}d width=%{public}d height=%{public}d decoded=%{public}d rendered=%{public}d',display.displayEpoch,metrics.videoEpoch||0,metrics.renderedEpoch||0,display.selectedScreen===undefined||display.selectedScreen===null?-1:display.selectedScreen,setting?.seq||0,setting?.sent?1:0,ack,compatible,exact,setting?.withinBudget===true?1:setting?.withinBudget===false?0:-1,error,metrics.width||0,metrics.height||0,metrics.decoded||0,metrics.rendered||0);
  }
  private logLegacyCapture(c:LegacyCaptureCounters|null|undefined):void {
    if(!c){return;}
    const key=[c.epoch,c.packets>0,c.padding>0,c.payloadBytes>0,c.completeAus>0,c.accepted>0,c.queueRejected>0,c.noPicture>0,c.profileRejected>0,c.timestampRejected>0,c.oversizeRejected>0,c.otherNalRejected>0,c.metadataRejected>0,c.reassemblyPli>0].join('/');
    if(key===this.lastCaptureDiagnostic){return;}this.lastCaptureDiagnostic=key;
    hilog.info(0x0303,'UUDisplayFrame','kind=3 epoch=%{public}d packets=%{public}d padding=%{public}d payloadBytes=%{public}d completeAu=%{public}d accepted=%{public}d rejected=%{public}d',c.epoch,c.packets,c.padding,c.payloadBytes,c.completeAus,c.accepted,c.queueRejected);
    hilog.info(0x0303,'UUDisplayFrame','kind=4 epoch=%{public}d noPicture=%{public}d profile=%{public}d timestamp=%{public}d oversize=%{public}d otherNal=%{public}d metadata=%{public}d pli=%{public}d',c.epoch,c.noPicture,c.profileRejected,c.timestampRejected,c.oversizeRejected,c.otherNalRejected,c.metadataRejected,c.reassemblyPli);
  }
  private inputPending:number=0; private inputGeneration:number=0;
  private pendingPointer:PendingPointer|undefined=undefined;
  private inputQueueMs:number|undefined=undefined;private coalescedPointer:number=0;
  sendInput(events:RemoteInput[]):boolean {
    if(this.multi){return !this.multiOpening&&this.foreground&&this.windowActive&&!this.watch&&!this.inputPaused&&this.controlOpen&&this.firstFrame&&this.multi.send(this.primaryScreen,'primary',events);}
    if(this.filesOnly||this.catalogOnly||this.lockOnly||this.terminalOnly||this.detailOwner!==0||!this.foreground||!this.windowActive||this.watch||this.inputPaused||this.displayBlocked||!this.firstFrame||!this.controlOpen||!this.busy||this.closing||events.length===0||events.length>256){return false;}
    const absolute=events.length===1&&events[0].action==='mouse_move_absolute';
    const arrivedAt=Date.now();
    if(absolute&&this.pendingPointer){
      this.pendingPointer.event=events[0];this.pendingPointer.arrivedAt=arrivedAt;
      this.coalescedPointer++;return true;
    }
    if(this.inputPending>=64){if(!absolute){this.cancel('input_queue_limit');}return false;}
    const pointer:PendingPointer|undefined=absolute?{event:events[0],arrivedAt:arrivedAt}:undefined;
    this.pendingPointer=pointer;
    const run=this.epoch;const generation=this.inputGeneration;this.inputPending++;
    this.chain=this.chain.then(async()=>{try{
      if(pointer&&this.pendingPointer===pointer){this.pendingPointer=undefined;}
      const batch=pointer?[pointer.event]:events;
      for(const e of batch){if(run!==this.epoch||generation!==this.inputGeneration||this.detailOwner!==0||!this.foreground||!this.windowActive||this.watch||this.inputPaused||this.displayBlocked||!this.controlOpen||this.closing){return;}
        this.inputQueueMs=Math.max(0,Date.now()-(pointer?.arrivedAt??arrivedAt));
        const p=await this.peerCommand({op:'peer_input',event:e});
        if(p.error==='display_change_input_blocked'){this.displayBlocked=true;this.pendingPointer=undefined;this.inputGeneration++;this.resetInputObservers();return;}
        if(p.error){this.show('输入发送失败：'+p.error);await this.cancel('input_send_failure');return;}
        if(e.action){hilog.info(0x0303,'UUS5','input action=%{public}s sent=%{public}d',e.action,p.inputSent||0);}
      }
    }finally{this.inputPending--;}}).catch(()=>{this.cancel('input_failure');});return true;
  }
  private tabletMove:TabletEvent|undefined=undefined; private tabletTimer:number=-1; private tabletIds:string='';
  private discardTabletMove():void {if(this.tabletTimer>=0){clearTimeout(this.tabletTimer);this.tabletTimer=-1;}this.tabletMove=undefined;this.tabletIds='';}
  private flushTabletMove():boolean {if(this.tabletTimer>=0){clearTimeout(this.tabletTimer);this.tabletTimer=-1;}const event=this.tabletMove;this.tabletMove=undefined;if(event===undefined){return true;}return this.queueTablet(event);}
  sendTablet(event:TabletEvent):boolean {
    if(event.type===2){const ids=event.points.map((p:TabletPoint)=>p.id).join(',');if(this.tabletIds!==ids){if(!this.flushTabletMove()){return false;}this.tabletIds=ids;return this.queueTablet(event);}this.tabletMove=event;if(this.tabletTimer<0){this.tabletTimer=setTimeout(()=>{this.tabletTimer=-1;if(!this.flushTabletMove()){this.cancel('touch_send_failure');}},16);}return true;}
    if(!this.flushTabletMove()){return false;}this.tabletIds=event.type===1?event.points.map((p:TabletPoint)=>p.id).join(','):'';return this.queueTablet(event);
  }
  private queueTablet(event:TabletEvent):boolean {
    if(this.touchSupport!==2||this.filesOnly||this.catalogOnly||this.lockOnly||this.terminalOnly||this.detailOwner!==0||!this.foreground||!this.windowActive||this.watch||this.inputPaused||this.displayBlocked||!this.firstFrame||!this.controlOpen||!this.busy||this.closing||this.inputPending>=64){return false;}
    const run=this.epoch;const generation=this.inputGeneration;this.inputPending++;
    const names:string[]=['','start','move','end','cancel'];
    const payload:TabletWireEvent={type:names[event.type],points:event.points};
    this.chain=this.chain.then(async()=>{try{if(run!==this.epoch||generation!==this.inputGeneration||this.inputPaused||this.watch||this.displayBlocked||this.closing){return;}const result=await this.peerCommand({op:'peer_touch',event:payload});if(result.error){await this.cancel('touch_send_failure');}}finally{this.inputPending--;}}).catch(()=>{this.cancel('touch_send_failure');});return true;
  }
  private inputResetSerial:number=0;
  private inputResets:Map<number,()=>void>=new Map();
  observeInputReset(fn:()=>void):()=>void {const id=++this.inputResetSerial;this.inputResets.set(id,fn);return ()=>{this.inputResets.delete(id);};}
  private resetInputObservers():void {this.inputResets.forEach((fn:()=>void)=>{try{fn();}catch(_){}});}
  releaseInputs():void {
    this.discardTabletMove();this.pendingPointer=undefined;this.resetInputObservers();this.inputGeneration++;
    if(this.multi){this.multi.revoke('primary').catch(()=>{});return;}
    if(!this.peer){return;}const run=this.epoch;
    this.chain=this.chain.then(async()=>{if(run!==this.epoch||!this.peer){return;}const p=await this.peerCommand({op:'peer_release_all'});hilog.info(0x0303,'UUS5','input_release=%{public}s',JSON.stringify(p));if(p.error){await this.cancel('input_release_failure');}}).catch(()=>{this.cancel('release_failure');});
  }
  private ws:webSocket.WebSocket|undefined=undefined;
  private request:http.HttpRequest|undefined=undefined;
  private timer:number=-1; private epoch:number=0; private pending:number=0;
  private chain:Promise<void>=Promise.resolve(); private observerSerial:number=0; private observers:Map<number,(s:string)=>void>=new Map();
  private offline:boolean=false;private peer:boolean=false;private answerAt:number=0;private began:number=0;
  private localCandidates:number=0;private remoteCandidates:number=0;private answered:boolean=false;private lastPeer:string='';
  private closeWait:(()=>void)|undefined=undefined;private closeObserved:boolean=false;
  private stateMonitors:Set<(blocked:boolean)=>void>=new Set<(blocked:boolean)=>void>();
  monitorState(fn:(blocked:boolean)=>void):()=>void{this.stateMonitors.add(fn);fn(this.busy||this.closing||this.detailOwner!==0);return ()=>{this.stateMonitors.delete(fn);};}
  private notifyState():void{if(this.codecRetrying){return;}const blocked=this.busy||this.closing||this.detailOwner!==0;this.stateMonitors.forEach((fn:(value:boolean)=>void)=>fn(blocked));}
  observe(fn:(s:string)=>void):()=>void {const id=++this.observerSerial;this.observers.set(id,fn);fn(this.text);return ()=>{this.observers.delete(id);};}
  private pollingRun:number=-1;
  private lastSignal:string='';
  private show(s:string):void {if(this.codecRetrying){this.text=s;return;}this.notifyState();const changed=s!==this.lastSignal;this.lastSignal=s;this.text=s;this.observers.forEach((fn:(value:string)=>void)=>{try{fn(s);}catch(_){}});if(changed){hilog.info(0x0303,'UUS5','signal_status=%{public}s',s);}}
  private async command(c:Command):Promise<Reply> {c.nowMs=Date.now();return JSON.parse(await invoke(JSON.stringify(c))) as Reply;}
  private async peerCommand(c:Command):Promise<PeerReply> {return JSON.parse(await invoke(JSON.stringify(c))) as PeerReply;}
  private enqueue(c:Command,run:number):void {
    if(run!==this.epoch){return;}if(this.pending>=64){this.cancel('bridge_queue_limit');return;}this.pending++;
    this.chain=this.chain.then(async()=>{try{if(run===this.epoch){await this.apply(await this.command(c),run);}}finally{this.pending--;}}).catch(()=>{if(run===this.epoch){this.cancel('bridge_failure');}});
  }
  private selectionSequence:number=0;
  async select(deviceKey:string,name:string='',current:()=>boolean=()=>true):Promise<boolean>{
    if(this.codecRetrying){this.codecRetryCancelled=true;return false;}
    if(this.detailOwner||this.busy||this.closing||!current()){return false;}
    const attempt=++this.selectionSequence;
    const result=await this.command({op:'select_device',deviceKey:deviceKey});
    if(attempt!==this.selectionSequence||this.detailOwner||this.busy||this.closing||!current()){return false;}
    if(!result.selectionValid){this.show(result.error||'选择失败');return false;}
    this.selected=deviceKey;this.harmonyTargetKey=result.harmonyHost===true?deviceKey:'';
    this.deviceName=name;this.show('已选择设备，等待本人确认');return true;
  }
  private assistanceId:string='';private assistanceCode:string='';
  get assistancePending():boolean{return this.assistanceId.length>0&&this.assistanceCode.length>0;}
  prepareAssistance(id:string,code:string):boolean {
    if(this.codecRetrying){this.codecRetryCancelled=true;return false;}
    if(this.busy||this.closing||!id.trim()||id.length>256||!code.trim()||code.length>1024||/[\u0000-\u001f\u007f]/.test(id+code)){return false;}
    this.assistanceId=id;this.assistanceCode=code;this.selected='assistance';this.deviceName='远程协助';return true;
  }
  clearAssistance():void {this.assistanceId='';this.assistanceCode='';}
  async joinAssistance():Promise<void> {await this.joinConfirmed('assistance');}
  async joinConfirmed(deviceKey:string,retryH264:boolean=false):Promise<void>{
    if(!retryH264){this.decoderOverride=-1;this.codecFallbackAttempted=false;}

    if(!this.foreground||this.busy||this.closing||deviceKey!==this.selected){return;}
    this.desktopOfferAt=0;
    if(this.isHarmonyTarget()){
      this.multiRequested=false;
      hilog.info(0x0303,'UUS5','target=HarmonyOS desktop_mode=single codec=AVC');
    }
    this.detachedScreens=[];this.primaryClosedWithSibling=false;this.endedHiddenRoom=false;this.legacyRetryAvailable=false;this.primaryAttached=true;this.multi=this.multiRequested&&!this.filesOnly&&!this.catalogOnly&&!this.lockOnly&&!this.terminalOnly&&!this.detailOwner&&deviceKey!=='assistance'?new MultiVideoClient():undefined;this.multiRequested=false;this.primaryScreen=-1;this.multiOpening=false;this.primaryEverFrame=false;this.legacyEverFrame=false;this.preparedGeneration=0;this.primarySlot=0;this.transferredSlot=-1;this.transferredScreen=-1;this.primaryClaiming=false;
    center.updateConnection();
    this.roomCodec=0;this.portraitStatus=[];this.latestDisplay=undefined;this.lastFrameDiagnostic='';this.lastReportDiagnostic='';this.lastConfigDiagnostic='';this.lastCaptureDiagnostic='';this.lastRtpDiagnosticAt=0;this.lastFailure='';this.connectionPhase=(this.filesOnly||this.catalogOnly||this.lockOnly||this.terminalOnly)?'preparing_data':'preparing_video';this.lastConnectionSummary='';this.diagnostic=(this.filesOnly||this.catalogOnly||this.lockOnly||this.terminalOnly)?'独立安全数据通道':'等待Surface';this.offline=false;this.busy=true;this.began=Date.now();const run=++this.epoch;
    try{
      if(!this.filesOnly&&!this.catalogOnly&&!this.lockOnly&&!this.terminalOnly&&!await this.prepareVideo(run)){if(run===this.epoch){await this.cancel(this.preparingFailure||'video/initialize_unclassified code=-103 kind=local');}return;}if(run!==this.epoch){return;}
      const assist=deviceKey==='assistance'&&this.assistancePending;
      const r=await this.command({op:assist?'assist_join':'join',connectId:assist?this.assistanceId:undefined,connectCode:assist?this.assistanceCode:undefined,deviceKey:deviceKey,confirmed:true,watch:this.watch||this.detailOwner!==0||this.filesOnly||this.catalogOnly||this.lockOnly,filesOnly:this.filesOnly,catalogOnly:this.catalogOnly,lockOnly:this.lockOnly,terminalOnly:this.terminalOnly,offerDelayMs:this.offerDelayMs,viewerWidth:this.viewerWidth,viewerHeight:this.viewerHeight,viewerRefresh:this.viewerRefresh,multiVideo:!!this.multi,renderSlot:this.multi?0:undefined,videoGeneration:this.multi?this.preparedGeneration:undefined});
      if(run!==this.epoch){if(r.request){r.request.body='';r.request.headers={};r.request.url='';}return;}
      if(!r.request){await this.cancel(r.error||'未生成房间请求');return;}
      const req=r.request;const task=http.createHttp();this.request=task;this.show(assist?'正在发起已确认的远程协助':'正在加入已确认的自有设备；可能启动 Windows 会话');
      try{let response=await task.request(req.url,{method:http.RequestMethod.POST,header:req.headers,extraData:req.body,connectTimeout:12000,readTimeout:12000,expectDataType:http.HttpDataType.STRING,usingCache:false});if(run!==this.epoch){return;}
        let body=typeof response.result==='string'?response.result:'';
        let out=await this.command({op:'join_response',id:req.id,httpStatus:response.responseCode,body:body});
        if(run!==this.epoch){return;}
        if(assist&&out.assistFallback){
          const fallback=await this.command({op:'assist_join',connectId:this.assistanceId,connectCode:this.assistanceCode,legacy:true,confirmed:true,offerDelayMs:this.offerDelayMs,viewerWidth:this.viewerWidth,viewerHeight:this.viewerHeight,viewerRefresh:this.viewerRefresh});
          req.body='';req.headers={};req.url='';
          if(run!==this.epoch){if(fallback.request){fallback.request.body='';fallback.request.headers={};fallback.request.url='';}return;}
          if(!fallback.request){await this.cancel(fallback.error||'assistance_fallback_failed');return;}
          const next=fallback.request;
          try{response=await task.request(next.url,{method:http.RequestMethod.POST,header:next.headers,extraData:next.body,connectTimeout:12000,readTimeout:12000,expectDataType:http.HttpDataType.STRING,usingCache:false});if(run!==this.epoch){return;}
            body=typeof response.result==='string'?response.result:'';out=await this.command({op:'join_response',id:next.id,httpStatus:response.responseCode,body:body});
          }finally{next.body='';next.headers={};next.url='';}
        }
        if(run!==this.epoch){return;}
        this.clearAssistance();
        hilog.info(0x0303,'UUS5','join http=%{public}d code=%{public}d passed=%{public}d',out.joinHttp||0,out.joinCode||0,out.joinPassed?1:0);
        if(out.joinCode===2002){await this.cancel('目标已有远控会话（2002），已停止');return;}if(out.joinPassed){this.began=Date.now();}await this.apply(out,run);if(run===this.epoch&&this.busy){this.startTimer(run);}
      }finally{
        if(run===this.epoch){this.clearAssistance();}
        if(this.request===task){this.request=undefined;task.destroy();}
        req.body='';req.headers={};req.url='';
      }
    }catch(_){if(run===this.epoch){await this.cancel('join_transport_failure');}}
  }
  private startTimer(run:number):void {if(this.timer>=0){clearInterval(this.timer);}this.timer=setInterval(()=>{if(run!==this.epoch||this.closing){return;}
    if(!(this.filesOnly?this.filesReady:this.controlOpen)&&Date.now()-this.began>45000){this.cancel('handshake_deadline');return;}
    if(this.pollingRun===run){return;}this.pollingRun=run;
    this.enqueue({op:'signal_tick'},run);
    if(this.peer){this.chain=this.chain.then(async()=>{
      if(run!==this.epoch||this.closing){return;}
      const collectDiagnostics=!this.multi&&this.inputPending===0&&Date.now()-this.lastRtpDiagnosticAt>=1500;
      if(collectDiagnostics){this.lastRtpDiagnosticAt=Date.now();}
      const p=await this.peerCommand({op:'peer_poll',collectDiagnostics:collectDiagnostics});if(run!==this.epoch||this.closing){return;}if(p.error){await this.cancel(p.error);return;}
      center.updateConnection(p.connectionInfo);
      this.portraitStatus=p.portraitSettings||[];this.logLegacyCapture(p.legacyCapture);if(!this.multi&&p.rtpDiagnostics){logRtpDiagnostics(p.rtpDiagnostics);}
      if(this.controlOpen&&!p.controlOpen){await this.cancel('control_channel_closed');return;}this.controlOpen=!!p.controlOpen;const nextTouch=p.touchSupport||((p.touchQueryExhausted)?3:0);if(this.touchSupport===2&&nextTouch!==2){this.releaseInputs();}this.touchSupport=nextTouch;this.controlEcho=!!p.echoReceived;if(this.filesOnly&&this.fileChannelOpen&&!p.fileChannelOpen){await this.cancel('file_channel_closed');return;}this.fileChannelOpen=!!p.fileChannelOpen;if(this.multi){await this.pollMulti();}const v:VideoState=(this.filesOnly||this.catalogOnly||this.lockOnly||this.terminalOnly||this.multi)?{}:this.readVideo();if(!this.filesOnly&&!this.catalogOnly&&!this.lockOnly&&!this.terminalOnly){await this.readMetrics(run);if(run===this.epoch&&!this.multi){this.readVideo();this.logDisplayFrame();}}if(run!==this.epoch){return;}
      const state=`ICE=${p.iceState||'?'} PC=${p.connectionState||'?'} DTLS=${p.dtlsState||'?'} tracks=${p.tracksObserved||0} dcOpen=${p.dataChannelsOpen||0} CONTROL=${this.controlOpen} echo=${!!p.echoReceived} videoReq=${!!p.videoRequested} RTP=${p.mediaPackets||0} AU=${p.accessUnits||0} input=${p.inputSent||0}\n${this.videoText}`;if(state!==this.lastPeer){this.lastPeer=state;hilog.info(0x0303,'UUP0','transport=%{public}s video=%{public}s',state,this.diagnostic);}this.show(this.terminalOnly?(this.controlOpen?'终端通道已连接':'正在建立终端连接'):this.lockOnly?(this.controlOpen?'锁屏通道已连接':'正在建立锁屏连接'):this.catalogOnly?(this.controlOpen?'应用通道已连接':'正在建立安全应用连接'):this.filesOnly?(this.filesReady?'文件通道已连接':'正在建立安全文件连接'):this.firstFrame?'远程桌面已显示，可操作':this.multiOpening?'正在切换显示器，等待新画面':this.controlOpen?'已连接，等待首帧画面':'正在建立安全远控连接');
      for(const c of p.candidates||[]){if(run!==this.epoch){return;}this.localCandidates++;await this.apply(await this.command({op:'signal_candidate',candidate:c}),run);}
      if(run!==this.epoch){return;}
      if(!this.multi&&!this.answered&&!this.controlOpen&&this.desktopOfferAt>0&&
        Date.now()-this.desktopOfferAt>=8000&&await this.retryUnsupportedHevc(run,'no_sdp_answer')){return;}
      if(!this.filesOnly&&!this.catalogOnly&&!this.lockOnly&&!this.terminalOnly&&this.controlOpen&&!this.multi&&Date.now()-this.lastHeartbeat>=1000){this.lastHeartbeat=Date.now();await this.peerCommand({op:'peer_input',event:{heartbeat:'kbd_heartbeat'} as RemoteInput});}
      if(run!==this.epoch){return;}
      if(this.multi&&this.primaryAttached&&!this.primaryEverFrame&&!this.multiOpening&&this.answered&&!this.firstFrame&&Date.now()-this.answerAt>20000){this.lastFailure='多屏协商未完成，可选择单窗口重试';this.legacyRetryAvailable=true;}
      if(v.error){await this.cancel(this.videoFailure(v,'decode'));return;}if(p.mediaError){await this.cancel('media/unsupported_codec');return;}if(this.initialFrameTimedOut()){const phase=(p.mediaPackets||0)===0?'no_rtp':(p.accessUnits||0)===0?'no_access_unit':!v.firstSps||!v.firstPps||!v.firstIdr?'waiting_parameter_sets_idr':(v.submitted||0)===0?'no_decoder_input':(v.decoded||0)===0?'no_decode_output':'no_surface_render';await this.cancel('video/'+phase+' deadline=20s');return;}
      if(p.connectionState==='failed'||p.iceState==='failed'||p.connectionState==='disconnected'||p.iceState==='disconnected'||p.connectionState==='closed'){await this.cancel('peer_failed');return;}
    }).catch(()=>{if(run===this.epoch){this.cancel('peer_poll_failure');}});}
    this.chain=this.chain.finally(()=>{if(this.pollingRun===run){this.pollingRun=-1;}});
  },250);}
  private async apply(r:Reply,run:number):Promise<void>{
    if(run!==this.epoch){return;}
    if(r.signal){this.connectionPhase=r.signal.state;const status=JSON.stringify(r.signal);if(status!==this.lastSignalJson){this.lastSignalJson=status;hilog.info(0x0303,'UUS5','signal_state=%{public}s',status);if(!this.controlOpen){this.show(r.signal.state+' · '+r.signal.message);}}}
    if(r.error){await this.cancel(r.error);return;}
    for(const a of r.actions||[]){if(run!==this.epoch){return;}
      if(a.kind==='connect'&&a.url){await this.connect(a,run);}
      else if(a.kind==='text'&&this.ws){if(!await this.ws.send(a.text||'')){throw new Error('send_failed');}if((a.text||'').startsWith('42')){hilog.info(0x0303,'UUS5','peer_summary=soac_send_submitted');}}
      else if(a.kind==='binary'&&this.ws){const bytes=new util.Base64Helper().decodeSync(a.base64||'');if(!await this.ws.send(bytes.buffer)){throw new Error('send_failed');}}
      else if(a.kind==='close'){await this.cancel('signal_closed');return;}
      a.text='';a.base64='';a.url='';a.headers={};
    }
    if(run!==this.epoch){return;}
    if(r.peerConfig){
      const p=await this.peerCommand({op:'peer_start',config:r.peerConfig,filesOnly:this.filesOnly,catalogOnly:this.catalogOnly,lockOnly:this.lockOnly,terminalOnly:this.terminalOnly,multiVideo:!!this.multi});if(run!==this.epoch){return;}if(p.error||!p.offer){await this.cancel(p.error||'missing_offer');return;}this.peer=true;const lines=p.offer.split('\r\n');
      hilog.info(0x0303,'UUS5','real_offer app=%{public}d audio=%{public}d video=%{public}d quic=%{public}d max_message=%{public}d delay_ms=0',lines.filter((l:string)=>l.startsWith('m=application')).length,lines.filter((l:string)=>l.startsWith('m=audio')).length,lines.filter((l:string)=>l.startsWith('m=video')).length,p.offer.includes('a=x-uuremote-quic')?1:0,p.offer.includes('a=max-message-size:262144')?1:0);
      hilog.info(0x0303,'UUS5','offer_extensions videoCount=%{public}d hasMid=%{public}d hasRid=%{public}d hasRepairedRid=%{public}d',lines.filter((l:string)=>l.startsWith('m=video')).length,lines.some((l:string)=>l.startsWith('a=extmap:')&&l.includes('urn:ietf:params:rtp-hdrext:sdes:mid'))?1:0,lines.some((l:string)=>l.startsWith('a=extmap:')&&l.includes('urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id'))?1:0,lines.some((l:string)=>l.startsWith('a=extmap:')&&l.includes('urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id'))?1:0);
      await this.apply(await this.command({op:'signal_offer',sdp:p.offer}),run);p.offer='';
      if(run===this.epoch&&!this.closing){this.desktopOfferAt=Date.now();}
    }
    if(run===this.epoch&&r.peerEvent&&this.peer){const e=r.peerEvent as Record<string,Object>;const p=await this.peerCommand({op:'peer_receive',event:r.peerEvent});if(run!==this.epoch){return;}if(p.error){if(p.error==='remote_hevc_unsupported'&&await this.retryUnsupportedHevc(run)){return;}await this.cancel(p.error);return;}if(e['type']==='answer'){this.answered=true;this.answerAt=Date.now();this.show((this.filesOnly||this.catalogOnly||this.lockOnly||this.terminalOnly)?'安全协商完成，等待数据通道':'真实 SDP Answer 已应用，等待桌面');}if(e['type']==='candidate'){this.remoteCandidates++;}}
  }
  private async retryUnsupportedHevc(run:number,reason:string='remote_hevc_unsupported'):Promise<boolean>{
    if(run!==this.epoch||this.roomCodec!==2||this.videoCodecPreference!==0||this.codecFallbackAttempted||this.codecRetrying||this.detailOwner!==0||this.selected==='assistance'||this.filesOnly||this.catalogOnly||this.lockOnly||this.terminalOnly){return false;}
    const key=this.selected,name=this.deviceName,watch=this.watch,multi=!!this.multi;
    if(!key){return false;}
    this.codecFallbackAttempted=true;this.codecRetrying=true;this.codecRetryCancelled=false;
    try{
      // End only our old room and finish renderer cleanup before a single retry.
      // An AVC-only host can close before producing any SDP answer.
      await this.cancel('codec_fallback');
      if(this.codecRetryCancelled||!this.foreground||!this.windowActive||this.busy||this.closing||!this.videoSettled){return true;}
      const state=JSON.parse(videoStatus()) as VideoState;if(state.reusable===false){return true;}
      const selected=await this.command({op:'select_device',deviceKey:key});
      if(this.codecRetryCancelled||!this.foreground||!this.windowActive||!selected.selectionValid){return true;}
      this.selected=key;this.deviceName=name;this.watch=watch;this.multiRequested=multi;this.decoderOverride=1;
      hilog.info(0x0303,'UUS5','codec_fallback from=2 to=1 reason=%{public}s',reason);
      this.show('正在使用 H.264 重新连接');
      await this.joinConfirmed(key,true);
    }finally{this.codecRetrying=false;this.show(this.text);}
    return true;
  }
  private async connect(a:Action,run:number):Promise<void>{
    const ws=webSocket.createWebSocket();this.ws=ws;this.closeObserved=false;
    ws.on('open',(err:BusinessError,value:Object)=>{if(run!==this.epoch){ws.close().catch(()=>{});return;}const code=(value as SocketOpen).status;hilog.info(0x0303,'UUS5','ws_open offline=%{public}d status=%{public}d',this.offline?1:0,code);if(code!==101){this.cancel('invalid_upgrade_status');}});
    ws.on('message',(err:BusinessError,data:string|ArrayBuffer)=>{if(run!==this.epoch){return;}if(err){this.cancel('ws_message_error');return;}if(typeof data==='string'){if(data.length>1048576){this.cancel('text_limit');return;}this.enqueue({op:'signal_text',text:data},run);}else{if(data.byteLength>1048576){this.cancel('binary_limit');return;}this.enqueue({op:'signal_binary',base64:new util.Base64Helper().encodeToStringSync(new Uint8Array(data))},run);}});
    ws.on('close',(err:BusinessError,result:webSocket.CloseResult)=>{this.closeObserved=true;if(this.closeWait){this.closeWait();this.closeWait=undefined;}hilog.info(0x0303,'UUS5','ws_closed code=%{public}d',result.code);if(run===this.epoch){this.cancel('remote_socket_closed');}});
    ws.on('error',(err:BusinessError)=>{hilog.warn(0x0303,'UUS5','ws_error code=%{public}d',err.code);if(run===this.epoch){this.cancel('websocket_transport_error');}});
    const headers:Record<string,string>=a.headers||{};const options:webSocket.WebSocketRequestOptions={header:headers,skipServerCertVerification:false,pingInterval:20,pongTimeout:10};const accepted=await ws.connect(a.url||'',options);if(!accepted){throw new Error('connect_not_created');}
  }
  private async closeSocket(ws:webSocket.WebSocket):Promise<void>{
    let waitTimer:number=-1;
    const started=Date.now();
    const closed=new Promise<void>((resolve:()=>void)=>{this.closeWait=resolve;waitTimer=setTimeout(()=>{this.closeWait=undefined;resolve();},2000);});
    try{
      ws.off('open');ws.off('message');ws.off('error');
      if(this.closeObserved){if(this.closeWait){this.closeWait();this.closeWait=undefined;}}
      else{await Promise.race([ws.close({code:1000,reason:'user session end'}).then(()=>closed),closed]);}
      await closed;
    }catch(_){}finally{if(waitTimer>=0){clearTimeout(waitTimer);}this.closeWait=undefined;ws.off('close');}
    hilog.info(0x0303,'UUS5','ws_close_observed=%{public}d elapsed_ms=%{public}d',this.closeObserved?1:0,Date.now()-started);
  }
  private async closeResources():Promise<void>{
    if(this.timer>=0){clearInterval(this.timer);this.timer=-1;}if(this.request){this.request.destroy();this.request=undefined;}
    const ws=this.ws;this.ws=undefined;
    // Start transport shutdown now; a stalled WebSocket close must not delay
    // closing the live WebRTC peer (and remote disconnect detection).
    const socketClosing=ws?this.closeSocket(ws):Promise.resolve();
    const p=await this.peerCommand({op:'peer_close'});hilog.info(0x0303,'UUS5','native_close=%{public}s',JSON.stringify(p));this.peer=false;this.controlOpen=false;await socketClosing;
    if(this.multi){await this.multi.dispose();this.multi=undefined;this.primaryScreen=-1;}
    if(this.videoTask){stopVideo();let deadline:number=-1;await Promise.race([this.videoTask.then(()=>{}),new Promise<void>((resolve:()=>void)=>{deadline=setTimeout(()=>{hardStopVideo();resolve();},1800);})]);if(deadline>=0){clearTimeout(deadline);}if(this.videoSettled){this.videoTask=undefined;}this.readVideo();}
    hilog.info(0x0303,'UUS5','release ws=0 timer=0 http=0 peer_closed=%{public}d weak_released=%{public}d local_candidates=%{public}d remote_candidates=%{public}d answered=%{public}d',p.closed?1:0,p.weakReleased?1:0,this.localCandidates,this.remoteCandidates,this.answered?1:0);
  }
  private cleanupTask:Promise<void>|undefined=undefined;
  private lastEndedDevice:string='';private lastEndedAccount:string='';private lastEndedUntil:number=0;
  get checkingEndedDevice():string{
    return Date.now()<this.lastEndedUntil&&client.view.wallpaperAccountKey===this.lastEndedAccount?this.lastEndedDevice:'';
  }
  private async leaveOwnRoom(req:Request):Promise<boolean>{
    let task:http.HttpRequest|undefined=undefined;const began=Date.now();let timer:number=-1;
    try{
      const request=http.createHttp();task=request;
      const options:http.HttpRequestOptions={method:http.RequestMethod.POST,header:req.headers,connectTimeout:2200,readTimeout:2200,expectDataType:http.HttpDataType.STRING,usingCache:false};
      if(req.body.length>0){options.extraData=req.body;}
      const result=request.request(req.url,options).then((response:http.HttpResponse):boolean=>{
        let code:number=-1;
        try{if(typeof response.result==='string'){code=(JSON.parse(response.result) as RoomLeaveResponse).code??-1;}}catch(_){}
        hilog.info(0x0303,'UUS5','room_leave_http=%{public}d api=%{public}d',response.responseCode,code);
        return response.responseCode===200&&code===0;
      }).catch((error:BusinessError):boolean=>{
        hilog.warn(0x0303,'UUS5','room_leave_transport_code=%{public}d',error.code||0);
        return false;
      });
      const acknowledged=await Promise.race([result,new Promise<boolean>((resolve:(value:boolean)=>void)=>{timer=setTimeout(()=>resolve(false),2200);})]);
      const binding=req.participantBinding==='confirmed'?1:req.participantBinding==='registered_device'?2:0;
      hilog.info(0x0303,'UUS5','room_leave_participant_binding=%{public}d',binding);
      // Never log the signed URL, credentials, controller/device IDs or response body.
      hilog.info(0x0303,'UUS5','room_leave_ack=%{public}d elapsed_ms=%{public}d',acknowledged?1:0,Date.now()-began);
      return acknowledged;
    }catch(_){hilog.warn(0x0303,'UUS5','room_leave_transport_failed');return false;}
    finally{if(timer>=0){clearTimeout(timer);}try{task?.destroy();}catch(_){}req.headers={};req.body='';req.url='';}
  }
  private async refreshEndedRoom(target:string,run:number,account:string):Promise<void>{
    for(const delay of [0,750,1500,3000,4500,6000,7500,9000]){
      if(delay>0){await new Promise<void>((resolve:()=>void)=>{setTimeout(resolve,delay);});}
      if(run!==this.epoch||this.busy||this.closing||!client.view.loggedIn||client.view.wallpaperAccountKey!==account){return;}
      if(await client.refreshDevices(true)){
        const device=client.view.devices.find((row)=>row.key===target);
        if(!device||device.participants?.length===0){if(this.lastEndedDevice===target){this.lastEndedUntil=0;}return;}
      }
    }
  }
  cancel(reason:string='user_cancel'):Promise<void>{
    if(this.codecRetrying&&reason!=='codec_fallback'){this.codecRetryCancelled=true;}
    if(this.cleanupTask){return this.cleanupTask;}
    if(!this.busy&&!this.peer&&!this.ws&&!this.request&&!this.videoTask&&!this.closing&&!this.selected){return Promise.resolve();}
    this.closing=true;center.updateConnection();this.multi?.seal();this.notifyState();const task=Promise.resolve().then(()=>this.performCancel(reason));this.cleanupTask=task;
    const complete=()=>{if(this.cleanupTask===task){this.cleanupTask=undefined;}};task.then(complete,complete);return task;
  }
  private async performCancel(reason:string):Promise<void>{
    if(this.multi&&reason!=='user_cancel'&&reason!=='user_disconnect'){this.legacyRetryAvailable=true;}
    this.clearAssistance();
    try{micNative.stop();}catch(_){}
    this.closing=true;
    const target=this.selected,account=client.view.wallpaperAccountKey||'';
    this.lastConnectionSummary=`stage=${this.connectionPhase} peer=${this.peer} answer=${this.answered} control=${this.controlOpen} localCandidates=${this.localCandidates} remoteCandidates=${this.remoteCandidates}`;
    try{
      try{audioStop();}catch(_){}this.watch=false;this.inputPaused=false;this.displayBlocked=false;this.displayEpoch=0;this.displayText='';this.metricsAt=0;center.reset();
      this.resetInputObservers();this.epoch++;this.inputGeneration++;this.pendingPointer=undefined;this.inputQueueMs=undefined;this.coalescedPointer=0;this.selected='';
      if(this.peer){try{const released=await this.peerCommand({op:'peer_release_all'});hilog.info(0x0303,'UUS5','input_release_before_signal=%{public}s',JSON.stringify(released));}catch(_){}}
      if(this.peer){try{const ended=await this.peerCommand({op:'peer_end_media'});hilog.info(0x0303,'UUS5','media_end=%{public}s',JSON.stringify(ended));}catch(_){}}
      try{
        if(this.peer&&account&&/^[a-f0-9]{64}$/.test(target)){
          let wait:number=-1;
          try{await Promise.race([client.refreshDevices(true),new Promise<void>((resolve:()=>void)=>{wait=setTimeout(resolve,650);})]);}
          finally{if(wait>=0){clearTimeout(wait);}}
        }
        const ended=await this.command({op:'session_cancel'});
        const acknowledged=ended.leaveRequest?await this.leaveOwnRoom(ended.leaveRequest):false;
        if(acknowledged&&!this.closeObserved){
          // The owned-room clear is the single authoritative exit. Allow its
          // notification to reach the receiver before closing local transports.
          await new Promise<void>((resolve:()=>void)=>{setTimeout(resolve,300);});
        }
        if(!acknowledged&&this.ws&&!this.closeObserved){for(const action of ended.actions||[]){if(action.kind==='text'){let sendTimer:number=-1;try{await Promise.race([this.ws.send(action.text||''),new Promise<void>((resolve:()=>void)=>{sendTimer=setTimeout(resolve,300);})]);}catch(_){}finally{if(sendTimer>=0){clearTimeout(sendTimer);}}}}}
      }catch(_){hilog.warn(0x0303,'UUP0','session_cancel_bridge_failed');}
      try{await this.closeResources();}catch(_){hardStopVideo();hilog.warn(0x0303,'UUP0','cleanup_bridge_failed');}
    }finally{
      this.busy=false;this.controlOpen=false;this.touchSupport=0;this.controlEcho=false;this.fileChannelOpen=false;this.firstFrame=false;
      const normal=reason==='user_cancel'||reason==='user_disconnect'||reason==='codec_fallback';const state=JSON.parse(videoStatus()) as VideoState;
      if(!normal){this.lastFailure=reason;hilog.error(0x0303,'UUP0','session_failure=%{public}s connection=%{public}s diagnostics=%{public}s',reason,this.lastConnectionSummary,this.diagnostic);}
      const cleanupOk=this.videoSettled&&state.reusable!==false;
      this.endedHiddenRoom=this.primaryClosedWithSibling;this.primaryClosedWithSibling=false;
      this.answered=false;this.answerAt=0;this.legacyEverFrame=false;this.localCandidates=0;this.remoteCandidates=0;this.lastPeer='';this.closing=false;this.filesOnly=false;this.catalogOnly=false;this.lockOnly=false;this.terminalOnly=false;
      // Notify page observers only after the terminal room state is visible.
      if(account&&/^[a-f0-9]{64}$/.test(target)&&(reason==='user_disconnect'||reason==='user_cancel')){
        this.lastEndedDevice=target;this.lastEndedAccount=account;this.lastEndedUntil=Date.now()+35000;
        this.refreshEndedRoom(target,this.epoch,account).catch(()=>{});
      }
      this.show(normal?(cleanupOk?'已断开，资源已释放':'已断开；视频清理未完成，请重启应用后重试'):'连接失败：'+reason);
    }
  }
}
export const session:SessionClient=new SessionClient();
