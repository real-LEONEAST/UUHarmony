import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import type { HostState } from 'libuuhost.so';
import { client, AuthView } from '../pages/AuthClient';
import { session } from '../pages/SessionClient';
import { pcPlatform,hostBusy,canShare,captureEnded } from './PcHostModel';

export interface HostNative {
  initialize:(path:string,width:number,height:number,language:string)=>number;
  adoptLegacyAccount:()=>number;bindSharedAccount:()=>number;clearSharedAccount:()=>number;
  getState:()=>HostState;startCapture:(width:number,height:number,id:number,sound?:boolean,primary?:boolean)=>number;
  startHost:()=>number;stopAsync:()=>Promise<number>;requestInput:()=>number;
  configureDisplay:(width:number,height:number,id:number,smooth?:boolean)=>number;stopCaptureAsync:()=>Promise<number>;
  setAssistanceEnabled:(enabled:boolean)=>number;resetAssistanceCode:()=>number;
  publishDeviceCover:(data:ArrayBuffer)=>Promise<number>;
}
export interface HostDisplay {id:number;name:string;width:number;height:number;}
export interface ShareView {
  displays:HostDisplay[];selectedDisplay:number;soundRequested:boolean;audioFrames:number;
  smooth:boolean;streamWidth:number;streamHeight:number;inputMessage:string;settingsMessage:string;
  keepPrimary?:boolean;encodedWidth?:number;encodedHeight?:number;
  canStart:boolean;viewerBusy:boolean;
  phase:string;message:string;encoder:boolean;encoderKnown:boolean;inputState:number;deviceId:string;code:string;assistance:boolean;online?:boolean;enabled?:boolean;
}
export function emptyShare():ShareView {return {displays:[],selectedDisplay:-1,soundRequested:false,audioFrames:0,smooth:false,streamWidth:0,streamHeight:0,inputMessage:'',settingsMessage:'',canStart:false,viewerBusy:false,phase:'idle',message:'共享已关闭',encoder:false,encoderKnown:false,inputState:0,deviceId:'',code:'',assistance:false};}
class PcHostService {
  readonly supported:boolean=pcPlatform(deviceInfo.deviceType);
  private native:HostNative|undefined=undefined;
  private loading:Promise<void>|undefined=undefined;
  private stopWork:Promise<boolean>|undefined=undefined;
  private captureStopWork:Promise<number>|undefined=undefined;
  private stoppedMedia:boolean=false;
  private delegated:boolean=false;
  private store:preferences.Preferences|undefined=undefined;
  private settingsWork:Promise<void>=Promise.resolve();
  private enabled:boolean=true;
  private lastLogged:boolean=false;
  private starting:boolean=false;
  private captureRequested:boolean=false;
  private captureFailed:boolean=false;
  private cleanupPending:boolean=false;
  private lifecycleEpoch:number=0;private inventoryEpoch:number=0;private inventoryLoaded:boolean=false;
  get canStart():boolean {return !!this.native&&!this.cleanupPending&&!this.starting&&this.view.phase!=='waiting'&&canShare(client.view.loggedIn,true,this.view.phase,session.busy||session.isClosing);}
  private timer:number=-1;
  private deadline:number=0;
  private observers:Map<number,(value:ShareView)=>void>=new Map();
  private sequence:number=0;
  private authStop:(()=>void)|undefined=undefined;
  sound:boolean=false;
  setSound(enabled:boolean):void {if(!this.busy){this.sound=enabled;}}
  setSmooth(smooth:boolean):void {
    if(this.busy||this.starting||this.view.phase==='waiting'){return;}
    this.view.smooth=smooth;
    this.publish();
  }
  setKeepPrimary(enabled:boolean):void {
    if(this.busy||this.starting||this.view.phase==='waiting'){return;}
    this.view.keepPrimary=enabled;
    this.publish();
  }
  view:ShareView=emptyShare();
  get busy():boolean{return hostBusy(this.view.phase)||(this.view.keepPrimary===true&&this.captureRequested);}
  get blocksOutgoing():boolean{return hostBusy(this.view.phase);}
  observe(fn:(value:ShareView)=>void):()=>void {const id=++this.sequence;this.observers.set(id,fn);fn(this.view);return ()=>{this.observers.delete(id);};}
  private publish():void {
    this.view={
      displays:this.view.displays,selectedDisplay:this.view.selectedDisplay,soundRequested:this.view.soundRequested,
      audioFrames:this.view.audioFrames,smooth:this.view.smooth,streamWidth:this.view.streamWidth,streamHeight:this.view.streamHeight,
      keepPrimary:this.view.keepPrimary,encodedWidth:this.view.encodedWidth,encodedHeight:this.view.encodedHeight,
      inputMessage:this.view.inputMessage,settingsMessage:this.view.settingsMessage,canStart:this.canStart,
      viewerBusy:session.busy||session.isClosing,phase:this.view.phase,message:this.view.message,
      encoder:this.view.encoder,encoderKnown:this.view.encoderKnown,inputState:this.view.inputState,deviceId:this.view.deviceId,
      code:this.view.code,assistance:this.view.assistance,online:this.view.online,enabled:this.enabled
    };
    this.observers.forEach((fn:(value:ShareView)=>void)=>fn(this.view));
  }
  async initialize(context:common.UIAbilityContext):Promise<void> {
    if(!this.supported||this.native){return;}
    if(!this.loading){this.loading=this.load(context);}
    try{await this.loading;}finally{this.loading=undefined;}
  }
  private async load(context:common.UIAbilityContext):Promise<void> {
    try{
      const module:HostNative=(await import('./PcHostNative')).hostNative;
      const screen=display.getDefaultDisplaySync();
      if(module.initialize(context.filesDir+'/uuremote/config.json',screen.width,screen.height,'zh')!==0){throw new Error('host_init');}
      if(module.adoptLegacyAccount()<0){throw new Error('account_migration');}
      this.native=module;
      this.store=preferences.getPreferencesSync(context,{name:'uu.pc.host'});
      this.enabled=this.store.getSync('enabled',true)===true;
      this.authStop=client.monitor((value:AuthView)=>{
        const entered=value.loggedIn&&!this.lastLogged;this.lastLogged=value.loggedIn;
        if(!value.loggedIn&&this.delegated){this.stop();}
        else if(entered&&this.enabled){Promise.resolve().then(()=>this.start());}
      });
      this.timer=setInterval(()=>this.update(),300);
      await this.refreshDisplays();this.update();
    }catch(_){this.view.phase='error';this.view.message='电脑共享暂时无法初始化，请解锁电脑后重新打开应用。';this.publish();}
  }
  private update():void {
    const module=this.native;if(!module||this.cleanupPending||this.captureStopWork){return;}
    const state:HostState=module.getState();
    this.view.audioFrames=state.audioFrames||0;this.view.encoder=state.encoderAvailable;this.view.encoderKnown=true;this.view.inputState=state.inputState;
    if(state.inputState!==0){this.view.inputMessage='';}
    const screen=this.view.displays.find((item:HostDisplay)=>item.id===this.view.selectedDisplay);
    this.view.streamWidth=state.serverRunning?(state.streamWidth||screen?.width||0):0;
    this.view.streamHeight=state.serverRunning?(state.streamHeight||screen?.height||0):0;
    this.view.encodedWidth=this.captureRequested&&state.captureState===0?state.encodedWidth||0:0;
    this.view.encodedHeight=this.captureRequested&&state.captureState===0?state.encodedHeight||0:0;
    this.view.online=state.online===true;
    this.view.deviceId=state.serverRunning?state.assistanceDeviceId:'';
    this.view.code=state.serverRunning?state.assistanceCode:'';
    this.view.assistance=state.assistanceEnabled;
    if(['waiting','preparing','sharing'].includes(this.view.phase)){
      if(!state.serverRunning){this.fail('被控服务已结束，请重新启用。');return;}
      const requested=(state.captureRequests||0)>0;
      if(this.view.keepPrimary&&this.captureRequested){
        if(state.captureState===0){
          this.deadline=0;
          this.view.phase=requested?'sharing':'waiting';
          this.view.message=requested?'正在共享已授权的主屏':'主屏已授权，等待远控连接，可连接其他电脑';
          if(requested&&session.busy&&!session.isClosing){
            session.cancel('本机收到远控连接，已结束向外发起的远控').catch(()=>{});
          }
        }else if(captureEnded(state.captureState)||(this.deadline>0&&Date.now()>this.deadline)){
          this.fail('主屏共享未获授权或已结束，可重新准备。');
          return;
        }
      }else if(!requested){
        if(this.captureRequested){this.releaseCapture(module);}
        this.captureFailed=false;
        this.view.phase='waiting';
        this.view.message=this.captureStopWork?'正在释放上一次屏幕共享…':
          this.view.online?'此电脑已上线，等待连接；当前未采集屏幕':'正在连接 UU 服务…';
      }else if(this.captureFailed){
        this.view.phase='preparing';this.view.message='本次屏幕共享未能启动，等待对方断开后可重试。';
      }else if(!this.captureRequested&&!session.busy&&!session.isClosing){
        this.captureRequested=true;this.view.phase='preparing';this.deadline=Date.now()+25000;
        this.view.soundRequested=this.sound;this.view.message='收到远控请求，请在系统窗口中允许屏幕共享';
        if(!screen||!this.view.encoder||module.startCapture(screen.width,screen.height,screen.id,this.sound)!==0){this.captureFailed=true;this.view.message='本次屏幕共享未能启动，等待对方断开后可重试。';}
      }else if(this.captureRequested){
        if(state.captureState===0){this.view.phase='sharing';this.view.message='正在向已连接设备共享屏幕';}
        else if(captureEnded(state.captureState)||Date.now()>this.deadline){
          this.releaseCapture(module);
          this.captureFailed=true;
          this.view.message='屏幕共享未获授权或已结束，等待对方断开';
        }
      }else{this.view.message='正在控制其他电脑，暂不接受屏幕共享请求';}
    }
    this.publish();
  }
  private releaseCapture(module:HostNative):void {
    this.captureRequested=false;
    const work=Promise.resolve().then(()=>module.stopCaptureAsync()).catch(()=>-1);
    this.captureStopWork=work;
    work.then((result:number)=>{
      this.captureStopWork=undefined;
      if(result!==0&&!this.cleanupPending){this.fail('屏幕采集未能停止，请重新启用共享。');}
    });
  }
  syncAccount():boolean {
    if(!this.native||!client.view.loggedIn||this.busy){return false;}
    if(this.native.bindSharedAccount()!==0){this.view.phase='error';this.view.message='无法读取当前账号，请解锁电脑或重新登录后重试。';this.publish();return false;}
    this.delegated=true;return true;
  }
  async refreshDisplays():Promise<void> {
    if(this.busy||this.view.phase==='waiting'){return;}
    const revision=++this.inventoryEpoch;
    try{const screens=await display.getAllDisplays();if(this.busy||this.view.phase==='waiting'||revision!==this.inventoryEpoch){return;}this.view.displays=screens.filter((item:display.Display)=>item.id>=0&&item.width>0&&item.height>0&&item.width<=8192&&item.height<=8192).map((item:display.Display):HostDisplay=>({id:item.id,name:item.name,width:item.width,height:item.height}));
      if(!this.view.displays.some((item:HostDisplay)=>item.id===this.view.selectedDisplay)){this.view.selectedDisplay=!this.inventoryLoaded&&this.view.displays.length?this.view.displays[0].id:-1;}
      this.inventoryLoaded=true;
    }catch(_){if(this.busy||this.view.phase==='waiting'||revision!==this.inventoryEpoch){return;}this.view.displays=[];this.view.selectedDisplay=-1;this.inventoryLoaded=true;}
    this.publish();
  }
  selectDisplay(id:number):void {if(this.busy||this.view.phase==='waiting'||!this.view.displays.some((item:HostDisplay)=>item.id===id)){return;}this.view.selectedDisplay=id;this.publish();}
  async start():Promise<void> {
    const module=this.native;
    if(!module||!this.canStart){return;}
    this.starting=true;
    this.publish();
    try{
    if(module.bindSharedAccount()!==0){this.view.phase='error';this.view.message='无法读取当前账号，请解锁电脑或重新登录后重试。';this.publish();return;}
    this.delegated=true;const run=++this.lifecycleEpoch;
    await this.refreshDisplays();
    if(run!==this.lifecycleEpoch||!client.view.loggedIn||session.busy||this.cleanupPending){return;}
    const primary=this.view.keepPrimary===true;
    let id=this.view.selectedDisplay;
    if(primary){
      try{id=display.getDefaultDisplaySync().id;}catch(_){id=-1;}
    }
    const screen=this.view.displays.find((item:HostDisplay)=>item.id===id);
    if(!screen){this.view.message='请先选择当前可用的屏幕。';this.publish();return;}
    const configured=module.configureDisplay(screen.width,screen.height,screen.id,this.view.smooth);
    if(configured!==0||module.startHost()!==0){
      await this.fail(configured===-2?'当前编码器不支持流畅档，请选择原画后重试。':'被控服务启动失败，请重试。');
      return;
    }
    this.view.phase='waiting';this.view.message='正在连接 UU 服务…';this.view.audioFrames=0;
    if(primary){
      this.captureRequested=true;
      this.deadline=Date.now()+60000;
      this.view.soundRequested=this.sound;
      this.view.phase='preparing';
      this.view.message='请在系统窗口授权共享主屏';
      if(module.startCapture(screen.width,screen.height,screen.id,this.sound,true)!==0){
        await this.fail('无法准备主屏共享，请重新启动共享。');
        return;
      }
    }
    this.publish();
    }finally{this.starting=false;this.publish();}
  }
  async setEnabled(enabled:boolean):Promise<void>{
    if(enabled&&!this.canStart){return;}
    this.enabled=enabled;
    this.view.settingsMessage='';
    const action=enabled?this.start():this.stop();
    const store=this.store;
    if(store){
      this.settingsWork=this.settingsWork.then(async ()=>{
        if(enabled!==this.enabled){return;}
        store.putSync('enabled',enabled);
        await store.flush();
      }).catch(()=>{
        if(enabled===this.enabled){
          this.view.settingsMessage='未能保存共享开关，下次打开应用时请检查共享状态。';
          this.publish();
        }
      });
    }
    await action;
  }
  private async fail(message:string):Promise<void> {if(!await this.stop()){return;}this.view.phase='error';this.view.message=message;this.publish();}
  async stop():Promise<boolean> {
    this.lifecycleEpoch++;
    const module=this.native;
    if(!module){return true;}
    let work=this.stopWork;
    if(!work){
      this.cleanupPending=true;
      this.captureRequested=false;
      this.captureFailed=false;
      this.view.phase='stopping';
      this.view.message='正在停止共享…';
      this.view.online=false;
      this.view.deviceId='';
      this.view.code='';
      this.view.assistance=false;
      this.view.soundRequested=false;
      this.view.audioFrames=0;
      this.view.streamWidth=0;
      this.view.streamHeight=0;
      this.view.encodedWidth=0;
      this.view.encodedHeight=0;
      this.view.keepPrimary=false;
      const pending=Promise.resolve().then(()=>this.finishStop(module)).catch(()=>this.stopFailed('停止共享遇到问题，请重试。'));
      this.stopWork=pending;
      work=pending;
      pending.then(()=>{if(this.stopWork===pending){this.stopWork=undefined;}});
      this.publish();
    }else if(this.view.phase==='stop-pending'){
      this.view.phase='stopping';
      this.view.message='正在检查共享状态…';
      this.publish();
    }
    const pending=work;
    let timer:number=-1;
    try{
      return await Promise.race([pending,new Promise<boolean>((resolve:(value:boolean)=>void)=>{
        timer=setTimeout(()=>{
          if(this.stopWork===pending&&this.view.phase==='stopping'){
            this.view.phase='stop-pending';
            this.view.message='仍在停止共享，完成后本页会自动更新。';
            this.publish();
          }
          resolve(false);
        },7000);
      })]);
    }finally{if(timer>=0){clearTimeout(timer);}}
  }
  private stopFailed(message:string):boolean {
    this.view.phase='stop-failed';
    this.view.message=message;
    this.publish();
    return false;
  }
  private async finishStop(module:HostNative):Promise<boolean> {
    if(!this.stoppedMedia){
      const releasing=this.captureStopWork;
      const result=await module.stopAsync();
      await releasing;
      if(result!==0){return this.stopFailed('未能停止共享，请重试。');}
      this.stoppedMedia=true;
    }
    while(module.getState().serverRunning){await new Promise<void>((resolve:()=>void)=>{setTimeout(resolve,100);});}
    if(module.clearSharedAccount()!==0){
      return this.stopFailed('共享已停止，账号同步尚未完成，请重试。');
    }
    this.delegated=false;
    this.cleanupPending=false;
    this.stoppedMedia=false;
    this.view.phase='idle';
    this.view.message='共享已关闭';
    this.publish();
    return true;
  }
  requestInput():void {
    if(!this.native){return;}
    this.view.inputMessage=this.native.requestInput()===0?'':'未能打开键鼠授权，请重试。';
    this.publish();
  }
  setAssistance(enabled:boolean):void {if(['waiting','preparing','sharing'].includes(this.view.phase)&&this.native){if(this.native.setAssistanceEnabled(enabled)!==0){this.view.message='设置未成功，请稍后重试。';this.publish();}}}
  resetCode():void {if(['waiting','preparing','sharing'].includes(this.view.phase)){this.native?.resetAssistanceCode();}}
  async publishCover(data:ArrayBuffer):Promise<boolean>{
    if(!this.native||!this.view.online||!client.view.loggedIn){return false;}
    const result=await this.native.publishDeviceCover(data);
    if(result!==0){return false;}
    if(client.view.loggedIn){client.refreshDevices(false);}
    return true;
  }
  dispose():void {this.lifecycleEpoch++;this.inventoryEpoch++;if(this.timer>=0){clearInterval(this.timer);this.timer=-1;}this.authStop?.();this.stop();}
}
export const pcHost:PcHostService=new PcHostService();
