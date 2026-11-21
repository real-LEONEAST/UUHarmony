import { remoteThumbnails } from './RemoteThumbnail';
import { windowPolicy } from './WindowPolicy';
import { UiColor } from './UiFoundation';
import { display } from '@kit.ArkUI';
import { client, AuthView } from './AuthClient';
import { session } from './SessionClient';
import { SettingReply } from './ControlCenter';
import { deviceLockRequest } from './DeviceLockRequest';
import { systemActionResult } from './RemoteSystemAction';
import { LivePreviewModel, PreviewPort, PreviewSample, PreviewRequest, PreviewView } from './LivePreviewModel';

class DetailPreviewPort implements PreviewPort {
  acquire(lock:boolean):number{return session.acquireDetailSession(lock);}
  owned(owner:number):boolean{return session.ownsDetailSession(owner);}
  select(owner:number,key:string,name:string):Promise<boolean>{return session.selectDetailDevice(owner,key,name);}
  surface(owner:number,id:string,width:number,height:number):void{session.detailSurface(owner,id,width,height);}
  async join(owner:number,key:string,lock:boolean=false):Promise<void>{if(this.owned(owner)){if(lock){await session.joinDetailLockConfirmed(owner,key);return;}session.watch=true;session.pauseInput(true);await session.joinConfirmed(key);}}
  sample():PreviewSample{const value:PreviewSample={generation:session.generation,selected:session.selected,busy:session.busy,closing:session.isClosing,control:session.controlOpen,echo:session.controlEcho,frame:session.firstFrame,width:session.frameWidth,height:session.frameHeight,failure:session.lastFailure,focused:session.windowFocused,loggedIn:client.view.loggedIn};return value;}
  observe(fn:()=>void):()=>void{return session.observe(()=>fn());}
  async watch():Promise<boolean>{const result=JSON.parse(await session.setting({kind:'watch',enabled:true})) as SettingReply;return !!result.localApplied&&result.watch===true;}
  bindLock(token:string,key:string,generation:number):boolean{return deviceLockRequest.bind(token,key,generation);}
  consumeLock(token:string,key:string,generation:number):boolean{return deviceLockRequest.consume(token,key,generation);}
  async lock():Promise<string>{return '立即锁屏：'+systemActionResult(await session.setting({kind:'lock_now',confirmed:true}));}
  cancel(owner:number):Promise<void>{return session.cancelDetailSession(owner);}
  async release(owner:number,id:string):Promise<void>{if(id){session.clearDetailSurface(owner,id);}await session.releaseDetailSession(owner);}
}

