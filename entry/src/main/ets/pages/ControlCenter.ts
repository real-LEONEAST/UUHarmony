import { DisplayState, displayStatus, displayErrorText } from './DisplayModel';
export interface SettingRequest {kind:string;value?:number|string;enabled?:boolean;width?:number;height?:number;confirmed?:boolean;localFpsLimit?:number;}
export interface SettingReply {seq?:number;sent?:boolean;sentMessages?:number;totalMessages?:number;remoteAck?:boolean|null;error?:string;watch?:boolean;localApplied?:boolean;inputUnreleased?:number;display?:DisplayState;}
interface DecoderCaps {available?:boolean;hardware?:boolean;supports720p?:boolean;supports1080p?:boolean;max720Fps?:number|null;max1080Fps?:number|null;sessionFpsLimit?:number;}
export interface DecoderSample {nowMs:number;lastFrameMs:number;decoded:number;rendered:number;received?:number;running:boolean;width?:number;height?:number;renderedEpoch?:number;videoEpoch?:number;renderSlot?:number;generation?:number;codec?:number;queueMs?:number;rtpQueueMs?:number;decoderMs?:number;arrivalToRenderMs?:number;discarded?:number;}
interface SettingRecord {seq:number;request:SettingRequest;sentMessages:number;totalMessages:number;sent:boolean;remoteAck:boolean|null;ackSupported:boolean;}
interface RemoteReport {fps?:number;quality?:number;width?:number;height?:number;customBps?:number;}
interface CenterReport {remoteAutoLock?:boolean|null;autoLockSupported?:boolean;remoteLocked?:boolean|null;autoUnlockSupported?:boolean|null;privacyError?:string|null;privacyReplyError?:number|null;privacySaverError?:number|null;privacySupport?:number;privacyCurrent?:number;privacyOwned?:boolean;settings:SettingRecord[];reported:RemoteReport;syncCount:number;remoteMaxFps:number|null;remoteCapWidth:number|null;remoteCapHeight:number|null;localSessionFpsLimit:number;}
interface LossSample {expected:number;receivedUnique:number;lostEstimate:number;lossPercent:number|null;method:string;}
export interface ConnectionInfo {method?:string|null;protocol?:string|null;}
interface LinkSample {bytesIn?:number|null;bytesOut?:number|null;nack?:number|null;pli?:number|null;}
export interface NetworkSample {elapsedMs:number;videoRtpBytesApprox:number;videoPackets:number;loss:LossSample;rttMs:number|null;watch:boolean;inputSent:number;center:CenterReport;display?:DisplayState;link?:LinkSample|null;inputQueueMs?:number;coalescedPointer?:number;error?:string;}
function metric(value:number|null|undefined,unit:string='',digits:number=0):string {
  return typeof value==='number'&&Number.isFinite(value)?value.toFixed(digits)+unit:'—';
}
function rate(current:number|null|undefined,previous:number|null|undefined,elapsed:number):number|undefined {
  return typeof current==='number'&&typeof previous==='number'&&current>=previous&&elapsed>0?(current-previous)*8/elapsed/1000:undefined;
}
export class ControlRow {
  kind:string;label:string;local:string='未选择';send:string='未发送';ack:string='未确认';reported:string='无远端状态回报';seq:number=0;
  constructor(kind:string,label:string){this.kind=kind;this.label=label;}
}
export class ControlView {
  autoLockKnown:boolean=false;remoteAutoLock:boolean=false;autoLockSupported:boolean=false;remoteLockKnown:boolean=false;remoteLocked:boolean=false;unlockCapabilityKnown:boolean=false;autoUnlockSupported:boolean=false;
  privacyError:string='';privacyErrorCode:number=0;
  privacySupport:number=0;privacyCurrent:number=0;privacyOwned:boolean=false;
  actualVideo:string='等待远端画面';
  fpsStatus:string='等待会话帧率信息';
  sessionReset:number=0;
  connectionMethod:string='未知';
  transportProtocol:string='未知';
  display:DisplayState|undefined=undefined;displayText:string='等待电脑报告显示器信息';
  rows:ControlRow[]=[new ControlRow('quality','画质'),new ControlRow('fps','帧率'),new ControlRow('resolution','分辨率'),new ControlRow('auto_lock','断开后锁屏'),new ControlRow('host_mute','被控端静音'),new ControlRow('privacy','防窥')];
  watch:boolean=false;watchStatus:string='本地操作模式';network:string='实际网络数据：等待会话';capability:string='正在查询本地能力';maxFps:number=30;supports720p:boolean=false;supports1080p:boolean=false;lastInputSent:number=0;
}
export class ControlCenter {
  view:ControlView=new ControlView();
  private notify:((v:ControlView)=>void)|undefined=undefined;
  private dispatch:((r:SettingRequest)=>Promise<string>)|undefined=undefined;
  private last:NetworkSample|undefined=undefined;private lastVideo:DecoderSample|undefined=undefined;
  private screenRate:number=0;
  observe(fn:((v:ControlView)=>void)|undefined):void{this.notify=fn;if(fn){fn(this.view);}}
  connect(fn:(r:SettingRequest)=>Promise<string>):void{this.dispatch=fn;}
  private show():void{if(this.notify){this.notify(this.view);}}
  capabilities(jsonText:string,refreshRate:number):void {
    const cap=JSON.parse(jsonText) as DecoderCaps;this.screenRate=refreshRate;
    this.view.supports720p=!!cap.supports720p;this.view.supports1080p=!!cap.supports1080p;
    this.view.capability=`本地显示 ${refreshRate||'未知'} Hz · 等待会话解码能力`;this.show();
  }
  async apply(request:SettingRequest,label:string):Promise<void>{
    const row=this.view.rows.find((r:ControlRow)=>r.kind===request.kind);if(row){row.local=label;row.send='正在排队';row.ack='未确认';row.seq=0;}this.show();
    if(request.kind==='fps'){request.localFpsLimit=Math.floor(this.view.maxFps);}
    if(!this.dispatch){if(row){row.send='未发送：会话不可用';}this.show();return;}
    try{const reply=JSON.parse(await this.dispatch(request)) as SettingReply;
      if(request.kind==='watch'){if(reply.localApplied){this.view.watch=!!reply.watch;this.view.watchStatus=`本地${reply.watch?'观看':'操作'}模式；无需远端ACK · 待释放${reply.inputUnreleased||0}`;}else{this.view.watchStatus='观看切换失败：'+(reply.error||'无结果');}}
      if(row){row.seq=reply.seq||0;row.send=reply.sent?'已发送 '+reply.sentMessages+'/'+reply.totalMessages:reply.error?displayErrorText(reply.error):'未完成发送';row.ack=reply.remoteAck===true?'远端ACK通过':reply.remoteAck===false?'远端拒绝':'未收到远端确认';}
    }catch(_){if(row){row.send='发送接口失败';}}this.show();
  }
  multiDisplay(screens:import('./DisplayModel').ScreenRow[],selected:number,observed:boolean,error:string='',width:number=0,height:number=0):void{this.view.display={screens:screens,inventoryReceived:true,inventoryGeneration:1,selectedScreen:selected,switchCommandSupported:true,switchCommandSent:false,displayEpoch:0,displayPending:false,inputBlocked:!observed,videoFrameObserved:observed,resolutionMatched:observed,displayError:error||null,screenBlocker:'',privacy:{supported:false,blocker:''}};this.view.displayText=displayStatus(this.view.display);this.view.actualVideo=observed&&width>0&&height>0?'实际收到 '+width+' × '+height:'等待当前显示器画面';this.show();}
  updateConnection(info?:ConnectionInfo|null):void {
    const method=info?.method==='direct'?'直连':info?.method==='relay'?'中继':'未知';
    const protocol=info?.protocol==='udp'?'UDP':info?.protocol==='tcp'?'TCP':'未知';
    if(method===this.view.connectionMethod&&protocol===this.view.transportProtocol){return;}
    this.view.connectionMethod=method;
    this.view.transportProtocol=protocol;
    this.show();
  }
  reset():void{this.last=undefined;this.lastVideo=undefined;const cap=this.view;this.view=new ControlView();this.view.sessionReset=cap.sessionReset+1;this.view.supports720p=cap.supports720p;this.view.supports1080p=cap.supports1080p;this.view.capability='等待会话解码能力';this.show();}
  sample(p:NetworkSample,v:DecoderSample,width:number,height:number,keepDisplay:boolean=false):void {
    if(p.error){return;}
    const previous=this.last,elapsed=previous?p.elapsedMs-previous.elapsedMs:0;
    const payload=rate(p.videoRtpBytesApprox,previous?.videoRtpBytesApprox,elapsed);
    const measuredReceive=rate(p.link?.bytesIn,previous?.link?.bytesIn,elapsed);
    const measuredSend=rate(p.link?.bytesOut,previous?.link?.bytesOut,elapsed);
    // Some ICE builds expose only STUN bytes. Do not present their counters as media traffic.
    const transportMeasured=measuredReceive!==undefined&&measuredReceive>0&&
      (payload===undefined||measuredReceive>=payload*0.8);
    const receive=transportMeasured?measuredReceive:undefined;
    const send=transportMeasured?measuredSend:undefined;
    let fps:number|undefined=undefined,decode:number|undefined=undefined,receivedFps:number|undefined=undefined;
    const prior=this.lastVideo;
    if(prior&&v.running&&prior.running&&v.renderSlot===prior.renderSlot&&v.generation===prior.generation&&v.videoEpoch===v.renderedEpoch&&v.renderedEpoch===prior.renderedEpoch&&prior.videoEpoch===prior.renderedEpoch&&v.nowMs>prior.nowMs&&v.decoded>=prior.decoded&&v.rendered>=prior.rendered){
      const dt=v.nowMs-prior.nowMs;
      fps=(v.rendered-prior.rendered)*1000/dt;decode=(v.decoded-prior.decoded)*1000/dt;
      if(v.received!==undefined&&prior.received!==undefined&&v.received>=prior.received){receivedFps=(v.received-prior.received)*1000/dt;}
    }
    this.last=p;this.lastVideo=v;this.view.lastInputSent=p.inputSent;
    if(!keepDisplay){this.view.display=p.display;this.view.displayText=displayStatus(p.display);}
    const frame=v.rendered>0;
    const size=frame&&(v.width||0)>0&&(v.height||0)>0?`${v.width} × ${v.height}`:'未知';
    const codec=v.codec===2?'H.265':v.codec===1?'H.264':'—';
    this.view.actualVideo=`${size} · 实收 ${metric(receivedFps,' 帧/秒',1)} · 送显 ${metric(fps,' 帧/秒',1)}`;
    const c=p.center;
    const requested=c.settings.filter((s:SettingRecord)=>s.request.kind==='fps').pop();
    const requestedFps=requested?.request.value;
    const requestStatus=requested?.remoteAck===false?'（被控端拒绝）':requested?.remoteAck===true?'（被控端已确认请求）':requested?.sent?'（已发送，待确认）':requested?'（未发出）':'';
    this.view.fpsStatus=`帧率目标 ${requestedFps===undefined?'默认':requestedFps+' 帧/秒'}${requestStatus} · 被控端设置回报 ${metric(c.reported.fps,' 帧/秒')}`;
    this.view.network=[
      `往返时延 ${metric(p.rttMs,' ms',1)} · RTP 丢包估算 ${metric(p.loss.lossPercent,'%',2)}`,
      `传输接收 ${metric(receive,' Mbps',2)} · 发送 ${metric(send,' Mbps',2)}`,
      `视频载荷 ${metric(payload,' Mbps',2)} · RTP 包 ${p.videoPackets}`,
      `视频重传请求 ${metric(p.link?.nack)} · 关键帧请求 ${metric(p.link?.pli)}`,
      `${codec} · ${size} · 实收 ${metric(receivedFps,' 帧/秒',1)} · 解码 ${metric(decode,' 帧/秒',1)} · 送显 ${metric(fps,' 帧/秒',1)}`,
      this.view.fpsStatus,
      `本机 RTP 排队 ${metric(frame?v.rtpQueueMs:undefined,' ms')} · 解码排队 ${metric(frame?v.queueMs:undefined,' ms')}`,
      `解码 ${metric(frame?v.decoderMs:undefined,' ms')} · 帧到达后送显 ${metric(frame?v.arrivalToRenderMs:undefined,' ms')} · 解码队列丢弃 ${metric(frame?v.discarded:undefined)}`,
      `输入已发 ${p.inputSent} · 本机排队 ${metric(p.inputQueueMs,' ms')} · 合并移动 ${metric(p.coalescedPointer)}`
    ].join('\n');
    this.view.privacyError=c.privacyError||'';this.view.privacyErrorCode=c.privacyReplyError||c.privacySaverError||0;this.view.autoLockKnown=typeof c.remoteAutoLock==='boolean';this.view.remoteAutoLock=c.remoteAutoLock===true;this.view.autoLockSupported=!!c.autoLockSupported;this.view.remoteLockKnown=typeof c.remoteLocked==='boolean';this.view.remoteLocked=c.remoteLocked===true;this.view.unlockCapabilityKnown=typeof c.autoUnlockSupported==='boolean';this.view.autoUnlockSupported=c.autoUnlockSupported===true;this.view.privacySupport=c.privacySupport||0;this.view.privacyCurrent=c.privacyCurrent||0;this.view.privacyOwned=!!c.privacyOwned;this.view.maxFps=Math.min(60,this.screenRate>0?this.screenRate:30,c.localSessionFpsLimit||30,c.remoteMaxFps||60);
    this.view.capability=`本地显示 ${this.screenRate||'未知'} Hz · ${codec} 解码上限 ${c.localSessionFpsLimit} 帧/秒 · 被控端编码能力 ${metric(c.remoteMaxFps,' 帧/秒')} · 可选上限 ${this.view.maxFps} 帧/秒`;
    for(const row of this.view.rows){const record=c.settings.find((s:SettingRecord)=>s.seq===row.seq);if(record){row.send=record.sent?'已发送 '+record.sentMessages+'/'+record.totalMessages:'部分或未发送 '+record.sentMessages+'/'+record.totalMessages;row.ack=record.remoteAck===true?(row.kind==='privacy'?'电脑已确认防窥状态':row.kind==='auto_lock'?'电脑已回报相同设置':'远端ACK通过'):record.remoteAck===false?(row.kind==='auto_lock'?'电脑仍回报不同设置':'远端拒绝'):record.ackSupported?'未收到远端确认':'协议无对应ACK';}
      if(row.kind==='auto_lock'){row.reported=this.view.autoLockKnown?'电脑报告：'+(this.view.remoteAutoLock?'开启':'关闭'):'尚未收到电脑的自动锁屏状态';}
      const q=c.reported;if(row.kind==='quality'&&q.quality!==undefined){row.reported='远端报告quality='+q.quality;}if(row.kind==='fps'&&q.fps!==undefined){row.reported='被控端设置回报 '+q.fps+' 帧/秒';}if(row.kind==='resolution'&&q.width&&q.height){row.reported=`远端报告${q.width}×${q.height}；解码${width}×${height}`;}
    }
    this.show();
  }
}
export const center:ControlCenter=new ControlCenter();
// Create a fresh ArkUI-observable snapshot; shared model objects are never bound directly.
export function snapshotView(value:ControlView):ControlView {
  const out=new ControlView();out.privacyError=value.privacyError;out.privacyErrorCode=value.privacyErrorCode;out.autoLockKnown=value.autoLockKnown;out.remoteAutoLock=value.remoteAutoLock;out.autoLockSupported=value.autoLockSupported;out.remoteLockKnown=value.remoteLockKnown;out.remoteLocked=value.remoteLocked;out.unlockCapabilityKnown=value.unlockCapabilityKnown;out.autoUnlockSupported=value.autoUnlockSupported;out.actualVideo=value.actualVideo;out.fpsStatus=value.fpsStatus;out.privacySupport=value.privacySupport;out.privacyCurrent=value.privacyCurrent;out.privacyOwned=value.privacyOwned;out.sessionReset=value.sessionReset;out.watch=value.watch;out.watchStatus=value.watchStatus;out.network=value.network;out.capability=value.capability;out.maxFps=value.maxFps;out.supports720p=value.supports720p;out.supports1080p=value.supports1080p;out.lastInputSent=value.lastInputSent;
  out.display=value.display;out.displayText=value.displayText;
  out.connectionMethod=value.connectionMethod;out.transportProtocol=value.transportProtocol;
  out.rows=[];for(const row of value.rows){const r=new ControlRow(row.kind,row.label);r.local=row.local;r.send=row.send;r.ack=row.ack;r.reported=row.reported;r.seq=row.seq;out.rows.push(r);}return out;
}
