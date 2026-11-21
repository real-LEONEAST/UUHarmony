import { CameraGesture } from './CameraGesture';
import { VirtualPlanStore } from './VirtualPlanStore';
import { layoutVirtualControls, VirtualPlacement, VirtualPlacementRequest, VirtualLayout } from './VirtualKeyLayout';
import { client, AuthView } from './AuthClient';
import { OwnedInputDispatcher } from './OwnedInputDispatcher';
import { PointerMotionOwnership } from './PointerMotionOwnership';
import { VirtualKeyRuntime } from './VirtualKeyRuntime';
import { VirtualKeyControl } from './VirtualKeyControl';
import { VirtualPlan, VirtualControl } from './VirtualKeyModel';
import { virtualSelection } from './VirtualPlanSelection';
import { adaptUuPlan } from './UuPlanAdapter';
import { util } from '@kit.ArkTS';
import { remotePresentation, RemotePresentation, remoteRailPlacement, RemoteRailPlacement } from './RemotePresentationModel';
import { UiColor } from './UiFoundation';
import { detached } from './DetachedCoordinator';
import { UiThemeDialog, UiDialogOptions } from './UiThemeDialog';
import { launchSelectedApp } from './AppCatalog';
import { RemoteTerminalPanel } from './RemoteTerminalPanel';
import { deviceLockRequest } from './DeviceLockRequest';
import { image } from '@kit.ImageKit';
import { remoteThumbnails } from './RemoteThumbnail';
import { RemoteSystemAction, systemActionLabel, systemActionResult } from './RemoteSystemAction';
import { AdvancedClient, AdvancedCommand } from './AdvancedClient';
import { AdvancedPanel } from './AdvancedPanel';
import { center, ControlView, ControlRow, SettingRequest, snapshotView } from './ControlCenter';
import { activeScreen, resolutionSize } from './DisplayModel';
import { videoCapabilities } from 'libs3c.so';
import { display, KeyboardAvoidMode } from '@kit.ArkUI';
import { windowPolicy } from './WindowPolicy';
import { RemoteRoute } from './RemoteRoute';
import { RemoteToolsRail } from './RemoteToolsRail';
import { adjacentScreen, toolbarScreenLabel } from './RemoteToolbarModel';
import { remoteLayout } from './RemoteLayoutModel';
import { PcTitleLayout, pcTitleLayout } from './PcTitleLayout';
import { ScreenRow, displayStatus } from './DisplayModel';
import { WindowSnapshot } from './WindowPolicy';
import { session, WindowsUnlockReply } from './SessionClient';
import { MobileInput, RemoteInput } from './MobileInput';
import { HardwareInput, harmonyKeyToVk } from './HardwareInputModel';
import { GamepadInput } from './GamepadInput';
import { common } from '@kit.AbilityKit';
import { MicrophoneClient, MicrophoneCommand, MicrophoneView } from './MicrophoneClient';
import { inputDevice } from '@kit.InputKit';
import { RemoteKeyboardDock } from './RemoteKeyboardDock';
import { RemoteOperationsPanel } from './RemoteOperationsPanel';
import { RemotePreferences } from './RemotePreferences';
import { pcHost } from '../pc/PcHostService';
import { pcFileWindows } from '../pc/PcFileWindows';
import { effectiveInputMode, RemoteInteractionState, RemoteInteractionFeedback, interactionFeedback } from './RemoteInteractionModel';
import { TabletTouch, TabletEvent, TabletPoint } from './TabletTouch';
import { VirtualMouse, VirtualContacts } from './VirtualMouse';
import { MobileTouch, TouchPoint, TouchMode, TouchEventKind, TouchAction, TouchActionKind, TouchView } from './MobileTouch';

interface TerminalReply {phase?:string;output?:string;sent?:boolean;error?:string;}

@Entry
@Component
struct RemoteDesktop {
  @State private unlockAvailable:boolean=false;
  @State private unlockEnrolled:boolean=false;
  @State private unlockEnabled:boolean=false;
  @State private unlockReenrollmentRequired:boolean=false;
  @State private unlockBusy:boolean=false;
  @State private unlockTogglePending:boolean=false;
  @State private unlockToggleFailure:string='';
  @State private orientationChoice:number=0;
  @State private unlockText:string='等待当前授权会话';
  private unlockStatusAt:number=0;
  private unlockStatusEpoch:number=-1;
  private unlockAutoEpoch:number=-1;
  @State private terminalOpen:boolean=false;
  @State private terminalDraft:string='';
  @State private terminalOutput:string='';
  @State private terminalPhase:string='closed';
  @State private terminalStatus:string='尚未打开';
  @State private terminalBusy:boolean=false;
  private terminalTimer:number=-1;
  private terminalPolling:boolean=false;
  @State private thumbnailPending:boolean=false;
  @State private thumbnailHint:string='设备封面会随已连接画面自动更新。';
  @State private systemActionPending:boolean=false;
  @State private systemActionText:string='需要当前授权会话；Windows 实际执行兼容性尚待验证。';
  @State private advancedOpen:boolean=false;
  @State private fileBrowsing:boolean=false;
  @State private advancedInitial:number=0;
  private advanced:AdvancedClient=new AdvancedClient((c:AdvancedCommand)=>session.advancedCommand(c));
  @State private centerView:ControlView=new ControlView();
  @State private centerOpen:boolean=false;
  @State private showConnectionDetails:boolean=false;
  @State private qa:number=5;
  @State private requestedFps:number=0;
  @State private requestedResolution:string='remote';
  @State private requestedLock:boolean=false;
  @State private requestedMute:boolean=false;

  

