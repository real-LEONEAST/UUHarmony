import { RemotePreferences } from './RemotePreferences';
import { DeviceMenuOrder } from './DeviceMenuOrder';
import { MORE_ACTIONS, moveMoreAction, moreActionLabel, lockResultNotice } from './DeviceDetailsModel';
import { common, bundleManager } from '@kit.AbilityKit';
import { LibraryTabs } from './LibraryTabs';
import { libraryTabState } from './LibraryTabState';
import { detailSessionInvalidated } from './LivePreviewModel';
import { LiveDesktopPreview } from './LiveDesktopPreview';
import { deviceLockRequest } from './DeviceLockRequest';
import { PinnedApplications } from './PinnedApplications';
import { image } from '@kit.ImageKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { compactPhoneLayout, compactDeviceCoverHeight, phoneLandscape } from './DeviceLayoutModel';
import { deviceWallpapers } from './DeviceWallpapers';
import { remoteThumbnails } from './RemoteThumbnail';
import { pcHost } from '../pc/PcHostService';
import { pcFileWindows } from '../pc/PcFileWindows';
import { AppNavigation } from '../pc/AppNavigation';
import { client, AuthView, emptyView } from './AuthClient';
import { DeviceCard, deviceCards, visibleDeviceCards, listIsStale, refreshTimeLabel, selectionMatches } from './DeviceListModel';
import { UiColor, UiStatusBadge, UiSecondaryButton, UiNotice } from './UiFoundation';
import { session } from './SessionClient';
import { RemoteRoute } from './RemoteRoute';
import { windowPolicy } from './WindowPolicy';

interface FileTransferRoute {deviceKey:string;deviceName?:string;confirmed:boolean;}

@Entry
@Component
struct Devices {
  @State private detailSessionKey:string='';
  @State private detailSessionName:string='';
  @State private detailLockToken:string='';
  @State private detailRequestId:number=0;
  private detailListStartedAt:number=0;
  @State private thumbnailVersion:number=0;
  @State private wallpaperVersion:number=0;
  private offWallpapers:()=>void=()=>{};
  private offThumbnails:()=>void=()=>{};
  @State private sharing:boolean=false;
  @State private allDevices:boolean=false;
  @State private selectedKey:string='';
  @State private detailOpen:boolean=false;
  @State private moreOpen:boolean=false;
  @State private removingDevice:boolean=false;
  @State private orderEditing:boolean=false;
  @State private orderSaving:boolean=false;
  @State private moreOrder:string[]=MORE_ACTIONS.slice();
  private orderPrefs:DeviceMenuOrder|undefined=undefined;
  private lockNoticeTimer:number=-1;
  @State private accountOpen:boolean=libraryTabState.selected==='account';
  @State private folded:string[]=[];
  @StorageLink('uuWindowWidth') private windowWidth:number=0;
  @StorageLink('uuWindowHeight') private windowHeight:number=0;
  private offShare:()=>void=()=>{};
  @State private view: AuthView = emptyView();
  @State private cards: DeviceCard[] = [];
  @State private stale: boolean = true;
  @State private updatedLabel: string = '尚未成功更新';
  @State private message: string = '';
  @State private navigating: boolean = false;
  @State private confirming: boolean = false;
  @State private controlDisconnecting:boolean=false;
  @State private sessionBlocked:boolean=false;
  private offSession:()=>void=()=>{};
  @StorageLink('uuSafeTop') private safeTop: number = 12;
  @StorageLink('uuSafeBottom') private safeBottom: number = 12;
  private visible: boolean = false;
  private timer: number = -1;
  private refreshDueAt:number=0;
  @State private refreshBusy:boolean=false;
  @State private refreshQueued:boolean=false;
  private actionEpoch:number=0;
  private stopObserving: () => void = () => {};


