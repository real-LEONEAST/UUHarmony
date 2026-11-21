import { CameraGesture } from './CameraGesture';
import { OwnedInputDispatcher } from './OwnedInputDispatcher';
import { PointerMotionOwnership } from './PointerMotionOwnership';
import { VirtualKeyRuntime } from './VirtualKeyRuntime';
import { VirtualKeyControl } from './VirtualKeyControl';
import { VirtualPlan, VirtualControl } from './VirtualKeyModel';
import { layoutVirtualControls, VirtualPlacement, VirtualPlacementRequest, VirtualLayout } from './VirtualKeyLayout';
import { TouchPoint } from './MobileTouch';
import { VirtualPlanStore } from './VirtualPlanStore';
import { virtualSelection } from './VirtualPlanSelection';
import { client, AuthView } from './AuthClient';
import { adaptUuPlan } from './UuPlanAdapter';
import { util } from '@kit.ArkTS';
import { UiColor } from './UiFoundation';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WindowPolicy, windowPolicy } from './WindowPolicy';
import { detached } from './DetachedCoordinator';
import { session } from './SessionClient';
import { MultiSnapshot } from './MultiVideoClient';
import { HardwareInput } from './HardwareInputModel';
import { RemoteInput } from './MobileInput';

@Entry({ useSharedStorage: true })
@Component
struct DetachedView {
  @LocalStorageProp('detachedLease') private lease: string = '';
  private virtualAccount:string='';private offVirtualAccount:()=>void=()=>{};private pageVisible:boolean=true;private virtualGateReady:boolean=false;
  @State private cameraMode:boolean=false;
  @State private virtualKeysOn:boolean=false;@State private virtualKeysHidden:boolean=false;@State private virtualFolder:string='';@State private roundSelected:string='';@State private virtualPlan:VirtualPlan|undefined=undefined;
  private cameraContact:number=-1;private cameraTouches:Set<number>=new Set();
  private camera:CameraGesture=new CameraGesture((dx:number,dy:number)=>this.dispatchOwned('camera:'+this.cameraContact,[{action:'mouse_move_relative',delta_x:dx,delta_y:dy}]),()=>this.releaseWindowInputs());
  private motionOwner:PointerMotionOwnership=new PointerMotionOwnership();private dragResidualX:number=0;private dragResidualY:number=0;
  private ownedInput:OwnedInputDispatcher=new OwnedInputDispatcher((events:RemoteInput[])=>this.sendNative(events),()=>this.releaseWindowInputs());
  private virtualRuntime:VirtualKeyRuntime=new VirtualKeyRuntime(this.ownedInput.ownership(),(kind:string,id:string)=>this.virtualLocal(kind,id),(delta:number)=>this.virtualWheel(delta),(id:number,dx:number,dy:number,end:boolean)=>this.virtualDrag(id,dx,dy,end),(id:number,controlId:string,dx:number,dy:number,end:boolean,commit:boolean)=>this.virtualRound(id,controlId,dx,dy,end,commit));
  @State private screenLabel: string = '显示器';
  @State private headerWidth: number = 800;
  @State private titleMerged: boolean = false;
  @State private titleInset: number = 0;
  @State private screenId: number = -1;
  @State private ready: boolean = false;
  @State private message: string = '正在准备显示器';
  @State private viewWidth: number = 1;
  @State private viewHeight: number = 1;
  @State private frameWidth: number = 1280;
  @State private frameHeight: number = 720;