  @State private signalText:string='请选择本人 Windows 电脑';
  @State private selected:number=0;
  @State private active:boolean=false;
  @State private controlEnabled:boolean=false;
  @State private frameWidth:number=1280;
  @State private frameHeight:number=720;
  @State private viewportW:number=320;
  @State private viewportH:number=180;
  @State private stageW:number=320;
  @State private stageH:number=180;
  @State private mode:TouchMode=TouchMode.Direct;
  private preferredMode:TouchMode=TouchMode.Direct;
  private virtualAccount:string='';private offVirtualAccount:()=>void=()=>{};
  private virtualGateReady:boolean=false;
  @State private cameraMode:boolean=false;
  @State private virtualKeysOn:boolean=false;
  @State private virtualKeysHidden:boolean=false;
  @State private virtualFolder:string='';
  @State private roundSelected:string='';
  @State private virtualPlan:VirtualPlan|undefined=undefined;
  private cameraContact:number=-1;private cameraTouches:Set<number>=new Set();
  private camera:CameraGesture=new CameraGesture((dx:number,dy:number)=>this.dispatchOwned('camera:'+this.cameraContact,[{action:'mouse_move_relative',delta_x:dx,delta_y:dy}]),()=>this.safeReset());
  private motionOwner:PointerMotionOwnership=new PointerMotionOwnership();
  private ownedInput:OwnedInputDispatcher=new OwnedInputDispatcher((events:RemoteInput[])=>session.sendInput(events),()=>session.releaseInputs());
  private virtualRuntime:VirtualKeyRuntime=new VirtualKeyRuntime(this.ownedInput.ownership(),(kind:string,id:string)=>this.virtualLocal(kind,id),(delta:number)=>this.virtualWheel(delta),(id:number,dx:number,dy:number,end:boolean)=>this.virtualDrag(id,dx,dy,end),(id:number,controlId:string,dx:number,dy:number,end:boolean,commit:boolean)=>this.virtualRound(id,controlId,dx,dy,end,commit));
  private dragResidualX:number=0;private dragResidualY:number=0;
  @State private touchSupport:number=0;
  @State private viewOnly:boolean=false;
  @State private cursorX:number=0.5; @State private cursorY:number=0.5;
  @State private mouseSize:number=1; @State private mouseOpacity:number=0.8;
  @State private mousePanelX:number=20; @State private mousePanelY:number=30;
  private tablet:TabletTouch=new TabletTouch(); private tabletSuppressed:boolean=false;
  private virtualMouse:VirtualMouse=new VirtualMouse(); private virtualContacts:VirtualContacts=new VirtualContacts();
  private virtualHeld:boolean=false; private virtualRightHeld:boolean=false; private virtualMiddleHeld:boolean=false;
  private virtualHandleX:number=0; private virtualHandleY:number=0;
  private canvasContacts:number=0; private virtualMulti:boolean=false; private virtualPaired:boolean=false;
  @State private speed:number=1;
  @State private zoom:number=1;
  @State private panX:number=0;
  @State private panY:number=0;
  @State private keyboard:boolean=false;
  @State private imeReset:number=0;
  @State private composing:boolean=false;
  @State private ctrl:boolean=false;
  @State private alt:boolean=false;
  @State private shift:boolean=false;
  @State private win:boolean=false;
  @State private inputHint:string='手机选词后即时上屏；外接键盘原生转发。';
  @State private imeHeight:number=0;
  @State private imeFocused:boolean=false;
  @State private externalKeyboard:boolean=false;
  @State private mergedPcTitle:boolean=false;
  @State private titleButtonInset:number=0;
  private initialCanvasFocusScheduled:boolean=false;
  private initialCanvasFocusDone:boolean=false;
  private canvasFocusRestorePending:boolean=false;
  private canvasFocusEpoch:number=0;
  private canvasPanelWasOpen:boolean=false;
  @State private gamepadEnabled:boolean=false;
  private mic:MicrophoneClient=new MicrophoneClient((c:MicrophoneCommand)=>{
    const command:AdvancedCommand={op:c.op,event:c.event};
    return session.advancedCommand(command);
  });
  @State private micActive:boolean=false;
  @State private micText:string='麦克风未开启';
  private micAllowed:boolean=false;
  private gamepad:GamepadInput=new GamepadInput((events:RemoteInput[])=>this.dispatchOwned('gamepad',events));
  private deviceListener=(change:inputDevice.DeviceListener):void=>{
    if(change.type==='remove' && this.gamepad.device===change.deviceId){this.safeReset();}
  };
  private keyboardDeviceListener=(change:inputDevice.DeviceListener):void=>{if(change.type==='remove'){this.safeReset();}};
  @State private canvasFocused:boolean=false;
  @State private toolsOpen:boolean=false;
  @State private operationsInitial:string='ops';
  @State private operationsPage:string='ops';
  private childParent:string='';
  @State private monitorsOpen:boolean=false;
  @State private screenBusy:boolean=false;
  @State private monitorRequestError:string='';
  @State private exitPending:boolean=false;
  @State private exitConfirming:boolean=false;
  @State private preferenceHint:string='操作方式和速度会记在本机，下次连接沿用。';
  @State private codecPreference:number=0;
  private preferences:RemotePreferences|undefined=undefined;
  private preferenceWrite:number=0;
  @State private hasFrame:boolean=false;
  @State private failureText:string='';
  @State private videoLeft:number=0;@State private videoRight:number=0;@State private videoTop:number=0;@State private videoBottom:number=0;
  @State private safeLeft:number=24;@State private safeRight:number=24;@State private safeTop:number=14;@State private safeBottom:number=14;
  @State private desktopName:string='远程桌面';
  private surfaceId:string='';private visible:boolean=false;private joining:boolean=false;private toolsTimer:number=-1;
  private surfaceController:XComponentController=new XComponentController();
  private tickTimer:number=-1;
  private releaseWindow:(()=>void)|undefined=undefined;
  private releaseRemoteClose:()=>void=()=>{};
  private returnAfterHiddenRoom():boolean {
    if(!this.joining||!session.takeEndedHiddenRoom()){return false;}
    if(!this.exitPending){this.exitPending=true;this.getUIContext().getRouter().back();}
    return true;
  }
  private screenOwner:number=0;
  private offSession:()=>void=()=>{};
  private offInputReset:()=>void=()=>{};
  private offScreenSession:()=>void=()=>{};
  private syncScreenOn():void{if(this.screenOwner){windowPolicy.setVideoScreen(this.screenOwner,this.visible&&!this.exitPending&&!this.directLockFlow&&!this.lockToken&&!!this.surfaceId&&session.appForeground&&session.busy&&!session.isClosing&&!session.filesOnly&&!session.catalogOnly&&!session.lockOnly&&session.controlOpen&&session.firstFrame);}}
  private previousKeyboardAvoid:KeyboardAvoidMode=KeyboardAvoidMode.OFFSET;
  private dispatchInput(events:RemoteInput[]):boolean {return this.dispatchOwned('shortcut',events);}
  private dispatchOwned(owner:string,events:RemoteInput[]):boolean {
    const filtered=events.filter((event:RemoteInput)=>!((event.action==='mouse_move_absolute'||event.action==='mouse_move_relative')&&!this.motionOwner.permits(owner)));return filtered.length===0||this.ownedInput.send(owner,filtered);
  }
  private virtualKeysReady():boolean {return this.virtualKeysOn&&this.stageW>this.stageH&&this.virtualLayout().complete&&this.visible&&this.inputAvailable()&&session.windowFocused&&session.appForeground&&!session.watch&&!this.toolsOpen&&!this.keyboard&&!this.advancedOpen&&!this.centerOpen&&!this.monitorsOpen&&!this.terminalOpen;}
  private syncVirtualGate():void {
    const ready=this.virtualKeysReady();const wasReady=this.virtualGateReady;this.virtualGateReady=ready;
    if(wasReady&&!ready){this.safeReset();}
    if(ready){this.virtualRuntime.resume();}else{this.virtualRuntime.resetLocal();}
  }
  private virtualWheel(delta:number):boolean {try{return this.virtualKeysReady()&&this.dispatchOwned('overlay-wheel',[{action:'mouse_scroll',delta_x:0,delta_y:delta}]);}catch(_){try{this.safeReset();}catch(__){}return false;}}
  private virtualDrag(id:number,dx:number,dy:number,end:boolean):boolean {
    try{const owner='overlay:'+id;if(end){this.motionOwner.release(owner);this.dragResidualX=0;this.dragResidualY=0;return true;}
    if(!this.virtualKeysReady()||!this.motionOwner.permits(owner)){return false;}if(!this.motionOwner.owns(owner)){if(!this.mobile.flush()||!this.pointer.flush()){return false;}if(!this.motionOwner.acquire(owner)){return false;}}const camera=this.virtualPlan?.camera;this.dragResidualX+=dx*(camera?.enabled?camera.sensitivityX:1);this.dragResidualY+=dy*(camera?.enabled?camera.sensitivityY:1);
    const x=Math.trunc(this.dragResidualX),y=Math.trunc(this.dragResidualY);this.dragResidualX-=x;this.dragResidualY-=y;
    return x===0&&y===0?true:this.dispatchOwned(owner,[{action:'mouse_move_relative',delta_x:x,delta_y:y}]);}catch(_){try{this.safeReset();}catch(__){}return false;}
  }
  private virtualLocal(kind:string,id:string):void {
    if(kind==='visibility'){this.safeReset();this.virtualKeysHidden=!this.virtualKeysHidden;this.syncVirtualGate();}
    else if(kind==='folder_round_start'){this.roundSelected='';this.virtualFolder=id;this.syncVirtualGate();}
    else if(kind==='folder_list'){const prior=this.virtualFolder;this.safeReset();this.virtualFolder=prior===id?'':id;this.syncVirtualGate();}
  }
  private virtualRound(id:number,controlId:string,dx:number,dy:number,end:boolean,commit:boolean):void {
    const plan=this.virtualPlan;if(!plan||this.virtualFolder!==controlId){return;}
    const children=plan.controls.filter((item:VirtualControl)=>item.ownerId===controlId).sort((a:VirtualControl,b:VirtualControl)=>a.order-b.order);
    if(!end){if(Math.hypot(dx,dy)<0.45||!children.length){this.roundSelected='';return;}const parent=plan.controls.find((item:VirtualControl)=>item.id===controlId);if(!parent){return;}const origin=this.virtualPlacement(parent);const cx=origin.x+origin.size/2,cy=origin.y+origin.size/2;let best=-2,chosen='';for(const child of children){const target=this.virtualPlacement(child);const vx=target.x+target.size/2-cx,vy=target.y+target.size/2-cy;const length=Math.hypot(vx,vy)*Math.hypot(dx,dy);if(length>0){const score=(vx*dx+vy*dy)/length;if(score>best){best=score;chosen=child.id;}}}this.roundSelected=chosen;return;}
    const selected=children.find((item:VirtualControl)=>item.id===this.roundSelected);this.roundSelected='';this.virtualFolder='';
    if(!commit||!selected||!selected.enabled||!this.virtualKeysReady()){return;}
    if(selected.kind==='visibility'){this.virtualLocal('visibility',selected.id);return;}
    if(selected.kind==='wheel'){this.virtualWheel(120);return;}
    if(selected.kind==='key'||selected.kind==='mouse'||selected.kind==='combo'){const owner='round:'+id,arbiter=this.ownedInput.ownership(),epoch=arbiter.generation();if(arbiter.acquire(owner,selected.actions,epoch)){arbiter.releaseOwner(owner,epoch);}}
  }
  private async toggleVirtualKeys():Promise<void>{
    this.safeReset();if(this.virtualKeysOn){this.virtualKeysOn=false;this.virtualFolder='';this.syncPreferredMode();this.toggleTools(false);return;}
    if(this.stageW<=this.stageH){this.getUIContext().getPromptAction().showToast({message:'请横屏使用虚拟按键'});return;}
    let plan:VirtualPlan|undefined=undefined;const run=session.generation;
    const scope=client.view.loggedIn?(client.view.wallpaperAccountKey||''):'offline';
    const currentScope=():string=>client.view.loggedIn?(client.view.wallpaperAccountKey||''):'offline';
    if(!scope){this.getUIContext().getPromptAction().showToast({message:'登录资料尚未就绪'});return;}
    try{
      const context=this.getUIContext().getHostContext() as common.UIAbilityContext;const store=new VirtualPlanStore(context,scope,currentScope);const saved=await store.current();
      if(run!==session.generation||scope!==currentScope()||!this.visible){return;}
      if(saved.state==='invalid'){this.getUIContext().getPromptAction().showToast({message:'已选方案无法读取，请重新选择'});return;}
      if(saved.state==='ready'&&saved.item){if(!saved.item.plan.canActivate){this.getUIContext().getPromptAction().showToast({message:'已选方案含待适配功能，请重新选择'});return;}plan=saved.item.plan;virtualSelection.set(plan,saved.item.id);}
      else{const bytes=await context.resourceManager.getRawFileContent('virtual-key-default.json');const raw=util.TextDecoder.create('utf-8',{fatal:true}).decodeToString(bytes);const result=adaptUuPlan(raw,'builtin');if(result.ok&&result.plan&&result.plan.canActivate){plan=result.plan;virtualSelection.set(plan);}}
    }catch(_){this.getUIContext().getPromptAction().showToast({message:'方案读取失败'});return;}
    if(!plan||!plan.canActivate||run!==session.generation||scope!==currentScope()||!this.visible||!session.busy){return;}
    if(plan.camera&&!this.camera.configure(plan.camera)){this.getUIContext().getPromptAction().showToast({message:'视角设置无效'});return;}
    this.virtualPlan=plan;this.cameraMode=!!plan.camera?.enabled;this.virtualKeysHidden=false;this.virtualFolder='';this.virtualKeysOn=true;
    if(this.mode===TouchMode.Tablet||this.mode===TouchMode.VirtualMouse){this.mode=TouchMode.Direct;this.touch.setMode(this.mode);}
    this.toggleTools(false);this.syncVirtualGate();
  }
  private toggleCameraMode():void{this.safeReset();this.cameraMode=!this.cameraMode;this.toggleTools(false);this.syncVirtualGate();}
  private manageVirtualKeys(edit:boolean=false):void{this.safeReset();this.virtualKeysOn=false;this.toggleTools(false);this.getUIContext().getRouter().pushUrl({url:'pages/VirtualPlanPage',params:{origin:'remote',mode:edit?'edit':'select'}}).catch(()=>{});}
  private virtualVisibleControls():VirtualControl[]{
    const plan=this.virtualPlan;if(!plan){return [];}if(this.virtualKeysHidden){return plan.controls.filter((c:VirtualControl)=>c.kind==='visibility');}const roots=plan.controls.filter((c:VirtualControl)=>!c.ownerId&&(c.visible||c.kind==='visibility'));if(this.virtualFolder){const parent=roots.find((c:VirtualControl)=>c.id===this.virtualFolder);const children=plan.controls.filter((c:VirtualControl)=>c.ownerId===this.virtualFolder&&(c.visible||c.kind==='visibility')).sort((a:VirtualControl,b:VirtualControl)=>a.order-b.order);if(parent?.kind==='folder_list'){return [parent,...children];}return roots.concat(children);}return roots;
  }
  private baseVirtualSize(c:VirtualControl):number{return Math.max(40,Math.min(160,c.radius*2));}
  private baseVirtualPoint(c:VirtualControl):TouchPoint {
    let x=c.x*this.stageW,y=c.y*this.stageH;const plan=this.virtualPlan;
    if(c.ownerId&&plan){const parent=plan.controls.find((item:VirtualControl)=>item.id===c.ownerId);if(parent){const children=plan.controls.filter((item:VirtualControl)=>item.ownerId===parent.id).sort((a:VirtualControl,b:VirtualControl)=>a.order-b.order);const slot=children.findIndex((item:VirtualControl)=>item.id===c.id);if(parent.kind==='folder_round'){const angle=2*Math.PI*slot/Math.max(1,children.length)-Math.PI/2;const distance=Math.max(52,parent.radius);x=parent.x*this.stageW+Math.cos(angle)*distance;y=parent.y*this.stageH+Math.sin(angle)*distance;}else{const rows=Math.ceil(children.length/2),column=slot%2,row=Math.floor(slot/2),side=parent.x>0.5?-1:1;x=parent.x*this.stageW+side*(60+column*48);y=parent.y*this.stageH+(row-(rows-1)/2)*48;}}}
    const size=this.baseVirtualSize(c);return {id:0,x:Math.max(0,Math.min(this.stageW-size,x-size/2)),y:Math.max(0,Math.min(this.stageH-size,y-size/2))};
  }
  private virtualLayoutKey:string='';private virtualLayoutCache:VirtualLayout={complete:false,items:[]};
  private virtualLayout():VirtualLayout {
    const controls=this.virtualVisibleControls();const key=JSON.stringify([this.stageW,this.stageH,this.virtualFolder,this.virtualKeysHidden,controls]);
    if(key!==this.virtualLayoutKey){const digits=controls.filter((control:VirtualControl)=>!control.ownerId&&['1','2','3','4'].includes(control.label));const align=!!this.virtualPlan&&this.virtualPlan.source==='builtin'&&digits.length===4&&digits.every((control:VirtualControl)=>Math.abs(control.x-digits[0].x)<0.002&&Math.abs(control.radius-digits[0].radius)<0.1);const requests:VirtualPlacementRequest[]=controls.map((control:VirtualControl):VirtualPlacementRequest=>{const point=this.baseVirtualPoint(control);const size=this.baseVirtualSize(control);return {id:control.id,x:point.x+size/2,y:point.y+size/2,size:size,group:this.virtualFolder&&controls.some((item:VirtualControl)=>item.id===this.virtualFolder&&item.kind==='folder_list')?(control.id===this.virtualFolder?'folder-list-parent':control.ownerId===this.virtualFolder?'folder-list-child':''):(align&&digits.includes(control)?'builtin-digits':'')};});this.virtualLayoutCache=layoutVirtualControls(requests,this.stageW,this.stageH);this.virtualLayoutKey=key;}
    return this.virtualLayoutCache;
  }
  private virtualPlacement(c:VirtualControl):VirtualPlacement {return this.virtualLayout().items.find((item:VirtualPlacement)=>item.id===c.id)||{id:c.id,x:0,y:0,size:0};}
  private virtualSize(c:VirtualControl):number{return this.virtualPlacement(c).size;}
  private virtualPoint(c:VirtualControl):TouchPoint {const item=this.virtualPlacement(c);return {id:0,x:item.x,y:item.y};}
  private mobile:MobileInput=new MobileInput((events:RemoteInput[])=>this.dispatchOwned('mobile',events));
  private hardware:HardwareInput=new HardwareInput((events:RemoteInput[])=>this.dispatchOwned('hardware',events));
  private pointer:HardwareInput=new HardwareInput((events:RemoteInput[])=>this.dispatchOwned('pointer',events));
  private touch:MobileTouch=new MobileTouch((a:TouchAction)=>this.touchAction(a),(v:TouchView)=>{this.zoom=v.zoom;this.panX=v.panX;this.panY=v.panY;});
  aboutToAppear():void {
    this.offVirtualAccount=client.monitor((view:AuthView)=>{const scope=view.loggedIn?(view.wallpaperAccountKey||'unavailable'):'offline';if(this.virtualAccount&&scope!==this.virtualAccount){this.safeReset();this.virtualKeysOn=false;this.virtualPlan=undefined;this.virtualFolder='';}this.virtualAccount=scope;});
    try{inputDevice.on('change',this.keyboardDeviceListener);}catch(_){}
    this.mic.setContext(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.mic.observe((view:MicrophoneView)=>{this.micActive=view.enabled||view.pending||view.capturing;this.micText=view.text;});
    this.mic.setForeground(true);
    this.loadInputPreferences();
    this.screenOwner=windowPolicy.acquireVideoScreen();this.offScreenSession=session.monitorState(()=>this.syncScreenOn());
    this.visible=true;this.orientationChoice=windowPolicy.getRemoteOrientation();this.desktopName=session.deviceName||'远程桌面';windowPolicy.applyRemote(true).then(()=>this.updateInsets());session.setForeground(true,!pcHost.supported);this.advanced.setForeground(true);
    try{this.previousKeyboardAvoid=this.getUIContext().getKeyboardAvoidMode();this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);}catch(_){}
    this.releaseWindow=windowPolicy.observe((value:WindowSnapshot)=>{this.safeLeft=value.insets.left;this.safeRight=value.insets.right;this.safeTop=value.insets.top;this.safeBottom=value.insets.bottom;this.imeHeight=value.keyboardHeight;this.updateVideoInsets();this.scheduleInitialCanvasFocus();});
    center.connect((r:SettingRequest)=>session.setting(r));center.observe((v:ControlView)=>{if(v.sessionReset!==this.centerView.sessionReset){this.advanced.disconnect();this.advancedOpen=false;this.qa=5;this.requestedFps=0;this.requestedResolution='remote';this.requestedLock=false;this.requestedMute=false;this.centerOpen=false;this.monitorRequestError='';}this.centerView=snapshotView(v);this.refreshWindowsUnlock();});
    let rate:number=0;try{const local=display.getDefaultDisplaySync();rate=local.refreshRate;session.setViewerDisplay(local.width,local.height,rate);}catch(_){}center.capabilities(videoCapabilities(),rate);
    this.offInputReset=session.observeInputReset(()=>this.clearLocal());
    this.offSession=session.observe((s:string)=>{if(this.returnAfterHiddenRoom()){return;}this.signalText=s;this.touchSupport=session.touchSupport;this.syncPreferredMode();this.failureText=session.lastFailure;this.hasFrame=session.firstFrame;this.active=session.busy;this.controlEnabled=session.controlOpen&&session.firstFrame;this.frameWidth=session.frameWidth;this.frameHeight=session.frameHeight;this.geometry();if(!session.busy&&this.terminalOpen){this.closeTerminal();}if(!session.windowFocused){this.closeTerminal();if(this.directLockFlow){deviceLockRequest.finish(session.selected,'锁屏已取消：窗口已失焦。');this.leave();}}this.applyInitialTool();this.applyDirectLock();this.scheduleInitialCanvasFocus();this.captureRemoteCover();this.syncScreenOn();this.syncVirtualGate();});
    this.syncInputGate();
    this.tickTimer=setInterval(()=>{this.touch.tick(Date.now());if(this.padReady()){this.gamepad.flush();}this.syncMicrophone();},40);
  }
  aboutToDisappear():void {
    try{inputDevice.off('change',this.keyboardDeviceListener);}catch(_){}
    this.releaseRemoteClose();
    windowPolicy.endRemoteTitle();
    this.dialog.close();
    this.mic.observe(undefined);this.mic.dispose();
    this.offVirtualAccount();this.closeTerminal();deviceLockRequest.cancel();this.lockToken='';
    this.stopGamepad();
    this.visible=false;this.retryRevision++;this.retrying=false;this.offScreenSession();windowPolicy.releaseVideoScreen(this.screenOwner);this.screenOwner=0;try{this.getUIContext().setKeyboardAvoidMode(this.previousKeyboardAvoid);}catch(_){}if(this.releaseWindow){this.releaseWindow();this.releaseWindow=undefined;}if(this.tickTimer>=0){clearInterval(this.tickTimer);this.tickTimer=-1;}this.clearToolsTimer();this.advanced.dispose();this.safeReset();center.observe(undefined);this.offInputReset();this.offSession();if(session.busy){if(session.multiMode&&detached.hasPane()){session.closeMultiPrimary();}else{session.cancel('remote_page_closed');}}windowPolicy.applyRemote(false);
  }
  onPageShow():void {
    this.visible=true;
    if(this.returnAfterHiddenRoom()){return;}
    if(pcHost.supported){
      this.releaseRemoteClose();
      this.releaseRemoteClose=windowPolicy.bindRemoteClose(()=>this.requestExit());
      windowPolicy.beginRemoteTitle((active:boolean,right:number)=>{this.mergedPcTitle=active;this.titleButtonInset=right;});
    }
    this.syncScreenOn();this.mic.setForeground(true);windowPolicy.applyRemote(true);
    const selected=virtualSelection.get();if(selected&&this.virtualKeysOn){this.virtualPlan=selected;}
    this.syncInputGate();
  }
  onPageHide():void {this.visible=false;this.releaseRemoteClose();windowPolicy.endRemoteTitle();this.syncScreenOn();this.mic.setForeground(false);deviceLockRequest.cancel();this.lockToken='';this.closeTerminal();this.safeReset();this.syncInputGate();}
  private syncMicrophone():void {
    const allowed=this.visible&&this.controlEnabled&&session.busy&&!session.isClosing&&!this.exitPending&&
      !session.watch&&!this.centerView.watch&&!this.lockToken;
    if(this.micAllowed!==allowed){this.micAllowed=allowed;this.mic.setControlAllowed(allowed);}
  }
  private toggleMicrophone():void {
    if(this.micActive){this.mic.disable();return;}
    this.syncMicrophone();if(this.micAllowed){this.mic.enable();}
  }
  onBackPress():boolean {if(this.terminalOpen){this.requestTerminalReturn();return true;}if(this.monitorsOpen){this.openMonitors(false);return true;}if(this.advancedOpen){if(this.advancedInitial===3&&this.fileBrowsing){this.fileBrowsing=false;}else{this.closeAdvanced();}return true;}if(this.centerOpen){this.openCenter(false);return true;}if(this.keyboard){this.keyboard=false;this.safeReset();this.syncInputGate();return true;}if(this.toolsOpen){if(this.operationsPage!=='ops'){this.operationsPage=this.operationsPage==='power'?'more':this.operationsPage==='hardware'||this.operationsPage==='mouse'?'external':'ops';}else{this.toggleTools(false);}return true;}this.requestExit();return true;}
  private updateVideoInsets():void{const value=windowPolicy.videoInsets();this.videoLeft=value.left;this.videoRight=value.right;this.videoTop=value.top;this.videoBottom=value.bottom;}
  private updateInsets():void{this.updateVideoInsets();const insets=windowPolicy.insets();this.safeLeft=insets.left;this.safeRight=insets.right;this.safeTop=insets.top;this.safeBottom=insets.bottom;}
  private clearToolsTimer():void{if(this.toolsTimer>=0){clearTimeout(this.toolsTimer);this.toolsTimer=-1;}}
  // Panels close only by explicit action: a late swipe must never hit the desktop.
  private armToolsTimer():void {this.clearToolsTimer();}
  private syncInputGate():void {const panel=this.terminalOpen||this.keyboard||this.toolsOpen||this.centerOpen||this.advancedOpen||this.monitorsOpen;if(this.canvasPanelWasOpen&&!panel&&this.initialCanvasFocusDone){this.canvasFocusRestorePending=true;}this.canvasPanelWasOpen=panel;session.pauseInput(this.terminalOpen||!this.visible||this.exitPending||this.exitConfirming||this.toolsOpen||this.centerOpen||this.advancedOpen||this.monitorsOpen);windowPolicy.setPanelSurface(panel);this.hardwareGates();this.syncVirtualGate();if(!this.initialFocusReady()){this.canvasFocusEpoch++;this.initialCanvasFocusScheduled=false;}else{this.scheduleInitialCanvasFocus();}}
  private toggleTools(value:boolean):void {this.safeReset();this.toolsOpen=value;if(value){this.centerOpen=false;this.advancedOpen=false;this.monitorsOpen=false;this.keyboard=false;}this.syncInputGate();this.armToolsTimer();}
  private openAdvanced(page:number):void {
    if(page===3&&pcHost.supported){
      this.safeReset();this.toolsOpen=false;this.syncInputGate();
      pcFileWindows.open({deviceKey:session.selected,deviceName:this.desktopName,borrowed:true}).catch(()=>{
        if(this.visible){this.getUIContext().getPromptAction().showToast({message:'无法打开文件窗口，请关闭已有文件窗口后重试。'});}
      });
      return;
    }
    this.fileBrowsing=false;this.childParent=this.toolsOpen?this.operationsPage:'';this.safeReset();this.toolsOpen=false;this.advancedInitial=page;this.advancedOpen=true;this.syncInputGate();this.armToolsTimer();
  }
  private restoreTools():void {if(this.childParent){this.operationsInitial=this.childParent;this.operationsPage=this.childParent;this.toolsOpen=true;this.childParent='';}}
  private closeAdvanced():void {this.fileBrowsing=false;this.safeReset();this.advancedOpen=false;this.restoreTools();this.syncInputGate();this.clearToolsTimer();}
  private bottomRail():boolean{return !pcHost.supported&&this.viewportH>this.viewportW;}
  private railWidth():number {return this.viewportH<440?78:88;}
  private railVisible():boolean {return !pcHost.supported&&!this.terminalOpen&&(this.hasFrame||session.hasEstablishedVideo)&&!this.failureText&&!this.keyboard;}
  private contentTop():number {return this.mergedPcTitle?48:this.safeTop+(pcHost.supported?56:0);}
  private pcTitleLayout():PcTitleLayout{return pcTitleLayout(this.viewportW,this.mergedPcTitle?this.titleButtonInset:this.safeRight);}
  private pcDisconnectWidth():number {return this.pcTitleLayout().compact?32:52;}
  private drawerRightInset():number {return this.safeRight+(this.railVisible()&&!this.bottomRail()?this.railWidth()+8:0);}
  private clearActionOverlays():void {this.safeReset();this.toolsOpen=false;this.centerOpen=false;this.advancedOpen=false;this.monitorsOpen=false;this.keyboard=false;this.childParent='';this.syncInputGate();}
  private presentation():RemotePresentation{return remotePresentation({width:this.viewportW,height:this.viewportH,left:this.videoLeft,right:this.videoRight,top:pcHost.supported?this.contentTop():this.videoTop,bottom:this.videoBottom,railWidth:this.railVisible()&&!this.bottomRail()?this.railWidth():0,railHeight:this.railVisible()&&this.bottomRail()?72:0,mobile:!pcHost.supported,panel:this.toolsOpen||this.centerOpen||this.monitorsOpen||this.advancedOpen,frameWidth:this.frameWidth,frameHeight:this.frameHeight,railTop:this.railVisible()&&this.bottomRail()?this.railPlacement().top:undefined,pcControlsRight:pcHost.supported?(this.mergedPcTitle?this.titleButtonInset:this.safeRight)+this.pcDisconnectWidth()+4:undefined});}
  private railPlacement():RemoteRailPlacement{return remoteRailPlacement(this.viewportW,this.viewportH,this.videoLeft,this.videoRight,this.videoTop,this.bottomRail()?Math.max(this.videoBottom,this.safeBottom):this.videoBottom,this.bottomRail(),this.viewportH<440);}
  private inputAvailable():boolean {return this.visible&&this.controlEnabled&&!this.exitPending&&!this.exitConfirming&&!this.failureText&&!this.viewOnly&&!this.centerView.watch&&!session.displayBlocked&&!this.screenBusy&&!this.centerView.display?.displayPending&&!this.centerView.display?.inputBlocked&&!this.centerView.display?.displayError;}
  private loadInputPreferences():void {
    this.externalKeyboard=pcHost.supported;
    const context=this.getUIContext().getHostContext();
    if(context){this.preferences=new RemotePreferences(context);this.codecPreference=this.preferences.loadVideoCodec();const value=this.preferences.load();this.externalKeyboard=this.preferences.loadExternalKeyboard(pcHost.supported);this.preferredMode=value.mode;this.mode=effectiveInputMode(this.preferredMode,this.touchSupport);this.speed=value.speed;this.mouseSize=value.mouseSize;this.mouseOpacity=value.mouseOpacity;this.mousePanelX=value.mouseX;this.mousePanelY=value.mouseY;if(!this.preferences.available){this.preferenceHint='未能读取本机偏好，本次使用屏幕触控。';}}
    else{this.preferenceHint='本次使用屏幕触控，偏好暂时无法保存。';}
    this.touch.setMode(this.mode);this.touch.setSpeed(this.speed);this.touch.setViewOnly(false);
  }
  private async saveInputPreferences():Promise<void> {
    const revision=++this.preferenceWrite;
    this.preferenceHint='正在记住选择…';
    const saved=this.preferences?await this.preferences.save(this.preferredMode,this.speed,this.mouseSize,this.mouseOpacity,this.mousePanelX,this.mousePanelY):false;
    if(this.visible&&revision===this.preferenceWrite){this.preferenceHint=saved?'已记住操作方式和速度，下次连接沿用。':'本次选择已生效，未能保存到本机。';}
  }
  private chooseInputMode(mode:TouchMode):void {
    this.safeReset();if(mode===TouchMode.Tablet||mode===TouchMode.VirtualMouse){this.virtualKeysOn=false;}this.preferredMode=mode;this.mode=mode;this.touch.setMode(mode);this.viewOnly=false;this.touch.setViewOnly(false);
    if(this.centerView.watch){center.apply({kind:'watch',enabled:false},'恢复操作');}
    this.saveInputPreferences();this.syncInputGate();
  }
  private syncPreferredMode():void {const preferred=effectiveInputMode(this.preferredMode,this.touchSupport);const effective=this.virtualKeysOn&&(preferred===TouchMode.Tablet||preferred===TouchMode.VirtualMouse)?TouchMode.Direct:preferred;if(effective!==this.mode){this.safeReset();this.mode=effective;this.touch.setMode(effective);}}
  private changePointerSpeed(value:number,commit:boolean):void {
    this.speed=Math.max(0.3,Math.min(3,value));this.touch.setSpeed(this.speed);
    if(commit){this.saveInputPreferences();}
  }
  private resumeOperation():void {
    this.safeReset();this.viewOnly=false;this.touch.setViewOnly(false);
    if(this.centerView.watch){center.apply({kind:'watch',enabled:false},'恢复操作');}
    this.syncInputGate();
  }
  private toggleViewport():void {
    if(this.viewOnly){this.resumeOperation();return;}
    this.safeReset();this.viewOnly=true;this.touch.setViewOnly(true);this.toggleTools(false);
  }
  private inputFeedback():RemoteInteractionFeedback {
    const state=new RemoteInteractionState();state.mode=this.mode;state.visible=this.visible;state.ready=this.controlEnabled&&this.hasFrame;
    state.exiting=this.exitPending;state.confirming=this.exitConfirming;state.failure=this.failureText;
    state.displayPending=this.screenBusy||!!this.centerView.display?.displayPending;state.displayBlocked=session.displayBlocked||!!this.centerView.display?.inputBlocked;state.displayError=this.centerView.display?.displayError||'';
    state.watch=this.centerView.watch;state.viewOnly=this.viewOnly;state.panel=this.toolsOpen?'操作面板':this.centerOpen?'画质设置':this.advancedOpen?'工具面板':this.monitorsOpen?'显示器面板':'';
    state.keyboard=this.keyboard;state.externalKeyboard=this.externalKeyboard;state.canvasFocused=this.canvasFocused;
    const feedback=interactionFeedback(state);
    if(feedback.tone==='ready'&&this.preferredMode===TouchMode.Tablet&&this.mode!==TouchMode.Tablet){return new RemoteInteractionFeedback('屏幕触控 · 可操作',this.touchSupport===0?'正在确认平板触控能力，暂用屏幕触控。':this.touchSupport===1?'远端不支持平板触控，已使用屏幕触控。':'未收到平板触控能力，已使用屏幕触控。','warning');}
    return feedback;
  }
  private openKeyboard():void {this.safeReset();this.toolsOpen=false;this.centerOpen=false;this.advancedOpen=false;this.monitorsOpen=false;this.keyboard=true;this.syncInputGate();}
  private closeKeyboard():void {this.keyboard=false;this.imeFocused=false;this.safeReset();this.syncInputGate();}
  private modifierLabel():string {return [this.ctrl?'Ctrl':'',this.alt?'Alt':'',this.shift?'Shift':'',this.win?'Win':''].filter((s:string)=>s.length>0).join('+');}
  private syncModifiers():void {const keys=this.mobile.modifierKeys();this.ctrl=keys.includes(162);this.alt=keys.includes(164);this.shift=keys.includes(160);this.win=keys.includes(91);}
  private selectModifier(key:number):void {if(!this.inputAvailable()||this.composing){return;}this.mobile.toggleModifier(key);this.syncModifiers();this.inputHint=this.modifierLabel().length>0?'组合键先在本地选择，下一按键时发送。':'已取消组合键选择。';}
  private clearModifiers():void {this.mobile.cancel();this.syncModifiers();this.inputHint='已清除本地组合键选择。';}
  private combo(keys:number[],key:number,label:string):void {if(!this.inputAvailable()||this.composing){return;}const accepted=this.mobile.combo(keys,key);this.syncModifiers();this.inputHint=accepted?'已排队发送 '+label:'未发送，请检查连接状态。';}
  private keyboardBottom():number {return Math.max(this.safeBottom,this.imeHeight>0?this.imeHeight+8:0);}
  private keyboardHeight():number {return Math.max(72,Math.min(340,this.viewportH-this.keyboardBottom()-this.safeTop));}
  private hardwareGates():void {
    const ready=this.visible&&this.inputAvailable()&&!this.keyboard&&!this.toolsOpen&&!this.centerOpen&&!this.advancedOpen&&!this.monitorsOpen;
    const dock=this.keyboard&&this.imeFocused;
    this.hardware.setGate(dock||this.externalKeyboard,dock||this.canvasFocused&&!this.imeFocused,dock?this.keyboardReady():ready);
    this.pointer.setGate(true,this.canvasFocused,ready);
  }
  private focusCanvas():void {try{this.getUIContext().getFocusController().requestFocus('touchViewport');}catch(_){return;}}
  private initialFocusReady():boolean {return pcHost.supported&&this.externalKeyboard&&this.controlEnabled&&session.windowFocused&&this.inputAvailable()&&!this.canvasFocused&&!this.imeFocused&&this.imeHeight===0&&!this.keyboard&&!this.toolsOpen&&!this.centerOpen&&!this.advancedOpen&&!this.monitorsOpen&&!this.terminalOpen;}
  private scheduleInitialCanvasFocus():void {if((this.initialCanvasFocusDone&&!this.canvasFocusRestorePending)||this.initialCanvasFocusScheduled||!this.initialFocusReady()){return;}this.initialCanvasFocusScheduled=true;const epoch=++this.canvasFocusEpoch;setTimeout(()=>{if(epoch!==this.canvasFocusEpoch){return;}this.initialCanvasFocusScheduled=false;if(this.initialFocusReady()){this.focusCanvas();}},100);}
  private canvasBlur():void {this.canvasFocused=false;this.safeReset();this.hardwareGates();}
  private toggleExternalKeyboard():void {this.safeReset();this.externalKeyboard=!this.externalKeyboard;this.preferences?.saveExternalKeyboard(this.externalKeyboard);this.toggleTools(false);if(this.externalKeyboard){setTimeout(()=>{if(this.visible&&session.windowFocused&&this.externalKeyboard&&!this.toolsOpen&&!this.keyboard){this.focusCanvas();}},100);}}
  private physicalKey(event:KeyEvent,fromDock:boolean=false):boolean {
    if(event.keySource===KeySource.JOYSTICK){
      if(!this.padReady() || (event.type!==KeyType.Down && event.type!==KeyType.Up)){return false;}
      const handled=this.gamepad.key(event.deviceId,event.keyCode,event.type===KeyType.Down);
      if(handled){event.stopPropagation();}return handled;
    }
    if(event.keySource!==KeySource.Keyboard){return false;}
    this.hardwareGates();if(fromDock?!this.keyboardReady():!this.externalKeyboard||this.imeFocused||this.keyboard){return false;}
    if(event.type!==KeyType.Down&&event.type!==KeyType.Up){return false;}
    let releaseCapture:boolean=false;try{releaseCapture=harmonyKeyToVk(event.keyCode)===13&&(event.getModifierKeyState?.(['Ctrl','Alt'])||false);}catch(_){}
    if(harmonyKeyToVk(event.keyCode)===13&&(this.hardware.hasPressedVk(162)||this.hardware.hasPressedVk(163))&&(this.hardware.hasPressedVk(164)||this.hardware.hasPressedVk(165))){releaseCapture=true;}
    if(releaseCapture&&event.type===KeyType.Down){this.externalKeyboard=false;if(fromDock){this.closeKeyboard();}else{this.safeReset();}this.hardwareGates();event.stopPropagation();return true;}
    const handled=this.hardware.key(event.keyCode,event.type===KeyType.Down);if(handled){event.stopPropagation();}return handled;
  }
  private physicalMouse(event:MouseEvent):void {
    event.stopPropagation();if(event.source!==SourceType.Mouse||this.mode===TouchMode.Tablet){return;}if(event.action===MouseAction.Move&&!this.motionOwner.permits('pointer')){return;}
    if(event.action===MouseAction.Press){this.focusCanvas();if(this.virtualKeysOn){this.motionOwner.acquire('pointer');}}this.hardwareGates();
    const point=this.touch.mapPoint(event.x,event.y);
    const button=event.button===MouseButton.Left?1:event.button===MouseButton.Right?2:event.button===MouseButton.Middle?4:0;
    this.pointer.mouse(event.action===MouseAction.Press?'down':event.action===MouseAction.Release?'up':'move',button,point.x,point.y,point.inside);if(event.action===MouseAction.Release&&this.pointer.pressedCount()===0){this.motionOwner.release('pointer');}
  }
  private physicalAxis(event:AxisEvent):void {
    if(event.source!==SourceType.Mouse||this.mode===TouchMode.Tablet||event.getPinchAxisScaleValue()>0){return;}this.hardwareGates();
    this.pointer.wheel(-event.getHorizontalAxisValue(),-event.getVerticalAxisValue());
  }
  private padReady():boolean {
    return this.gamepadEnabled && this.visible && this.canvasFocused && this.inputAvailable() &&
      !this.toolsOpen && !this.keyboard && !this.advancedOpen && !this.centerOpen && !this.monitorsOpen && !this.terminalOpen;
  }
  private stopGamepad():void {
    if(this.gamepadEnabled){try{inputDevice.off('change',this.deviceListener);}catch(_){}}
    this.gamepadEnabled=false;
    this.gamepad.reset();
  }
  private toggleGamepad():void {
    this.safeReset();
    if(this.gamepadEnabled){this.stopGamepad();return;}
    try{inputDevice.on('change',this.deviceListener);}catch(_){
      this.getUIContext().getPromptAction().showToast({message:'系统未提供手柄设备监听'});return;
    }
    this.gamepadEnabled=true;
    this.toggleTools(false);
    this.focusCanvas();
  }
  private gamepadAxis(event:FocusAxisEvent):void {
    if(!this.padReady() || event.deviceId===undefined || event.source!==SourceType.JOYSTICK){return;}
    const id=event.deviceId;
    event.axisMap.forEach((value:number,axis:AxisModel)=>{
      this.gamepad.axis(id,axis===AxisModel.ABS_RX?2:axis===AxisModel.ABS_RY?3:axis,value);
    });
    event.stopPropagation();
  }
  private captureRemoteCover():void{
    if(!this.visible||!this.hasFrame||!session.firstFrame||!session.controlOpen||!session.busy||session.isClosing||!session.windowFocused||this.exitPending||this.directLockFlow||this.lockToken||!this.surfaceId){return;}
    const key=session.selected;const generation=session.generation;const surface=this.surfaceId;
    remoteThumbnails.captureRendered(key,surface,generation,session.frameWidth,session.frameHeight,()=>this.visible&&this.hasFrame&&session.firstFrame&&session.controlOpen&&session.busy&&!session.isClosing&&session.windowFocused&&!this.exitPending&&!this.directLockFlow&&!this.lockToken&&session.selected===key&&session.generation===generation&&this.surfaceId===surface);
  }
  private async saveDesktopThumbnail():Promise<void>{
    if(this.thumbnailPending||!this.visible||!this.hasFrame||!this.controlEnabled||this.exitPending||!this.surfaceId){return;}
    const key=session.selected;const generation=remoteThumbnails.generation;const surface=this.surfaceId;this.thumbnailPending=true;
    let pixels:image.PixelMap|undefined=undefined;
    try{
      pixels=await image.createPixelMapFromSurface(surface);
      const info=await pixels.getImageInfo();const factor=Math.min(1,480/Math.max(info.size.width,info.size.height));
      if(factor<1){await pixels.scale(factor,factor);}
      if(!this.visible||!this.hasFrame||this.exitPending||session.selected!==key||this.surfaceId!==surface){await pixels.release();pixels=undefined;this.thumbnailHint='会话已变化，未保存封面。';return;}
      const saved=remoteThumbnails.save(key,pixels,generation);pixels=undefined;
      this.thumbnailHint=saved?'已保存当前真实桌面画面；返回设备可查看时间，退出账号即清空。':'账号已变化，未保存封面。';
    }catch(_){if(pixels){pixels.release().catch(()=>{});}this.thumbnailHint='当前画面获取失败，未保存封面。';}
    finally{this.thumbnailPending=false;}
  }
  private dialogOptions:UiDialogOptions={title:'',message:''};
  private dialog:CustomDialogController=new CustomDialogController({builder:UiThemeDialog({dark:true,options:this.dialogOptions}),customStyle:true,cancel:()=>this.dialogOptions.cancel?.()});
  private showDialog(options:UiDialogOptions):void{this.dialogOptions=options;this.dialog.open();}
  private requestTerminal():void{
    if(!this.visible||!session.windowFocused||session.watch||this.centerView.watch||!this.controlEnabled||this.exitPending||this.terminalOpen){return;}
    const key=session.selected;this.safeReset();
    this.showDialog({title:'打开交互终端？',message:this.desktopName+'\n使用当前授权会话向电脑请求终端。仅发送你手动提交的输入，电脑端仍可拒绝。关闭终端可能结束当前shell；输入输出不会保存到日志。',primaryButton:{value:'取消',action:()=>{}},secondaryButton:{value:'打开终端',action:()=>{if(this.visible&&session.selected===key){this.openTerminal();}}}});
  }
  private terminalReply(raw:string):void{
    const value=JSON.parse(raw) as TerminalReply;
    if(value.error){this.terminalStatus=value.error==='terminal_reconnect_required'?'本会话已打开过终端；请重新连接电脑后再打开，避免旧响应与新请求混淆。':'终端接口不可用或当前会话已变化。';this.terminalPhase='failed';return;}
    this.terminalPhase=value.phase||'failed';
    this.terminalOutput=(value.output||'').replace(/\u001b\[[0-?]*[ -/]*[@-~]/g,'').replace(/\u001b\][^\u0007]*(?:\u0007|$)/g,'').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g,'');
    this.terminalStatus=this.terminalPhase==='open'?'终端已由电脑确认打开；80×24':this.terminalPhase==='opening'?'已请求打开，等待电脑确认':this.terminalPhase==='exited'?'终端已退出':this.terminalPhase==='failed'?'电脑拒绝、响应无效、超时或发送失败；重新连接电脑后可手动重试。':'终端已关闭';
  }
  private async openTerminal():Promise<void>{
    if(!this.visible||!session.windowFocused||session.watch||this.centerView.watch||!session.controlOpen||this.exitPending||this.terminalOpen){return;}
    this.clearActionOverlays();this.terminalOpen=true;this.terminalDraft='';this.terminalOutput='';this.terminalBusy=true;this.syncInputGate();
    const generation=session.generation;try{const raw=await session.terminalCommand({action:'open',confirmed:true});if(this.terminalOpen&&generation===session.generation){this.terminalReply(raw);}}catch(_){this.terminalPhase='failed';this.terminalStatus='无法读取终端响应。';}finally{this.terminalBusy=false;}
    if(this.terminalOpen&&generation===session.generation){this.terminalTimer=setInterval(()=>this.pollTerminal(generation),400);}
  }
  private async pollTerminal(generation:number):Promise<void>{
    if(!this.terminalOpen||!this.visible||this.terminalBusy||this.terminalPolling||generation!==session.generation){return;}this.terminalPolling=true;
    try{const raw=await session.terminalCommand({action:'status'});if(this.terminalOpen&&generation===session.generation){this.terminalReply(raw);}}catch(_){}finally{this.terminalPolling=false;}
  }
  private async terminalSend(text:string,line:boolean=false):Promise<void>{
    if(!this.terminalOpen||this.terminalPhase!=='open'||this.terminalBusy||!this.visible||!text){return;}
    const generation=session.generation;this.terminalBusy=true;
    try{const raw=await session.terminalCommand({action:'write',text:text+(line?'\r':'')});if(this.terminalOpen&&generation===session.generation){const reply=JSON.parse(raw) as TerminalReply;this.terminalReply(raw);if(reply.sent){this.terminalDraft='';}}}catch(_){this.terminalStatus='输入未完成发送；请核对电脑状态，避免重复提交。';}finally{this.terminalBusy=false;}
  }
  private requestTerminalReturn():void{
    if(!this.visible||!this.terminalOpen||this.exitPending){return;}const generation=session.generation;const key=session.selected;
    const valid=():boolean=>this.visible&&this.terminalOpen&&!this.exitPending&&generation===session.generation&&key===session.selected;
    this.getUIContext().showAlertDialog({title:'离开终端',message:'选择返回位置。这里只分离终端连接；电脑能否跨断线保留会话仍需验证。',primaryButton:{value:'设备列表',action:()=>{if(valid()){this.leave();}}},secondaryButton:{value:'显示远控画面',action:()=>{if(valid()){this.closeTerminal(true);}}}});
  }
  private closeTerminal(reveal:boolean=false):void{
    if(this.terminalTimer>=0){clearInterval(this.terminalTimer);this.terminalTimer=-1;}
    if(this.terminalOpen){session.terminalCommand({action:'detach_selected'},true);}
    this.terminalStatus='终端输入已暂停，已尝试分离连接；返回画面需明确选择。';
    if(reveal){this.terminalOpen=false;}this.terminalDraft='';this.terminalOutput='';this.terminalPhase='closed';this.terminalBusy=false;this.syncInputGate();
  }
  private securityReady():boolean{return this.visible&&session.busy&&session.controlOpen&&session.controlEcho&&!session.isClosing&&session.windowFocused;}
  private requestPrivacy(mode:number):void{
    if(!this.securityReady()||this.systemActionPending||this.exitPending||this.exitConfirming||(mode===3&&this.centerView.privacySupport!==2)||(mode===2&&this.centerView.privacySupport<1)){return;}
    const key=session.selected;const generation=session.generation;this.systemActionPending=true;this.safeReset();const cancel=()=>{this.systemActionPending=false;};
    this.showDialog({title:mode===1?'关闭防窥？':mode===2?'开启隐私壁纸？':'关闭电脑物理屏幕？',message:this.desktopName+'\n'+(mode===1?'恢复电脑屏幕正常显示。':'远程画面继续显示，电脑本地屏幕将'+(mode===2?'显示所选隐私壁纸。':'关闭。')+'断开连接时恢复屏幕。'),cancel:cancel,primaryButton:{value:'取消',action:cancel},secondaryButton:{value:'确认',action:async()=>{
      if(this.securityReady()&&!this.exitPending&&session.selected===key&&session.generation===generation&&session.windowFocused){await center.apply({kind:'privacy',value:mode,confirmed:true},mode===1?'关闭':mode===2?'隐私壁纸':'关闭物理屏幕');}cancel();
    }}});
  }
  private privacyStatus():string{
    const row=this.centerView.rows.find((item:ControlRow)=>item.kind==='privacy');
    const mode=this.centerView.privacyCurrent;return (this.centerView.privacyErrorCode?'防窥切换失败（错误码 '+this.centerView.privacyErrorCode+'）；':this.centerView.privacyError?'防窥切换失败；':'')+(mode===1?'防窥已关闭':mode===2?'隐私壁纸已开启':mode===3?'物理屏幕已关闭':'正在读取防窥状态');
  }
  private requestSystemAction(kind:RemoteSystemAction):void {
    if(!this.securityReady()||this.exitPending||this.exitConfirming||this.systemActionPending){return;}
    const selected=session.selected;const generation=session.generation;const name=this.desktopName;const label=systemActionLabel(kind);
    this.safeReset();this.systemActionPending=true;
    const cancel=()=>{this.systemActionPending=false;};
    this.showDialog({title:label+'？',message:name+'\n'+(kind==='lock_now'?'电脑将进入锁定状态，需要在电脑端解锁。':'此操作会中断会话，未保存的工作可能丢失。')+'\n通过专用协议发送，Windows 执行兼容性尚待验证。',cancel:cancel,
      primaryButton:{value:'取消',action:cancel},secondaryButton:{value:label,action:async()=>{
        if(!this.securityReady()||this.exitPending||session.selected!==selected||session.generation!==generation){cancel();return;}
        this.systemActionText='正在发送'+label+'…';
        try{const raw=await session.setting({kind:kind,confirmed:true});if(this.visible&&session.selected===selected&&session.generation===generation){this.systemActionText=label+'：'+systemActionResult(raw);}}
        catch(_){this.systemActionText='发送结果不可用，请观察电脑状态。';}
        this.systemActionPending=false;
      }}});
  }
  private showDesktop():void {
    if(!this.inputAvailable()){return;}this.clearActionOverlays();
    this.dispatchInput([{action:'kbd_press',key:91},{action:'kbd_press',key:68},{action:'kbd_release',key:68},{action:'kbd_release',key:91}]);
  }
  private switchWindow():void {
    if(!this.inputAvailable()){return;}this.clearActionOverlays();
    this.combo([164],9,'Alt+Tab');
  }
  private openMonitors(value:boolean,fromTools:boolean=false):void {
    this.safeReset();
    if(value){
      this.childParent=fromTools&&this.toolsOpen?this.operationsPage:'';
      this.centerOpen=false;
      this.advancedOpen=false;
      this.fileBrowsing=false;
      this.keyboard=false;
    }
    this.toolsOpen=false;
    this.monitorsOpen=value;
    if(!value){this.restoreTools();}
    this.syncInputGate();
  }
  private currentMonitor(id:number):boolean {
    const display=this.centerView.display;
    return display?.selectedScreen===id&&this.hasFrame&&!this.screenBusy&&!session.displayBlocked&&
      !display.displayPending&&!display.inputBlocked&&!display.displayError;
  }
  private monitorPanelStatus():string {
    const display=this.centerView.display;
    if(this.screenBusy){return '正在发送切屏请求';}
    if(this.monitorRequestError){return this.monitorRequestError;}
    if(!display?.inventoryReceived||display.displayPending||display.displayError){return this.centerView.displayText;}
    if(display.changeKind==='switch'&&!this.hasFrame){return '正在接收所选显示器画面';}
    if(display.screens.length===0){return '电脑未报告可用的显示器';}
    if(display.screens.length===1){return '电脑当前只有一块显示器';}
    return display.switchCommandSupported?'':'当前连接暂不支持切换显示器';
  }
  private monitorSelectionAvailable():boolean {
    return this.visible&&!this.exitPending&&!this.exitConfirming&&!this.screenBusy&&session.hasEstablishedVideo&&session.controlOpen&&!this.directLockFlow&&!this.lockToken&&!!this.centerView.display?.inventoryReceived&&!!this.centerView.display?.switchCommandSupported&&!this.centerView.display?.displayPending;
  }
  private stepScreen(step:number):void {
    if(this.exitPending||this.exitConfirming||this.screenBusy||!this.monitorSelectionAvailable()){return;}
    const id=adjacentScreen(this.centerView.display,step);
    if(id===undefined){return;}
    this.switchScreen(id);
  }
  private openScreenWindow(id:number):void {if(!session.multiMode){return;}const context=this.getUIContext().getHostContext() as common.UIAbilityContext;detached.open(context,id).then((ok:boolean)=>{if(!ok){this.getUIContext().getPromptAction().showToast({message:'无法打开显示器窗口',duration:2000});}});}
  private dragScreenEnd(id:number,event:GestureEvent):void {const finger=event.fingerList?.[0];if(!finger||Math.abs(event.offsetX)+Math.abs(event.offsetY)<24){return;}if(Math.abs(event.offsetY)>=56||!windowPolicy.containsDisplayPoint(finger.displayX,finger.displayY)){this.openScreenWindow(id);}}
  private async switchScreen(id:number):Promise<void> {
    if(!this.monitorSelectionAvailable()||!this.centerView.display?.screens.some((s:ScreenRow)=>s.id===id)){return;}
    this.safeReset();
    this.monitorRequestError='';
    this.screenBusy=true;
    try{
      if(session.multiMode){if(detached.hasScreen(id)){await detached.showScreen(id);return;}if(!await session.switchMultiPrimary(id)&&this.visible){this.getUIContext().getPromptAction().showToast({message:'显示器切换未完成，请重试',duration:2500});}return;}
      const generation=session.generation;
      const next=await this.advanced.switchScreen(id);
      if(!this.visible||session.generation!==generation){return;}
      if(next){
        const value=snapshotView(this.centerView);
        value.display=next;
        value.displayText=displayStatus(next);
        this.centerView=value;
      }else{
        this.monitorRequestError=this.advanced.view.screenText;
      }
    }finally{this.screenBusy=false;}
  }
  private retrying:boolean=false;private retryRevision:number=0;private lastDesktopMulti:boolean=false;
  private initialTool:string='';
  private lockToken:string='';
  private lockGeneration:number=-1;
  private directLockStarted:boolean=false;
  @State private directLockFlow:boolean=false;
  private async applyDirectLock():Promise<void>{
    if(!this.lockToken||this.directLockStarted||!this.visible||this.exitPending||!session.controlOpen||!session.controlEcho){return;}
    if(!deviceLockRequest.consume(this.lockToken,session.selected,this.lockGeneration)){this.lockToken='';return;}
    this.directLockStarted=true;const key=session.selected;const generation=this.lockGeneration;
    const raw=await session.setting({kind:'lock_now',confirmed:true});
    if(this.visible&&session.selected===key){deviceLockRequest.finish(key,'立即锁屏：'+systemActionResult(raw));this.lockToken='';await this.leave();}
  }
  private launchingApp:boolean=false;
  private async launchPinned(id:string):Promise<void> {
    if(this.launchingApp||session.watch||!this.visible||!session.controlOpen){return;}
    if(this.toolsOpen){this.clearActionOverlays();}
    const epoch=session.generation;const device=session.selected;
    const valid=():boolean=>this.visible&&!this.exitPending&&session.busy&&!session.isClosing&&session.windowFocused&&!session.watch&&session.generation===epoch&&session.selected===device;
    this.launchingApp=true;
    try{const message=await launchSelectedApp(id,valid);if(valid()){this.getUIContext().getPromptAction().showToast({message:message});}}
    finally{this.launchingApp=false;}
  }
  private applyInitialTool():void {
    if(!this.initialTool||!this.controlEnabled||!this.visible||this.exitPending){return;}
    const tool=this.initialTool;
    this.initialTool='';
    if(/^app-[a-f0-9]{64}$/.test(tool)){
      this.launchPinned(tool.slice(4));
      return;
    }
    switch(tool){
      case 'reboot': this.requestSystemAction('reboot');break;
      case 'shutdown': this.requestSystemAction('shutdown');break;
      case 'watch': center.apply({kind:'watch',enabled:true},'仅观看'); break;
      case 'files': this.openAdvanced(3); break;
      case 'clipboard': this.openAdvanced(2); break;
      case 'keyboard': this.openKeyboard(); break;
      case 'display': this.operationsInitial='display'; this.toggleTools(true); break;
      case 'operations': this.toggleTools(true); break;
      case 'power': this.operationsInitial='power';this.toggleTools(true);break;
      case 'terminal': this.openTerminal();break;
    }
  }
  private async beginOnSurface():Promise<void>{
    if(this.joining||this.exitPending||!this.surfaceId){return;}
    this.joining=true;
    await windowPolicy.applyRemote(true);
    if(!this.visible||this.exitPending||!this.surfaceId){return;}
    const route=this.getUIContext().getRouter().getParams() as RemoteRoute;
    if(!route||route.deviceKey!==session.selected||!route.confirmed){this.signalText='设备选择已改变，请返回重新确认';return;}
    if(session.busy||session.isClosing){return;}
    this.initialTool=route.initialTool||'';this.lockToken=this.initialTool==='lock_now'?(route.lockToken||''):'';this.directLockFlow=this.initialTool==='lock_now';
    // Gate keyboard and pointer dispatch before the first frame can enable input.
    const startWatching=this.initialTool==='watch'||this.initialTool==='lock_now';
    if(startWatching){session.watch=true;}
    session.setVideoCodecPreference(this.codecPreference);
    this.lastDesktopMulti=false;
    session.enableMultiVideo(this.lastDesktopMulti);
    const joining=session.joinConfirmed(route.deviceKey);
    if(this.lockToken){this.lockGeneration=session.generation;if(!deviceLockRequest.bind(this.lockToken,route.deviceKey,this.lockGeneration)){this.lockToken='';}}
    await joining;
    if(startWatching&&!session.busy){session.watch=false;}
  }
  private async retryDesktop(forceSingle:boolean,forceH264:boolean=false,forceMulti:boolean=false):Promise<void>{
    const route=this.getUIContext().getRouter().getParams() as RemoteRoute;
    if(this.retrying||!this.visible||this.exitPending||!route||!route.confirmed||!route.deviceKey||detached.hasPane()){return;}
    const revision=++this.retryRevision,key=route.deviceKey,name=this.desktopName;
    const retryMulti=forceMulti||(!forceSingle&&this.lastDesktopMulti);
    this.retrying=true;
    try{
      if(forceH264){this.codecPreference=1;await this.preferences?.saveVideoCodec(1);}
      if(revision!==this.retryRevision||!this.visible||this.exitPending||detached.hasPane()){return;}
      this.safeReset();await session.cancel('user_disconnect');
      const run=session.generation;const current=this.getUIContext().getRouter().getParams() as RemoteRoute;
      if(revision!==this.retryRevision||!this.visible||this.exitPending||detached.hasPane()||!current?.confirmed||current.deviceKey!==key){return;}
      if(!await session.select(key,name)){return;}
      if(revision!==this.retryRevision||run!==session.generation||!this.visible||this.exitPending||detached.hasPane()||session.selected!==key){return;}
      session.setVideoCodecPreference(this.codecPreference);this.lastDesktopMulti=retryMulti;session.enableMultiVideo(retryMulti);await session.joinConfirmed(key);
    }finally{if(revision===this.retryRevision){this.retrying=false;}}
  }
  private retrySingleWindow():Promise<void>{return this.retryDesktop(true);}
  private retrySeparateWindows():Promise<void>{return this.retryDesktop(false,false,true);}
  private switchingDisplay():boolean {
    const display=this.centerView.display;
    return pcHost.supported&&session.hasEstablishedVideo&&!this.hasFrame&&!this.failureText&&!this.directLockFlow&&
      !display?.displayError&&(this.screenBusy||display?.displayPending===true||!!display?.changeKind)&&
      !(session.primaryScreenId<0&&detached.hasPane()&&!this.screenBusy);
  }
  private cancelExit():void {this.exitConfirming=false;this.syncInputGate();}
  private requestExit():void {
    if(this.exitPending||this.exitConfirming){return;}
    this.leave().catch(()=>{});
  }
  private async leave():Promise<void>{
    if(this.exitPending){return;}
    this.exitPending=true;this.exitConfirming=false;deviceLockRequest.cancel();this.lockToken='';
    this.safeReset();this.syncInputGate();
    try{await session.cancel('user_disconnect');}
    finally{await windowPolicy.applyRemote(false);if(this.visible){this.getUIContext().getRouter().back();}}
  }
  private clearLocal():void {this.camera.reset();this.cameraContact=-1;this.cameraTouches.clear();this.virtualRuntime.resetLocal();this.virtualFolder='';this.roundSelected='';this.ownedInput.resetLocal();this.motionOwner.reset();this.dragResidualX=0;this.dragResidualY=0;this.virtualContacts.cancel();this.tablet.cancel();this.tabletSuppressed=false;this.virtualMouse.cancel();this.virtualMulti=false;this.virtualPaired=false;this.virtualHeld=false;this.virtualRightHeld=false;this.virtualMiddleHeld=false;this.gamepad.reset();this.touch.cancel();this.mobile.cancel();this.imeReset++;this.composing=false;this.hardware.resetLocal();this.pointer.resetLocal();this.ctrl=false;this.alt=false;this.shift=false;this.win=false;}
  private safeReset():void {this.clearLocal();session.releaseInputs();}
  private geometryKey:string='';
  private geometry():void {const key=`${this.stageW}/${this.stageH}/${this.frameWidth}/${this.frameHeight}`;if(key===this.geometryKey){return;}this.safeReset();this.geometryKey=key;this.touch.setGeometry({viewportW:this.stageW,viewportH:this.stageH,frameW:this.frameWidth,frameH:this.frameHeight});this.syncVirtualGate();}
  private fitWidth():number {return Math.min(this.stageW,this.stageH*this.frameWidth/this.frameHeight);}
  private fitHeight():number {return this.fitWidth()*this.frameHeight/this.frameWidth;}
  private touchAction(a:TouchAction):void {
    if(a.kind===TouchActionKind.MoveAbsolute){if(this.motionOwner.permits('mobile')){this.mobile.absolute(a.x,a.y);}}
    else if(a.kind===TouchActionKind.MoveRelative){if(this.motionOwner.permits('mobile')){this.mobile.relative(a.dx,a.dy);}}
    else if(a.kind===TouchActionKind.Scroll){this.mobile.scroll(a.dx,a.dy);}
    else if(a.kind===TouchActionKind.Press){this.mobile.button(a.button==='left'?1:2,true);}
    else if(a.kind===TouchActionKind.Release){this.mobile.button(a.button==='left'?1:2,false);}
  }
  private cameraTouch(event:TouchEvent,overlayChanged:number[]):boolean {
    const settings=this.virtualPlan?.camera;if(!settings?.enabled||!this.cameraMode||!this.virtualKeysReady()){return false;}
    if(event.type===TouchType.Down){for(const point of event.changedTouches){if(overlayChanged.includes(point.id)||this.virtualRuntime.owns(point.id)||this.cameraTouches.size>=16){continue;}this.cameraTouches.add(point.id);if(!this.virtualRuntime.beginExternal(point.id)){continue;}if(this.cameraContact>=0){continue;}const owner='camera:'+point.id;if(!this.motionOwner.permits(owner)){continue;}if(!this.motionOwner.owns(owner)){if(!this.mobile.flush()||!this.pointer.flush()){continue;}if(!this.motionOwner.acquire(owner)){continue;}}if(this.camera.begin(point.id,point.x,point.y,this.stageW,this.stageH,this.camera.epoch())){this.cameraContact=point.id;}else{this.motionOwner.release(owner);}}return true;}
    if(event.type===TouchType.Move){if(this.cameraContact>=0){const point=event.touches.find((item:TouchObject)=>item.id===this.cameraContact);if(point){this.camera.move(point.id,point.x,point.y,this.camera.epoch());}}return this.cameraTouches.size>0;}
    if(event.type===TouchType.Up){let consumed=false;for(const point of event.changedTouches){if(!this.cameraTouches.has(point.id)){continue;}consumed=true;this.cameraTouches.delete(point.id);this.virtualRuntime.endExternal(point.id);if(point.id===this.cameraContact){this.camera.end(point.id);this.motionOwner.release('camera:'+point.id);this.cameraContact=-1;}}return consumed||this.cameraTouches.size>0;}
    if(event.type===TouchType.Cancel){this.safeReset();return true;}return false;
  }
  private handleTouch(event:TouchEvent):void {
    event.stopPropagation();
    if(event.source===SourceType.Mouse){return;}
    const overlayChanged:number[]=event.changedTouches.filter((t:TouchObject)=>this.virtualRuntime.owns(t.id)).map((t:TouchObject)=>t.id);
    const live:number[]=[];for(const t of event.touches){if(!(event.type===TouchType.Up&&event.changedTouches.some((c:TouchObject)=>c.id===t.id))){live.push(t.id);}}this.virtualRuntime.observeContacts(live);
    this.reconcileContacts(event);
    if(event.type===TouchType.Cancel){this.canvasContacts=0;this.safeReset();this.tablet.platformCancel();return;}
    this.canvasContacts=event.touches.filter((t:TouchObject)=>!this.virtualContacts.own(t.id)&&!this.virtualRuntime.owns(t.id)&&!(event.type===TouchType.Up&&event.changedTouches.some((c:TouchObject)=>c.id===t.id))).length;
    if(this.tablet.isBlocked()&&event.type===TouchType.Up){for(const t of event.changedTouches){this.tablet.up(t.id);}}
    if(this.cameraTouch(event,overlayChanged)){return;}
    if(!this.virtualContacts.ready()){return;}
    if(!this.visible||this.exitPending||this.exitConfirming||this.failureText||this.monitorsOpen||this.screenBusy||this.toolsOpen||this.advancedOpen||this.centerOpen||this.keyboard||this.centerView.watch||session.displayBlocked||this.centerView.display?.displayPending||this.centerView.display?.inputBlocked||this.centerView.display?.displayError||(!this.controlEnabled&&!this.viewOnly)){return;}
    if(event.type===TouchType.Down){this.focusCanvas();if(this.virtualKeysOn){this.motionOwner.acquire('mobile');}}
    if(event.type===TouchType.Up&&this.canvasContacts===0){this.motionOwner.release('mobile');}
    if(this.mode===TouchMode.Tablet&&!this.viewOnly){this.handleTablet(event);return;}
    if(this.mode===TouchMode.VirtualMouse&&!this.viewOnly){this.handleVirtualCanvas(event);return;}
    const points:TouchPoint[]=[];const remaining:TouchPoint[]=[];
    if(event.type===TouchType.Up){
      for(const t of event.changedTouches){if(!this.virtualRuntime.owns(t.id)&&!overlayChanged.includes(t.id)){points.push({id:t.id,x:t.x,y:t.y});}}
      for(const t of event.touches){if(!this.virtualRuntime.owns(t.id)&&!event.changedTouches.some((c:TouchObject)=>c.id===t.id)){remaining.push({id:t.id,x:t.x,y:t.y});}}
      this.touch.handle(TouchEventKind.Up,points,remaining,Date.now());
    }else{
      for(const t of event.touches){if(!this.virtualRuntime.owns(t.id)){points.push({id:t.id,x:t.x,y:t.y});}}
      this.touch.handle(event.type===TouchType.Down?TouchEventKind.Down:TouchEventKind.Move,points,points,Date.now());
    }
  }
  private sendTabletEvent(event:TabletEvent|undefined):void {if(event!==undefined&&!session.sendTablet(event)){this.safeReset();}}
  private handleTablet(event:TouchEvent):void {
    if(session.touchSupport!==2){return;}
    if(this.tabletSuppressed){if(this.canvasContacts===0){this.tabletSuppressed=false;}return;}
    if(event.type===TouchType.Down){for(const t of event.changedTouches){const mapped=this.touch.mapPoint(t.x,t.y);if(!mapped.inside){this.safeReset();this.tabletSuppressed=true;return;}this.sendTabletEvent(this.tablet.down({id:t.id,x:mapped.x,y:mapped.y}));}}
    else if(event.type===TouchType.Move){const points:TabletPoint[]=[];for(const t of event.touches){const p=this.touch.mapPoint(t.x,t.y);points.push({id:t.id,x:p.x,y:p.y});}this.sendTabletEvent(this.tablet.move(points));}
    else if(event.type===TouchType.Up){for(const t of event.changedTouches){this.sendTabletEvent(this.tablet.up(t.id));}}
  }
  private reconcileContacts(event:TouchEvent):void {const ids:number[]=[];for(const t of event.touches){if(!(event.type===TouchType.Up&&event.changedTouches.some((c:TouchObject)=>c.id===t.id))){ids.push(t.id);}}this.virtualContacts.reconcile(ids);this.tablet.reconcileBlocked(ids);}
  private virtualReady():boolean {return this.inputAvailable()&&!this.toolsOpen&&!this.advancedOpen&&!this.centerOpen&&!this.monitorsOpen&&!this.keyboard&&!this.terminalOpen&&this.virtualContacts.ready();}
  private virtualAnchor():void {this.mobile.absolute(this.virtualMouse.x,this.virtualMouse.y);}
  private handleVirtualCanvas(event:TouchEvent):void {
    if(!this.virtualReady()){return;}
    if(event.type===TouchType.Down&&this.canvasContacts>1){this.virtualMouse.cancel();this.virtualMulti=true;}
    else if(this.virtualMulti){if(this.canvasContacts===0){this.virtualMulti=false;}return;}
    else if(event.type===TouchType.Down&&event.changedTouches.length===1){const t=event.changedTouches[0];this.virtualContacts.canvas=t.id;this.virtualPaired=this.virtualHeld||this.virtualRightHeld||this.virtualMiddleHeld||this.virtualContacts.wheelUp>=0||this.virtualContacts.wheelDown>=0;this.virtualMouse.down(t.id,t.x,t.y,Date.now());}
    else if(event.type===TouchType.Move){for(const t of event.touches){if(this.virtualMouse.move(t.id,t.x,t.y,this.fitWidth()*this.zoom,this.fitHeight()*this.zoom,this.speed)){this.cursorX=this.virtualMouse.x;this.cursorY=this.virtualMouse.y;this.virtualAnchor();}}}
    else if(event.type===TouchType.Up){for(const t of event.changedTouches){const owned=t.id===this.virtualContacts.canvas;const tap=this.virtualMouse.up(t.id,t.x,t.y,Date.now());if(owned){this.virtualContacts.canvas=-1;if(tap&&!this.virtualPaired&&!this.virtualHeld&&!this.virtualRightHeld&&!this.virtualMiddleHeld){this.virtualAnchor();this.mobile.button(1,true);this.mobile.button(1,false);}this.virtualPaired=false;}}}
  }
  private virtualButton(event:TouchEvent,button:number):void {
    event.stopPropagation();this.reconcileContacts(event);
    if(event.type===TouchType.Down&&event.changedTouches.length&&this.virtualReady()){
      const id=event.changedTouches[0].id;const owner=button===1?this.virtualContacts.left:button===2?this.virtualContacts.right:this.virtualContacts.wheel;
      if(owner<0){if(this.virtualContacts.canvas>=0){this.virtualPaired=true;}this.virtualAnchor();if(this.mobile.button(button,true)){if(button===1){this.virtualContacts.left=id;this.virtualHeld=true;}else if(button===2){this.virtualContacts.right=id;this.virtualRightHeld=true;}else{this.virtualContacts.wheel=id;this.virtualMiddleHeld=true;}}}
    }else if(event.type===TouchType.Up||event.type===TouchType.Cancel){
      const owner=button===1?this.virtualContacts.left:button===2?this.virtualContacts.right:this.virtualContacts.wheel;
      if(event.type===TouchType.Cancel||(owner>=0&&event.changedTouches.some((t:TouchObject)=>t.id===owner))){
        const held=button===1?this.virtualHeld:button===2?this.virtualRightHeld:this.virtualMiddleHeld;if(button===1){this.virtualContacts.left=-1;this.virtualHeld=false;}else if(button===2){this.virtualContacts.right=-1;this.virtualRightHeld=false;}else{this.virtualContacts.wheel=-1;this.virtualMiddleHeld=false;}if(held){this.mobile.button(button,false);}
      }
    }
  }
  private virtualScrollButton(event:TouchEvent,up:boolean):void {
    event.stopPropagation();this.reconcileContacts(event);
    const owner=up?this.virtualContacts.wheelUp:this.virtualContacts.wheelDown;
    if(event.type===TouchType.Down&&event.changedTouches.length&&owner<0&&this.virtualReady()){if(this.virtualContacts.canvas>=0){this.virtualPaired=true;}if(up){this.virtualContacts.wheelUp=event.changedTouches[0].id;}else{this.virtualContacts.wheelDown=event.changedTouches[0].id;}this.virtualAnchor();this.mobile.scroll(0,up?40:-40);}
    else if(event.type===TouchType.Cancel||(event.type===TouchType.Up&&owner>=0&&event.changedTouches.some((t:TouchObject)=>t.id===owner))){if(up){this.virtualContacts.wheelUp=-1;}else{this.virtualContacts.wheelDown=-1;}}
  }
  private virtualHandle(event:TouchEvent):void {
    event.stopPropagation();this.reconcileContacts(event);
    if(event.type===TouchType.Down&&event.changedTouches.length&&this.virtualReady()&&this.virtualContacts.handle<0){const t=event.changedTouches[0];this.virtualContacts.handle=t.id;this.virtualHandleX=t.windowX;this.virtualHandleY=t.windowY;}
    else if(event.type===TouchType.Move){for(const t of event.touches){if(t.id===this.virtualContacts.handle){this.mousePanelX=Math.max(0,Math.min(this.stageW-178*this.mouseSize,this.mousePanelX+t.windowX-this.virtualHandleX));this.mousePanelY=Math.max(0,Math.min(this.stageH-180*this.mouseSize,this.mousePanelY+t.windowY-this.virtualHandleY));this.virtualHandleX=t.windowX;this.virtualHandleY=t.windowY;}}}
    else if(event.type===TouchType.Cancel||(event.type===TouchType.Up&&event.changedTouches.some((t:TouchObject)=>t.id===this.virtualContacts.handle))){this.virtualContacts.handle=-1;this.saveInputPreferences();}
  }
  private special(key:number,label:string='按键'):void {if(!this.inputAvailable()||this.composing){return;}const accepted=this.mobile.key(key);this.syncModifiers();this.inputHint=accepted?'已排队发送 '+label:'未发送，请检查连接状态。';}
  private shortcut(key:number):void {this.mobile.shortcut(key);this.ctrl=false;this.alt=false;this.shift=false;this.win=false;}
  private keyboardReady():boolean {
    return this.keyboard&&this.imeFocused&&this.inputAvailable()&&session.busy&&session.appForeground&&session.windowFocused&&!session.isClosing&&!session.watch&&!this.toolsOpen&&!this.centerOpen&&!this.advancedOpen&&!this.monitorsOpen&&!this.terminalOpen;
  }
  private commitIme(text:string):boolean {
    if(!this.keyboardReady()){return false;}
    const accepted=this.mobile.commitText(text);this.syncModifiers();
    this.inputHint=accepted?'文字已排队发送，请以电脑画面为准。':'文字未发送且不会重放；组合键仅接受单字母或数字。';return accepted;
  }
  private imeKey(key:number,count:number):boolean {
    if(!this.keyboardReady()){return false;}
    const accepted=count===1?this.mobile.key(key):this.mobile.repeatKey(key,count);this.syncModifiers();return accepted;
  }
  private openCenter(value:boolean):void {if(value){this.childParent=this.toolsOpen?this.operationsPage:'';}this.safeReset();this.toolsOpen=false;this.centerOpen=value;if(!value){this.restoreTools();}this.syncInputGate();this.armToolsTimer();}
  private quality(value:number,label:string):void {this.qa=value;center.apply({kind:'quality',value:value},label);}
  private fps(value:number):void {this.requestedFps=value;center.apply({kind:'fps',value:value},value+' 帧/秒');}
  private async resolution(value:string):Promise<void> {
    this.requestedResolution=value;
    const screen=activeScreen(this.centerView.display);
    const source=screen?.initial||screen?.currentResolution||{width:this.frameWidth,height:this.frameHeight};
    if(value==='remote'){this.qa=4;await center.apply({kind:'resolution',value:'remote'},'传输原始尺寸 · '+source.width+'×'+source.height);return;}
    const size=resolutionSize(source,{width:vp2px(this.viewportW),height:vp2px(this.viewportH)},value);
    center.apply({kind:'resolution',value:value,width:size.width,height:size.height},(value==='fit'?'适应窗口':value)+' · '+size.width+'×'+size.height);
  }
  private autoLockStatus():string{return this.centerView.autoLockKnown?'电脑报告：'+(this.centerView.remoteAutoLock?'开启':'关闭'):this.centerView.autoLockSupported?'电脑状态未知；发送后等待回报':'尚未收到电脑的设置能力';}
  private autoLockNext():boolean{return this.centerView.autoLockKnown?!this.centerView.remoteAutoLock:!this.requestedLock;}
  private secureStateText():string{return this.centerView.remoteLockKnown?'电脑当前：'+(this.centerView.remoteLocked?'已锁定':'未锁定'):'电脑锁定状态未知';}
  private unlockHint():string {
    if(this.centerView.remoteLockKnown&&!this.centerView.remoteLocked){return '电脑报告：已解锁 · '+this.unlockText;}
    return this.unlockText;
  }
  private async refreshWindowsUnlock():Promise<void>{
    if(!this.visible||!session.windowsUnlockAllowed()||this.unlockBusy){return;}
    const generation=session.generation;
    if(this.unlockStatusEpoch!==generation){this.unlockAvailable=false;this.unlockEnrolled=false;this.unlockEnabled=false;this.unlockReenrollmentRequired=false;this.unlockToggleFailure='';this.unlockText='正在读取这台电脑的自动解锁设置';this.unlockStatusAt=0;this.unlockStatusEpoch=generation;}
    if(Date.now()-this.unlockStatusAt<2000){return;}this.unlockStatusAt=Date.now();
    await this.windowsUnlockAction('status','');
    if(this.visible&&generation===session.generation&&session.windowsUnlockAllowed()&&this.unlockAvailable&&!this.unlockReenrollmentRequired&&this.unlockEnabled&&this.unlockEnrolled&&this.centerView.remoteLockKnown&&this.centerView.remoteLocked&&this.centerView.unlockCapabilityKnown&&this.centerView.autoUnlockSupported&&this.unlockAutoEpoch!==generation){
      this.unlockAutoEpoch=generation;await this.windowsUnlockAction('use','');
    }
  }
  private async windowsUnlockAction(action:string,password:string):Promise<void>{
    if(!this.visible||this.exitPending||this.exitConfirming||this.unlockBusy||!session.windowsUnlockAllowed()){password='';return;}
    const generation=session.generation;const key=session.selected;this.unlockBusy=true;this.unlockTogglePending=action==='enable'||action==='disable';if(this.unlockTogglePending){this.unlockToggleFailure='';this.unlockText='正在更新自动解锁设置…';}
    try{
      const reply:WindowsUnlockReply=await session.windowsUnlock(action,password);password='';
      if(!this.visible||generation!==session.generation||key!==session.selected){return;}
      if(reply.error||reply.ok===false||((action==='enable'||action==='disable')&&(reply.ok!==true||reply.enabled!==(action==='enable')))||(action==='enroll'&&(reply.ok!==true||reply.enrolled!==true||reply.enabled!==false))||(action==='delete'&&(reply.ok!==true||reply.enrolled!==false||reply.enabled!==false))||(action==='status'&&typeof reply.available!=='boolean')){if(action==='enable'||action==='disable'){this.unlockToggleFailure=action;}this.unlockText=action==='use'?'自动解锁未完成，请在电脑本机确认或手动解锁':'操作未完成，请检查授权会话与系统安全存储后重试';return;}
      if(reply.available!==undefined){this.unlockAvailable=reply.available;}
      if(reply.enrolled!==undefined){this.unlockEnrolled=reply.enrolled;}
      if(reply.enabled!==undefined){this.unlockEnabled=reply.enabled;}
      if(reply.available!==undefined){this.unlockReenrollmentRequired=reply.reenrollmentRequired===true;}
      if(action==='use'){this.unlockText=reply.sent?'已发送自动解锁请求，等待电脑报告结果':'自动解锁未发送，请手动解锁';}
      else if(action==='enroll'){this.unlockToggleFailure='';this.unlockText='密码已安全保存；请单独开启这台电脑的自动解锁';}
      else if(action==='delete'){this.unlockToggleFailure='';this.unlockText='已删除这台电脑的密码并关闭自动解锁';}
      else if(action==='disable'){this.unlockToggleFailure='';this.unlockText='这台电脑的自动解锁已关闭';}
      else if(action==='enable'){this.unlockToggleFailure='';this.unlockText='已开启这台电脑的自动解锁';}
      else if(this.unlockReenrollmentRequired){this.unlockText='这台电脑已保存密码，自动解锁设置已'+(this.unlockEnabled?'开启':'关闭')+'。本次连接的设备身份尚未验证，已暂停提交。可关闭本地设置；重新设置密码会绑定本次设备身份。';}
      else if(!this.unlockAvailable){this.unlockText='当前电脑或授权会话尚未提供自动解锁';}
      else if(this.unlockAutoEpoch!==generation){this.unlockText=this.unlockEnabled?'这台电脑的自动解锁已开启':this.unlockEnrolled?'已保存密码，自动解锁未开启':'尚未设置 Windows 账户密码';}
    }catch(_){if(this.visible&&generation===session.generation&&key===session.selected){if(action==='enable'||action==='disable'){this.unlockToggleFailure=action;}this.unlockText='系统安全存储不可用，自动解锁未完成';}}
    finally{password='';this.unlockBusy=false;this.unlockTogglePending=false;}
  }
  private remoteToggle(kind:string,value:boolean):void {
    if(kind==='auto_lock'&&!this.centerView.autoLockSupported){return;}
    const key=session.selected;const generation=session.generation;
    const label=kind==='auto_lock'?'断开后自动锁屏':'被控端静音';
    this.showDialog({title:'确认影响 Windows 状态',message:'目标电脑：'+this.desktopName+'。'+(value?'开启':'关闭')+label+'。'+(kind==='auto_lock'?'开启后正常断开可能锁住这台电脑，请准备在Windows本机解锁。':'开启会改变被控电脑声音输出，关闭将按上游协议恢复声音。')+'仅在你确认后发送；界面不会把发送结果当成远端实际生效。',primaryButton:{value:'取消',action:()=>{}},secondaryButton:{value:'确认发送',action:()=>{if(!this.securityReady()||this.exitPending||session.selected!==key||session.generation!==generation||!session.windowFocused){return;}if(kind==='auto_lock'){this.requestedLock=value;}else{this.requestedMute=value;}center.apply({kind:kind,enabled:value,confirmed:true},value?'开启':'关闭');}}});
  }
  @Builder
  resolutionChoice(label:string,value:string,key:string,available:boolean){
    Button((this.requestedResolution===value?'✓ ':'')+label,{type:ButtonType.Normal}).fontColor(UiColor.text).id(key)
      .height('auto').constraintSize({minHeight:48}).padding(12).margin({right:8,bottom:8}).fontSize(14).borderRadius(12)
      .fontColor(this.requestedResolution===value?UiColor.primary:UiColor.text)
      .backgroundColor(this.requestedResolution===value?UiColor.primarySoft:UiColor.neutralSoft)
      .border({width:this.requestedResolution===value?1:0,color:UiColor.primary}).borderRadius(12)
      .accessibilityText(label+(this.requestedResolution===value?'，已选择':''))
      .enabled(this.controlEnabled&&available).onClick(()=>this.resolution(value))
  }
  @Builder
  controlPanel(){
    Column({space:10}){
      Row({space:8}){Text('画质与连接').fontSize(22).fontWeight(FontWeight.Bold).layoutWeight(1);Button('返回',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).constraintSize({minHeight:48}).id('closeCenter').onClick(()=>this.openCenter(false))}.width('100%')
      Scroll(){Column({space:10}){
        Text(this.centerView.capability).fontSize(11).fontColor(UiColor.secondary).width('100%')
        Text('画质').fontSize(16).fontWeight(FontWeight.Medium).width('100%')
        Text('选择目标画质，实际效果取决于连接与电脑能力。').fontSize(13).fontColor(UiColor.secondary).width('100%')
        Flex({wrap:FlexWrap.Wrap}){
          Button('自动',{type:ButtonType.Normal}).fontColor(UiColor.text).id('qualityAuto').height('auto').constraintSize({minHeight:48}).padding(12).margin({right:8,bottom:8}).fontSize(14).borderRadius(12).fontColor(this.qa===5?UiColor.primary:UiColor.text).backgroundColor(this.qa===5?UiColor.primarySoft:UiColor.neutralSoft).accessibilityText('自动'+(this.qa===5?'，已选择':'')).onClick(()=>this.quality(5,'自动'))
          Button('高清2M',{type:ButtonType.Normal}).fontColor(UiColor.text).id('quality2M').height('auto').constraintSize({minHeight:48}).padding(12).margin({right:8,bottom:8}).fontSize(14).borderRadius(12).fontColor(this.qa===2?UiColor.primary:UiColor.text).backgroundColor(this.qa===2?UiColor.primarySoft:UiColor.neutralSoft).accessibilityText('高清2M'+(this.qa===2?'，已选择':'')).onClick(()=>this.quality(2,'高清2M'))
          Button('超清8M',{type:ButtonType.Normal}).fontColor(UiColor.text).id('quality8M').height('auto').constraintSize({minHeight:48}).padding(12).margin({right:8,bottom:8}).fontSize(14).borderRadius(12).fontColor(this.qa===3?UiColor.primary:UiColor.text).backgroundColor(this.qa===3?UiColor.primarySoft:UiColor.neutralSoft).accessibilityText('超清8M'+(this.qa===3?'，已选择':'')).onClick(()=>this.quality(3,'超清8M'))
          Button('高码率20M',{type:ButtonType.Normal}).fontColor(UiColor.text).id('quality20M').height('auto').constraintSize({minHeight:48}).padding(12).margin({right:8,bottom:8}).fontSize(14).borderRadius(12).fontColor(this.qa===4?UiColor.primary:UiColor.text).backgroundColor(this.qa===4?UiColor.primarySoft:UiColor.neutralSoft).accessibilityText('高码率20M'+(this.qa===4?'，已选择':'')).onClick(()=>this.quality(4,'高码率20M'))
        }.enabled(this.controlEnabled)
        Text(this.centerView.actualVideo).fontSize(12).fontColor(UiColor.secondary).width('100%')
        Text('目标帧率').fontSize(15).width('100%')
        Text(this.centerView.fpsStatus).fontSize(12).fontColor(UiColor.secondary).width('100%')
        Flex({wrap:FlexWrap.Wrap}){Button('30 帧',{type:ButtonType.Normal}).fontColor(UiColor.text).id('fps30').height('auto').constraintSize({minHeight:48}).padding(12).margin({right:8,bottom:8}).borderRadius(12).fontColor(this.requestedFps===30?UiColor.primary:UiColor.text).backgroundColor(this.requestedFps===30?UiColor.primarySoft:UiColor.neutralSoft).accessibilityText('30帧'+(this.requestedFps===30?'，已选择':'')).enabled(this.controlEnabled&&this.centerView.maxFps>=30).onClick(()=>this.fps(30));Button('60 帧',{type:ButtonType.Normal}).fontColor(UiColor.text).id('fps60').height('auto').constraintSize({minHeight:48}).padding(12).margin({right:8,bottom:8}).borderRadius(12).fontColor(this.requestedFps===60?UiColor.primary:UiColor.text).backgroundColor(this.requestedFps===60?UiColor.primarySoft:UiColor.neutralSoft).accessibilityText('60帧'+(this.requestedFps===60?'，已选择':'')).enabled(this.controlEnabled&&this.centerView.maxFps>=60).onClick(()=>this.fps(60))}
        Text('传输画面尺寸').fontSize(15).width('100%')
        Text(this.centerView.displayText).fontSize(12).fontColor(UiColor.secondary).width('100%')
        Text('按显示器比例请求传输尺寸，不更改电脑屏幕分辨率；实际画面尺寸以送显结果为准。').fontSize(12).fontColor(UiColor.secondary).width('100%')
        Flex({wrap:FlexWrap.Wrap}){
          this.resolutionChoice('传输原始尺寸','remote','resolutionRemote',!!activeScreen(this.centerView.display)?.initial)
          this.resolutionChoice('适应窗口','fit','resolutionFit',true)
          this.resolutionChoice('720p','720p','resolution720',true)
          this.resolutionChoice('1080p','1080p','resolution1080',true)
        }
        Row(){Text('观看模式 · '+(this.centerView.watch?'开启':'关闭')).layoutWeight(1);Button(this.centerView.watch?'允许操作':'仅观看',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).id('watchToggle').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).enabled(this.controlEnabled).onClick(()=>center.apply({kind:'watch',enabled:!this.centerView.watch},'观看'))}.width('100%')
        Text(this.centerView.watchStatus).fontSize(11).width('100%')
        Row(){Text('断开后自动锁屏 · '+this.autoLockStatus()).layoutWeight(1);Button(this.autoLockNext()?'开启':'关闭',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).id('autoLockToggle').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).enabled(this.centerView.autoLockSupported).onClick(()=>this.remoteToggle('auto_lock',this.autoLockNext()))}.enabled(this.securityReady())
        Row(){Text('被控端静音（本地选择）').layoutWeight(1);Button(this.requestedMute?'关闭':'开启',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).id('hostMuteToggle').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).onClick(()=>this.remoteToggle('host_mute',!this.requestedMute))}.enabled(this.controlEnabled)
        Divider()
        Button(this.showConnectionDetails?'收起连接详情':'查看连接详情',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).id('connectionDetails').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).constraintSize({minHeight:48}).width('100%').onClick(()=>this.showConnectionDetails=!this.showConnectionDetails)
        if(this.showConnectionDetails){
        Text('实际网络与解码状态').fontColor(UiColor.text).fontSize(15).fontWeight(FontWeight.Bold).width('100%')
        Text('连接方式：'+this.centerView.connectionMethod).id('detailsConnectionMethod').fontColor(UiColor.text).fontSize(12).width('100%')
        Text('传输协议：'+this.centerView.transportProtocol).id('detailsTransportProtocol').fontColor(UiColor.text).fontSize(12).width('100%')
        Text(this.centerView.network).fontColor(UiColor.text).id('networkStatus').fontSize(12).width('100%')
        Text('请求状态（解码尺寸/FPS的实测变化见上方）').fontColor(UiColor.text).fontSize(14).width('100%')
        ForEach(this.centerView.rows,(row:ControlRow)=>{
          Column({space:3}){Text(row.label+' · 本地选择：'+row.local).fontColor(UiColor.text).fontSize(13).fontWeight(FontWeight.Medium).width('100%');Text(row.send+' · '+row.ack).fontColor(UiColor.text).fontSize(11).width('100%');Text(row.reported).fontSize(11).fontColor(UiColor.secondary).width('100%')}.padding(8).width('100%').backgroundColor(UiColor.neutralSoft).borderRadius(8)
        },(row:ControlRow)=>row.kind+'|'+row.local+'|'+row.send+'|'+row.ack+'|'+row.reported)
        }
      }.width('100%')}.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }.padding(20).width('100%').height('100%').backgroundColor(UiColor.surface).borderRadius(22).foregroundColor(UiColor.text)
  }
  @Builder
  keyboardPanel(){
    RemoteKeyboardDock({composing:$composing,available:this.inputAvailable()&&session.windowFocused&&session.appForeground,resetToken:this.imeReset,nativeOnly:pcHost.supported,modifiers:this.modifierLabel(),hint:this.inputHint,maxHeight:this.keyboardHeight(),imeVisible:this.imeHeight>0,
      onModifier:(key:number)=>this.selectModifier(key),onKey:(key:number,label:string)=>this.special(key,label),onCombo:(keys:number[],key:number,label:string)=>this.combo(keys,key,label),
      onClear:()=>this.clearModifiers(),onCommit:(text:string)=>this.commitIme(text),onImeKey:(key:number,count:number)=>this.imeKey(key,count),onPhysicalKey:(event:KeyEvent)=>this.physicalKey(event,true),canInput:()=>this.keyboardReady(),inputEpoch:()=>this.imeReset,onReset:()=>this.safeReset(),onClose:()=>this.closeKeyboard(),onFocusChange:(focused:boolean)=>{this.imeFocused=focused;this.hardwareGates();}})
  }
  @Builder
  toolsPanel(){
    RemoteOperationsPanel({orientationChoice:this.orientationChoice,onOrientation:(value:number)=>{this.safeReset();this.orientationChoice=value;windowPolicy.setRemoteOrientation(value);},actualCodec:session.selectedVideoCodec,codecPreference:this.codecPreference,onCodecPreference:(value:number)=>{this.codecPreference=value;this.preferences?.saveVideoCodec(value);},multiMode:session.multiMode,singleModeAvailable:session.multiMode&&!detached.hasPane(),multiModeAvailable:pcHost.supported&&!session.multiMode&&!session.watch&&session.separateWindowsAvailable&&this.hasFrame,onSingleMode:()=>this.retrySingleWindow(),onMultiMode:()=>this.retrySeparateWindows(),securityReady:this.securityReady(),autoLockSupported:this.centerView.autoLockSupported,autoLockText:this.autoLockStatus(),secureStateText:this.secureStateText(),unlockHint:this.unlockHint(),unlockAvailable:this.unlockAvailable,unlockEnrolled:this.unlockEnrolled,unlockReenrollmentRequired:this.unlockReenrollmentRequired,unlockEnabled:this.unlockEnabled,unlockBusy:this.unlockBusy,unlockTogglePending:this.unlockTogglePending,unlockToggleFailure:this.unlockToggleFailure,onUnlock:(action:string,password:string)=>this.windowsUnlockAction(action,password),actualVideo:this.centerView.actualVideo,fpsStatus:this.centerView.fpsStatus,onTerminal:()=>this.requestTerminal(),privacySupport:this.centerView.privacySupport,privacyOwned:this.centerView.privacyOwned,privacyCurrent:this.centerView.privacyCurrent,privacyText:this.privacyStatus(),onPrivacy:(mode:number)=>this.requestPrivacy(mode),thumbnailPending:this.thumbnailPending,thumbnailHint:this.thumbnailHint,onThumbnail:()=>this.saveDesktopThumbnail(),systemActionPending:this.systemActionPending,systemActionText:this.systemActionText,onSystemAction:(kind:RemoteSystemAction)=>this.requestSystemAction(kind),route:$operationsPage,quality:this.qa,fps:this.requestedFps,maxFps:this.centerView.maxFps,onQualityChoice:(value:number,label:string)=>this.quality(value,label),onFpsChoice:(value:number)=>this.fps(value),initialPage:this.operationsInitial,locked:this.requestedLock,hostMuted:this.requestedMute,network:this.centerView.network,connectionMethod:this.centerView.connectionMethod,transportProtocol:this.centerView.transportProtocol,
      deviceKey:session.selected,onPinned:(id:string)=>this.launchPinned(id),
      desktopControls:pcHost.supported,onLock:()=>this.remoteToggle('auto_lock',this.autoLockNext()),onMute:()=>this.remoteToggle('host_mute',!this.requestedMute),onDesktop:()=>this.showDesktop(),onWindows:()=>this.switchWindow(),desktopName:this.desktopName,mode:this.mode,speed:this.speed,externalKeyboard:this.externalKeyboard,
      viewOnly:this.viewOnly,watch:this.centerView.watch,ready:this.controlEnabled&&!this.exitPending&&!this.exitConfirming,statusText:this.inputFeedback().title,statusTone:this.inputFeedback().tone,
      preferenceHint:this.preferenceHint,compact:this.viewportH<480,
      touchSupport:this.touchSupport,mouseSize:this.mouseSize,mouseOpacity:this.mouseOpacity,onMouseAppearance:(size:number,opacity:number,commit:boolean)=>{this.mouseSize=size;this.mouseOpacity=opacity;if(commit){this.saveInputPreferences();}},
      onMode:(mode:TouchMode)=>this.chooseInputMode(mode),onSpeed:(value:number,commit:boolean)=>this.changePointerSpeed(value,commit),
      gamepadEnabled:this.gamepadEnabled,onGamepad:()=>this.toggleGamepad(),
      micActive:this.micActive,micText:this.micText,onMicrophone:()=>this.toggleMicrophone(),
      onExternalKeyboard:()=>this.toggleExternalKeyboard(),onViewport:()=>this.toggleViewport(),onResetView:()=>{this.safeReset();this.touch.resetView();},
      onWatch:()=>{this.safeReset();center.apply({kind:'watch',enabled:!this.centerView.watch},'观看');},
      onKeyboard:()=>this.openKeyboard(),virtualKeysOn:this.virtualKeysOn,onVirtualKeys:()=>this.toggleVirtualKeys(),onVirtualManage:()=>this.manageVirtualKeys(),onVirtualEdit:()=>this.manageVirtualKeys(true),virtualPlanName:virtualSelection.get()?.name||this.virtualPlan?.name||'官方默认',cameraAvailable:!!this.virtualPlan?.camera?.enabled,cameraActive:this.cameraMode,onCameraMode:()=>this.toggleCameraMode(),onQuality:()=>this.openCenter(true),onMonitors:()=>this.openMonitors(true,true),onSound:()=>this.openAdvanced(1),
      onClipboard:()=>this.openAdvanced(2),onFiles:()=>this.openAdvanced(3),onRelease:()=>{this.safeReset();this.getUIContext().getPromptAction().showToast({message:'已请求释放全部输入',duration:1500});},
      onClose:()=>this.toggleTools(false),onDisconnect:()=>this.requestExit()})
  }
  @Builder
  monitorPanel(){
    Column({space:12}){
      Row(){Text('显示器').fontSize(22).fontWeight(FontWeight.Bold).layoutWeight(1);Button('返回',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).backgroundColor(UiColor.neutralSoft).constraintSize({minHeight:48}).id('closeMonitors').onClick(()=>this.openMonitors(false))}.width('100%')
      if(this.monitorPanelStatus()){
        Text(this.monitorPanelStatus()).id('monitorStatus').fontSize(13).fontColor(UiColor.secondary).width('100%')
      }
      Scroll(){Column({space:8}){
        ForEach(this.centerView.display?.screens||[],(screen:ScreenRow,index:number)=>{
          Column({space:4}){
            Button({type:ButtonType.Normal}){
              Row({space:10}){
                Column({space:4}){
                  Text(screen.name||'显示器 '+(index+1)).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
                    .width('100%').maxLines(2).textOverflow({overflow:TextOverflow.Ellipsis})
                  Text(`${screen.native.width} × ${screen.native.height}${screen.native.height>screen.native.width?' · 竖屏':''}${screen.primary?' · 主屏幕':''}`)
                    .fontSize(12).fontColor(UiColor.secondary).width('100%')
                }.layoutWeight(1)
                if(this.currentMonitor(screen.id)){
                  Text('✓ 当前屏幕').fontSize(12).fontColor(UiColor.primary)
                }else if(this.centerView.display?.requestedScreen===screen.id&&this.centerView.display?.changeKind==='switch'){
                  if(this.centerView.display?.displayPending){Text('正在切换').fontSize(12).fontColor(UiColor.secondary)}
                  else if(this.centerView.display?.displayError){Text('重试切换').fontSize(12).fontColor(UiColor.primary)}
                }
              }.width('100%')
            }.id('switchScreen'+screen.id).borderRadius(12).width('100%').height('auto').constraintSize({minHeight:56}).padding(12)
              .backgroundColor(this.currentMonitor(screen.id)?UiColor.primarySoft:UiColor.neutralSoft)
              .accessibilitySelected(this.currentMonitor(screen.id))
              .stateEffect(!this.currentMonitor(screen.id))
              .enabled(this.currentMonitor(screen.id)||this.monitorSelectionAvailable())
              .onClick(()=>{if(!this.currentMonitor(screen.id)){this.switchScreen(screen.id);}})
            if(pcHost.supported&&session.multiMode){
              Button('在独立窗口打开',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).id('detachScreen'+screen.id).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).width('100%').constraintSize({minHeight:48})
                .enabled(!detached.hasScreen(screen.id)&&!this.screenBusy&&this.controlEnabled).onClick(()=>this.openScreenWindow(screen.id))
            }
          }.width('100%')
        },(screen:ScreenRow,index:number)=>screen.id+'|'+(screen.name||index)+'|'+screen.native.width+'x'+screen.native.height+'|'+screen.primary)
        if(pcHost.supported&&session.multiMode){
          Text('可将顶部显示器标签向下拖出，或在这里打开独立窗口。').fontSize(13).fontColor(UiColor.secondary).width('100%')
        }
      }.width('100%')}.id('monitorScroll').layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Off)
    }.id('remoteMonitorPanel').padding(20).width('100%').height('100%').backgroundColor(UiColor.surface).borderRadius(22).foregroundColor(UiColor.text)
  }
  @Builder
  pcHeader(){
    Row({space:4}){
      if(!this.pcTitleLayout().compact){Image($r('app.media.ui_computer')).width(20).height(20).accessibilityLevel('no')}
      if(this.pcTitleLayout().showName){Text(this.desktopName).fontSize(14).fontColor(UiColor.text).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).constraintSize({maxWidth:120})}
      if(this.pcTitleLayout().tabsWidth>=48){Scroll(){Row({space:4}){
        if(!this.centerView.display?.inventoryReceived){Text('等待显示器信息').fontSize(12).fontColor(UiColor.secondary).padding(8)}
        ForEach(this.centerView.display?.screens||[],(screen:ScreenRow)=>{
          Button('显示器 '+((this.centerView.display?.screens||[]).findIndex((item:ScreenRow)=>item.id===screen.id)+1)+(screen.name?' · '+screen.name:''),{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).id('pcScreenTab'+screen.id).fontSize(13).height(40).padding({left:12,right:12}).fontColor(UiColor.text)
            .backgroundColor(this.centerView.display?.selectedScreen===screen.id?UiColor.primarySoft:UiColor.neutralSoft)
            .enabled((this.controlEnabled||(session.multiMode&&session.controlOpen&&session.hasEstablishedVideo))&&!this.screenBusy&&!this.centerView.display?.displayPending&&!!this.centerView.display?.switchCommandSupported)
            .onClick(()=>this.switchScreen(screen.id)).gesture(PanGesture({distance:16}).onActionEnd((event:GestureEvent)=>this.dragScreenEnd(screen.id,event)))
        },(screen:ScreenRow)=>screen.id.toString()+'|'+screen.name+'|'+screen.native.width+'x'+screen.native.height+'|'+(this.centerView.display?.selectedScreen===screen.id)+'|'+this.screenBusy)
      }}.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width(this.pcTitleLayout().tabsWidth)}else{Button('屏',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).id('pcScreensOverflow').accessibilityText('选择显示器').width(32).height(40).padding(0).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).onClick(()=>this.openMonitors(true))}
      Blank().id('pcWindowDrag').width(this.pcTitleLayout().dragWidth).height(48).layoutWeight(1).onTouch((event:TouchEvent)=>{if(this.mergedPcTitle&&event.type===TouchType.Down){event.stopPropagation();windowPolicy.moveRemoteWindow();}}).gesture(TapGesture({count:2}).onAction(()=>{if(this.mergedPcTitle){windowPolicy.toggleRemoteWindowSize();}}))
      Button(this.pcTitleLayout().compact?'控':'控制中心',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).id('pcControlCenter').accessibilityText('控制中心').width(this.pcTitleLayout().compact?32:88).height(40).fontSize(13).padding(0).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).onClick(()=>{this.operationsInitial='ops';this.operationsPage='ops';this.toggleTools(!this.toolsOpen);})
      Button(this.pcTitleLayout().compact?'断':'断开',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).id('pcDisconnect').accessibilityText('断开连接').width(this.pcDisconnectWidth()).height(40).fontSize(13).padding(0).fontColor(UiColor.text).backgroundColor(UiColor.errorSoft).onClick(()=>this.requestExit())
    }.id('pcRemoteHeader').width('100%').height(this.mergedPcTitle?48:56).padding({left:this.mergedPcTitle?8:this.safeLeft,right:this.mergedPcTitle?this.titleButtonInset:this.safeRight}).backgroundColor(UiColor.surface).position({left:0,top:this.mergedPcTitle?0:this.safeTop})
  }
  build(){
    Stack({alignContent:Alignment.Center}){
      Stack({alignContent:Alignment.Center}){
      Stack({alignContent:Alignment.Center}){
        XComponent({id:'remoteDesktop',type:XComponentType.SURFACE,controller:this.surfaceController})
          .width(this.fitWidth()).height(this.fitHeight()).onAreaChange((_old:Area,area:Area)=>{session.setViewport(vp2px(Number(area.width)),vp2px(Number(area.height)));}).scale({x:this.zoom,y:this.zoom}).translate({x:this.panX,y:this.panY})
          .onLoad(()=>{this.surfaceId=this.surfaceController.getXComponentSurfaceId();session.setSurface(this.surfaceId);this.beginOnSurface();})
          .onDestroy(()=>{if(session.multiMode&&detached.hasPane()){session.clearPrimarySurface(this.surfaceId);session.closeMultiPrimary();}else{session.surfaceDestroyed(this.surfaceId);}this.surfaceId='';this.syncScreenOn();})
        Text('').width('100%').height('100%').backgroundColor('#00000000').id('touchViewport').accessibilityText('远程桌面输入区域').focusable(true).focusOnTouch(true).defaultFocus(true)
          .onFocus(()=>{this.canvasFocused=true;this.initialCanvasFocusDone=true;this.canvasFocusRestorePending=false;this.canvasFocusEpoch++;this.initialCanvasFocusScheduled=false;this.hardwareGates();}).onBlur(()=>this.canvasBlur()).onKeyPreIme((e:KeyEvent)=>e.keySource===KeySource.Keyboard?this.physicalKey(e):false).onKeyEvent((e:KeyEvent)=>e.keySource===KeySource.JOYSTICK?this.physicalKey(e):false)
          .onFocusAxisEvent((e:FocusAxisEvent)=>this.gamepadAxis(e))
          .onMouse((e:MouseEvent)=>this.physicalMouse(e)).onAxisEvent((e:AxisEvent)=>this.physicalAxis(e)).onTouch((e:TouchEvent)=>this.handleTouch(e))
          .onHover((hover:boolean)=>{if(!hover&&this.pointer.pressedCount()>0){this.safeReset();}})
        if(this.virtualKeysReady()&&this.virtualPlan){
          ForEach(this.virtualVisibleControls(),(control:VirtualControl)=>{
            VirtualKeyControl({control:control,runtime:this.virtualRuntime,controlSize:this.virtualSize(control),highlight:control.id===this.roundSelected})
              .position({left:this.virtualPoint(control).x,top:this.virtualPoint(control).y})
          },(control:VirtualControl)=>control.id)
        }
        if(this.mode===TouchMode.VirtualMouse&&!this.viewOnly&&this.inputAvailable()&&!this.toolsOpen&&!this.centerOpen&&!this.advancedOpen&&!this.monitorsOpen&&!this.keyboard){
          Path().commands('M0 0 L0 22 L5 17 L9 25 L12 23 L8 15 L16 15 Z').width(16).height(25).fill('#FFFFFF').stroke('#111111').strokeWidth(1).position({left:(this.stageW-this.fitWidth()*this.zoom)/2+this.panX+this.cursorX*this.fitWidth()*this.zoom,top:(this.stageH-this.fitHeight()*this.zoom)/2+this.panY+this.cursorY*this.fitHeight()*this.zoom}).hitTestBehavior(HitTestMode.None)
          Column({space:4}){
            Text('⋮⋮  移动鼠标面板').fontSize(12).fontColor(UiColor.text).width(170).height(28).textAlign(TextAlign.Center).onTouch((e:TouchEvent)=>this.virtualHandle(e))
            Row({space:4}){
              Text('左键').fontSize(14).fontColor(UiColor.text).width(55).height(50).textAlign(TextAlign.Center).backgroundColor(UiColor.neutralSoft).borderRadius(8).onTouch((e:TouchEvent)=>this.virtualButton(e,1))
              Column({space:3}){
                Text('上滚').fontSize(12).fontColor(UiColor.text).width(50).height(44).textAlign(TextAlign.Center).backgroundColor(UiColor.neutralSoft).borderRadius(6).onTouch((e:TouchEvent)=>this.virtualScrollButton(e,true))
                Text('中键').fontSize(12).fontColor(UiColor.text).width(50).height(48).textAlign(TextAlign.Center).backgroundColor(UiColor.neutralSoft).borderRadius(6).onTouch((e:TouchEvent)=>this.virtualButton(e,4))
                Text('下滚').fontSize(12).fontColor(UiColor.text).width(50).height(44).textAlign(TextAlign.Center).backgroundColor(UiColor.neutralSoft).borderRadius(6).onTouch((e:TouchEvent)=>this.virtualScrollButton(e,false))
              }
              Text('右键').fontSize(14).fontColor(UiColor.text).width(55).height(50).textAlign(TextAlign.Center).backgroundColor(UiColor.neutralSoft).borderRadius(8).onTouch((e:TouchEvent)=>this.virtualButton(e,2))
            }
          }.padding(4).backgroundColor(UiColor.surface).opacity(this.mouseOpacity).scale({x:this.mouseSize,y:this.mouseSize,centerX:0,centerY:0}).borderRadius(12).position({left:Math.max(0,Math.min(this.stageW-198*this.mouseSize,this.mousePanelX)),top:Math.max(0,Math.min(this.stageH-140*this.mouseSize,this.mousePanelY))})
        }
      }.width(this.presentation().width).height(this.presentation().height).position({left:this.presentation().x,top:this.presentation().y}).clip(true).backgroundColor('#03070D').onAreaChange((_old:Area,area:Area)=>{this.stageW=Number(area.width);this.stageH=Number(area.height);this.geometry();})
      if(this.switchingDisplay()){
        Row({space:8}){
          LoadingProgress().width(22).height(22).color(UiColor.primary)
          Text('正在接收所选显示器画面').fontSize(13).fontColor(UiColor.text)
        }.id('pcScreenSwitchStatus').padding(12).borderRadius(12).backgroundColor(UiColor.surface)
          .position({left:this.safeLeft+16,bottom:this.safeBottom+16}).hitTestBehavior(HitTestMode.None)
      }else if(!this.hasFrame||this.directLockFlow||session.multiMode&&session.primaryScreenId<0){
        Scroll(){Column({space:16}){
          Text(session.multiMode&&session.primaryScreenId<0&&detached.hasPane()?'显示器已移至独立窗口':this.failureText.length>0?'连接未完成':this.directLockFlow?'正在连接并锁屏':session.hasEstablishedVideo?'等待显示器画面':'正在连接电脑').fontSize(24).fontWeight(FontWeight.Bold).fontColor(UiColor.text).width('100%')
          Text(this.desktopName).fontSize(17).fontColor(UiColor.text).width('100%')
          Text(session.hasEstablishedVideo?this.centerView.displayText:this.signalText).id('remoteStatus').fontSize(14).fontColor(UiColor.secondary).width('100%')
          if(session.hasEstablishedVideo&&!this.failureText&&!this.directLockFlow&&!this.railVisible()){Button('选择显示器',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).backgroundColor(UiColor.neutralSoft).id('recoverMonitorSelection').width('100%').constraintSize({minHeight:48}).enabled(this.monitorSelectionAvailable()).onClick(()=>this.openMonitors(true))}
          if(this.failureText.length>0){
            if(!detached.hasPane()){Button('使用 H.264 重试',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).backgroundColor(UiColor.neutralSoft).id('retryH264').width('100%').constraintSize({minHeight:48}).onClick(()=>{this.retryDesktop(false,true);})}
            if(session.legacyRetryAvailable&&!detached.hasPane()){Button('使用单窗口重试',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).backgroundColor(UiColor.neutralSoft).id('retrySingleWindow').width('100%').constraintSize({minHeight:48}).onClick(()=>this.retrySingleWindow())}
            Button('返回设备',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).fontColor(UiColor.onPrimary).backgroundColor(UiColor.primary).id('returnDevices').width('100%').constraintSize({minHeight:48}).onClick(()=>this.leave())
          }else{
            LoadingProgress().id('connectingSpinner').width(40).height(40).color(UiColor.primary)
            Button(this.directLockFlow?'取消锁屏并返回':session.hasEstablishedVideo?'断开并返回设备':'取消连接，返回设备',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).fontColor(UiColor.onPrimary).backgroundColor(UiColor.primary).id('cancelConnection').width('100%').constraintSize({minHeight:48}).onClick(()=>this.leave())
          }
        }.padding(24).width('100%').constraintSize({maxWidth:520})}.width('100%').height('100%').scrollBar(BarState.Off).padding({left:this.safeLeft,right:this.safeRight,top:this.safeTop,bottom:this.safeBottom}).backgroundColor(UiColor.background).onTouch((event:TouchEvent)=>event.stopPropagation())
      }
      if(this.virtualKeysOn&&this.stageW>this.stageH&&this.virtualPlan&&!this.virtualLayout().complete){Text('窗口太小，无法安全显示虚拟按键').fontColor(Color.White).padding(8).backgroundColor('#AA222222').hitTestBehavior(HitTestMode.None)}
      if(this.hasFrame&&(this.centerView.watch||this.viewOnly)){
        Text(this.centerView.watch?'仅观看':'本地缩放').id('remoteModeFlag').fontSize(12).fontColor(UiColor.text).padding(8).backgroundColor(UiColor.surface).borderRadius(10).position({left:this.safeLeft+8,top:this.contentTop()+8}).hitTestBehavior(HitTestMode.None)
      }
      if(this.keyboard){Column(){this.keyboardPanel()}.width(Math.min(720,this.viewportW-this.safeLeft-this.safeRight)).position({left:this.safeLeft,bottom:this.keyboardBottom()})}
      if(this.toolsOpen||this.centerOpen||this.monitorsOpen||this.advancedOpen){
        Stack({alignContent:Alignment.TopStart}){Column(){
          if(this.toolsOpen){this.toolsPanel()}
          if(this.centerOpen){this.controlPanel()}
          if(this.monitorsOpen){this.monitorPanel()}
          if(this.advancedOpen){AdvancedPanel({client:this.advanced,initialPage:this.advancedInitial,fileBrowsing:$fileBrowsing,onClose:()=>this.closeAdvanced(),onPrivacy:()=>{this.advancedOpen=false;this.operationsPage='privacy';this.toolsOpen=true;this.syncInputGate();}})}
        }.id('remoteMenuSheet').width(this.presentation().panelWidth).height(this.presentation().panelHeight).clip(true).borderRadius(18).position({left:this.presentation().panelX,top:this.presentation().panelY})}
          .width('100%').height('100%').backgroundColor(Color.Transparent).onTouch((e:TouchEvent)=>e.stopPropagation())
      }
      if(pcHost.supported&&!this.terminalOpen){this.pcHeader()}
      if(this.terminalOpen){RemoteTerminalPanel({draft:$terminalDraft,output:this.terminalOutput,status:this.terminalStatus,ready:this.terminalPhase==='open',busy:this.terminalBusy,onSend:(text:string,line:boolean)=>this.terminalSend(text,line),onKey:(text:string)=>this.terminalSend(text),onClose:()=>this.requestTerminalReturn()})}
      if(this.railVisible()){
        Row(){RemoteToolsRail({selectedTool:this.monitorsOpen?'railMonitors':this.toolsOpen||this.centerOpen||this.advancedOpen?'railControls':'',screenLabel:toolbarScreenLabel(this.centerView.display),inputAvailable:this.inputAvailable(),horizontal:this.bottomRail(),compact:this.viewportH<440,availableHeight:this.railPlacement().height,availableWidth:this.railPlacement().width,
          onControls:()=>{this.operationsInitial='ops';this.operationsPage='ops';this.toggleTools(true);},onMonitors:()=>this.openMonitors(!this.monitorsOpen),onKeyboard:()=>this.openKeyboard(),onDesktop:()=>this.showDesktop(),onWindows:()=>this.switchWindow(),onBegin:()=>this.safeReset(),onStep:(step:number)=>this.stepScreen(step)})}
          .position({left:this.railPlacement().left,top:this.railPlacement().top}).constraintSize({maxWidth:this.railPlacement().width,maxHeight:this.railPlacement().height}).hitTestBehavior(HitTestMode.Default)
      }
      Row(){}.width('100%').height(this.videoBottom).position({left:0,bottom:0}).backgroundColor('#03070D').hitTestBehavior(HitTestMode.None)
      }.width('100%').height('100%')
    }.width('100%').height('100%').onAreaChange((_old:Area,area:Area)=>{this.viewportW=Number(area.width);this.viewportH=Number(area.height);this.updateInsets();}).backgroundColor('#03070D').expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM]).onTouch(()=>{if(this.toolsOpen||this.centerOpen||this.advancedOpen){this.armToolsTimer();}})
  }
}