  aboutToAppear(): void {
    const context=this.getUIContext().getHostContext() as common.UIAbilityContext;deviceWallpapers.setContext(context);this.orderPrefs=new DeviceMenuOrder(context);
    this.visible = true;this.offThumbnails=remoteThumbnails.observe((version:number)=>{this.thumbnailVersion=version;});deviceWallpapers.setVisible(true);this.offWallpapers=deviceWallpapers.observe((version:number)=>{this.wallpaperVersion=version;});
    this.offSession=session.monitorState((blocked:boolean)=>{this.sessionBlocked=blocked;if(!blocked&&this.refreshQueued){this.autoRefresh(true);}});
    this.offShare=pcHost.observe(()=>{this.sharing=pcHost.blocksOutgoing;});
    windowPolicy.applyRemote(false);
    this.stopObserving = client.observe((value: AuthView) => {
      this.view = value;
      this.rebuild();
      if (!value.loggedIn && this.visible) {this.closeDetailSession();
        this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' }).catch(() => {});
      }
    });
    this.timer = setInterval(() => { this.view = client.view; this.rebuild();this.autoRefresh(); }, 5000);
    this.autoRefresh(true);
  }
  aboutToDisappear(): void {
    this.clearNotice();deviceLockRequest.takeResult(this.selectedKey);this.actionEpoch++;this.confirming=false;this.closeDetailSession();this.visible = false;this.offThumbnails();this.offWallpapers();deviceWallpapers.setVisible(false);
    this.stopObserving();this.offShare();this.offSession();
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
  }
  onPageShow(): void {
    this.visible = true;deviceWallpapers.setVisible(true);
    this.navigating = false;this.confirming=false;
    windowPolicy.applyRemote(false);
    deviceLockRequest.takeResult(this.selectedKey);
    this.clearNotice();
    this.view = client.view;this.refreshQueued=true;
    this.autoRefresh(true);this.rebuild();
  }
  onPageHide(): void { this.refreshQueued=false;this.clearNotice();deviceLockRequest.takeResult(this.selectedKey);this.actionEpoch++;this.confirming=false;this.closeDetailSession();this.visible = false;deviceWallpapers.setVisible(false); }
  private rebuild(): void {
    this.thumbnailVersion=remoteThumbnails.version;
    const now: number = Date.now();
    this.stale = listIsStale(this.view.devicesUpdatedAtMs,this.view.devicesRefreshFailed,now);
    this.updatedLabel = refreshTimeLabel(this.view.devicesUpdatedAtMs, now);
    this.cards = deviceCards(this.view.devices, this.stale, session.checkingEndedDevice);
    if(this.detailSessionKey&&detailSessionInvalidated(this.cards,this.detailSessionKey,this.detailSessionName,this.detailListStartedAt,this.view.devicesUpdatedAtMs,this.view.devicesRefreshFailed)){this.closeDetailSession();}
    deviceWallpapers.sync(this.cards,this.view.refreshes,this.selectedKey);
  }
  private autoRefresh(force:boolean=false):void{
    if(!this.visible||!client.view.loggedIn||this.refreshBusy||this.navigating||this.confirming||this.controlDisconnecting||session.busy||session.isClosing||session.detailSessionActive){return;}
    const now=Date.now();if(!force&&now<this.refreshDueAt&&this.refreshDueAt-now<=30000){return;}
    this.refreshDueAt=now+30000;this.refreshQueued=false;this.refreshBusy=true;
    client.refreshDevices(true).finally(()=>{this.refreshBusy=false;this.refreshQueued=false;if(this.visible){this.view=client.view;this.rebuild();}});
  }
  private refresh():void{this.autoRefresh(true);}
  private async freshTarget(key:string,name:string):Promise<DeviceCard|undefined>{
    const run=this.actionEpoch;
    const confirmed=await client.refreshDevices();
    if(!this.visible||run!==this.actionEpoch){return undefined;}
    this.view=client.view;this.rebuild();
    if(!confirmed&&(!this.view.loggedIn||!(this.view.devicesUpdatedAtMs>0))){this.message='暂时无法获取设备，请稍后再试。';return undefined;}
    const target=this.cards.find((card:DeviceCard)=>card.key===key&&card.name===name);
    if(!target||!target.connectable){this.message=target?.presence==='offline'?'设备已离线，未建立连接。':'设备状态已变化，未建立连接。';return undefined;}
    return target;
  }
  private canRemoveDevice(card:DeviceCard):boolean{
    return this.visible&&this.view.loggedIn&&!card.current&&!this.confirming&&!this.removingDevice&&!session.busy&&!session.isClosing;
  }
  private requestDeviceRemoval(card:DeviceCard):void{
    if(!this.canRemoveDevice(card)){return;}
    const revision=this.actionEpoch;
    const details=card.name+(card.recordLabel?'\n'+card.recordLabel:'')+'\n'+card.statusLabel;
    this.confirming=true;
    const cancel=():void=>{this.confirming=false;};
    this.getUIContext().showAlertDialog({
      title:'删除设备？',message:details+'\n删除后，这台设备需要重新绑定才能继续远程访问。',
      primaryButton:{value:'取消',action:cancel},
      secondaryButton:{value:'删除设备', action:()=>{cancel();this.removeSelectedDevice(card,revision);}},
      cancel:cancel
    });
  }
  private async removeSelectedDevice(card:DeviceCard,revision:number):Promise<void>{
    if(!this.canRemoveDevice(card)||revision!==this.actionEpoch){return;}
    this.removingDevice=true;
    this.message='正在核对设备并提交删除请求…';
    try{
      const result=await client.removeDevice(card.key,card.name);
      if(!this.visible||revision!==this.actionEpoch){return;}
      this.view=client.view;
      this.rebuild();
      if(result==='removed'){
        if(this.selectedKey===card.key){this.closeDetails();}
        this.message='已从账号删除 '+card.name+'。';
      }else if(result==='changed'){
        this.message='设备名称或控制状态已变化，请刷新后核对。';
      }else if(result==='rejected'){
        this.message='服务端拒绝删除设备（HTTP '+this.view.httpStatus+'，服务代码 '+this.view.apiCode+'）。';
      }else{
        this.message='尚未确认删除结果，请刷新设备列表后查看。';
      }
    }finally{this.removingDevice=false;}
  }
  @Builder
  private removeDeviceButton(card:DeviceCard){
    if(!card.current){
      Button(this.removingDevice?'正在处理…':'删除设备',{type:ButtonType.Normal})
        .id('removeDevice').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft)
        .borderRadius(12).constraintSize({minHeight:48}).width('100%')
        .enabled(this.canRemoveDevice(card)).onClick(()=>this.requestDeviceRemoval(card))
    }
  }
  private detailControlText(key:string):string {
    const card=this.selected();
    if(!card||card.key!==key||card.controlState==='idle'||card.controlState==='locally-ended'){return '';}
    return this.stale&&this.refreshBusy?'正在更新设备状态…':this.stale&&this.refreshQueued?'等待更新设备状态…':card.controlLabel;
  }
  private controlDisconnectTarget(key:string):DeviceCard|undefined {
    const card=this.selected();
    return card?.key===key&&!card.current&&!this.stale&&card.participantToken?card:undefined;
  }
  private requestControlDisconnect(key:string):void{
    const card=this.controlDisconnectTarget(key);
    if(!card||!this.visible||this.confirming||this.controlDisconnecting||session.busy||session.isClosing){return;}
    this.confirming=true;const name=card.name;const token=card.participantToken;const run=this.actionEpoch;
    const cancel=():void=>{this.confirming=false;};
    this.getUIContext().showAlertDialog({title:'断开该设备的全部控制？',message:name+'\n'+card.controlLabel+'\n将中断这台设备当前的所有远程控制。确认后会重新读取状态；若控制端已变化则取消。',cancel:cancel,primaryButton:{value:'取消',action:cancel},secondaryButton:{value:'断开全部控制',action:()=>{this.confirming=false;this.disconnectControl(key,name,token,run);}}});
  }
  private async disconnectControl(key:string,name:string,token:string,run:number):Promise<void>{
    if(this.controlDisconnecting||!this.visible||run!==this.actionEpoch){return;}this.controlDisconnecting=true;
    try{const beforeRefresh=client.view.refreshes;const refreshed=await client.refreshDevices(true);if(!this.visible||run!==this.actionEpoch){return;}this.view=client.view;this.rebuild();
      const target=this.controlDisconnectTarget(key);
      if(!refreshed||client.view.refreshes<=beforeRefresh||!target||target.name!==name||!token||target.participantToken!==token||session.busy||session.isClosing){this.message='控制状态已变化或无法确认，请重新查看后再操作。';return;}
      const sent=await client.clearDeviceControl(key,token);if(!this.visible||run!==this.actionEpoch){return;}
      if(!sent){this.message='断开请求未确认（HTTP '+client.view.httpStatus+'，服务代码 '+client.view.apiCode+'），请刷新后重试。';return;}
      this.message='已提交断开请求，正在确认设备状态…';const checked=await client.refreshDevices(true);if(!this.visible||run!==this.actionEpoch){return;}
      this.view=client.view;this.rebuild();const after=this.cards.find((item:DeviceCard)=>item.key===key);
      this.message=checked&&after?.controlState==='idle'?'已确认该设备当前没有控制端。':'断开请求已提交，但尚未确认控制全部结束，请刷新查看。';
    }finally{this.controlDisconnecting=false;}
  }
  @Builder private detailControlStatus(key:string){
    if(this.detailControlText(key)){
      Text(this.detailControlText(key)).id('deviceControlStatus').fontSize(14).fontColor(UiColor.secondary).width('100%')
    }
    if(this.controlDisconnectTarget(key)){
      Button(this.controlDisconnecting?'处理中…':'断开控制').id('disconnectDeviceControl').fontSize(13)
        .fontColor(UiColor.onPrimary).backgroundColor(UiColor.primary)
        .enabled(!this.controlDisconnecting&&!this.confirming&&!session.busy&&!session.isClosing)
        .onClick(()=>this.requestControlDisconnect(key))
    }
  }
  private visibleCards():DeviceCard[] {
    return visibleDeviceCards(this.cards,this.allDevices);
  }
  private connect(card: DeviceCard, initialTool: string = '', appName:string=''): void {
    this.clearNotice();this.rebuild();
    if(this.sharing){this.message="请先停止共享此电脑，再连接其他设备。";return;}
    if (!selectionMatches(this.cards, card.key, card.name) || this.navigating || this.confirming || session.busy || session.isClosing) { return; }
    if(initialTool===''||initialTool==='watch'){this.enter(card.key,card.name,initialTool);return;}
    this.confirming = true;
    this.getUIContext().showAlertDialog({
      title: appName?'连接并打开「'+appName+'」？':initialTool==='lock_now'?'立即锁屏这台电脑？':initialTool==='terminal'?'连接交互终端？':'连接这台电脑？',
      message: card.name + (card.recordLabel.length > 0 ? '\n' + card.recordLabel : '') + (initialTool==='lock_now'?'\n将建立已授权会话，就绪后仅发送一次锁屏并断开。需要在电脑端解锁；可在连接期间取消。':initialTool==='terminal'?'\n将在已授权会话里请求终端，只有手动提交的内容才会发送；被控端可拒绝。':'\n请核对完整名称。连接不会抢占已有会话。'),
      cancel: () => { this.confirming = false; },
      primaryButton: { value: '取消', action: () => { this.confirming = false; } },
      secondaryButton: { value: initialTool==='lock_now'?'连接并锁屏':initialTool==='terminal'?'连接终端':'进入桌面', action: () => { this.confirming = false; this.enter(card.key, card.name, initialTool); } }
    });
  }
  private async enter(key: string, label: string, initialTool: string = ''): Promise<void> {
    this.rebuild();
    if (this.sharing || !this.visible || this.navigating || !selectionMatches(this.cards, key, label)) {
      this.message = '设备状态已变化，未建立连接。'; return;
    }
    const action=this.actionEpoch;this.navigating = true;
    this.message = '';
    const target=await this.freshTarget(key,label);if(action!==this.actionEpoch||!this.visible){return;}if(!target){this.navigating=false;return;}
    const selected=await session.select(key,label);if(action!==this.actionEpoch||!this.visible){return;}
    if (!selected) {
      this.message = '设备状态已变化，未建立连接。'; this.navigating = false; return;
    }
    this.view = client.view;
    this.rebuild();
    if (this.sharing || !this.visible || !selectionMatches(this.cards, key, label)) {
      this.message = '设备状态已变化，未建立连接。'; this.navigating = false; return;
    }
    const params: RemoteRoute = { deviceKey: key, confirmed: true, initialTool: initialTool,lockToken:initialTool==='lock_now'?deviceLockRequest.create(key):undefined };
    try { await this.getUIContext().getRouter().pushUrl({ url: initialTool==='terminal'?'pages/Terminal':'pages/RemoteDesktop', params: params }); }
    catch (_) { deviceLockRequest.cancel();this.message = '暂时无法打开远程桌面，请重试。'; this.navigating = false; }
  }
  private logout(): void {
    if (this.navigating || this.confirming || session.busy) { return; }
    this.getUIContext().showAlertDialog({ title: '退出当前账号？', message: pcHost.busy?'将先停止共享此电脑，再退出当前账号。之后需要重新扫码登录。':'退出后需要重新扫码登录。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '退出', action: async () => { if(await pcHost.stop()){await client.logout();} } } });
  }
  private compact():boolean{return compactPhoneLayout(deviceInfo.deviceType,this.windowWidth,this.windowHeight,this.safeTop,this.safeBottom);}
  private sideNavigation():boolean{return phoneLandscape(deviceInfo.deviceType,this.windowWidth,this.windowHeight);}
  private split():boolean{return this.windowWidth-(pcHost.supported&&this.windowWidth>=840?232:0)>=720;}
  private selected():DeviceCard|undefined {return this.cards.find((card:DeviceCard)=>card.key===this.selectedKey);}
  private categoryCards(category:string):DeviceCard[]{return this.cards.filter((card:DeviceCard)=>card.category===category).sort((a:DeviceCard,b:DeviceCard)=>Number(b.current)-Number(a.current)||a.name.localeCompare(b.name)||a.key.localeCompare(b.key));}
  private groupCards(presence:string):DeviceCard[]{return this.visibleCards().filter((card:DeviceCard)=>card.presence===presence);}
  private artwork(card:DeviceCard):Resource|image.PixelMap{const wallpaper=deviceWallpapers.get(card.key);if(wallpaper){return wallpaper;}return $r('app.media.device_landscape');}
  private coverLabel(card:DeviceCard):string{const wallpaper=deviceWallpapers.label(card.key);if(deviceWallpapers.get(card.key)){return wallpaper;}return '默认插画';}
  private ready(card:DeviceCard):boolean{return card.connectable&&!this.sharing&&!this.navigating&&!this.confirming&&!this.sessionBlocked&&!session.busy&&!session.isClosing&&!session.detailSessionActive;}
  onBackPress():boolean{this.clearNotice();if(this.moreOpen){this.actionEpoch++;this.navigating=false;this.confirming=false;this.closeDetailSession();this.moreOpen=false;return true;}if(this.detailSessionKey){this.closeDetailSession();this.autoRefresh(true);return true;}if(this.detailOpen||this.accountOpen){this.navigating=false;this.confirming=false;this.detailOpen=false;this.accountOpen=false;this.actionEpoch++;this.autoRefresh(true);return true;}if(this.allDevices){this.allDevices=false;return true;}return false;}
  private closeDetailSession():void{this.detailRequestId++;this.detailSessionKey='';this.detailSessionName='';this.detailLockToken='';deviceLockRequest.cancel();}
  private closeDetails():void{this.clearNotice();this.actionEpoch++;this.navigating=false;this.confirming=false;this.moreOpen=false;this.closeDetailSession();this.detailOpen=false;this.selectedKey='';this.autoRefresh(true);}
  private chooseDevice(card:DeviceCard):void{this.clearNotice();this.moreOpen=false;this.actionEpoch++;this.navigating=false;this.confirming=false;if(card.key!==this.selectedKey){this.closeDetailSession();}this.selectedKey=card.key;this.detailOpen=true;this.accountOpen=false;this.message='';this.rebuild();this.autoRefresh(true);}
  private detailSessionIds():number[]{return [this.detailRequestId];}
  private requestDetailSession(card:DeviceCard,lock:boolean=false):void{
    this.clearNotice();this.rebuild();if(!this.visible||!this.ready(card)||!selectionMatches(this.cards,card.key,card.name)||this.selectedKey!==card.key){return;}
    this.confirming=true;const cancel=()=>{this.confirming=false;};
    this.getUIContext().showAlertDialog({title:lock?'立即锁屏这台电脑？':'在详情中预览实时桌面？',message:card.name+'\n'+(lock?'将建立仅允许本次锁屏的授权会话，指令发送后断开并留在详情。连接期间可取消；发送不等于执行成功。':'仅为这台电脑建立前台只读视频会话，不发送键鼠、麦克风或终端输入。切换设备、返回或进入后台会停止。'),cancel:cancel,primaryButton:{value:'取消',action:cancel},secondaryButton:{value:lock?'连接并锁屏':'开始实时预览',action:()=>{
      cancel();this.rebuild();if(!this.visible||!this.ready(card)||this.selectedKey!==card.key||!selectionMatches(this.cards,card.key,card.name)){return;}
      this.beginDetailSession(card.key,card.name,lock);
    }}});
  }
  private async beginDetailSession(key:string,name:string,lock:boolean):Promise<void>{
    const action=this.actionEpoch;this.confirming=true;
    try{const target=await this.freshTarget(key,name);if(action!==this.actionEpoch||!target||this.selectedKey!==key||this.sharing||session.busy||session.isClosing||session.detailSessionActive){return;}
      this.detailRequestId++;this.detailListStartedAt=this.view.devicesUpdatedAtMs;this.detailSessionName=name;this.detailLockToken=lock?deviceLockRequest.create(key):'';this.detailSessionKey=key;this.message='';
    }finally{if(action===this.actionEpoch){this.confirming=false;}}
  }
  private detailSessionStopped(id:number,message:string):void{if(id!==this.detailRequestId||!this.visible||!this.detailSessionKey){return;}this.closeDetailSession();this.showResult(message);}
  private more(card:DeviceCard):void{this.clearNotice();this.closeDetailSession();this.orderEditing=false;this.orderSaving=false;this.moreOrder=this.orderPrefs?this.orderPrefs.load(this.view.wallpaperAccountKey||'',card.key):MORE_ACTIONS.slice();this.moreOpen=true;}
  private async saveMoreOrder():Promise<void>{if(this.orderSaving){return;}const key=this.selectedKey;const account=this.view.wallpaperAccountKey||'';const action=this.actionEpoch;this.orderSaving=true;try{const saved=this.orderPrefs?await this.orderPrefs.save(account,key,this.moreOrder):false;if(this.selectedKey!==key||!this.visible||!this.moreOpen||action!==this.actionEpoch||account!==(this.view.wallpaperAccountKey||'')){return;}if(saved){this.orderEditing=false;this.message='';}else{this.message='顺序暂未保存，请稍后重试。';}}finally{if(action===this.actionEpoch){this.orderSaving=false;}}}
  private moreIcon(tool:string):Resource{return tool==='files'?$r('app.media.device_files'):tool==='watch'?$r('app.media.device_eye'):$r('app.media.device_grid');}
  private clearNotice():void{if(this.lockNoticeTimer>=0){clearTimeout(this.lockNoticeTimer);this.lockNoticeTimer=-1;}this.message='';}
  private showResult(result:string):void{this.clearNotice();const notice=lockResultNotice(result);if(notice){this.message=notice;const key=this.selectedKey;this.lockNoticeTimer=setTimeout(()=>{if(this.selectedKey===key){this.message='';}this.lockNoticeTimer=-1;},3500);}else{this.message=result;}}
  private action(card:DeviceCard,tool:string):void{this.clearNotice();if(tool==='terminal'&&card.platformLabel==='Windows'){this.openTerminalHub(card);}else if(tool==='more'){this.more(card);}else if(tool==='files'){this.openFiles(card);}else if(tool==='watch'){this.connect(card,'watch');}else if(tool==='lock_now'){this.requestDetailSession(card,true);}else if(tool!=='wake'){this.connect(card,tool);}}
  private async openTerminalHub(card:DeviceCard):Promise<void>{
    if(!this.visible||this.navigating||this.confirming||this.sharing||session.busy||session.isClosing||!this.view.loggedIn){return;}
    this.closeDetailSession();this.navigating=true;
    try{await this.getUIContext().getRouter().pushUrl({url:"pages/TerminalHub",params:{deviceKey:card.key,deviceName:card.name}});}catch(_){this.message="暂时无法打开终端。";}finally{this.navigating=false;}
  }
  private async openFiles(card:DeviceCard):Promise<void>{
    if(!this.visible||this.navigating||this.confirming||this.sharing){return;}this.clearNotice();this.closeDetailSession();
    const waiting=this.actionEpoch;this.navigating=true;
    for(let step=0;step<160&&session.detailSessionActive;step++){await new Promise<void>((resolve:()=>void)=>{setTimeout(resolve,50);});if(!this.visible||waiting!==this.actionEpoch){return;}}
    if(session.detailSessionActive){this.navigating=false;this.message='正在结束预览，请稍后重试。';return;}
    const action=this.actionEpoch;const target=await this.freshTarget(card.key,card.name);if(!target||!this.visible||action!==this.actionEpoch||session.busy||session.isClosing){if(action===this.actionEpoch){this.navigating=false;}return;}
    const params:FileTransferRoute={deviceKey:card.key,deviceName:card.name,confirmed:true};
    if(pcHost.supported){
      try{await pcFileWindows.open({deviceKey:card.key,deviceName:card.name,borrowed:false});}
      catch(_){this.message='暂时无法打开文件窗口，请关闭已有文件窗口后重试。';}
      finally{if(action===this.actionEpoch){this.navigating=false;}}
      return;
    }
    try{await this.getUIContext().getRouter().pushUrl({url:'pages/FileTransfer',params:params});}catch(_){this.navigating=false;this.message='暂时无法打开文件传输。';}
  }
  private navigate(page:string):void{if(page==='share'){this.getUIContext().getRouter().replaceUrl({url:'pages/PcShare'}).catch(()=>{});}else{this.selectLibraryTab(page);}}
  @Builder
  deviceCard(card:DeviceCard){
    Button({type:ButtonType.Normal}){
      Row({space:this.compact()?8:14}){
        Stack({alignContent:Alignment.BottomStart}){
          Image(this.artwork(card)).width('100%').height('100%').objectFit(ImageFit.Cover).opacity(card.presence==='offline'?0.5:1)
          Text(card.statusLabel).fontSize(11).fontColor(Color.White).padding(5).backgroundColor('#660F2630').borderRadius(5).margin(5)
        }.width(this.compact()?72:112).height(this.compact()?58:92).clip(true).accessibilityLevel('no')
        Column({space:this.compact()?2:6}){
          Text(card.name).fontSize(this.compact()?15:16).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%').maxLines(this.compact()?1:2).textOverflow({overflow:TextOverflow.Ellipsis}).wordBreak(WordBreak.BREAK_ALL).id('deviceName_'+card.key)
          if(this.compact()){Text(card.platformLabel+' · '+(this.stale&&this.refreshBusy?'正在更新设备状态…':this.stale&&this.refreshQueued?'等待更新设备状态…':card.controlLabel)).fontSize(12).fontColor(UiColor.secondary).width('100%').maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})}else{Text(card.platformLabel).fontSize(13).fontColor(UiColor.secondary).width('100%');Text(this.stale&&this.refreshBusy?'正在更新设备状态…':this.stale&&this.refreshQueued?'等待更新设备状态…':card.controlLabel).fontSize(12).fontColor(UiColor.secondary).width('100%').maxLines(3)}
          if(card.recordLabel.length>0){Text(card.recordLabel).fontSize(12).fontColor(UiColor.secondary).width('100%')}
        }.layoutWeight(1).padding({top:this.compact()?4:8,bottom:this.compact()?4:8}).alignItems(HorizontalAlign.Start)
        Image($r('app.media.device_chevron')).width(16).height(16).fillColor(UiColor.secondary).flexShrink(0)
      }.width('100%').constraintSize({minHeight:this.compact()?58:92}).padding({right:this.compact()?8:16})
    }.width('100%').height('auto').padding(0).backgroundColor(UiColor.surface)
      .border({width:this.split()&&this.selectedKey===card.key?2:0,color:UiColor.primary}).borderRadius(18).clip(true)
      .accessibilityText(card.name+'，'+card.statusLabel+'，查看详情')
      .onClick(()=>this.chooseDevice(card))
  }
  @Builder
  otherDeviceCard(card:DeviceCard){
    Row({space:12}){Column({space:6}){Text(card.name).fontSize(16).fontColor(UiColor.text).width('100%');Text(card.platformLabel+(card.current?' · 本机':'')).fontSize(13).fontColor(UiColor.secondary).width('100%');if(card.recordLabel.length>0){Text(card.recordLabel).fontSize(12).fontColor(UiColor.secondary).width('100%')}}.layoutWeight(1);Text(card.statusLabel).fontSize(13).fontColor(UiColor.secondary)}.width('100%').padding(16).backgroundColor(UiColor.surface).borderRadius(18)
  }
  @Builder
  group(title:string,presence:string){
    if(this.groupCards(presence).length>0){
      Button({type:ButtonType.Normal}){
        Row({space:8}){
          Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiColor.secondary)
          Text(this.groupCards(presence).length.toString()).fontSize(12).fontColor(UiColor.secondary).layoutWeight(1)
          Image($r('app.media.device_chevron')).width(16).height(16).fillColor(UiColor.secondary).rotate({angle:this.folded.includes(presence)?0:90})
        }.width('100%')
      }.width('100%').height(this.compact()?36:48).padding(4).backgroundColor(Color.Transparent)
        .accessibilityText(title+(this.folded.includes(presence)?'，展开':'，收起'))
        .onClick(()=>{this.folded=this.folded.includes(presence)?this.folded.filter((item:string)=>item!==presence):this.folded.concat([presence]);})
      if(!this.folded.includes(presence)){
        ForEach(this.groupCards(presence),(card:DeviceCard)=>{if(card.category==='computer'){this.deviceCard(card)}else{this.otherDeviceCard(card)}},(card:DeviceCard)=>card.key+'|'+JSON.stringify(card)+'|'+this.thumbnailVersion+'|'+this.wallpaperVersion)
      }
    }
  }
  private showDeviceInfo(card:DeviceCard):void {
    const detail=card.platformLabel+(card.current?' · 本机':'')+(card.recordLabel?'\n'+card.recordLabel:'');
    if(this.canRemoveDevice(card)){
      this.getUIContext().showAlertDialog({title:card.name,message:detail,primaryButton:{value:'关闭',action:()=>{}},
        secondaryButton:{value:'删除设备',action:()=>this.requestDeviceRemoval(card)}});
      return;
    }
    this.getUIContext().showAlertDialog({title:card.name,message:detail,primaryButton:{value:'关闭',action:()=>{}}});
  }
  @Builder
  allDeviceRow(card:DeviceCard){
    Button({type:ButtonType.Normal}){Row({space:14}){
      if(card.category==='computer'){Image($r('app.media.device_display')).width(25).height(25).fillColor(UiColor.secondary).accessibilityLevel('no')}else if(card.category==='mobile'){Image($r('app.media.device_mobile')).width(25).height(25).fillColor(UiColor.secondary).accessibilityLevel('no')}else{Text('◇').fontSize(26).fontColor(UiColor.secondary).width(25).textAlign(TextAlign.Center).accessibilityLevel('no')}
      Column({space:4}){Row({space:6}){Text(card.name).id('allDeviceName_'+card.key).fontSize(16).fontColor(UiColor.text).maxLines(2).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1);if(card.current){Text('本机').fontSize(11).fontColor(UiColor.primary).padding({left:6,right:6,top:2,bottom:2}).backgroundColor(UiColor.primarySoft).borderRadius(5)}}.width('100%');if(card.recordLabel){Text(card.recordLabel).fontSize(12).fontColor(UiColor.secondary).width('100%')}}.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Image($r('app.media.device_chevron')).width(16).height(16).fillColor(UiColor.secondary)
    }.width('100%').constraintSize({minHeight:58}).padding({left:16,right:16,top:8,bottom:8})}.width('100%').height('auto').padding(0).backgroundColor(UiColor.surface).accessibilityText(card.name+(card.current?'，本机':'')+'，查看详情').onClick(()=>{if(card.category==='computer'){this.chooseDevice(card);}else{this.showDeviceInfo(card);}})
  }
  @Builder
  allDeviceSection(title:string,category:string){
    if(this.categoryCards(category).length>0){
      Text(title+' '+this.categoryCards(category).length.toString()).fontSize(14).fontWeight(FontWeight.Medium).fontColor(UiColor.secondary).width('100%').padding({top:16,bottom:6})
      Column(){ForEach(this.categoryCards(category),(card:DeviceCard)=>{this.allDeviceRow(card)},(card:DeviceCard)=>card.key+'|'+JSON.stringify(card))}.width('100%').borderRadius(16).clip(true)
    }
  }
  @Builder
  allDevicesPage(){
    Column({space:8}){
      Row({space:8}){Button('返回').height(48).fontColor(UiColor.primary).backgroundColor(Color.Transparent).onClick(()=>{this.allDevices=false;this.detailOpen=false;this.closeDetailSession();});Text('全部设备').fontSize(26).fontWeight(FontWeight.Bold).fontColor(UiColor.text).layoutWeight(1);Button(this.view.pending?'刷新中':'刷新').height(48).fontColor(UiColor.primary).backgroundColor(Color.Transparent).enabled(!this.view.pending&&!this.navigating).onClick(()=>this.refresh())}.width('100%')
      Scroll(){Column({space:0}){
        if(this.view.devicesRefreshFailed&&this.cards.length===0){UiNotice({text:'暂时无法获取设备，请稍后重试。',tone:'error'})}
        if(this.view.devicesIncomplete>0){UiNotice({text:'部分设备记录缺少有效标识，暂时无法展示。'})}
        if(this.message.length>0){UiNotice({text:this.message})}
        this.allDeviceSection('电脑','computer')
        this.allDeviceSection('手机/平板','mobile')
        this.allDeviceSection('其他设备','unknown')
        if(this.cards.length===0){Text(this.view.pending?'正在获取设备':'还没有设备').fontSize(16).fontColor(UiColor.secondary).width('100%').textAlign(TextAlign.Center).padding(24)}
      }.width('100%')}.layoutWeight(1).width('100%').align(Alignment.TopStart).id('allDevicesScroll').scrollBar(BarState.Off)
    }.width('100%').height('100%')
  }
  @Builder
  library(){
    Column({space:8}){
      Row({space:8}){
        Text(this.allDevices?'全部设备':'可控设备').fontSize(this.compact()?20:26).fontWeight(FontWeight.Bold).fontColor(UiColor.text).layoutWeight(1)
        Button(this.view.pending?'刷新中':'刷新').id('refreshDevices').fontSize(13).fontColor(UiColor.primary).backgroundColor(Color.Transparent).height(this.compact()?40:48).enabled(!this.view.pending&&!this.navigating).onClick(()=>this.refresh())
        Button(this.allDevices?'返回':'全部设备').id('allDevicesToggle').fontSize(13).fontColor(UiColor.primary).backgroundColor(UiColor.primarySoft).height(this.compact()?40:48).padding({left:12,right:12}).onClick(()=>{this.allDevices=!this.allDevices;this.folded=[];this.detailOpen=false;this.closeDetailSession();})
      }.width('100%')
      if(this.view.pending&&this.cards.length===0){Row({space:8}){
        Text(this.view.pending?'正在更新设备状态…':this.updatedLabel).id('deviceRefreshTime').fontSize(12).fontColor(UiColor.secondary).layoutWeight(1)

      }.width('100%')}
      Scroll(){Column({space:8}){
        if(this.sharing){UiNotice({text:'此电脑正在共享，请先停止共享再连接其他设备。'})}
        if(this.view.deviceMigration==='failed'){UiNotice({text:'本机设备类型更新未完成（HTTP '+(this.view.migrationHttp||0)+'，服务代码 '+(this.view.migrationApi??-1)+'），已保留原身份。',tone:'error'})}
        if(this.view.deviceMigration==='readback_unconfirmed'){UiNotice({text:'设备类型更新请求已提交，但云端尚未确认类型，请刷新后检查。',tone:'error'})}
        if(this.view.deviceMigration==='alias_restore_failed'){UiNotice({text:'本机类型已更新，但原设备别名未能恢复；请在设备列表中检查。',tone:'error'})}
        if(this.view.devicesRefreshFailed&&this.cards.length===0){UiNotice({text:'暂时无法获取设备，请稍后重试。',tone:'error'})}
        if(this.message.length>0){UiNotice({text:this.message})}
        if(this.view.devicesIncomplete>0){UiNotice({text:'部分设备记录缺少有效标识，暂时无法展示。'})}
        this.group('在线设备','online')
        this.group('离线设备','offline');this.group('状态待确认','unknown')
        if(this.visibleCards().length===0){Column({space:14}){
          Image($r('app.media.ui_computer')).width(52).height(52)
          Text(this.view.pending?'正在获取设备':'还没有设备').fontSize(18).fontColor(UiColor.text)
          Text(this.allDevices?'刷新以获取最新设备列表。':'在电脑上登录同一 UU 账号并保持在线，然后刷新。').fontSize(14).fontColor(UiColor.secondary).textAlign(TextAlign.Center)
          if(!this.view.pending){UiSecondaryButton({label:'刷新设备',onAction:()=>this.refresh()})}
        }.width('100%').padding(24).backgroundColor(UiColor.surface).borderRadius(18)}
      }.width('100%')}.layoutWeight(1).width('100%').align(Alignment.TopStart).id('deviceLibraryScroll').scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
    }.width('100%').height('100%')
  }
  @Builder
  shortcut(card:DeviceCard,icon:Resource,label:string,tool:string){
    Button({type:ButtonType.Normal}){
      Column({space:9}){Image(icon).width(25).height(25).fillColor(UiColor.primary).accessibilityLevel('no');Text(label).fontSize(12).fontColor(UiColor.text).textAlign(TextAlign.Center)}.width('100%').padding({top:14,bottom:14})
    }.layoutWeight(1).height('auto').padding(0).backgroundColor(UiColor.surface).borderRadius(14)
      .enabled(this.ready(card)).opacity(this.ready(card)?1:0.45)
      .onClick(()=>{if(tool==='watch'){this.requestDetailSession(card);}else if(tool==='lock_now'){this.requestDetailSession(card,true);}else if(tool==='more'){this.more(card);}else{this.connect(card,tool);}})
  }
  @Builder
  actionRow(card:DeviceCard,icon:Resource,label:string,sub:string,tool:string){
    Button({type:ButtonType.Normal}){Row({space:this.compact()?8:12}){
      Image(icon).width(this.compact()?20:24).height(this.compact()?20:24).fillColor(UiColor.primary)
      Column({space:4}){Text(label).fontSize(this.compact()?14:16).fontColor(UiColor.text).width('100%');if(sub.length>0){Text(sub).fontSize(12).fontColor(UiColor.secondary).width('100%')}}.layoutWeight(1)
      Image($r('app.media.device_chevron')).width(18).height(18).fillColor(UiColor.secondary)
    }.width('100%').constraintSize({minHeight:this.compact()?44:0}).padding(this.compact()?10:16)}.width('100%').height('auto').padding(0).backgroundColor(UiColor.surface).borderRadius(16)
      .enabled(tool!=='wake'&&(tool==='more'||tool==='codex'&&this.view.loggedIn&&!session.busy&&!session.isClosing||this.ready(card))).opacity(tool!=='wake'&&(tool==='more'||tool==='codex'&&this.view.loggedIn&&!session.busy&&!session.isClosing||this.ready(card))?1:0.5).onClick(()=>this.action(card,tool))
  }
  @Builder
  details(card:DeviceCard){
    if(this.moreOpen){this.moreTools(card)}else{
    Column({space:this.compact()?8:16}){
      Row({space:10}){
        Button(this.split()?'关闭详情':'返回').id('closeDeviceDetails').height(this.compact()?40:48).fontSize(14).backgroundColor(UiColor.surface).fontColor(UiColor.primary).onClick(()=>this.closeDetails())
        Text(card.name).fontSize(this.compact()?18:22).fontWeight(FontWeight.Bold).fontColor(UiColor.text).layoutWeight(1).maxLines(2).textOverflow({overflow:TextOverflow.Ellipsis}).wordBreak(WordBreak.BREAK_ALL)
        UiStatusBadge({label:this.cards.find((row:DeviceCard)=>row.key===this.selectedKey)?.statusLabel||card.statusLabel,tone:this.stale?'unknown':(this.cards.find((row:DeviceCard)=>row.key===this.selectedKey)?.presence||card.presence)})
      }.width('100%')
      Scroll(){Column({space:16}){
        if(this.message.length>0){UiNotice({text:this.message})}
        this.detailControlStatus(card.key)
        if(this.detailSessionKey===card.key){
          ForEach(this.detailSessionIds(),(id:number)=>{LiveDesktopPreview({deviceKey:this.detailSessionKey,deviceName:this.detailSessionName,lockToken:this.detailLockToken,onStopped:(message:string)=>this.detailSessionStopped(id,message)})},(id:number)=>id.toString())
        }else{
        Button({type:ButtonType.Normal}){
          Stack({alignContent:Alignment.BottomStart}){
            if(this.compact()){Image(this.artwork(card)).width('100%').height(compactDeviceCoverHeight(this.windowHeight,this.safeTop,this.safeBottom)).objectFit(ImageFit.Cover)}else{Image(this.artwork(card)).width('100%').aspectRatio(1.7).objectFit(ImageFit.Cover)}
            Column({space:6}){
              Text(this.navigating?'正在打开…':card.connectable?'进入桌面  ↗':card.actionLabel).fontSize(this.compact()?17:22).fontWeight(FontWeight.Bold).fontColor(Color.White)
              Text(this.coverLabel(card)).fontSize(12).fontColor('#DDE9F2')
            }.width('100%').alignItems(HorizontalAlign.Start).padding(this.compact()?6:20).backgroundColor('#550B203A')
          }.width('100%').borderRadius(22).clip(true)
        }.id('connectDevice_'+card.key).width('100%').height('auto').padding(0).backgroundColor(Color.Transparent).enabled(this.ready(card)).onClick(()=>this.connect(card))
        }
        this.actionRow(card,$r('app.media.device_files'),'文件传输','','files')
        this.actionRow(card,$r('app.media.device_eye'),'观看模式','','watch')
        this.actionRow(card,$r('app.media.device_grid'),'终端',card.platformLabel==='Windows'?'普通终端、Codex':'','terminal')
        this.actionRow(card,$r('app.media.device_grid'),'更多','','more')
        if(card.category==='computer'&&card.platformLabel==='Windows'){PinnedApplications({deviceKey:card.key,deviceName:card.name,ready:this.ready(card),launch:(id:string,name:string)=>this.connect(card,'app-'+id,name)})}
        if(!card.connectable){UiSecondaryButton({label:'刷新设备状态',onAction:()=>this.refresh()})}
      }.width('100%').padding({bottom:24})}.layoutWeight(1).width('100%').id('deviceDetailsScroll').scrollBar(BarState.Off)
    }.width('100%').height('100%')
  }
  }
  @Builder
  moreTools(card:DeviceCard){
    Column({space:14}){
      Row(){Button('返回').height(48).backgroundColor(Color.Transparent).fontColor(UiColor.primary).onClick(()=>{this.clearNotice();this.actionEpoch++;this.navigating=false;this.confirming=false;this.closeDetailSession();this.moreOpen=false;});Text('更多').fontSize(22).fontColor(UiColor.text).layoutWeight(1);Button(this.orderEditing?'保存顺序':'调整顺序').height(48).backgroundColor(Color.Transparent).fontColor(UiColor.primary).enabled(!session.busy&&!session.isClosing&&!this.orderSaving).onClick(()=>{this.clearNotice();if(this.orderEditing){this.saveMoreOrder();}else{this.orderEditing=true;}})}.width('100%')
      Scroll(){Column({space:10}){
        if(this.message.length>0){UiNotice({text:this.message})}
        if(this.detailSessionKey===card.key){ForEach(this.detailSessionIds(),(id:number)=>{LiveDesktopPreview({deviceKey:this.detailSessionKey,deviceName:this.detailSessionName,lockToken:this.detailLockToken,onStopped:(message:string)=>this.detailSessionStopped(id,message)})},(id:number)=>id.toString())}
        ForEach(this.moreOrder,(tool:string)=>{
          if(this.orderEditing){
            Row({space:8}){Text(moreActionLabel(tool)).layoutWeight(1).fontSize(16).fontColor(UiColor.text);Button('上移').height(48).enabled(!this.orderSaving&&this.moreOrder.indexOf(tool)>0).onClick(()=>{this.moreOrder=moveMoreAction(this.moreOrder,tool,-1);});Button('下移').height(48).enabled(!this.orderSaving&&this.moreOrder.indexOf(tool)<this.moreOrder.length-1).onClick(()=>{this.moreOrder=moveMoreAction(this.moreOrder,tool,1);})}.width('100%').padding(12).backgroundColor(UiColor.surface).borderRadius(14)
          }else{this.actionRow(card,this.moreIcon(tool),moreActionLabel(tool),tool==='wake'?'此设备未报告可用的远程开机能力':'',tool)}
        },(tool:string)=>tool)
        if(!this.orderEditing){this.removeDeviceButton(card)}
      }.width('100%').padding({bottom:24})}.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }.width('100%').height('100%')
  }
  @Builder
  account(){
    Scroll(){
    Column({space:20}){
      Text('我的').fontSize(28).fontWeight(FontWeight.Bold).fontColor(UiColor.text).width('100%')
      Column({space:12}){
        Text('UU 账号').fontSize(20).fontWeight(FontWeight.Medium).fontColor(UiColor.text).width('100%')
        Text(this.view.accountLabel||'已登录').fontSize(16).fontColor(UiColor.secondary).width('100%').wordBreak(WordBreak.BREAK_ALL)
        UiSecondaryButton({label:'退出账号',onAction:()=>this.logout()})
      }.width('100%').padding(22).backgroundColor(UiColor.surface).borderRadius(20)
      Button({type:ButtonType.Normal}){
        Row({space:12}){Column({space:5}){Text('设置').fontSize(20).fontColor(UiColor.text).width('100%')}.layoutWeight(1);Text('›').fontSize(26).fontColor(UiColor.secondary)}.width('100%')
      }.id('openAppSettings').width('100%').padding(22).borderRadius(18).backgroundColor(UiColor.surface).onClick(()=>{this.getUIContext().getRouter().pushUrl({url:'pages/AppSettings'}).catch(()=>{});})
      Text('UUHarmony · 非官方客户端').fontSize(13).fontColor(UiColor.secondary)
      Blank()
    }.width('100%').height('100%')
    }.width('100%').height('100%').scrollBar(BarState.Off)
  }
  @Builder
  navigation(){
    LibraryTabs({compact:this.compact(),vertical:this.sideNavigation(),selected:this.accountOpen?'account':'devices',assistanceAvailable:!this.sharing&&!session.busy&&!session.isClosing,
      onSelect:(tab:string)=>this.selectLibraryTab(tab)})
  }
  private selectLibraryTab(tab:string):void{
    if(tab==='assistance'){
      if(this.sharing||session.busy||session.isClosing){return;}
      this.clearNotice();this.moreOpen=false;this.closeDetailSession();libraryTabState.selected='assistance';
      this.getUIContext().getRouter().replaceUrl({url:'pages/Assistance'}).catch(()=>{libraryTabState.selected=this.accountOpen?'account':'devices';this.message='暂时无法打开远程协助';});return;
    }
    this.closeDetailSession();libraryTabState.selected=tab==='account'?'account':'devices';this.accountOpen=tab==='account';this.detailOpen=false;
  }
  build(){
    Row({space:this.sideNavigation()?8:24}){
      if(!pcHost.supported&&this.sideNavigation()){this.navigation()}
      if(pcHost.supported&&this.windowWidth>=840){AppNavigation({selected:this.accountOpen?'account':'devices',wide:true,onSelect:(page:string)=>this.navigate(page)})}
      Column({space:12}){
        if(pcHost.supported&&this.windowWidth<840){AppNavigation({selected:this.accountOpen?'account':'devices',onSelect:(page:string)=>this.navigate(page)})}
        if(this.accountOpen){Column(){this.account()}.layoutWeight(1).width('100%')}
        else if(this.split()&&!this.allDevices){
          Row({space:24}){
            Column(){this.library()}.width(this.windowWidth>=1100?360:300).height('100%')
            Column(){
              if(this.detailOpen&&this.selected()){ForEach([this.selected()!],(card:DeviceCard)=>{this.details(card)},(card:DeviceCard)=>card.key)}
              else{Column({space:14}){Image($r('app.media.ui_computer')).width(64).height(64);Text('选择一台设备').fontSize(22).fontColor(UiColor.text);Text('查看详情，或连接后使用远程工具').fontSize(14).fontColor(UiColor.secondary).textAlign(TextAlign.Center)}.width('100%').height('100%').justifyContent(FlexAlign.Center)}
            }.layoutWeight(1).height('100%')
          }.layoutWeight(1).width('100%').alignItems(VerticalAlign.Top)
        }else if(this.detailOpen&&this.selected()){Column(){this.details(this.selected()!)}.layoutWeight(1).width('100%')}
        else if(this.allDevices){Column(){this.allDevicesPage()}.layoutWeight(1).width('100%')}
        else{Column(){this.library()}.layoutWeight(1).width('100%')}
        if(!pcHost.supported&&!this.sideNavigation()){this.navigation()}
      }.layoutWeight(1).height('100%')
    }.padding({left:this.compact()?10:18,right:this.compact()?10:18,top:this.safeTop+(this.compact()?4:12),bottom:this.safeBottom+(this.compact()?2:4)}).width('100%').height('100%').backgroundColor(UiColor.background)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],[LayoutSafeAreaEdge.TOP,LayoutSafeAreaEdge.BOTTOM])
      .expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
  }
}