  private offCoordinator: () => void = () => {};
  private offPolicy: () => void = () => {};
  private lastGateLog: string = '';
  private policy: WindowPolicy | undefined = undefined;
  private surface: string = '';
  private controller: XComponentController = new XComponentController();
  private off: () => void = () => {};
  private offSession: () => void = () => {};
  private canvasFocused: boolean = false;
  private input:HardwareInput=new HardwareInput((events:RemoteInput[])=>this.dispatchOwned('hardware',events));
  private sendNative(events:RemoteInput[]):boolean {const pane=detached.lookup(this.lease);return !!pane&&!!session.multi&&session.multi.send(pane.screenId,this.lease,events);}
  private dispatchOwned(owner:string,events:RemoteInput[]):boolean {const filtered=events.filter((event:RemoteInput)=>!((event.action==='mouse_move_absolute'||event.action==='mouse_move_relative')&&!this.motionOwner.permits(owner)));return !filtered.length||this.ownedInput.send(owner,filtered);}
  private resetLocal():void {this.camera.reset();this.cameraContact=-1;this.cameraTouches.clear();this.virtualRuntime.resetLocal();this.ownedInput.resetLocal();this.motionOwner.reset();this.input.resetLocal();this.dragResidualX=0;this.dragResidualY=0;this.virtualFolder='';this.roundSelected='';}
  private releaseWindowInputs():void {this.virtualGateReady=false;this.resetLocal();const multi=session.multi;if(multi){multi.revoke(this.lease).then(()=>{if(this.pageVisible&&this.ready&&session.appForeground&&!session.watch&&!session.isClosing&&detached.lookup(this.lease)?.focused){detached.claim(this.lease);}}).catch(()=>{});}}
  private virtualKeysReady():boolean {const pane=detached.lookup(this.lease);return this.virtualKeysOn&&this.pageVisible&&this.viewWidth>this.viewHeight&&this.virtualLayout().complete&&this.ready&&!!pane?.focused&&this.canvasFocused&&session.appForeground&&!session.watch&&!session.isClosing&&!!session.multi?.isOwner(this.screenId,this.lease);}
  private syncVirtualGate():void {const ready=this.virtualKeysReady(),previous=this.virtualGateReady;this.virtualGateReady=ready;if(previous&&!ready){this.releaseWindowInputs();}if(ready){this.virtualRuntime.resume();}else{this.virtualRuntime.resetLocal();}}
  private virtualWheel(delta:number):boolean {try{return this.virtualKeysReady()&&this.dispatchOwned('overlay-wheel',[{action:'mouse_scroll',delta_x:0,delta_y:delta}]);}catch(_){try{this.releaseWindowInputs();}catch(__){}return false;}}
  private virtualDrag(id:number,dx:number,dy:number,end:boolean):boolean {try{const owner='overlay:'+id;if(end){this.motionOwner.release(owner);this.dragResidualX=0;this.dragResidualY=0;return true;}if(!this.virtualKeysReady()||!this.motionOwner.permits(owner)){return false;}if(!this.motionOwner.owns(owner)){if(!this.input.flush()){return false;}if(!this.motionOwner.acquire(owner)){return false;}}const camera=this.virtualPlan?.camera;this.dragResidualX+=dx*(camera?.enabled?camera.sensitivityX:1);this.dragResidualY+=dy*(camera?.enabled?camera.sensitivityY:1);const x=Math.trunc(this.dragResidualX),y=Math.trunc(this.dragResidualY);this.dragResidualX-=x;this.dragResidualY-=y;return x===0&&y===0?true:this.dispatchOwned(owner,[{action:'mouse_move_relative',delta_x:x,delta_y:y}]);}catch(_){try{this.releaseWindowInputs();}catch(__){}return false;}}
  private virtualLocal(kind:string,id:string):void {
    if(kind==='visibility'){this.releaseWindowInputs();this.virtualKeysHidden=!this.virtualKeysHidden;this.syncVirtualGate();}
    else if(kind==='folder_round_start'){this.roundSelected='';this.virtualFolder=id;this.syncVirtualGate();}
    else if(kind==='folder_list'){const prior=this.virtualFolder;this.releaseWindowInputs();this.virtualFolder=prior===id?'':id;this.syncVirtualGate();}
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
    this.releaseWindowInputs();if(this.virtualKeysOn){this.virtualKeysOn=false;this.virtualFolder='';return;}
    if(this.viewWidth<=this.viewHeight){this.getUIContext().getPromptAction().showToast({message:'请横屏使用虚拟按键'});return;}
    const scope=client.view.loggedIn?(client.view.wallpaperAccountKey||''):'offline';const current=():string=>client.view.loggedIn?(client.view.wallpaperAccountKey||''):'offline';const run=session.generation;if(!scope){this.getUIContext().getPromptAction().showToast({message:'登录资料尚未就绪'});return;}let plan:VirtualPlan|undefined=undefined;
    try{const context=this.getUIContext().getHostContext() as common.UIAbilityContext;const saved=await new VirtualPlanStore(context,scope,current).current();if(scope!==current()||run!==session.generation||!this.pageVisible){return;}if(saved.state==='invalid'){this.message='已选方案无法读取，请重新选择';return;}if(saved.state==='ready'&&saved.item){if(!saved.item.plan.canActivate){this.message='已选方案含待适配功能';return;}plan=saved.item.plan;virtualSelection.set(plan,saved.item.id);}else{const bytes=await context.resourceManager.getRawFileContent('virtual-key-default.json');const result=adaptUuPlan(util.TextDecoder.create('utf-8',{fatal:true}).decodeToString(bytes),'builtin');if(result.ok&&result.plan&&result.plan.canActivate){plan=result.plan;}}}catch(_){this.message='方案读取失败';return;}
    if(!plan||scope!==current()||run!==session.generation||!this.pageVisible){return;}if(plan.camera&&!this.camera.configure(plan.camera)){this.message='视角设置无效';return;}this.virtualPlan=plan;this.cameraMode=!!plan.camera?.enabled;this.virtualKeysOn=true;this.virtualKeysHidden=false;this.virtualFolder='';try{this.getUIContext().getFocusController().requestFocus('detachedCanvas');}catch(_){}this.syncVirtualGate();
  }
  private virtualVisibleControls():VirtualControl[]{
    const plan=this.virtualPlan;if(!plan){return [];}if(this.virtualKeysHidden){return plan.controls.filter((c:VirtualControl)=>c.kind==='visibility');}const roots=plan.controls.filter((c:VirtualControl)=>!c.ownerId&&(c.visible||c.kind==='visibility'));if(this.virtualFolder){const parent=roots.find((c:VirtualControl)=>c.id===this.virtualFolder);const children=plan.controls.filter((c:VirtualControl)=>c.ownerId===this.virtualFolder&&(c.visible||c.kind==='visibility')).sort((a:VirtualControl,b:VirtualControl)=>a.order-b.order);if(parent?.kind==='folder_list'){return [parent,...children];}return roots.concat(children);}return roots;
  }
  private baseVirtualSize(c:VirtualControl):number{return Math.max(40,Math.min(160,c.radius*2));}
  private baseVirtualPoint(c:VirtualControl):TouchPoint {
    let x=c.x*this.viewWidth,y=c.y*this.viewHeight;const plan=this.virtualPlan;
    if(c.ownerId&&plan){const parent=plan.controls.find((item:VirtualControl)=>item.id===c.ownerId);if(parent){const children=plan.controls.filter((item:VirtualControl)=>item.ownerId===parent.id).sort((a:VirtualControl,b:VirtualControl)=>a.order-b.order);const slot=children.findIndex((item:VirtualControl)=>item.id===c.id);if(parent.kind==='folder_round'){const angle=2*Math.PI*slot/Math.max(1,children.length)-Math.PI/2;const distance=Math.max(52,parent.radius);x=parent.x*this.viewWidth+Math.cos(angle)*distance;y=parent.y*this.viewHeight+Math.sin(angle)*distance;}else{const rows=Math.ceil(children.length/2),column=slot%2,row=Math.floor(slot/2),side=parent.x>0.5?-1:1;x=parent.x*this.viewWidth+side*(60+column*48);y=parent.y*this.viewHeight+(row-(rows-1)/2)*48;}}}
    const size=this.baseVirtualSize(c);return {id:0,x:Math.max(0,Math.min(this.viewWidth-size,x-size/2)),y:Math.max(0,Math.min(this.viewHeight-size,y-size/2))};
  }
  private virtualLayoutKey:string='';private virtualLayoutCache:VirtualLayout={complete:false,items:[]};
  private virtualLayout():VirtualLayout {
    const controls=this.virtualVisibleControls();const key=JSON.stringify([this.viewWidth,this.viewHeight,this.virtualFolder,this.virtualKeysHidden,controls]);
    if(key!==this.virtualLayoutKey){const digits=controls.filter((control:VirtualControl)=>!control.ownerId&&['1','2','3','4'].includes(control.label));const align=!!this.virtualPlan&&this.virtualPlan.source==='builtin'&&digits.length===4&&digits.every((control:VirtualControl)=>Math.abs(control.x-digits[0].x)<0.002&&Math.abs(control.radius-digits[0].radius)<0.1);const requests:VirtualPlacementRequest[]=controls.map((control:VirtualControl):VirtualPlacementRequest=>{const point=this.baseVirtualPoint(control);const size=this.baseVirtualSize(control);return {id:control.id,x:point.x+size/2,y:point.y+size/2,size:size,group:this.virtualFolder&&controls.some((item:VirtualControl)=>item.id===this.virtualFolder&&item.kind==='folder_list')?(control.id===this.virtualFolder?'folder-list-parent':control.ownerId===this.virtualFolder?'folder-list-child':''):(align&&digits.includes(control)?'builtin-digits':'')};});this.virtualLayoutCache=layoutVirtualControls(requests,this.viewWidth,this.viewHeight);this.virtualLayoutKey=key;}
    return this.virtualLayoutCache;
  }
  private virtualPlacement(c:VirtualControl):VirtualPlacement {return this.virtualLayout().items.find((item:VirtualPlacement)=>item.id===c.id)||{id:c.id,x:0,y:0,size:0};}
  private virtualSize(c:VirtualControl):number{return this.virtualPlacement(c).size;}
  private virtualPoint(c:VirtualControl):TouchPoint {const item=this.virtualPlacement(c);return {id:0,x:item.x,y:item.y};}


