import { window, display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { deviceInfo, BusinessError } from '@kit.BasicServicesKit';
import { RemoteLayout, remoteLayout } from './RemoteLayoutModel';

// One Stage window; page orientation changes never own or recreate the WebRTC session.
export interface WindowInsets {left:number;right:number;top:number;bottom:number;}
export interface WindowSnapshot {
  width:number;height:number;insets:WindowInsets;keyboardHeight:number;layout:RemoteLayout;
}
export class WindowPolicy {
  private publishGlobal:boolean=false;
  constructor(publishGlobal:boolean=false) {this.publishGlobal=publishGlobal;}
  private main:window.Window|undefined=undefined;
  private remoteClose:(()=>void)|undefined=undefined;
  private titleActive:boolean=false;
  private titleOldVisible:boolean=true;
  private titleOldHeight:number=0;
  private titleOldButtonStyle:window.DecorButtonStyle|undefined=undefined;
  private titleRight:number=0;
  private titleEpoch:number=0;
  private titleRetryTimer:number=-1;
  private titleRetryEpoch:number=0;
  private titleListener:((value:window.TitleButtonRect)=>void)|undefined=undefined;
  private titleObserver:((active:boolean,right:number)=>void)|undefined=undefined;
  private screenOwners:Map<number,boolean>=new Map();
  private screenOwnerSerial:number=0;
  private screenForeground:boolean=false;
  private screenSerial:Promise<void>=Promise.resolve();
  private screenRevision:number=0;
  private serial:Promise<void>=Promise.resolve();
  private wantedRemote:boolean=false;
  private panelSurface:boolean=false;
  private terminalSurfaceOwner:number=0;
  private terminalSurfaceSerial:number=0;
  private context:common.UIAbilityContext|undefined=undefined;
  private generation:number=0;
  private pixelWidth:number=0;private pixelHeight:number=0;private fallbackDensity:number=1;
  private status:window.WindowStatusType=window.WindowStatusType.UNDEFINED;
  private keyboardPixels:number=0;
  private appliedOrientation:window.Orientation|undefined=undefined;
  private policyQueued:boolean=false;private published:string='';
  private observerSerial:number=0;
  private observers:Map<number,(value:WindowSnapshot)=>void> = new Map();
  private avoidChanged:(()=>void)|undefined=undefined;
  private sizeChanged:((value:window.Size)=>void)|undefined=undefined;
  private statusChanged:((value:window.WindowStatusType)=>void)|undefined=undefined;
  private densityChanged:((value:number)=>void)|undefined=undefined;
  private keyboardChanged:((value:number)=>void)|undefined=undefined;
  attach(stage:window.WindowStage,context:common.UIAbilityContext):void {
    const previous=this.main;this.remoteClose=undefined;this.endRemoteTitle();this.unbind();this.main=undefined;this.screenRevision++;
    if(previous){this.screenSerial=this.screenSerial.then(async()=>{try{await previous.setWindowKeepScreenOn(false);}catch(_){}}).catch(()=>{});}
    this.context=context;
    try{this.main=stage.getMainWindowSync();}catch(_){this.main=undefined;}
    const run=++this.generation;
    this.appliedOrientation=undefined;this.published='';this.keyboardPixels=0;
    this.readWindowSize();
    try{this.status=this.main?.getWindowStatus()||window.WindowStatusType.UNDEFINED;}catch(_){this.status=window.WindowStatusType.UNDEFINED;}
    this.avoidChanged=()=>{if(run===this.generation){this.publishSnapshot();}};
    this.sizeChanged=(value:window.Size)=>{
      if(run!==this.generation){return;}
      const before=this.orientation();this.pixelWidth=value.width;this.pixelHeight=value.height;
      this.publishSnapshot();
      // Only a phone becoming a large/folded window changes the orientation policy.
      // Ordinary resize and a phone rotating retain the same short edge and do not enqueue it.
      if(before!==this.orientation()){this.queuePolicy();}
    };
    this.statusChanged=(value:window.WindowStatusType)=>{if(run!==this.generation){return;}const changed=this.status!==value;this.status=value;this.publishSnapshot();if(changed){this.queuePolicy();}};
    this.densityChanged=(value:number)=>{if(run!==this.generation){return;}const before=this.orientation();if(value>0){this.fallbackDensity=value;}this.publishSnapshot();if(before!==this.orientation()){this.queuePolicy();}};
    this.keyboardChanged=(value:number)=>{if(run!==this.generation){return;}this.keyboardPixels=Math.max(0,value);this.publishSnapshot();};
    try{this.main?.on('avoidAreaChange',this.avoidChanged);}catch(_){}
    try{this.main?.on('windowSizeChange',this.sizeChanged);}catch(_){}
    try{this.main?.on('windowStatusChange',this.statusChanged);}catch(_){}
    try{this.main?.on('systemDensityChange',this.densityChanged);}catch(_){}
    try{this.main?.on('keyboardHeightChange',this.keyboardChanged);}catch(_){}
    this.publishSnapshot();
    this.refreshSystemBars();this.queueScreenPolicy();
  }
  private readWindowSize():void {try{const rect=this.main?.getWindowProperties().windowRect;this.pixelWidth=rect?.width||0;this.pixelHeight=rect?.height||0;}catch(_){}}
  private vp(value:number):number {
    if(!Number.isFinite(value)||value<=0){return 0;}
    try{const result=this.main?.getUIContext().px2vp(value);if(result!==undefined&&Number.isFinite(result)&&result>=0){return result;}}catch(_){}
    try{const density=this.main?.getWindowDensityInfo();const current=density&&density.customDensity>0?density.customDensity:density?.systemDensity;if(current&&current>0){return value/current;}}catch(_){}
    try{this.fallbackDensity=display.getDefaultDisplaySync().densityPixels||this.fallbackDensity;}catch(_){}
    return value/this.fallbackDensity;
  }
  private phoneWindow():boolean {
    let phone:boolean=false;try{phone=deviceInfo.deviceType==='phone';}catch(_){}
    if(!phone||![window.WindowStatusType.UNDEFINED,window.WindowStatusType.FULL_SCREEN].includes(this.status)){return false;}
    const w=this.vp(this.pixelWidth),h=this.vp(this.pixelHeight);
    // A normal landscape phone can be wide; its short edge still distinguishes it from a large window.
    return w===0||h===0||Math.min(w,h)<600;
  }
  private remoteOrientation:number=0;
  setRemoteOrientation(value:number):void{if(!Number.isInteger(value)||value<0||value>4){return;}this.remoteOrientation=value;this.queuePolicy();}
  getRemoteOrientation():number{return this.remoteOrientation;}
  private orientation():window.Orientation{return this.phoneWindow()?(this.wantedRemote?([window.Orientation.USER_ROTATION_LANDSCAPE,window.Orientation.PORTRAIT,window.Orientation.LANDSCAPE,window.Orientation.PORTRAIT_INVERTED,window.Orientation.LANDSCAPE_INVERTED][this.remoteOrientation]):window.Orientation.AUTO_ROTATION_RESTRICTED):window.Orientation.UNSPECIFIED;}
  ownWindowId():number{try{return this.main?.getWindowProperties().id??0;}catch(_){return 0;}}
  ownWindowFocused():boolean{try{return this.main?.isFocused()===true;}catch(_){return false;}}
  bindRemoteClose(action:()=>void):()=>void {
    this.remoteClose=action;
    return ()=>{if(this.remoteClose===action){this.remoteClose=undefined;}};
  }
  requestRemoteClose():boolean {
    const action=this.remoteClose;
    if(!action){return false;}
    // Return the window close veto before starting session cleanup.
    setTimeout(()=>{
      if(this.remoteClose!==action){return;}
      try{action();}catch(_){hilog.warn(0x0303,'UUTitle','remote_close_failed');}
    },0);
    return true;
  }
  async focusOwnWindow(sourceId:number):Promise<boolean>{const current=this.main;if(!current){return false;}try{await current.showWindow();if(sourceId>0&&sourceId!==this.ownWindowId()){await window.shiftAppWindowFocus(sourceId,this.ownWindowId());try{await current.restore();}catch(_){}}else{await current.restore();}return this.main===current;}catch(_){return false;}}
  async showMainWindow():Promise<boolean>{const current=this.main;if(!current){return false;}try{try{await current.restore();}catch(_){}await current.showWindow();return this.main===current;}catch(_){return false;}}
  containsDisplayPoint(x:number,y:number,headerOnly:boolean=false):boolean {
    if(!Number.isFinite(x)||!Number.isFinite(y)){return false;}
    try{const w=this.main;if(!w){return false;}const rect=w.getWindowProperties().windowRect;const ui=w.getUIContext();const left=ui.px2vp(rect.left),top=ui.px2vp(rect.top),width=ui.px2vp(rect.width),height=ui.px2vp(rect.height);return x>=left&&x<=left+width&&y>=top&&y<=top+(headerOnly?Math.min(80,height):height);}catch(_){return false;}
  }
  snapshot():WindowSnapshot {
    const width=this.vp(this.pixelWidth),height=this.vp(this.pixelHeight),insets=this.insets();
    let keyboard=this.vp(this.keyboardPixels);
    try{const area=this.main?.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD);if(area){keyboard=Math.max(keyboard,this.vp(area.bottomRect.height));}}catch(_){}
    return {width:width,height:height,insets:insets,keyboardHeight:keyboard,
      layout:remoteLayout(Math.max(0,width-insets.left-insets.right),Math.max(0,height-insets.top-insets.bottom))};
  }
  observe(listener:(value:WindowSnapshot)=>void):()=>void {
    const id=++this.observerSerial;this.observers.set(id,listener);
    try{listener(this.snapshot());}catch(_){hilog.warn(0x0303,'UUP0UI','window_observer_failed');}
    return ()=>{this.observers.delete(id);};
  }
  videoInsets():WindowInsets {
    const result:WindowInsets={left:0,right:0,top:0,bottom:0};
    if(!this.phoneWindow()){return result;}
    for(const type of [window.AvoidAreaType.TYPE_CUTOUT,window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR]){
      try{const area=this.main?.getWindowAvoidArea(type);if(area){result.left=Math.max(result.left,this.vp(area.leftRect.width));result.right=Math.max(result.right,this.vp(area.rightRect.width));result.top=Math.max(result.top,this.vp(area.topRect.height));result.bottom=Math.max(result.bottom,this.vp(area.bottomRect.height));}}catch(_){}
    }
    return result;
  }
  insets():WindowInsets {
    const result:WindowInsets={left:18,right:18,top:12,bottom:12};
    const types:window.AvoidAreaType[]=[window.AvoidAreaType.TYPE_CUTOUT,window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR];
    if(!this.wantedRemote||!this.phoneWindow()){types.push(window.AvoidAreaType.TYPE_SYSTEM);}
    for(const type of types){
      try{const area=this.main?.getWindowAvoidArea(type);if(area){
        result.left=Math.max(result.left,this.vp(area.leftRect.width)+8);
        result.right=Math.max(result.right,this.vp(area.rightRect.width)+8);
        result.top=Math.max(result.top,this.vp(area.topRect.height)+8);
        result.bottom=Math.max(result.bottom,this.vp(area.bottomRect.height)+8);
      }}catch(_){}
    }
    return result;
  }
  private publishSnapshot():void {
    const value=this.snapshot(),key=JSON.stringify(value);if(key===this.published){return;}this.published=key;
    if(this.publishGlobal){AppStorage.setOrCreate('uuSafeTop',value.insets.top);AppStorage.setOrCreate('uuSafeBottom',value.insets.bottom);
    AppStorage.setOrCreate('uuSafeLeft',value.insets.left);AppStorage.setOrCreate('uuSafeRight',value.insets.right);
    AppStorage.setOrCreate('uuWindowWidth',value.width);AppStorage.setOrCreate('uuWindowHeight',value.height);}
    this.observers.forEach((listener:(value:WindowSnapshot)=>void)=>{try{listener(this.snapshot());}catch(_){hilog.warn(0x0303,'UUP0UI','window_observer_failed');}});
  }
  private unbind():void {
    if(this.avoidChanged){try{this.main?.off('avoidAreaChange',this.avoidChanged);}catch(_){}}
    if(this.sizeChanged){try{this.main?.off('windowSizeChange',this.sizeChanged);}catch(_){}}
    if(this.statusChanged){try{this.main?.off('windowStatusChange',this.statusChanged);}catch(_){}}
    if(this.densityChanged){try{this.main?.off('systemDensityChange',this.densityChanged);}catch(_){}}
    if(this.keyboardChanged){try{this.main?.off('keyboardHeightChange',this.keyboardChanged);}catch(_){}}
    this.generation++;
  }
  detach():void {this.remoteClose=undefined;this.terminalSurfaceOwner=0;this.cancelTitleRetry();const old=this.main;this.endRemoteTitle();this.unbind();this.main=undefined;this.screenRevision++;if(old){this.screenSerial=this.screenSerial.then(async()=>{try{await old.setWindowKeepScreenOn(false);}catch(_){}}).catch(()=>{});}this.context=undefined;this.pixelWidth=0;this.pixelHeight=0;this.keyboardPixels=0;this.appliedOrientation=undefined;this.published='';this.observers.clear();}
  private updateTitleRect(rect:window.TitleButtonRect):void {
    if(!this.titleActive){return;}
    // TitleButtonRect is already in vp and measured from the window's upper right.
    const width=this.vp(this.pixelWidth);
    if(!Number.isFinite(rect.width)||!Number.isFinite(rect.right)||!Number.isFinite(rect.top)||!Number.isFinite(rect.height)||rect.width<=0||rect.height<=0||rect.right<0||rect.top<0||rect.top+rect.height>48||(width>0&&rect.width+rect.right>width)){hilog.warn(0x0303,'UUTitle','rect global=%{public}d width=%{public}d right=%{public}d top=%{public}d height=%{public}d windowWidth=%{public}d',this.publishGlobal?1:0,rect.width||0,rect.right||0,rect.top||0,rect.height||0,width||0);this.endRemoteTitle();return;}
    this.titleRight=Math.ceil(rect.width+rect.right+8);this.titleObserver?.(true,this.titleRight);
  }
  beginScopedRemoteTitle(observer:(active:boolean,right:number)=>void):void {
    this.cancelTitleRetry();const run=++this.titleRetryEpoch;let attempts=0;
    const attempt=()=>{if(run!==this.titleRetryEpoch){return;}attempts++;this.beginRemoteTitle((active:boolean,right:number)=>{
      observer(active,right);
      if(active&&this.titleRetryTimer>=0){clearTimeout(this.titleRetryTimer);this.titleRetryTimer=-1;}
      if(!active&&attempts<10&&run===this.titleRetryEpoch&&this.titleRetryTimer<0){this.titleRetryTimer=setTimeout(()=>{this.titleRetryTimer=-1;attempt();},150);}
    });};attempt();
  }
  cancelTitleRetry():void {this.titleRetryEpoch++;if(this.titleRetryTimer>=0){clearTimeout(this.titleRetryTimer);this.titleRetryTimer=-1;}}
  beginRemoteTitle(observer:(active:boolean,right:number)=>void):void {
    this.endRemoteTitle();this.titleObserver=observer;
    const current=this.main;if(!current||!['pc','2in1'].includes(deviceInfo.deviceType)){hilog.info(0x0303,'UUTitle','stage=0 global=%{public}d code=0 inset=0',this.publishGlobal?1:0);observer(false,0);return;}
    try{this.titleOldVisible=current.getWindowDecorVisible();this.titleOldHeight=current.getWindowDecorHeight();this.titleOldButtonStyle=current.getDecorButtonStyle();}catch(error){hilog.warn(0x0303,'UUTitle','stage=1 global=%{public}d code=%{public}d inset=0',this.publishGlobal?1:0,(error as BusinessError).code||0);this.titleObserver=undefined;observer(false,0);return;}
    let substage=0;try{
      this.titleActive=true;substage=1;current.setWindowDecorHeight(48);substage=2;current.setWindowTitleMoveEnabled(false);substage=3;current.setDecorButtonStyle({colorMode:this.captionMode()});substage=4;current.setWindowDecorVisible(false);
      const epoch=++this.titleEpoch;this.titleListener=(rect:window.TitleButtonRect)=>{if(this.main===current&&this.titleEpoch===epoch){this.updateTitleRect(rect);}};
      substage=5;current.on('windowTitleButtonRectChange',this.titleListener);substage=6;this.updateTitleRect(current.getTitleButtonRect());hilog.info(0x0303,'UUTitle','stage=%{public}d global=%{public}d code=0 inset=%{public}d',this.titleActive?3:2,this.publishGlobal?1:0,this.titleRight);
    }catch(error){hilog.warn(0x0303,'UUTitle','stage=2 global=%{public}d code=%{public}d substage=%{public}d inset=0',this.publishGlobal?1:0,(error as BusinessError).code||0,substage);this.titleActive=true;this.endRemoteTitle();observer(false,0);}
  }
  endRemoteTitle():void {
    this.titleEpoch++;
    const current=this.main;const observer=this.titleObserver;this.titleObserver=undefined;
    const wasActive=this.titleActive;this.titleActive=false;
    if(this.titleListener){try{current?.off('windowTitleButtonRectChange',this.titleListener);}catch(_){}this.titleListener=undefined;}
    if(wasActive&&current){try{current.setWindowTitleMoveEnabled(true);}catch(_){}try{if(this.titleOldButtonStyle){current.setDecorButtonStyle(this.titleOldButtonStyle);}}catch(_){}try{if(this.titleOldHeight>=37&&this.titleOldHeight<=112){current.setWindowDecorHeight(this.titleOldHeight);}}catch(_){}try{current.setWindowDecorVisible(this.titleOldVisible);}catch(_){}}
    this.titleOldButtonStyle=undefined;
    this.titleRight=0;observer?.(false,0);
  }
  moveRemoteWindow():void {if(!this.titleActive||!this.main){return;}try{this.main.startMoving().catch(()=>{});}catch(_){}}
  toggleRemoteWindowSize():void {if(!this.titleActive||!this.main){return;}try{const current=this.main;const status=current.getWindowStatus();(status===window.WindowStatusType.MAXIMIZE||status===window.WindowStatusType.FULL_SCREEN?current.recover():current.maximize(window.MaximizePresentation.EXIT_IMMERSIVE)).catch(()=>{});}catch(_){}}
  acquireVideoScreen():number{const id=++this.screenOwnerSerial;this.screenOwners.set(id,false);return id;}
  setVideoScreen(owner:number,active:boolean):void{if(!this.screenOwners.has(owner)||this.screenOwners.get(owner)===active){return;}this.screenOwners.set(owner,active);this.queueScreenPolicy();}
  releaseVideoScreen(owner:number):void{if(this.screenOwners.delete(owner)){this.queueScreenPolicy();}}
  setScreenForeground(value:boolean):void{if(this.screenForeground===value){return;}this.screenForeground=value;if(!value){this.screenOwners.forEach((_active:boolean,id:number)=>this.screenOwners.set(id,false));}this.queueScreenPolicy();}
  private queueScreenPolicy():void{
    const revision=++this.screenRevision;
    this.screenSerial=this.screenSerial.then(async()=>{const current=this.main;if(!current||revision!==this.screenRevision){return;}
      const wanted=this.screenForeground&&Array.from(this.screenOwners.values()).some((value:boolean)=>value);
      try{await current.setWindowKeepScreenOn(wanted);}catch(error){const code=(error as BusinessError).code||0;hilog.warn(0x0303,'UUP0UI','window_keep_screen_on_failed code=%{public}d',code);}
      // A later change is serialized after this call; it restores the newest state.
    }).catch(()=>{});
  }
  acquireTerminalSurface():number {const owner=++this.terminalSurfaceSerial;this.terminalSurfaceOwner=owner;this.refreshSystemBars();return owner;}
  releaseTerminalSurface(owner:number):void {if(owner===0||owner!==this.terminalSurfaceOwner){return;}this.terminalSurfaceOwner=0;this.refreshSystemBars();}
  setPanelSurface(value:boolean):void {if(this.panelSurface===value){return;}this.panelSurface=value;this.refreshSystemBars();}
  private color(resource:Resource):string {
    const manager=this.context?.resourceManager;if(!manager){throw new Error('window_context_unavailable');}
    return '#'+(manager.getColorSync(resource.id)>>>0).toString(16).padStart(8,'0');
  }
  private captionMode():ConfigurationConstant.ColorMode {
    const color=this.context?.resourceManager.getColorSync($r('app.color.ui_surface').id)??0xFFFFFFFF;
    const r=(color>>>16)&255,g=(color>>>8)&255,b=color&255;
    return r*299+g*587+b*114<128000?ConfigurationConstant.ColorMode.COLOR_MODE_DARK:ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
  }
  private async paintSystemBars(current:window.Window):Promise<void>{
    try{
      const background:string=this.terminalSurfaceOwner!==0?'#FFFFFFFF':this.wantedRemote?(this.panelSurface?this.color($r('app.color.ui_surface')):'#FF03070D'):this.color($r('app.color.ui_background'));
      const foreground:string=this.terminalSurfaceOwner!==0?'#FF20242A':this.wantedRemote&&!this.panelSurface?'#FFF2F5FA':this.color($r('app.color.ui_text'));
      if(this.titleActive){try{current.setDecorButtonStyle({colorMode:this.captionMode()});}catch(_){}}
      current.setWindowBackgroundColor(background);
      await current.setWindowSystemBarProperties({statusBarColor:background,navigationBarColor:background,statusBarContentColor:foreground,navigationBarContentColor:foreground,enableStatusBarAnimation:false,enableNavigationBarAnimation:false});
    }catch(error){const code=(error as BusinessError).code||0;hilog.warn(0x0303,'UUP0UI','window_system_bar_colors_failed code=%{public}d',code);}
  }
  refreshSystemBars():Promise<void>{
    this.serial=this.serial.then(async()=>{const current=this.main;if(current){this.readWindowSize();await this.paintSystemBars(current);this.publishSnapshot();}}).catch(()=>{});
    return this.serial;
  }
  applyRemote(remote:boolean):Promise<void>{
    this.wantedRemote=remote;
    if(!remote){this.panelSurface=false;this.remoteOrientation=0;}
    return this.queuePolicy();
  }
  private queuePolicy():Promise<void> {
    if(this.policyQueued){return this.serial;}this.policyQueued=true;
    this.serial=this.serial.then(async()=>{
      this.policyQueued=false;
      const current=this.main,run=this.generation;if(!current){return;}
      const direction=this.orientation();
      if(this.appliedOrientation!==direction){try{await current.setPreferredOrientation(direction);if(this.main===current&&run===this.generation){this.appliedOrientation=direction;}}catch(_){hilog.warn(0x0303,'UUP0UI','window_orientation_request_failed');}}
      if(run!==this.generation||current!==this.main){return;}
      // Gesture navigation is drawn over app content; an opaque bar color alone
      // cannot paint the reserved strip of a non-fullscreen window.
      try{await current.setWindowLayoutFullScreen(true);}catch(_){hilog.warn(0x0303,'UUP0UI','window_fullscreen_request_failed');}
      if(run!==this.generation||current!==this.main){return;}
      try{await current.setWindowSystemBarEnable(this.wantedRemote&&this.phoneWindow()?[]:['status','navigation']);}catch(_){hilog.warn(0x0303,'UUP0UI','window_system_bars_request_failed');}
      if(run!==this.generation||current!==this.main){return;}
      await this.paintSystemBars(current);
      this.publishSnapshot();
    }).catch(()=>{this.policyQueued=false;});return this.serial;
  }
}
export const windowPolicy:WindowPolicy=new WindowPolicy(true);
