import { UiColor } from './UiFoundation';
import { RemoteSystemAction } from './RemoteSystemAction';
import { preferences } from '@kit.ArkData';
import { APP_STORE, PinnedApp, readPinnedApps } from './AppCatalog';
import { TouchMode } from './MobileTouch';
import { PrivacyChoice,privacyWallpaperApi } from './PrivacyWallpapers';

// Presentation only. The parent owns preferences, input gates and the live Surface.
@Component
export struct RemoteOperationsPanel {
  @Prop desktopControls:boolean=false;
  @State private showTouchOptions:boolean=false;
  onOrientation:(value:number)=>void=()=>{};
  @Prop @Watch('securityChanged') securityReady:boolean=false;
  @Prop autoLockSupported:boolean=false;
  @Prop autoLockText:string='电脑状态未知';
  @Prop secureStateText:string='电脑锁定状态未知';
  @Prop unlockHint:string='尚未收到电脑的解锁能力';
  @Prop unlockAvailable:boolean=false;
  @Prop unlockEnrolled:boolean=false;
  @Prop unlockReenrollmentRequired:boolean=false;
  @Prop unlockEnabled:boolean=false;
  @Prop unlockBusy:boolean=false;
  @Prop unlockTogglePending:boolean=false;
  @Prop unlockToggleFailure:string='';
  @State private unlockEditing:boolean=false;
  @State private unlockPassword:string='';
  onUnlock:(action:string,password:string)=>void=()=>{};
  aboutToDisappear():void{this.unlockPassword='';this.unlockEditing=false;this.privacyRevision++;}
  private securityChanged():void{if(!this.securityReady){this.unlockPassword='';this.unlockEditing=false;}}

  @Prop actualVideo:string='实际收到尺寸未知 · 渲染帧率未知';
  @Prop privacySupport:number=0;
  @Prop privacyOwned:boolean=false;
  @Prop privacyCurrent:number=0;
  @Prop privacyText:string='远端状态未知';
  @State private privacyChoices:PrivacyChoice[]=[];
  @State private privacyLoading:boolean=false;
  @State private privacyWallpaperHint:string='';
  onPrivacy:(mode:number)=>void=()=>{};
  @Prop thumbnailPending:boolean=false;
  @Prop thumbnailHint:string='';
  onThumbnail:()=>void=()=>{};
  onTerminal:()=>void=()=>{};
  @Prop systemActionPending:boolean=false;
  @Prop systemActionText:string='需要当前授权会话';
  onSystemAction:(kind:RemoteSystemAction)=>void=()=>{};
  @Prop desktopName:string='远程桌面';
  @Prop deviceKey:string='';
  @State private pinned:PinnedApp[]=[];
  @State private pinnedHint:string='';
  onPinned:(id:string)=>void=()=>{};
  @Prop mode:TouchMode=TouchMode.Direct;
  @Prop touchSupport:number=0;
  @Prop mouseSize:number=1; @Prop mouseOpacity:number=0.8;
  onMouseAppearance:(size:number,opacity:number,commit:boolean)=>void=()=>{};
  @Prop speed:number=1;
  @Prop externalKeyboard:boolean=false;
  @Prop gamepadEnabled:boolean=false;
  onGamepad:()=>void=()=>{};
  @Prop micActive:boolean=false;
  @Prop micText:string='麦克风未开启';
  onMicrophone:()=>void=()=>{};
  @Prop viewOnly:boolean=false;
  @Prop watch:boolean=false;
  @Prop ready:boolean=false;
  @Prop statusText:string='正在连接';
  @Prop statusTone:string='paused';
  @Prop preferenceHint:string='';
  @Prop compact:boolean=false;
  onMode:(mode:TouchMode)=>void=()=>{};
  onSpeed:(value:number,commit:boolean)=>void=()=>{};
  onExternalKeyboard:()=>void=()=>{};
  onViewport:()=>void=()=>{};
  onResetView:()=>void=()=>{};
  onWatch:()=>void=()=>{};
  onKeyboard:()=>void=()=>{};
  onVirtualKeys:()=>void=()=>{};
  onVirtualManage:()=>void=()=>{};
  onVirtualEdit:()=>void=()=>{};
  @Prop virtualPlanName:string='官方默认';
  @Prop cameraAvailable:boolean=false;@Prop cameraActive:boolean=false;
  onCameraMode:()=>void=()=>{};
  @Prop virtualKeysOn:boolean=false;
  @Prop orientationChoice:number=0;
  onQuality:()=>void=()=>{};
  onMonitors:()=>void=()=>{};
  onSound:()=>void=()=>{};
  onClipboard:()=>void=()=>{};
  onFiles:()=>void=()=>{};
  onRelease:()=>void=()=>{};
  onClose:()=>void=()=>{};
  onDisconnect:()=>void=()=>{};
  private contentScroller:Scroller=new Scroller();