// Embedded real decoder Surface. No pointer/keyboard/terminal/microphone controls exist here.
@Component
export struct LiveDesktopPreview {
  @Prop deviceKey:string='';
  @Prop deviceName:string='';
  @Prop lockToken:string='';
  onStopped:(message:string)=>void=()=>{};
  @State private status:string='正在准备预览';
  @State private live:boolean=false;
  @State private stopping:boolean=false;
  @State private viewportWidth:number=0;
  @State private viewportHeight:number=0;
  private screenOwner:number=0;
  private surface:string='';private active:boolean=false;private started:boolean=false;
  private model:LivePreviewModel|undefined=undefined;
  private controller:XComponentController=new XComponentController();
  private offAuth:()=>void=()=>{};
  aboutToAppear():void{
    this.active=true;this.screenOwner=windowPolicy.acquireVideoScreen();const port:DetailPreviewPort=new DetailPreviewPort();
    this.model=new LivePreviewModel(port,(value:PreviewView)=>{if(this.active){this.status=value.status;this.live=value.live;this.stopping=value.stopping;windowPolicy.setVideoScreen(this.screenOwner,!this.lockToken&&value.live&&!value.stopping&&session.appForeground&&session.busy&&!session.isClosing&&session.selected===this.deviceKey);this.capturePreviewCover();}},(message:string)=>{if(this.active){this.onStopped(message);}});
    this.offAuth=client.monitor((value:AuthView)=>{if(!value.loggedIn){this.stop('账号已退出，实时预览已停止。');}});
    try{const local=display.getDefaultDisplaySync();session.setViewerDisplay(local.width,local.height,local.refreshRate);}catch(_){}
    this.begin();
  }
  aboutToDisappear():void{if(this.lockToken){deviceLockRequest.cancelToken(this.lockToken);}this.active=false;windowPolicy.releaseVideoScreen(this.screenOwner);this.screenOwner=0;this.offAuth();this.model?.stop('详情已关闭，实时预览已停止。');}
  private begin():void{
    if(!this.active||this.started||(!this.lockToken&&(!this.surface||this.viewportWidth<=0||this.viewportHeight<=0))||!this.model){return;}
    this.started=true;const request:PreviewRequest={key:this.deviceKey,name:this.deviceName,surface:this.surface,width:this.viewportWidth,height:this.viewportHeight,lockToken:this.lockToken||undefined};this.model.start(request);
  }
  private capturePreviewCover():void{
    if(!this.active||!this.live||this.lockToken||!session.firstFrame||!session.controlOpen||!session.busy||session.isClosing||!session.windowFocused||!client.view.loggedIn||!this.surface||session.selected!==this.deviceKey){return;}
    const key=this.deviceKey;const generation=session.generation;const surface=this.surface;
    remoteThumbnails.captureRendered(key,surface,generation,session.frameWidth,session.frameHeight,()=>this.active&&this.live&&!this.lockToken&&session.firstFrame&&session.controlOpen&&session.busy&&!session.isClosing&&session.windowFocused&&client.view.loggedIn&&session.selected===key&&session.generation===generation&&this.surface===surface);
  }
  private stop(message:string):void{if(this.screenOwner){windowPolicy.setVideoScreen(this.screenOwner,false);}if(this.lockToken){deviceLockRequest.cancelToken(this.lockToken);}this.model?.stop(message);}
  build(){
    Column({space:10}){
      Row(){Text(this.lockToken?'设备锁屏':'实时桌面预览').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UiColor.text).layoutWeight(1);Button(this.lockToken?'取消':'停止预览').id('stopLiveDesktopPreview').enabled(!this.stopping).onClick(()=>this.stop(this.lockToken?'已取消锁屏；已发送的指令无法撤回。':'已停止实时预览。'))}.width('100%')
      if(this.lockToken){Text(this.status).fontSize(13).fontColor(UiColor.text).width('100%')}else{
      Stack(){
        XComponent({id:'detailDesktopPreview',type:XComponentType.SURFACE,controller:this.controller})
          .width('100%').height('100%')
          .onLoad(()=>{this.surface=this.controller.getXComponentSurfaceId();this.begin();})
          .onDestroy(()=>{this.stop('预览显示区域已关闭。');this.surface='';})
        if(!this.live||this.lockToken.length>0){Column({space:10}){if(!this.stopping){LoadingProgress().width(30).height(30).color(UiColor.primary)}Text(this.status).fontSize(13).fontColor(UiColor.text).textAlign(TextAlign.Center)}.width('100%').height('100%').padding(16).backgroundColor(UiColor.surface)}
      }.width('100%').aspectRatio(1.7).clip(true).borderRadius(14).backgroundColor('#03070D')
        .onAreaChange((_old:Area,value:Area)=>{this.viewportWidth=Number(value.width);this.viewportHeight=Number(value.height);this.begin();if(this.started){this.model?.resize(this.viewportWidth,this.viewportHeight);}})
      }
      if(this.live&&!this.lockToken){Text(this.status).id('livePreviewStatus').fontSize(12).fontColor(UiColor.secondary).width('100%')}
      Text(this.lockToken?'锁屏请求发出后，请在电脑上确认。':'仅观看').fontSize(11).fontColor(UiColor.secondary).width('100%')
    }.width('100%').padding(14).backgroundColor(UiColor.surface).borderRadius(18)
  }
}