  aboutToAppear(): void {
    this.offVirtualAccount=client.monitor((view:AuthView)=>{const scope=view.loggedIn?(view.wallpaperAccountKey||'unavailable'):'offline';if(this.virtualAccount&&scope!==this.virtualAccount){this.releaseWindowInputs();this.virtualKeysOn=false;this.virtualPlan=undefined;}this.virtualAccount=scope;});
    this.offCoordinator = detached.observe(() => { this.gate(); });
    this.policy = detached.getPolicy(this.lease);
    this.policy?.applyRemote(true);
    if (this.policy) {
      this.offPolicy = this.policy.observe((snapshot) => { this.headerWidth = snapshot.width; });
    }
    const pane = detached.lookup(this.lease);
    if (!pane) { return; }
    this.screenId = pane.screenId;
    const multi = session.multi;
    if (multi) {
      this.off = multi.observe((state: MultiSnapshot) => {
        const index = state.screens.findIndex((item) => item.id === this.screenId);
        const row = index >= 0 ? state.screens[index] : undefined;
        this.screenLabel = index >= 0 ? '显示器 ' + (index + 1) + (row?.name ? ' · ' + row.name : '') : '显示器';
        const stream = state.streams.find((item) => item.screenId === this.screenId);
        this.ready = !!stream?.mappingConfirmed && !!stream?.videoFrameObserved;
        this.message = stream?.error || (!this.ready ? '等待此显示器的新画面' : '');
        if (stream && stream.width > 0 && stream.height > 0) {
          this.frameWidth = stream.width;
          this.frameHeight = stream.height;
        }
        if (this.ready) { detached.claim(this.lease); }
        this.gate();
      });
    }
    this.offSession = session.observe(() => {
      if (!session.busy && !session.isClosing) { detached.disconnected(); }this.gate();
    });
  }