  @Prop actualCodec:number=0;
  @Prop codecPreference:number=0;
  onCodecPreference:(value:number)=>void=()=>{};
  @Prop multiMode:boolean=false;
  @Prop singleModeAvailable:boolean=false;
  @Prop multiModeAvailable:boolean=false;
  onSingleMode:()=>void=()=>{};
  onMultiMode:()=>void=()=>{};
  @Prop initialPage:string='ops';
  @Prop quality:number=5;
  @Prop fps:number=0;
  @Prop fpsStatus:string='';
  @Prop maxFps:number=30;
  onQualityChoice:(value:number,label:string)=>void=()=>{};
  onFpsChoice:(value:number)=>void=()=>{};
  @Prop locked:boolean=false;
  @Prop hostMuted:boolean=false;
  @Prop network:string='等待采样';
  @Prop connectionMethod:string='未知';
  @Prop transportProtocol:string='未知';
  onLock:()=>void=()=>{};
  onMute:()=>void=()=>{};
  onDesktop:()=>void=()=>{};
  onWindows:()=>void=()=>{};
  @Link route:string;
  private trail:string[]=[];
  private privacyRevision:number=0;
  private async loadPrivacyWallpapers():Promise<void>{
    if(this.privacyLoading){return;}const revision=++this.privacyRevision;this.privacyLoading=true;
    try{const reply=await privacyWallpaperApi('list');if(revision===this.privacyRevision&&this.route==='privacy'){this.privacyChoices=reply.choices;this.privacyWallpaperHint=reply.message;}}
    finally{if(revision===this.privacyRevision){this.privacyLoading=false;}}
  }
  private openPrivacy():void{this.open('privacy');this.privacyChoices=[];this.privacyWallpaperHint='正在读取电脑的隐私壁纸…';this.loadPrivacyWallpapers();}
  private async usePrivacyWallpaper(choice:PrivacyChoice):Promise<void>{
    if(this.privacyLoading||!this.securityReady){return;}const revision=++this.privacyRevision;this.privacyLoading=true;
    try{const reply=await privacyWallpaperApi('select',choice);if(revision===this.privacyRevision&&this.route==='privacy'){this.privacyWallpaperHint=reply.message;if(reply.message==='壁纸设置已保存，正在通知电脑更新'){this.privacyChoices=this.privacyChoices.map((item:PrivacyChoice):PrivacyChoice=>({key:item.key,type:item.type,presetId:item.presetId,title:item.title,url:item.url,selected:item.key===choice.key}));this.onPrivacy(2);}}}
    finally{if(revision===this.privacyRevision){this.privacyLoading=false;}}
  }
  aboutToAppear():void {this.route=this.initialPage;}
  private open(page:string):void {this.unlockPassword='';this.unlockEditing=false;this.trail.push(this.route);this.route=page;this.contentScroller.scrollTo({xOffset:0,yOffset:0});}
  private back():void {this.unlockPassword='';this.unlockEditing=false;this.route=this.trail.pop()||'ops';}
  private openApps():void {
    this.pinned=[];this.pinnedHint='可在设备详情的「快速启动」中添加这台电脑的应用。';
    try{
      const store=preferences.getPreferencesSync(this.getUIContext().getHostContext()!,{name:APP_STORE});
      this.pinned=readPinnedApps(store,this.deviceKey);
    }catch(_){this.pinnedHint='快捷方式读取失败，请返回后重试。';}
    this.open('apps');
  }
  private title():string {return this.route==='privacy'?'防窥模式与壁纸':this.route==='display'?'显示':this.route==='security'?'安全':this.route==='external'?'外设':this.route==='more'?'更多工具':this.route==='shortcuts'?'系统快捷操作':this.route==='power'?'设备控制':this.route==='hardware'?'外接键盘':this.route==='mouse'?'鼠标':this.route==='net'?'网络状态':'操作';}
  private wallpaperTitle(key:string,fallback:string):string{const item=this.privacyChoices.find((entry:PrivacyChoice)=>'privacyWallpaper_'+entry.key===key);return item?(item.selected?'已选 · ':'')+item.title:fallback;}
  @Builder
  section(title:string){Text(title).fontSize(13).fontColor(UiColor.secondary).width('100%').margin({top:10,bottom:3})}
  @Builder
  action(title:string,description:string,key:string,available:boolean,callback:()=>void){
    Button({type:ButtonType.Normal}){
      Row({space:10}){Column({space:4}){Text(key.startsWith('privacyWallpaper_')?this.wallpaperTitle(key,title):key==='windowsUnlockEnroll'?(this.unlockReenrollmentRequired?'为当前电脑重新设置密码':this.unlockEnrolled?'更新 Windows 账户密码':'设置 Windows 账户密码'):key==='viewportToggle'?(this.viewOnly?'结束本地缩放':'本地缩放'):key==='windowsUnlockToggle'?(this.unlockTogglePending?'正在更新…':this.unlockEnabled?'关闭自动解锁':'开启自动解锁'):key==='externalKeyboardToggle'?(this.externalKeyboard?'关闭外接键盘直控':'开启外接键盘直控'):key==='microphoneToggle'?(this.micActive?'关闭麦克风回传':'开启麦克风回传'):key==='virtualCameraToggle'?(this.cameraActive?'切换到指针操作':'切换到视角控制'):title).fontSize(15).fontColor(UiColor.text).width('100%');if(key==='windowsUnlockToggle'||key==='autoLockToggle'||key==='hostMuteToggle'||key==='panelWatchToggle'||key==='openHardware'||key==='gamepadToggle'||key==='microphoneToggle'||key==='securityPrivacy'||key==='openPrivacy'||key==='saveDesktopThumbnail'||key==='privacyWallpaperRefresh'||description.length>0){Text(key==='windowsUnlockToggle'?(this.unlockTogglePending?'正在保存设置':this.unlockToggleFailure?(this.unlockToggleFailure==='enable'?'开启':'关闭')+'未完成，当前为'+(this.unlockEnabled?'开启':'关闭'):this.unlockEnabled?'已开启':'已关闭'):key==='autoLockToggle'?this.autoLockText:key==='hostMuteToggle'?(this.hostMuted?'本地选择：开启':'本地选择：关闭'):key==='panelWatchToggle'?(this.watch?'已开启，暂停远程输入':'已关闭'):key==='openHardware'?(this.externalKeyboard?'直控已开启':'直控已关闭'):key==='gamepadToggle'?(this.gamepadEnabled?'直控已开启':'直控已关闭'):key==='microphoneToggle'?this.micText:key==='securityPrivacy'?this.privacyText:key==='saveDesktopThumbnail'?this.thumbnailHint:key==='privacyWallpaperRefresh'?(this.privacyLoading?'正在读取…':'读取 UU 保存的预设和自定义壁纸'):key==='openPrivacy'?(this.privacyCurrent===1?'已关闭':this.privacyCurrent===2?'隐私壁纸':this.privacyCurrent===3?'关闭物理屏幕':'等待电脑状态'):description).fontSize(12).fontColor(UiColor.secondary).width('100%')}}.layoutWeight(1);if((key==='orientationSystem'&&this.orientationChoice===0)||(key==='orientationPortrait'&&this.orientationChoice===1)||(key==='orientationLandscape'&&this.orientationChoice===2)||(key==='orientationReversePortrait'&&this.orientationChoice===3)||(key==='orientationReverseLandscape'&&this.orientationChoice===4)){Text('✓').fontSize(15).fontColor(UiColor.primary)}else{SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([UiColor.secondary])}}.width('100%')
    }.id(key).width('100%').height('auto').constraintSize({minHeight:50}).padding(12).borderRadius(12).backgroundColor(UiColor.neutralSoft).enabled(key.startsWith('privacyWallpaper_')?this.securityReady&&!this.privacyLoading&&this.privacySupport>0:key==='privacyWallpaperRefresh'?this.securityReady&&!this.privacyLoading:key==='saveDesktopThumbnail'?this.ready&&!this.thumbnailPending:key==='windowsUnlockEnroll'?this.securityReady&&this.unlockAvailable&&!this.unlockBusy:key==='windowsUnlockDelete'||key==='windowsUnlockToggle'?this.securityReady&&!this.unlockBusy:key==='autoLockToggle'?this.securityReady&&this.autoLockSupported:key==='hostMuteToggle'||key==='panelWatchToggle'?this.ready:key==='gamepadToggle'?this.ready&&!this.watch&&!this.viewOnly:key==='microphoneToggle'?this.micActive||(this.ready&&!this.watch):key==='openMonitors'||key==='viewportToggle'||key==='openFiles'||key==='openClipboard'||key==='openSound'?this.ready:key==='openQuality'?this.ready&&!this.multiMode:key==='lockNow'||key==='rebootNow'||key==='shutdownNow'?this.securityReady&&!this.systemActionPending:key==='openTerminal'?this.ready:key==='shortcutDesktop'||key==='shortcutWindows'?this.ready&&!this.watch&&!this.viewOnly:available).onClick(callback)
  }
  @Builder
  privacyChoice(title:string,description:string,key:string,mode:number,available:boolean){
    Button({type:ButtonType.Normal}){
      Row({space:10}){
        Column({space:4}){Text(title).fontSize(15).fontColor(this.privacyCurrent===mode?UiColor.primary:UiColor.text).width('100%');Text(description).fontSize(12).fontColor(UiColor.secondary).width('100%')}.layoutWeight(1)
        Text(this.privacyCurrent===mode?'✓':'').fontSize(20).fontColor(UiColor.primary).width(24)
      }.width('100%')
    }.id(key).width('100%').height('auto').constraintSize({minHeight:50}).padding(12).borderRadius(12)
      .backgroundColor(!available?UiColor.neutralSoft:this.privacyCurrent===mode?UiColor.primarySoft:UiColor.neutralSoft).border({width:this.privacyCurrent===mode?1:0,color:UiColor.primary})
      .accessibilityText(title+(this.privacyCurrent===mode?'，已选择':''))
      .enabled(this.securityReady&&!this.systemActionPending&&(mode===1?(this.privacySupport>0||this.privacyOwned):mode===2?this.privacySupport>0:this.privacySupport===2)).onClick(()=>this.onPrivacy(mode))
  }
  @Builder
  unavailable(title:string,hint:string){
    Row(){Text(title).fontSize(14).fontColor(UiColor.secondary).layoutWeight(1);Text(hint).fontSize(11).fontColor(UiColor.secondary)}.width('100%').padding(13).borderRadius(12).backgroundColor(UiColor.neutralSoft).accessibilityText(title+'，'+hint)
  }
  @Builder
  virtualTile(icon:string,label:string,key:string,enabled:boolean,selected:boolean,callback:()=>void){
    Button({type:ButtonType.Normal}){Row({space:6}){Text(icon).fontSize(18).fontColor((key==='virtualKeysToggle'?this.virtualKeysOn:selected)?UiColor.primary:UiColor.text);Text(label).fontSize(12).maxLines(1).fontColor((key==='virtualKeysToggle'?this.virtualKeysOn:selected)?UiColor.primary:UiColor.text)}}.id(key).layoutWeight(1).height(44).padding({left:4,right:4}).borderRadius(12).backgroundColor((key==='virtualKeysToggle'?this.virtualKeysOn:selected)?UiColor.primarySoft:UiColor.neutralSoft).enabled(key==='virtualKeysToggle'||key==='openSoftKeyboard'?this.ready&&!this.watch&&!this.viewOnly:enabled).onClick(callback)
  }
  @Builder
  home(){
    Row({space:6}){Button('断开',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).layoutWeight(1).height(48).fontSize(12).backgroundColor(UiColor.errorSoft).fontColor(UiColor.error).onClick(this.onDisconnect);Button('缩放',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).layoutWeight(1).height(48).fontSize(12).backgroundColor(UiColor.neutralSoft).fontColor(UiColor.text).enabled(this.ready).onClick(this.onViewport);Button('声音',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).layoutWeight(1).height(48).fontSize(12).backgroundColor(UiColor.neutralSoft).fontColor(UiColor.text).enabled(this.ready).onClick(this.onSound);Button(this.watch?'恢复操作':'仅观看',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).layoutWeight(1).height(48).fontSize(12).backgroundColor(UiColor.neutralSoft).fontColor(UiColor.text).enabled(this.ready).onClick(this.onWatch)}.width('100%')
    if(this.desktopControls){
      this.action('文件传输','打开双栏窗口','openFiles',this.ready,this.onFiles)
      this.action('显示','画质与显示器','openDisplay',true,()=>this.open('display'))
      this.action('键鼠与外设','','openExternal',true,()=>this.open('external'))
      this.action('触控与虚拟按键',this.showTouchOptions?'收起':'展开','touchOptions',true,()=>{this.showTouchOptions=!this.showTouchOptions;})
    }
    if(!this.desktopControls||this.showTouchOptions){
    Text('键盘与按键 · '+this.virtualPlanName).id('virtualCurrentPlan').fontSize(12).fontColor(UiColor.secondary).maxLines(1).width('100%').margin({top:6,bottom:2})
    Row({space:8}){
      this.virtualTile('⌨','屏幕键盘','openSoftKeyboard',this.ready&&!this.watch&&!this.viewOnly,false,this.onKeyboard)
      this.virtualTile('✥','虚拟按键','virtualKeysToggle',this.ready&&!this.watch&&!this.viewOnly,this.virtualKeysOn,this.onVirtualKeys)
    }.width('100%')
    Row({space:8}){
      this.virtualTile('⇄','切换方案','virtualKeysManage',true,false,this.onVirtualManage)
      this.virtualTile('✎','编辑方案','virtualKeysEdit',true,false,this.onVirtualEdit)
    }.width('100%')
    if(this.virtualKeysOn&&this.cameraAvailable){this.action(this.cameraActive?'切换到指针操作':'切换到视角控制','手动切换，不自动判断游戏锁鼠状态','virtualCameraToggle',this.ready&&!this.watch&&!this.viewOnly,this.onCameraMode)}
    this.section('操作方式')
    Row({space:8}){
      Button('屏幕触控'+(this.mode===TouchMode.Direct?' ✓':''),{type:ButtonType.Normal}).fontColor(UiColor.text).id('touchModeDirect').layoutWeight(1).fontColor(this.mode===TouchMode.Direct?UiColor.text:UiColor.secondary).borderRadius(12).backgroundColor(this.mode===TouchMode.Direct?UiColor.primarySoft:UiColor.neutralSoft).onClick(()=>this.onMode(TouchMode.Direct))
      Button('触控板'+(this.mode===TouchMode.Trackpad?' ✓':''),{type:ButtonType.Normal}).fontColor(UiColor.text).id('touchModeTrackpad').layoutWeight(1).fontColor(this.mode===TouchMode.Trackpad?UiColor.text:UiColor.secondary).borderRadius(12).backgroundColor(this.mode===TouchMode.Trackpad?UiColor.primarySoft:UiColor.neutralSoft).onClick(()=>this.onMode(TouchMode.Trackpad))
    }.width('100%')
    Button('虚拟鼠标'+(this.mode===TouchMode.VirtualMouse?' ✓':''),{type:ButtonType.Normal}).fontColor(UiColor.text).id('touchModeVirtualMouse').width('100%').fontColor(this.mode===TouchMode.VirtualMouse?UiColor.text:UiColor.secondary).borderRadius(12).backgroundColor(this.mode===TouchMode.VirtualMouse?UiColor.primarySoft:UiColor.neutralSoft).onClick(()=>this.onMode(TouchMode.VirtualMouse))
    if(this.mode===TouchMode.VirtualMouse){
      Text('鼠标大小 '+this.mouseSize.toFixed(1)+' ×').fontSize(12).fontColor(UiColor.secondary).width('100%')
      Slider({value:this.mouseSize,min:0.8,max:1.4,step:0.1}).onChange((v:number,m:SliderChangeMode)=>this.onMouseAppearance(v,this.mouseOpacity,m===SliderChangeMode.End||m===SliderChangeMode.Click))
      Text('鼠标透明度 '+Math.round(this.mouseOpacity*100)+'%').fontSize(12).fontColor(UiColor.secondary).width('100%')
      Slider({value:this.mouseOpacity,min:0.4,max:1,step:0.1}).onChange((v:number,m:SliderChangeMode)=>this.onMouseAppearance(this.mouseSize,v,m===SliderChangeMode.End||m===SliderChangeMode.Click))
    }
    Button('平板触控'+(this.mode===TouchMode.Tablet?' ✓':''),{type:ButtonType.Normal}).fontColor(UiColor.text).id('touchModeTablet').width('100%').enabled(this.touchSupport===2&&!this.multiMode).fontColor(UiColor.text).borderRadius(12).backgroundColor(this.mode===TouchMode.Tablet?UiColor.primarySoft:UiColor.neutralSoft).onClick(()=>this.onMode(TouchMode.Tablet))
    Text(this.touchSupport===0?'平板触控：正在确认远端能力。':this.touchSupport===1?'远端系统不支持平板触控，请选择其他方式。':this.touchSupport===3?'未收到远端能力信息，请使用其他操作方式。':'平板触控：手势交由远端应用处理，本地缩放请使用画面缩放。').fontSize(12).fontColor(UiColor.secondary).width('100%')
    if(this.mode===TouchMode.Tablet){Text('使用外接鼠标前请切回屏幕触控。').fontSize(12).fontColor(UiColor.secondary).width('100%')}
    if(this.mode===TouchMode.Trackpad||this.mode===TouchMode.VirtualMouse){Text('指针速度 '+this.speed.toFixed(1)+' ×').fontSize(13).fontColor(UiColor.text).width('100%');Slider({value:this.speed,min:0.3,max:3,step:0.1}).id('pointerSpeed').selectedColor(UiColor.primary).trackColor(UiColor.neutralSoft).blockColor(UiColor.text).onChange((value:number,mode:SliderChangeMode)=>this.onSpeed(value,mode===SliderChangeMode.End||mode===SliderChangeMode.Click))}
    }
    if(!this.desktopControls){this.action('显示','画质与显示器','openDisplay',true,()=>this.open('display'))}
    this.action('安全','','openSecurity',true,()=>this.open('security'))
    this.action('防窥模式',this.privacyCurrent===1?'已关闭':this.privacyCurrent===2?'隐私壁纸':this.privacyCurrent===3?'关闭物理屏幕':'等待电脑状态','openPrivacy',true,()=>this.openPrivacy())
    if(!this.desktopControls){this.action('外设','','openExternal',true,()=>this.open('external'))}
    this.action('更多工具','','openMore',true,()=>this.open('more'))
    this.section('快捷操作')
    this.action('系统快捷操作','','openShortcuts',true,()=>this.open('shortcuts'))
    Text(this.preferenceHint).fontSize(11).fontColor(UiColor.secondary).width('100%')
  }
  @Builder
  qualityChoice(label:string,value:number,bitrate:string){
    Button({type:ButtonType.Normal}){Column({space:3}){Text(label+(this.quality===value?' ✓':'')).fontSize(13).fontColor(UiColor.text);if(bitrate.length>0){Text(bitrate).fontSize(9).fontColor(UiColor.secondary)}}}.id('qualityChoice'+value).layoutWeight(1).height(52).borderRadius(12).backgroundColor(this.quality===value?UiColor.primarySoft:UiColor.neutralSoft).enabled(this.ready&&!this.multiMode).onClick(()=>this.onQualityChoice(value,label))
  }
  @Builder
  contents(){
    if(this.route==='ops'){this.home()}
    if(this.route==='display'){
      this.section('帧率与画面')
      Text('视频编码（下次连接生效） · 当前：'+(this.actualCodec===2?'H.265':this.actualCodec===1?'H.264':'尚未确定')).fontSize(12).fontColor(UiColor.secondary).width('100%')
      Row({space:8}){Button('H.265 优先'+(this.codecPreference===0?' ✓':''),{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).id('codecAuto').layoutWeight(1).height(40).backgroundColor(this.codecPreference===0?UiColor.primarySoft:UiColor.neutralSoft).onClick(()=>this.onCodecPreference(0));Button('H.264'+(this.codecPreference===1?' ✓':''),{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).id('codecH264').layoutWeight(1).height(40).backgroundColor(this.codecPreference===1?UiColor.primarySoft:UiColor.neutralSoft).onClick(()=>this.onCodecPreference(1))}.width('100%')
      if(this.desktopControls){
        Text(this.multiMode?'独立窗口模式 · 可把显示器拖出为独立窗口。码率、帧率和传输尺寸在单窗口模式调整。':
          '单窗口模式 · 在同一窗口切换显示器，可调整码率、帧率和传输尺寸。')
          .fontSize(12).fontColor(UiColor.secondary).width('100%')
        if(this.singleModeAvailable){
          Button('重连到单窗口模式',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12)
            .backgroundColor(UiColor.neutralSoft).id('switchSingleWindowMode').width('100%').onClick(()=>this.onSingleMode())
        }
        if(this.multiModeAvailable){
          Button('重连到独立窗口模式',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12)
            .backgroundColor(UiColor.neutralSoft).id('switchMultiWindowMode').width('100%').onClick(()=>this.onMultiMode())
        }
      }
      Text(this.actualVideo).id('actualVideoSummary').fontSize(12).fontColor(UiColor.secondary).width('100%')
      Row({space:8}){
        Button('30 帧'+(this.fps===30?' ✓':''),{type:ButtonType.Normal}).fontColor(UiColor.text).id('fps30').layoutWeight(1).height(48).fontColor(UiColor.text).borderRadius(12).backgroundColor(this.fps===30?UiColor.primarySoft:UiColor.neutralSoft).enabled(this.ready&&!this.multiMode&&this.maxFps>=30).onClick(()=>this.onFpsChoice(30))
        Button('60 帧'+(this.fps===60?' ✓':''),{type:ButtonType.Normal}).fontColor(UiColor.text).id('fps60').layoutWeight(1).height(48).fontColor(UiColor.text).borderRadius(12).backgroundColor(this.fps===60?UiColor.primarySoft:UiColor.neutralSoft).enabled(this.ready&&!this.multiMode&&this.maxFps>=60).onClick(()=>this.onFpsChoice(60))
      }.width('100%')
      Row({space:5}){
        this.qualityChoice('自动',5,'')
        this.qualityChoice('高清',2,'2 Mbps')
        this.qualityChoice('超清',3,'8 Mbps')
        this.qualityChoice('高码率',4,'20 Mbps')
      }.width('100%')
      if(!this.multiMode){Text(this.fpsStatus).fontSize(12).fontColor(UiColor.secondary).width('100%')}
      this.action('传输尺寸与请求状态','等比缩放及实际画面','openQuality',this.ready&&!this.multiMode,this.onQuality)
      this.section('本机屏幕方向')
      this.action('跟随系统旋转锁定','进入时先横屏，随后遵守鸿蒙自动旋转开关','orientationSystem',true,()=>this.onOrientation(0))
      this.action('竖屏','','orientationPortrait',true,()=>this.onOrientation(1))
      this.action('横屏','','orientationLandscape',true,()=>this.onOrientation(2))
      this.action('反向竖屏','','orientationReversePortrait',true,()=>this.onOrientation(3))
      this.action('反向横屏','','orientationReverseLandscape',true,()=>this.onOrientation(4))
      this.section('多显示器管理')
      this.action('多显示器','','openMonitors',this.ready,this.onMonitors)
      this.action(this.viewOnly?'结束本地缩放':'本地缩放','只调整此窗口中的画面','viewportToggle',this.ready,this.onViewport)
      this.action('画面复位','','resetViewport',true,this.onResetView)
      this.action('网络状态','','openNetwork',true,()=>this.open('net'))
    }
    if(this.route==='security'){
      this.section('被控电脑')
      Text(this.secureStateText).fontSize(12).fontColor(UiColor.secondary).width('100%')
      this.action('远程结束后锁屏',this.autoLockText,'autoLockToggle',this.securityReady&&this.autoLockSupported,this.onLock)
      this.action('被控端静音',this.hostMuted?'本地选择：开启':'本地选择：关闭','hostMuteToggle',this.ready,this.onMute)
      this.section('会话权限')
      this.action('仅观看',this.watch?'已开启，暂停远程输入':'已关闭','panelWatchToggle',this.ready,this.onWatch)
      this.section('其他能力')
      this.action('防窥模式与壁纸',this.privacyText,'securityPrivacy',true,()=>this.openPrivacy())
      this.section('自动解锁被控端')
      Text(this.unlockHint).fontSize(12).fontColor(UiColor.secondary).width('100%')
      if(this.unlockEditing){
        Text('仅用于这台电脑的 Windows 账户密码，不支持 PIN。密码保存在本机系统安全存储。保存后仍需单独开启。').fontSize(12).fontColor(UiColor.secondary).width('100%')
        TextInput({text:this.unlockPassword,placeholder:'Windows 账户密码'}).id('windowsUnlockPassword').fontColor(UiColor.text).placeholderColor(UiColor.secondary).caretColor(UiColor.primary).borderRadius(12).backgroundColor(UiColor.neutralSoft).border({width:1,color:UiColor.divider}).type(InputType.Password).showPasswordIcon(false).maxLength(1024).onChange((value:string)=>{this.unlockPassword=value;})
        Row({space:8}){
          Button('取消',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).id('windowsUnlockCancel').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).layoutWeight(1).onClick(()=>{this.unlockPassword='';this.unlockEditing=false;})
          Button('安全保存',{type:ButtonType.Normal}).fontColor(UiColor.text).borderRadius(12).id('windowsUnlockSave').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).layoutWeight(1).enabled(this.securityReady&&!this.unlockBusy&&this.unlockPassword.length>0).onClick(()=>{const password=this.unlockPassword;this.unlockPassword='';this.unlockEditing=false;this.onUnlock('enroll',password);})
        }.width('100%')
      }else{
        this.action(this.unlockReenrollmentRequired?'为当前电脑重新设置密码':this.unlockEnrolled?'更新 Windows 账户密码':'设置 Windows 账户密码','仅对当前本人电脑生效','windowsUnlockEnroll',this.securityReady&&this.unlockAvailable&&!this.unlockBusy,()=>{this.unlockPassword='';this.unlockEditing=true;})
      }
      if(this.unlockEnrolled){
        if(!this.unlockReenrollmentRequired||this.unlockEnabled){
        this.action(this.unlockEnabled?'关闭自动解锁':'开启自动解锁',this.unlockReenrollmentRequired?'仅关闭已保存的本地设置，不会提交密码':this.unlockEnabled?'已保存本地设置；每次连接仍须验证设备身份':'需要你明确开启后才会自动使用','windowsUnlockToggle',this.securityReady&&!this.unlockBusy,()=>this.onUnlock(this.unlockEnabled?'disable':'enable',''))
        }
        this.action('删除已保存的密码','同时关闭这台电脑的自动解锁','windowsUnlockDelete',this.securityReady&&!this.unlockBusy,()=>{this.unlockPassword='';this.unlockEditing=false;this.onUnlock('delete','');})
      }
    }
    if(this.route==='privacy'){
      Text(this.privacyText).id('privacyCurrentState').fontSize(12).fontColor(UiColor.secondary).width('100%')
      this.section('防窥模式')
      this.privacyChoice('关闭防窥','恢复电脑屏幕正常显示','privacyOff',1,this.securityReady&&!this.systemActionPending&&(this.privacySupport>0||this.privacyOwned))
      this.privacyChoice('开启隐私壁纸','电脑物理屏幕显示隐私壁纸','privacyPicture',2,this.securityReady&&!this.systemActionPending&&this.privacySupport>0)
      this.privacyChoice('关闭物理屏幕','远程画面继续显示','privacyScreenOff',3,this.securityReady&&!this.systemActionPending&&this.privacySupport===2)
      this.section('电脑的隐私壁纸')
      Text(this.privacyWallpaperHint).fontSize(12).fontColor(UiColor.secondary).width('100%')
      ForEach(this.privacyChoices,(item:PrivacyChoice)=>{
        Column({space:8}){
          if(item.url.length){Image(item.url).width('100%').height(120).objectFit(ImageFit.Cover).borderRadius(12)}
          this.action((item.selected?'已选 · ':'')+item.title,'保存此壁纸后，可确认开启防窥','privacyWallpaper_'+item.key,this.securityReady&&!this.privacyLoading&&this.privacySupport>0,()=>this.usePrivacyWallpaper(item))
        }.width('100%')
      },(item:PrivacyChoice)=>item.key)
      this.action('刷新壁纸列表',this.privacyLoading?'正在读取…':'读取 UU 保存的预设和自定义壁纸','privacyWallpaperRefresh',this.securityReady&&!this.privacyLoading,()=>this.loadPrivacyWallpapers())
    }
    if(this.route==='external'){
      this.section('键盘与指针')
      this.action('外接键盘',this.externalKeyboard?'直控已开启':'直控已关闭','openHardware',true,()=>this.open('hardware'))
      this.action('鼠标','操作说明','openMouse',true,()=>this.open('mouse'))
      this.section('其他外设')
      this.action('手柄',this.gamepadEnabled?'关闭手柄直控':'开启外接手柄直控','gamepadToggle',this.ready&&!this.watch&&!this.viewOnly,this.onGamepad)
      this.action(this.micActive?'关闭麦克风回传':'开启麦克风回传',this.micText,'microphoneToggle',this.micActive||(this.ready&&!this.watch),this.onMicrophone)
    }
    if(this.route==='hardware'){
      this.action(this.externalKeyboard?'关闭外接键盘直控':'开启外接键盘直控','桌面取得焦点时向电脑发送按键','externalKeyboardToggle',true,this.onExternalKeyboard)
      Text('Ctrl+Alt+Enter 退出直控。系统保留快捷键仍由鸿蒙处理。').fontSize(13).fontColor(UiColor.secondary).width('100%')
    }
    if(this.route==='mouse'){Text('外接鼠标可点击、拖动和滚动。触屏模拟鼠标请在操作面板选择触控板，调节指针速度。').fontSize(14).fontColor(UiColor.secondary).width('100%')}
    if(this.route==='more'){
      this.section('文件与连接')
      this.action('文件传输','浏览、上传与下载','openFiles',this.ready,this.onFiles)
      this.action('剪贴板','手动发送或接收文字','openClipboard',this.ready,this.onClipboard)
      this.action('网络状态','','openNetwork',true,()=>this.open('net'))
      this.section('设备与会话')
      this.action('保存桌面封面',this.thumbnailHint,'saveDesktopThumbnail',this.ready&&!this.thumbnailPending,this.onThumbnail)
      this.action('设备控制','锁屏与电源','openPower',true,()=>this.open('power'))
      this.action('远程声音','本机播放','openSound',this.ready,this.onSound)
      if(this.deviceKey.length&&this.deviceKey!=='assistance'){
        this.action('快速启动','已添加的电脑应用','openPinnedApps',this.ready,()=>this.openApps())
      }
      this.action('交互终端','使用当前授权会话，手动输入','openTerminal',this.ready,this.onTerminal)
      this.action('释放全部输入','','releaseAllInputs',true,this.onRelease)
    }
    if(this.route==='apps'){
      if(!this.pinned.length){Text(this.pinnedHint).fontSize(14).fontColor(UiColor.secondary).width('100%')}
      ForEach(this.pinned,(app:PinnedApp)=>{
        this.action(app.name,'','pinnedApp'+app.id,this.ready&&!this.watch&&!this.viewOnly,()=>this.onPinned(app.id))
      },(app:PinnedApp)=>app.id)
    }
    if(this.route==='power'){
      this.section(this.desktopName)
      this.action('立即锁屏','需要在电脑端解锁','lockNow',this.securityReady&&!this.systemActionPending,()=>this.onSystemAction('lock_now'))
      this.action('重新启动','将中断会话','rebootNow',this.securityReady&&!this.systemActionPending,()=>this.onSystemAction('reboot'))
      this.action('关机','将中断会话','shutdownNow',this.securityReady&&!this.systemActionPending,()=>this.onSystemAction('shutdown'))
      Text(this.systemActionText).fontSize(12).fontColor(UiColor.secondary).width('100%')
    }
    if(this.route==='shortcuts'){
      this.action('显示桌面','Win+D','shortcutDesktop',this.ready&&!this.watch&&!this.viewOnly,this.onDesktop)
      this.action('切换窗口','Alt+Tab','shortcutWindows',this.ready&&!this.watch&&!this.viewOnly,this.onWindows)
      this.action('更多快捷键','','shortcutKeyboard',this.ready&&!this.watch&&!this.viewOnly,this.onKeyboard)
    }
    if(this.route==='net'){
      Text('连接方式：'+this.connectionMethod).id('connectionMethod').fontSize(13).fontColor(UiColor.text).width('100%')
      Text('传输协议：'+this.transportProtocol).id('transportProtocol').fontSize(13).fontColor(UiColor.text).width('100%')
      Text(this.network).id('networkStatus').fontSize(13).fontColor(UiColor.secondary).width('100%')
    }
  }
  build(){
    Column({space:10}){
      Row({space:8}){
        if(this.route!=='ops'){Button('‹',{type:ButtonType.Normal}).fontColor(UiColor.text).id('operationsBack').width(48).height(48).fontSize(26).fontColor(UiColor.text).borderRadius(12).backgroundColor(UiColor.neutralSoft).onClick(()=>this.back())}
        Text(this.route==='apps'?'快速启动':this.title()).fontSize(20).fontWeight(FontWeight.Bold).fontColor(UiColor.text).layoutWeight(1)
        Button('×',{type:ButtonType.Normal}).fontColor(UiColor.text).id('closeTools').width(48).height(48).fontSize(24).fontColor(UiColor.text).borderRadius(12).backgroundColor(UiColor.neutralSoft).onClick(this.onClose)
      }.width('100%')
      Scroll(this.contentScroller){Column({space:8}){
        Text(this.statusText).id('operationsInputStatus').fontSize(11).fontColor(UiColor.secondary).width('100%')
        this.contents()
      }.width('100%').padding({bottom:8})}.id('operationsContent').layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }.id('remoteToolsPanel').width('100%').height('100%').padding(this.compact?14:20).borderRadius(12).backgroundColor(UiColor.surface).onTouch((event:TouchEvent)=>event.stopPropagation())
  }
}