  onPageShow(): void {
    this.pageVisible=true;this.gate();
    hilog.info(0x0303, 'UUTitle', 'stage=4 global=0 code=%{public}d inset=0', this.policy ? 1 : 0);
    this.policy?.beginScopedRemoteTitle((active: boolean, right: number) => {
      this.titleMerged = active;
      this.titleInset = right;
    });
  }

  onPageHide(): void { this.pageVisible=false;this.releaseWindowInputs();this.policy?.cancelTitleRetry(); this.policy?.endRemoteTitle(); }

  aboutToDisappear(): void {
    this.pageVisible=false;this.offVirtualAccount();this.releaseWindowInputs();
    this.offCoordinator();
    this.offPolicy();
    this.policy?.cancelTitleRetry();
    this.policy?.endRemoteTitle();
    this.policy?.applyRemote(false);
    this.off();
    this.offSession();
    this.input.resetLocal();
    detached.focus(this.lease, false);
  }

  private gate(): void {
    const pane = detached.lookup(this.lease);
    const gateLog = (pane?.focused ? '1' : '0') + (this.canvasFocused ? '1' : '0') + (this.ready ? '1' : '0') + (session.multi?.isOwner(this.screenId, this.lease) ? '1' : '0');
    if (gateLog !== this.lastGateLog) {
      this.lastGateLog = gateLog;
      hilog.info(0x0303, 'UUMultiInput', 'gate screen=%{public}d window=%{public}d canvas=%{public}d ready=%{public}d owner=%{public}d', this.screenId, pane?.focused ? 1 : 0, this.canvasFocused ? 1 : 0, this.ready ? 1 : 0, session.multi?.isOwner(this.screenId, this.lease) ? 1 : 0);
    }
    this.input.setGate(true, this.pageVisible && !!pane?.focused && this.canvasFocused,
      this.ready && session.busy && session.appForeground && !session.watch && !session.isClosing && !!session.multi?.isOwner(this.screenId, this.lease));
    this.syncVirtualGate();
  }
  private cameraTouch(event:TouchEvent,overlayChanged:number[]):boolean {
    const settings=this.virtualPlan?.camera;if(!settings?.enabled||!this.cameraMode||!this.virtualKeysReady()){return false;}
    if(event.type===TouchType.Down){for(const point of event.changedTouches){if(overlayChanged.includes(point.id)||this.virtualRuntime.owns(point.id)||this.cameraTouches.size>=16){continue;}this.cameraTouches.add(point.id);if(!this.virtualRuntime.beginExternal(point.id)){continue;}if(this.cameraContact>=0){continue;}const owner='camera:'+point.id;if(!this.motionOwner.permits(owner)){continue;}if(!this.motionOwner.owns(owner)){if(!this.input.flush()){continue;}if(!this.motionOwner.acquire(owner)){continue;}}if(this.camera.begin(point.id,point.x,point.y,this.viewWidth,this.viewHeight,this.camera.epoch())){this.cameraContact=point.id;}else{this.motionOwner.release(owner);}}return true;}
    if(event.type===TouchType.Move){if(this.cameraContact>=0){const point=event.touches.find((item:TouchObject)=>item.id===this.cameraContact);if(point){this.camera.move(point.id,point.x,point.y,this.camera.epoch());}}return this.cameraTouches.size>0;}
    if(event.type===TouchType.Up){let consumed=false;for(const point of event.changedTouches){if(!this.cameraTouches.has(point.id)){continue;}consumed=true;this.cameraTouches.delete(point.id);this.virtualRuntime.endExternal(point.id);if(point.id===this.cameraContact){this.camera.end(point.id);this.motionOwner.release('camera:'+point.id);this.cameraContact=-1;}}return consumed||this.cameraTouches.size>0;}
    if(event.type===TouchType.Cancel){this.releaseWindowInputs();return true;}return false;
  }
  private widthFit(): number {
    return Math.max(1, Math.min(this.viewWidth, this.viewHeight * this.frameWidth / this.frameHeight));
  }
  private heightFit(): number {
    return Math.max(1, Math.min(this.viewHeight, this.viewWidth * this.frameHeight / this.frameWidth));
  }
  private handleKey(event: KeyEvent): boolean {
    this.gate();
    if (event.keySource !== KeySource.Keyboard || (event.type !== KeyType.Down && event.type !== KeyType.Up)) { return false; }
    const handled = this.input.key(event.keyCode, event.type === KeyType.Down);
    if (handled) { event.stopPropagation(); }
    return handled;
  }
  private mouse(event: MouseEvent,fullCanvas:boolean=false): void {
    if (event.source !== SourceType.Mouse) { return; }
    if(event.action===MouseAction.Move&&!this.motionOwner.permits('hardware')){return;}
    event.stopPropagation();
    if (event.action === MouseAction.Press) {
      if(this.virtualKeysOn){this.motionOwner.acquire('hardware');}
      try { this.getUIContext().getFocusController().requestFocus('detachedCanvas'); } catch (_) {}
    }
    this.gate();
    const left=fullCanvas?(this.viewWidth-this.widthFit())/2:0,top=fullCanvas?(this.viewHeight-this.heightFit())/2:0;const x=(event.x-left)/this.widthFit(),y=(event.y-top)/this.heightFit();
    const button = event.button === MouseButton.Left ? 1 : event.button === MouseButton.Right ? 2 :
      event.button === MouseButton.Middle ? 4 : 0;
    this.input.mouse(event.action === MouseAction.Press ? 'down' : event.action === MouseAction.Release ? 'up' : 'move',
      button, x, y, x >= 0 && x <= 1 && y >= 0 && y <= 1);
    if(event.action===MouseAction.Release&&this.input.pressedCount()===0){this.motionOwner.release('hardware');}
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text(this.screenLabel)
          .fontColor(UiColor.text).fontSize(13).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: Math.max(50, Math.min(180, this.headerWidth - this.titleInset - 190)) })
          .gesture(PanGesture({ distance: 16 }).onActionEnd((event: GestureEvent) => {
            const finger = event.fingerList?.[0];
            if (finger && Math.abs(event.offsetX) + Math.abs(event.offsetY) >= 24 &&
              windowPolicy.containsDisplayPoint(finger.displayX, finger.displayY, true)) {
              detached.close(this.lease, true).catch(() => { this.message = '合并失败，请重试'; });
            }
          }));
        Blank().layoutWeight(1).height(48)
          .onTouch((event: TouchEvent) => {
            if (this.titleMerged && event.type === TouchType.Down) {
              event.stopPropagation();
              this.policy?.moveRemoteWindow();
            }
          })
          .gesture(TapGesture({ count: 2 }).onAction(() => {
            if (this.titleMerged) { this.policy?.toggleRemoteWindowSize(); }
          }));
        Row({space:3}){ForEach([0,1,2],(id:number)=>{if(detached.hasScreen(id)){Button('屏'+(id+1),{type:ButtonType.Normal}).fontColor(UiColor.text).backgroundColor(UiColor.primarySoft).fontColor(UiColor.primary).id('focusDetachedScreen'+id).fontSize(12).height(36).borderRadius(12).onClick(()=>{detached.showScreen(id);})}})} 
        Button(this.virtualKeysOn?'关闭按键':'虚拟按键').id('detachedVirtualToggle').onClick(()=>this.toggleVirtualKeys())
        if(this.virtualKeysOn&&this.virtualPlan?.camera?.enabled){Button(this.cameraMode?'指针':'视角').id('detachedCameraToggle').onClick(()=>{this.releaseWindowInputs();this.cameraMode=!this.cameraMode;this.syncVirtualGate();})}
        Button('关闭此屏幕',{type:ButtonType.Normal}).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).id('closeDetachedScreen'+this.screenId).borderRadius(12).height(40).fontSize(12).onClick(()=>{detached.close(this.lease).catch(()=>{this.message='关闭失败，请重试';});})
        Button(this.headerWidth < 460 ? '合并' : '合并回主窗口',{type:ButtonType.Normal}).borderRadius(12).fontColor(UiColor.primary).backgroundColor(UiColor.primarySoft)
          .id('mergeDetachedScreen').fontSize(12).height(40).padding({ left: 8, right: 8 })
          .onClick(() => {
            detached.close(this.lease, true).catch(() => { this.message = '合并失败，请重试'; });
          });
        Button(this.headerWidth < 460 ? '断开' : '断开全部',{type:ButtonType.Normal}).borderRadius(12).fontColor(UiColor.error).backgroundColor(UiColor.errorSoft)
          .id('disconnectAllWindows').fontSize(12).height(40).padding({ left: 8, right: 8 })
          .onClick(() => { session.disconnectAllWindows(); });
      }.height(48).padding({ left: 12, right: this.titleMerged ? this.titleInset : 12 })
        .width('100%').backgroundColor(UiColor.surface)

      Stack() {
        XComponent({ id: 'detachedDesktop', type: XComponentType.SURFACE, controller: this.controller })
          .width(this.widthFit()).height(this.heightFit())
          .onLoad(() => {
            this.surface = this.controller.getXComponentSurfaceId();
            const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
            detached.attach(this.lease, this.surface, () => { context.terminateSelf(); }).then((ok: boolean) => {
              if (!ok) {
                this.message = '无法打开此显示器';
                context.terminateSelf();
              }
            });
          })
          .onDestroy(() => { detached.close(this.lease).catch(() => {}); })
        Text('').width(this.widthFit()).height(this.heightFit()).backgroundColor('#00000000')
          .id('detachedCanvas').focusable(true).focusOnTouch(true).defaultFocus(true)
          .onFocus(() => {
            this.canvasFocused = true;
            detached.focus(this.lease, true);
            this.gate();
          })
          .onBlur(() => {
            this.canvasFocused = false;
            this.resetLocal();
            detached.focus(this.lease, false);
          })
          .onTouch((event:TouchEvent)=>{const live:number[]=[];for(const t of event.touches){if(!(event.type===TouchType.Up&&event.changedTouches.some((changed:TouchObject)=>changed.id===t.id))){live.push(t.id);}}this.virtualRuntime.observeContacts(live);})
          .onKeyPreIme((event: KeyEvent) => this.handleKey(event))
          .onMouse((event: MouseEvent) => this.mouse(event))
          .onAxisEvent((event: AxisEvent) => {
            if (event.source === SourceType.Mouse) {
              this.gate();
              this.input.wheel(-event.getHorizontalAxisValue(), -event.getVerticalAxisValue());
            }
          })
        if(this.virtualKeysReady()&&this.virtualPlan?.camera?.enabled&&this.cameraMode){
          Text('').width('100%').height('100%').backgroundColor('#00000000').id('detachedCameraSurface').accessibilityText('三维视角控制区域')
            .onTouch((event:TouchEvent)=>{const changed:number[]=event.changedTouches.filter((t:TouchObject)=>this.virtualRuntime.owns(t.id)).map((t:TouchObject)=>t.id);const live:number[]=[];for(const t of event.touches){if(!(event.type===TouchType.Up&&event.changedTouches.some((p:TouchObject)=>p.id===t.id))){live.push(t.id);}}this.virtualRuntime.observeContacts(live);if(this.cameraTouch(event,changed)){event.stopPropagation();}})
            .onMouse((event:MouseEvent)=>this.mouse(event,true)).onAxisEvent((event:AxisEvent)=>{if(event.source===SourceType.Mouse){this.gate();this.input.wheel(-event.getHorizontalAxisValue(),-event.getVerticalAxisValue());}})
        }
        if(this.virtualKeysReady()&&this.virtualPlan){ForEach(this.virtualVisibleControls(),(control:VirtualControl)=>{VirtualKeyControl({control:control,runtime:this.virtualRuntime,controlSize:this.virtualSize(control),highlight:control.id===this.roundSelected}).position({left:this.virtualPoint(control).x,top:this.virtualPoint(control).y})},(control:VirtualControl)=>control.id)}
        if(this.virtualKeysOn&&this.viewWidth>this.viewHeight&&this.virtualPlan&&!this.virtualLayout().complete){Text('窗口太小，无法安全显示虚拟按键').fontColor(Color.White).padding(8).backgroundColor('#AA222222').hitTestBehavior(HitTestMode.None)}
        if (!this.ready) { Text(this.message).fontColor(UiColor.text).fontSize(16).padding(12).backgroundColor(UiColor.surface).borderRadius(12) }
      }.layoutWeight(1).width('100%').backgroundColor('#03070D')
        .onTouch((event:TouchEvent)=>{const live:number[]=[];for(const t of event.touches){if(!(event.type===TouchType.Up&&event.changedTouches.some((changed:TouchObject)=>changed.id===t.id))){live.push(t.id);}}this.virtualRuntime.observeContacts(live);})
        .onAreaChange((_old: Area, area: Area) => {
          const width=Number(area.width),height=Number(area.height);if(width!==this.viewWidth||height!==this.viewHeight){this.releaseWindowInputs();this.viewWidth=width;this.viewHeight=height;this.syncVirtualGate();}
        })
    }.width('100%').height('100%').backgroundColor('#03070D')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]);
  }
}
