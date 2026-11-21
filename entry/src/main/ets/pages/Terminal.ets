import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { notebookWebString } from './TerminalNotebookModel';
import { RetainedTerminal,TerminalRetainedStore } from './TerminalRetainedStore';
import { session } from './SessionClient';
import { client } from './AuthClient';
import { RemoteRoute } from './RemoteRoute';
import { RemoteTerminalPanel } from './RemoteTerminalPanel';
import { UiColor } from './UiFoundation';
import { deviceCards, selectionMatches } from './DeviceListModel';
import { TerminalDrafts } from './TerminalDrafts';
import { windowPolicy } from './WindowPolicy';
import { TerminalItem, TerminalNames, terminalCanEnter, terminalCanKill } from './TerminalSessionModel';

interface TerminalReply {rawStreamEpoch?:string;phase?:string;output?:string;sent?:boolean;error?:string;session?:number;selectedToken?:number;sessions?:TerminalItem[];opening?:boolean;openQuarantined?:boolean;errorDetail?:string;listState?:string;killState?:string;killTarget?:number;}

interface TuiRoute extends RemoteRoute {agent?:string;}
interface TuiRaw {error?:string;gap?:boolean;base64?:string;nextCursor?:number;streamEpoch?:string;}
interface TuiWebState {rendered:number;pending:number;cols:number;rows:number;overflow:boolean;bracketedPaste?:boolean;appCursor?:boolean;}
interface TuiInput {text:string;}
interface TuiScreen {snapshot:string;cols:number;rows:number;}
class TuiMemory {cursor:number=0;epoch:string='';seq:number=0;pending:number=-1;snapshot:string='';cols:number=80;rows:number=24;failed:boolean=false;}
@Entry
@Component
struct Terminal {
  private agent:string='ordinary';
  private store:TerminalRetainedStore=new TerminalRetainedStore();
  private retained:RetainedTerminal[]=[];
  private managed:Map<number,TerminalItem>=new Map<number,TerminalItem>();
  private web:webview.WebviewController|undefined=undefined;
  private webReady:boolean=false;
  private webToken:number=-1;
  private serverEpoch:string='';
  private memories:Map<number,TuiMemory>=new Map<number,TuiMemory>();
  private inputTail:Promise<void>=Promise.resolve();
  private queuedInputs:number=0;
  @State private sending:boolean=false;
  @State private viewportReady:boolean=false;
  @State private viewportMounted:boolean=false;
  private codexHandled:boolean=false;
  private launchCodex:boolean=false;
  private trackingNew:boolean=false;
  private intentionalLeave:boolean=false;
  private keyboardMode:KeyboardAvoidMode|undefined=undefined;
  @State private list:boolean=true;
  @State private draft:string='';
  @State private output:string='';
  @State private status:string='正在建立独立终端连接…';
  @State private phase:string='connecting';
  @State private sessions:TerminalItem[]=[];
  @State private selectedSession:number=-1;
  @State private selectedToken:number=-1;
  @State private opening:boolean=false;
  @State private openQuarantined:boolean=false;
  @State private listState:string='';
  @State private killState:string='';
  @State private killTarget:number=-1;
  private drafts:TerminalDrafts=new TerminalDrafts();
  private names:TerminalNames=new TerminalNames();
  private refreshRequested:boolean=false;
  private pendingNavigation:boolean=false;
  private pendingSession:number=-1;
  private pendingAttach:number=-1;
  private pendingAttachToken:number=-1;
  @State private busy:boolean=false;
  @State private inputActive:boolean=false;
  @StorageLink('uuSafeTop') private safeTop:number=12;
  @StorageLink('uuSafeBottom') private safeBottom:number=12;
  private visible:boolean=false;
  private terminalSurfaceOwner:number=0;
  private opened:boolean=false;
  private joinAttempted:boolean=false;
  private storageReady:boolean=false;
  private polling:boolean=false;
  private timer:number=-1;
  private generation:number=0;
  private deviceKey:string='';
  private deviceName:string='';
  private started:number=0;
  private operation:number=0;
  private accountKey:string='';
  private accountLabel:string='';

  aboutToAppear():void {
    this.visible=true;
    const route=this.getUIContext().getRouter().getParams() as TuiRoute;
    if(!route||!route.confirmed||route.deviceKey!==session.selected||session.busy||session.isClosing){this.phase='failed';this.status='设备选择已变化，请返回设备列表。';return;}
    this.deviceKey=route.deviceKey;this.deviceName=session.deviceName;this.accountKey=client.view.wallpaperAccountKey||'';this.accountLabel=client.view.accountLabel;this.started=Date.now();
    this.agent=route.agent==='codex'?'codex':'ordinary';
    if(!this.accountKey||!this.deviceKey){this.phase='failed';this.status='账号或设备身份尚未确认，未连接终端。';return;}try{this.store.initialize(this.getUIContext().getHostContext() as common.UIAbilityContext,this.accountKey,this.deviceKey);this.retained=this.store.load();this.storageReady=true;}catch(_){this.phase='failed';this.status='会话保留存储不可用，未连接终端。';return;}
    this.generation=session.generation;
    this.timer=setInterval(()=>this.poll(),100);
  }
  aboutToDisappear():void {this.releaseSurface();this.visible=false;this.operation++;this.setLive(false);if(this.timer>=0){clearInterval(this.timer);this.timer=-1;}const generation=this.generation;const refs=this.sessions.filter((x:TerminalItem)=>x.attached);this.inputTail.then(async()=>{await this.store.save(this.retained);if(session.terminalOnly&&session.generation===generation&&session.selected===this.deviceKey){for(const item of refs){await session.terminalCommand({action:'detach',session:item.session,sessionToken:item.sessionToken},true,()=>session.terminalOnly&&session.generation===generation&&session.selected===this.deviceKey);}await session.cancel('user_disconnect');}}).catch(()=>{});}
  onPageShow():void {this.visible=true;try{this.keyboardMode=this.getUIContext().getKeyboardAvoidMode();this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);}catch(_){}if(!this.terminalSurfaceOwner){this.terminalSurfaceOwner=windowPolicy.acquireTerminalSurface();}this.inputActive=this.valid();}
  onPageHide():void {this.releaseSurface();this.visible=false;this.inputActive=false;}
  private releaseSurface():void {try{if(this.keyboardMode!==undefined){this.getUIContext().setKeyboardAvoidMode(this.keyboardMode);}}catch(_){}this.keyboardMode=undefined;const owner=this.terminalSurfaceOwner;this.terminalSurfaceOwner=0;if(owner){windowPolicy.releaseTerminalSurface(owner);}}
  onBackPress():boolean {if(!this.list){this.showList();return true;}this.leave();return true;}
  private sameAccount():boolean{return client.view.loggedIn&&(client.view.wallpaperAccountKey||'')===this.accountKey&&client.view.accountLabel===this.accountLabel;}
  private valid():boolean{return this.visible&&this.sameAccount()&&session.appForeground&&session.windowFocused&&session.terminalOnly&&session.busy&&!session.isClosing&&session.generation===this.generation&&session.selected===this.deviceKey;}
  private apply(raw:string):void {
    const value=JSON.parse(raw) as TerminalReply;
    if(value.error){if(value.error!=='terminal_channel_not_ready'){this.status='终端操作未完成，请检查会话状态。';}return;}
    if(value.killState==='confirmed'&&value.killTarget!==undefined&&(this.retained.some((r:RetainedTerminal)=>r.id===value.killTarget)||this.managed.has(value.killTarget))){this.retained=this.retained.filter((r:RetainedTerminal)=>r.id!==value.killTarget);this.managed.delete(value.killTarget);this.store.save(this.retained);}
    const incoming=value.sessions||[];
    for(const old of this.sessions){if(!incoming.some((item:TerminalItem)=>item.sessionToken===old.sessionToken)){this.drafts.forget(old.sessionToken);if(this.selectedToken===old.sessionToken){this.draft='';this.list=true;}}}
    for(const item of incoming){this.labelToken(item.sessionToken);}
    const next=value.session===undefined||value.session===null?-1:value.session;
    const nextToken=value.selectedToken===undefined||value.selectedToken===null?-1:value.selectedToken;
    if(next!==this.selectedSession||nextToken!==this.selectedToken){this.draft=this.drafts.switchTo(nextToken,this.draft);this.selectedSession=next;this.selectedToken=nextToken;}
    this.sessions=incoming;this.opening=!!value.opening;this.openQuarantined=!!value.openQuarantined;this.listState=value.listState||'';this.killState=value.killState||'';this.killTarget=value.killTarget===undefined||value.killTarget===null?-1:value.killTarget;
    this.phase=value.phase||'failed';if(this.phase==='open'){this.viewportMounted=true;}
    if(this.pendingNavigation&&!this.opening){if(this.phase==='open'&&this.selectedSession>=0&&(this.pendingSession<0||this.pendingSession===this.selectedSession)){this.list=false;}this.pendingNavigation=false;this.pendingSession=-1;}
    this.serverEpoch=value.rawStreamEpoch||'';
    this.status=this.openQuarantined?'新建结果不确定；请重新连接后再新建。':this.phase==='open'?'终端已连接 · 80×24':this.phase==='opening'?'正在打开终端…':this.phase==='exited'?'该终端已退出':this.phase==='available'?'点击会话以连接':this.phase==='failed'?'终端请求未完成':'选择或新建会话';
    if(this.killState==='pending'){this.status='正在请求终止会话…';}else if(this.killState==='confirmed'){this.status='电脑已确认终止会话。';}else if(this.killState==='unknown'){this.status='终止结果未知。';}else if(this.killState==='rejected'){this.status='电脑未确认终止会话。';}
  }
  private async poll():Promise<void> {
    this.inputActive=this.valid();
    if(!this.visible||this.polling||this.busy||this.queuedInputs>0){return;}
    if(!this.sameAccount()){if(session.terminalOnly&&session.generation===this.generation){await session.cancel('account_changed');}this.phase='failed';this.status='账号已退出，终端连接已结束。';return;}
    if(!this.joinAttempted){
      if(session.busy||session.isClosing||session.selected!==this.deviceKey||session.generation!==this.generation){this.phase='failed';this.status='连接状态已变化，请返回后重试。';return;}
      if(Date.now()-this.started>45000){this.phase='failed';this.status='页面未就绪，未发起终端连接；请返回后重试。';return;}
      if(!session.appForeground||!session.windowFocused){this.status='等待终端页面就绪…';return;}
      this.joinAttempted=true;session.joinTerminalConfirmed(this.deviceKey);this.generation=session.generation;
    }
    if(!session.busy&&!session.isClosing){this.viewportReady=false;this.setLive(false);if(this.phase!=='closed'&&this.phase!=='exited'){this.phase='failed';this.status='连接未建立或已中断；可返回设备列表选择普通远控。';}return;}
    if(!this.valid()){this.setLive(false);return;}
    if(this.pendingAttach>=0&&this.listState==='confirmed'&&!this.polling&&!this.busy){const id=this.pendingAttach;const token=this.pendingAttachToken;this.pendingAttach=-1;this.pendingAttachToken=-1;const item=this.sessions.find((entry:TerminalItem)=>entry.session===id&&entry.sessionToken===token&&entry.listed);if(item){this.attachConfirmed(item);}else{this.status='该会话已不在电脑列表中。';}return;}
    if(this.pendingAttach>=0&&(this.listState==='timeout'||this.listState==='unknown'||this.listState==='failed')){this.pendingAttach=-1;this.pendingAttachToken=-1;this.status='无法确认会话仍存在，未进入。';}
    if(this.refreshRequested&&!this.polling&&!this.busy&&this.listState!=='pending'){this.refreshRequested=false;this.refreshList();return;}
    if(!this.opened&&Date.now()-this.started>45000){this.phase='failed';this.status='终端通道超时；可返回设备列表选择普通远控。';await session.cancel('terminal_deadline');return;}
    this.polling=true;
    try{
      if(!this.opened){
        if(session.controlOpen&&session.controlEcho){this.opened=true;const raw=await session.terminalCommand({action:'list'},false,()=>this.valid());const value=JSON.parse(raw) as TerminalReply;if(value.error==='terminal_channel_not_ready'){this.opened=false;}if(!this.valid()){return;}if(value.error==='terminal_channel_not_ready'){if(Date.now()-this.started>45000){this.phase='failed';this.status='终端通道超时；可返回设备列表选择普通远控。';await session.cancel('terminal_deadline');}return;}this.opened=true;this.apply(raw);}
      }else{const raw=await session.terminalCommand({action:'status'},false,()=>this.valid());if(this.valid()){this.apply(raw);}}
      if(this.trackingNew&&this.phase==='open'){const item=this.sessions.find((r:TerminalItem)=>r.session===this.selectedSession);if(item){this.managed.set(item.session,item);if(item.createdAt){this.track(item);this.trackingNew=false;}else{this.refreshRequested=true;}}}
      if(this.agent==='codex'&&!this.codexHandled&&this.listState==='confirmed'){this.codexHandled=true;const entry=this.retained.find((r:RetainedTerminal)=>r.agent==='codex'&&this.sessions.some((x:TerminalItem)=>x.session===r.id&&x.createdAt===r.createdAt));this.polling=false;if(entry){const item=this.sessions.find((r:TerminalItem)=>r.session===entry.id);if(item){await this.choose(item);}}else{this.launchCodex=true;await this.createNow();}return;}
      await this.pump();
      if(this.launchCodex&&this.viewportReady&&this.phase==='open'&&!this.list){this.launchCodex=false;this.polling=false;await this.send('codex resume --all',true,false);}

    }catch(_){this.phase='failed';this.status='终端响应无法读取。';}finally{this.polling=false;}
  }
  private async send(text:string,line:boolean=false,clearDraft:boolean=false):Promise<void>{
    if(!this.valid()||this.list||!this.viewportReady||this.phase!=='open'||!text||this.queuedInputs>=32){return;}
    if(clearDraft&&this.sending){return;}if(clearDraft&&/[\r\n]/.test(text)){this.getUIContext().showAlertDialog({title:'发送多行内容？',message:'多行内容可能执行多条命令。请确认当前终端和内容。',primaryButton:{value:'取消',action:()=>{}},secondaryButton:{value:'发送',action:()=>this.sendConfirmed(text,line,true)}});return;}
    await this.sendConfirmed(text,line,clearDraft);
  }
  private async sendConfirmed(text:string,line:boolean,clearDraft:boolean):Promise<void>{
    const id=this.selectedSession,token=this.selectedToken,generation=this.generation;this.queuedInputs++;if(clearDraft){this.sending=true;}
    const next=this.inputTail.then(async()=>{for(let i=0;i<100&&this.polling;i++){await new Promise<void>((r:()=>void)=>setTimeout(r,10));}if(!this.valid()||this.polling||this.list||this.selectedSession!==id||this.selectedToken!==token||this.generation!==generation){return;}
      let payload=text;let paste=false;if(this.webReady&&this.web){const modes=JSON.parse(await this.webCall('window.uuTerminal.state()')) as TuiWebState;if(clearDraft&&modes.bracketedPaste){paste=true;payload='\u001b[200~'+text+'\u001b[201~';}else if(modes.appCursor&&/^\u001b\[[ABCD]$/.test(text)){payload=text.replace('[','O');}}
      const current=():boolean=>this.valid()&&this.selectedSession===id&&this.selectedToken===token&&this.generation===generation&&!this.list;
      let reply=JSON.parse(await session.terminalCommand({action:'write',session:id,sessionToken:token,text:payload+(line&&!clearDraft?'\r':'')},false,current)) as TerminalReply;
      // A distinct Enter event follows draft input, including shells that do not advertise bracketed paste.
      // This is one user submission, never a retry of uncertain terminal input.
      if(reply.sent&&clearDraft&&line){await new Promise<void>((r:()=>void)=>setTimeout(r,1200));if(!current()){this.status='内容已发送，页面状态变化，未追加回车；请核对终端。';return;}reply=JSON.parse(await session.terminalCommand({action:'write',session:id,sessionToken:token,text:'\r'},false,current)) as TerminalReply;}
      if(reply.sent){if(clearDraft&&this.draft===text){this.draft='';}}else{this.viewportReady=false;const memory=this.memories.get(token);if(memory){memory.failed=true;}this.status='输入结果未确认，未重发。请核对终端。';}
    }).catch(()=>{this.viewportReady=false;const memory=this.memories.get(token);if(memory){memory.failed=true;}this.status='输入发送失败，草稿保留；未自动重发。';});this.inputTail=next;try{await next;}finally{this.queuedInputs--;if(clearDraft){this.sending=false;}}
  }
  private async refreshList():Promise<void>{
    if(!this.valid()||this.busy||this.polling||this.listState==='pending'){return;}this.busy=true;
    try{const raw=await session.terminalCommand({action:'list'},false,()=>this.valid());if(this.valid()){this.apply(raw);}}finally{this.busy=false;}
  }
  private showList():void {this.drafts.remember(this.draft);this.list=true;this.setLive(false);this.refreshRequested=true;}
  private async choose(item:TerminalItem):Promise<void>{
    if(!this.valid()||this.busy||this.opening||!terminalCanEnter(item)){return;}
    const broken=this.memories.get(item.sessionToken);if(broken?.failed&&item.attached){if(!await this.acquireOperation()){return;}try{this.apply(await session.terminalCommand({action:'detach',session:item.session,sessionToken:item.sessionToken},false,()=>this.valid()));this.pendingAttach=item.session;this.pendingAttachToken=item.sessionToken;this.listState='';this.refreshRequested=true;}finally{this.busy=false;}return;}
    if(!item.attached){if(this.listState==='pending'||this.listState==='timeout'||this.listState==='unknown'){this.status='无法确认会话仍存在，请重新连接后重试。';return;}this.pendingAttach=item.session;this.pendingAttachToken=item.sessionToken;this.listState='';this.refreshRequested=true;return;}
    this.managed.set(item.session,item);this.track(item);if(!await this.acquireOperation()){return;}const id=item.session;try{this.drafts.remember(this.draft);const raw=await session.terminalCommand({action:'select',session:id,sessionToken:item.sessionToken},false,()=>this.valid()&&this.list);if(this.valid()){this.apply(raw);if(!(JSON.parse(raw) as TerminalReply).error){this.list=false;}}}finally{this.busy=false;}
  }
  private async attachConfirmed(item:TerminalItem):Promise<void>{
    if(!this.valid()||!this.list||this.busy||this.opening||!item.listed){return;}this.managed.set(item.session,item);this.track(item);this.busy=true;const id=item.session;const sessionToken=item.sessionToken;
    try{this.drafts.remember(this.draft);const raw=await session.terminalCommand({action:'attach',session:id,sessionToken:sessionToken,confirmed:true},false,()=>this.valid()&&this.list&&this.sessions.some((entry:TerminalItem)=>entry.session===id&&entry.sessionToken===sessionToken&&entry.listed));if(this.valid()){this.apply(raw);if(!(JSON.parse(raw) as TerminalReply).error){this.pendingNavigation=true;this.pendingSession=id;}}}finally{this.busy=false;}
  }
  private terminate(id:number):void {
    if(!this.valid()||this.busy||this.killState==='pending'){return;}const item=this.sessions.find((entry:TerminalItem)=>entry.session===id);if(!item||!terminalCanKill(item)){return;}
    const generation=this.generation;const key=this.deviceKey;const sessionToken=item.sessionToken;
    this.getUIContext().showAlertDialog({title:'终止这个终端会话？',message:this.labelToken(item.sessionToken)+'\n将向电脑发送终止请求，其他会话不受此操作影响。',primaryButton:{value:'取消',action:()=>{}},secondaryButton:{value:'终止会话',action:()=>{if(this.valid()&&generation===this.generation&&key===this.deviceKey&&this.sessions.some((entry:TerminalItem)=>entry.session===id&&entry.sessionToken===sessionToken&&entry.phase!=='exited'&&!entry.killUncertain)){this.kill(id,sessionToken);}}}});
  }
  private async kill(id:number,sessionToken:number):Promise<void>{
    if(!this.valid()||this.busy||this.killState==='pending'){return;}if(!await this.acquireOperation()){return;}const generation=this.generation;const token=this.operation;
    try{const raw=await session.terminalCommand({action:'kill',session:id,sessionToken:sessionToken,confirmed:true},false,()=>this.valid()&&this.sessions.some((entry:TerminalItem)=>entry.session===id&&entry.sessionToken===sessionToken&&!entry.killUncertain));if(this.visible&&token===this.operation&&generation===session.generation&&session.selected===this.deviceKey){this.apply(raw);const reply=JSON.parse(raw) as TerminalReply;if(reply.killState==='confirmed'){this.retained=this.retained.filter((r:RetainedTerminal)=>r.id!==id);await this.store.save(this.retained);this.managed.delete(id);}}}finally{this.busy=false;}
  }
  private canTransition():boolean{return this.visible&&this.deviceKey.length>0&&this.sameAccount()&&session.appForeground&&session.windowFocused&&!this.busy&&this.queuedInputs===0&&!session.isClosing&&((session.terminalOnly&&session.generation===this.generation&&session.selected===this.deviceKey)||(!session.busy&&(session.generation===this.generation||session.generation===this.generation+1)));}
  private desktop():void {
    if(!this.canTransition()){return;}const generation=session.generation;const key=this.deviceKey;
    this.getUIContext().showAlertDialog({title:'进入远程画面？',message:'将保留终端会话并切换到远程画面。',primaryButton:{value:'取消',action:()=>{}},secondaryButton:{value:'进入画面',action:()=>{if(this.canTransition()&&generation===session.generation&&key===this.deviceKey){this.switchDesktop();}}}});
  }
  private async switchDesktop():Promise<void>{
    if(!this.canTransition()){return;}this.busy=true;const key=this.deviceKey;const name=this.deviceName;const token=++this.operation;const generation=session.generation;const owned=session.terminalOnly&&session.busy&&generation===this.generation;
    try{
      if(owned){if(!await this.preserve()){return;}await this.detachAll(generation);if(!this.visible||token!==this.operation||session.generation!==generation){return;}await session.cancel('user_disconnect');}
      const after=session.generation;if(after!==generation+(owned?1:0)||!this.visible||token!==this.operation||!this.sameAccount()||!session.appForeground||!session.windowFocused||session.busy||session.isClosing){return;}
      const refreshed=await client.refreshDevices(true);if(!this.visible||token!==this.operation||session.generation!==after||!this.sameAccount()||!session.appForeground||!session.windowFocused||!refreshed||!selectionMatches(deviceCards(client.view.devices,false),key,name)){this.status='设备状态已变化，请返回设备列表。';return;}
      if(!await session.select(key,name,()=>this.visible&&token===this.operation&&session.generation===after&&this.sameAccount()&&session.appForeground&&session.windowFocused)){this.status='设备状态已变化，请返回设备列表。';return;}
      if(!this.visible||token!==this.operation||session.generation!==after||session.selected!==key){return;}const route:RemoteRoute={deviceKey:key,confirmed:true};await this.getUIContext().getRouter().replaceUrl({url:'pages/RemoteDesktop',params:route});
    }finally{this.busy=false;}
  }
  private requestCreate():void {
    if(!this.canTransition()||this.opening||this.openQuarantined){return;}const generation=session.generation;
    this.getUIContext().showAlertDialog({title:'新建终端会话？',message:this.deviceName+'\n将创建一个新的终端会话。',primaryButton:{value:'取消',action:()=>{}},secondaryButton:{value:'新建',action:()=>{if(this.canTransition()&&session.generation===generation){this.createNow();}}}});
  }
  private async createNow():Promise<void>{
    if(!this.canTransition()||this.opening||this.openQuarantined){return;}
    if(!this.valid()){this.status='连接已中断，请返回设备列表后重新连接。';return;}
    if(!await this.acquireOperation()){return;}try{this.drafts.remember(this.draft);const raw=await session.terminalCommand({action:'open',confirmed:true},false,()=>this.valid());if(this.valid()){this.apply(raw);if(!(JSON.parse(raw) as TerminalReply).error){this.trackingNew=true;this.pendingNavigation=true;this.pendingSession=-1;}}}finally{this.busy=false;}
  }
  private async detachAll(generation:number):Promise<void>{
    const attached=this.sessions.filter((item:TerminalItem)=>item.attached);
    for(const item of attached){if(!this.valid()||generation!==session.generation){return;}await session.terminalCommand({action:'detach',session:item.session,sessionToken:item.sessionToken},false,()=>this.valid()&&generation===session.generation);}
  }
  private leave():void {
    if(!this.visible||this.busy||this.queuedInputs>0){return;}
    if(!this.storageReady){this.getUIContext().getRouter().back();return;}
    const names=this.retained.filter((r:RetainedTerminal)=>r.agent===this.agent).map((r:RetainedTerminal)=>r.name).join('、');this.getUIContext().showAlertDialog({title:'退出终端',message:'保留：电脑会话继续，列表保留。关闭并清空仅结束本页打开或本模式保留的会话：'+(names||'本页已打开的会话')+'。其他会话不处理。',buttons:[{value:'保留并退出',action:()=>this.keepAndLeave()},{value:'关闭并清空',action:()=>this.closeAndLeave()},{value:'取消',action:()=>{}}]});
  }
  private async keepAndLeave():Promise<void>{if(!await this.preserve()){return;}await this.leaveNow();}
  private async confirmedList():Promise<boolean>{
    if(!this.valid()){return false;}
    try{let value=JSON.parse(await session.terminalCommand({action:'list'},false,()=>this.valid())) as TerminalReply;if(value.error){this.status='未能核实电脑会话。';return false;}this.apply(JSON.stringify(value));
      for(let i=0;i<100&&value.listState==='pending';i++){await new Promise<void>((r:()=>void)=>setTimeout(r,50));if(!this.valid()){return false;}value=JSON.parse(await session.terminalCommand({action:'status'},false,()=>this.valid())) as TerminalReply;if(value.error){return false;}this.apply(JSON.stringify(value));}
      return this.valid()&&value.listState==='confirmed';
    }catch(_){this.status='未能读取电脑会话状态。';return false;}
  }
  private async closeAndLeave():Promise<void>{
    if(!this.canTransition()){return;}if(!this.valid()){this.offerLocalClear();return;}if(!await this.acquireOperation()){return;}
    try{if(!await this.confirmedList()){this.busy=false;this.offerLocalClear();return;}
      const targets=this.sessions.filter((x:TerminalItem)=>x.listed&&(this.retained.some((r:RetainedTerminal)=>r.agent===this.agent&&r.id===x.session&&r.createdAt===x.createdAt)||this.managed.get(x.session)?.sessionToken===x.sessionToken));
      for(const target of targets){let value=JSON.parse(await session.terminalCommand({action:'kill',session:target.session,sessionToken:target.sessionToken,confirmed:true},false,()=>this.valid())) as TerminalReply;
        for(let i=0;i<100&&!value.error&&value.killState==='pending'&&value.killTarget===target.session;i++){await new Promise<void>((r:()=>void)=>setTimeout(r,50));if(!this.valid()){break;}value=JSON.parse(await session.terminalCommand({action:'status'},false,()=>this.valid())) as TerminalReply;}
        this.apply(JSON.stringify(value));
        if(value.error||value.killState!=='confirmed'||value.killTarget!==target.session){
          // The PC may have closed the window between LIST and KILL. Revalidate
          // absence; never retry KILL or target a recycled ID.
          if(!await this.confirmedList()||this.sessions.some((x:TerminalItem)=>x.listed&&x.session===target.session&&x.createdAt===target.createdAt)){this.status='未确认电脑会话已结束；手机记录仍保留。';this.busy=false;this.offerLocalClear();return;}
        }
        this.retained=this.retained.filter((r:RetainedTerminal)=>r.id!==target.session||r.createdAt!==target.createdAt);this.managed.delete(target.session);
      }
      this.retained=this.retained.filter((r:RetainedTerminal)=>r.agent!==this.agent||this.sessions.some((x:TerminalItem)=>x.listed&&x.session===r.id&&x.createdAt===r.createdAt));
      if(!await this.store.save(this.retained)){this.status='电脑会话已处理，但手机记录清理失败；请重试。';return;}this.clearTransient();this.busy=false;await this.leaveNow();
    }catch(_){this.status='未能确认电脑会话已结束；手机记录仍保留。';this.busy=false;this.offerLocalClear();}finally{this.busy=false;}
  }
  private clearTransient():void {this.trackingNew=false;this.launchCodex=false;this.pendingNavigation=false;this.pendingSession=-1;this.draft='';this.drafts=new TerminalDrafts();this.memories.clear();this.managed.clear();this.pendingAttach=-1;this.pendingAttachToken=-1;this.viewportReady=false;this.setLive(false);}
  private offerLocalClear():void {
    if(!this.canTransition()){return;}const generation=session.generation;
    this.getUIContext().showAlertDialog({title:'无法确认电脑会话状态',message:'可以仅清空手机本模式的会话记录并退出。这不会终止电脑上可能仍在运行的任务。',primaryButton:{value:'取消',action:()=>{}},secondaryButton:{value:'仅清空手机记录并退出',action:()=>{if(this.canTransition()&&session.generation===generation){this.clearLocalAndLeave();}}}});
  }
  private async clearLocalAndLeave():Promise<void>{
    if(!this.canTransition()){return;}this.busy=true;
    try{const remaining=this.retained.filter((r:RetainedTerminal)=>r.agent!==this.agent&&!Array.from(this.managed.values()).some((x:TerminalItem)=>x.session===r.id&&x.createdAt===r.createdAt));if(!await this.store.save(remaining)){this.status='手机记录清理失败，请重试。';return;}this.retained=remaining;this.clearTransient();this.busy=false;await this.leaveNow();}finally{this.busy=false;}
  }
  private async leaveNow():Promise<void>{const priorBusy=this.busy;this.busy=true;try{const token=++this.operation;const generation=session.generation;if(session.terminalOnly&&generation===this.generation){await this.detachAll(generation);if(!this.visible||token!==this.operation||session.generation!==generation){return;}await session.cancel('user_disconnect');}if(this.visible&&token===this.operation&&!session.busy&&!session.isClosing&&(session.generation===generation||session.generation===generation+1)){this.getUIContext().getRouter().back();}}finally{this.busy=priorBusy;}}
  private async acquireOperation():Promise<boolean>{if(this.busy||this.queuedInputs>0){return false;}this.busy=true;for(let i=0;i<100&&this.polling;i++){await new Promise<void>((r:()=>void)=>setTimeout(r,10));}if(this.polling||!this.valid()){this.busy=false;return false;}return true;}
  private labelToken(token:number):string {const item=this.sessions.find((r:TerminalItem)=>r.sessionToken===token);return item?((this.agent==='codex'?'Codex · ':'')+(item.name||'终端 '+item.session.toString())):'终端';}
  private displaySessions():TerminalItem[]{if(this.agent!=='codex'){return this.sessions;}return this.sessions.filter((x:TerminalItem)=>this.managed.has(x.session)||this.retained.some((r:RetainedTerminal)=>r.agent==='codex'&&r.id===x.session&&r.createdAt===x.createdAt));}
  private track(item:TerminalItem):void {if(!item.createdAt){return;}const old=this.retained.find((r:RetainedTerminal)=>r.id===item.session&&r.createdAt===item.createdAt);const row:RetainedTerminal={id:item.session,createdAt:item.createdAt,name:item.name||'终端',agent:old?.agent||this.agent};this.retained=[row,...this.retained.filter((r:RetainedTerminal)=>r.id!==item.session)];this.store.save(this.retained);}
  private async preserve():Promise<boolean>{
    const priorBusy=this.busy;this.busy=true;
    try{for(let i=0;i<100&&this.polling;i++){await new Promise<void>((r:()=>void)=>setTimeout(r,10));}if(this.polling||this.queuedInputs>0){this.status='正在处理终端，请稍后退出。';return false;}
      if(this.valid()){let value=JSON.parse(await session.terminalCommand({action:'list'},false,()=>this.valid())) as TerminalReply;this.apply(JSON.stringify(value));for(let i=0;i<100&&value.listState==='pending';i++){await new Promise<void>((r:()=>void)=>setTimeout(r,50));value=JSON.parse(await session.terminalCommand({action:'status'},false,()=>this.valid())) as TerminalReply;this.apply(JSON.stringify(value));}if(value.listState!=='confirmed'){this.status='未确认电脑列表，暂未退出。';return false;}
        for(const id of this.managed.keys()){const item=this.sessions.find((x:TerminalItem)=>x.session===id);if(item){if(!item.createdAt){this.status='电脑未提供可核实的会话创建身份，暂未退出。';return false;}this.track(item);}}
      }
      if(!await this.store.save(this.retained)){this.status='会话保留信息保存失败，暂未退出。';return false;}return true;
    }finally{this.busy=priorBusy;}
  }
  private setLive(value:boolean):void {if(this.webReady&&this.web){this.web.runJavaScript('window.uuTerminal.setLive('+value+')').catch(()=>{});}}
  private async webCall(code:string):Promise<string>{if(!this.webReady||!this.web){throw new Error('terminal_web_not_ready');}return notebookWebString(await this.web.runJavaScript(code));}
  private async pump():Promise<void>{
    if(!this.webReady||!this.web||this.phase!=='open'||this.selectedSession<0||!this.serverEpoch){this.viewportReady=false;return;}
    const token=this.selectedToken,id=this.selectedSession;let memory=this.memories.get(token);
    if(!memory||memory.epoch!==this.serverEpoch){memory=new TuiMemory();memory.epoch=this.serverEpoch;this.memories.set(token,memory);if(this.webToken===token){this.webToken=-1;}}
    if(memory.failed){this.viewportReady=false;return;}
    if(this.webToken!==token){this.viewportReady=false;const old=this.memories.get(this.webToken);if(old){const state=JSON.parse(await this.webCall('window.uuTerminal.state()')) as TuiWebState;if(state.pending>0){return;}if(old.pending>=0){old.cursor=old.pending;old.pending=-1;}const screen=JSON.parse(await this.webCall('window.uuTerminal.snapshot()')) as TuiScreen;old.snapshot=screen.snapshot;old.cols=screen.cols;old.rows=screen.rows;}
      await this.webCall('window.uuTerminal.open('+JSON.stringify(memory.snapshot)+','+memory.cols+','+memory.rows+','+JSON.stringify(this.agent)+')');memory.seq=0;memory.pending=-1;this.webToken=token;await this.webCall('window.uuTerminal.setLive(true)');
    }
    const state=JSON.parse(await this.webCall('window.uuTerminal.state()')) as TuiWebState;
    if(state.overflow){throw new Error('terminal_keyboard_overflow');}if(memory.pending>=0){if(state.rendered!==memory.seq){return;}memory.cursor=memory.pending;memory.pending=-1;}
    if(state.pending>0){return;}await this.webCall('window.uuTerminal.setLive(true)');this.viewportReady=true;
    const input=JSON.parse(await this.webCall('window.uuTerminal.takeInput()')) as TuiInput;
    if(input.text){if(!this.list){this.polling=false;await this.send(input.text);this.polling=true;}else if(/^(\u001b\[[0-9;?]*[Rcn])+$/.test(input.text)){await session.terminalCommand({action:'write',session:id,sessionToken:token,text:input.text},false,()=>this.valid()&&this.selectedToken===token);}}
    if(!this.list&&(state.cols!==memory.cols||state.rows!==memory.rows)){const resized=JSON.parse(await session.terminalCommand({action:'resize',session:id,sessionToken:token,cols:state.cols,rows:state.rows},false,()=>this.valid()&&this.selectedToken===token)) as TerminalReply;if(resized.error){throw new Error('terminal_resize_failed');}memory.cols=state.cols;memory.rows=state.rows;}
    const raw=JSON.parse(await session.terminalCommand({action:'raw_read',session:id,sessionToken:token,streamEpoch:memory.epoch,cursor:memory.cursor,limit:16384},false,()=>this.valid()&&this.selectedToken===token)) as TuiRaw;
    if(raw.error||raw.gap||raw.streamEpoch!==memory.epoch||raw.nextCursor===undefined){memory.failed=true;this.viewportReady=false;this.setLive(false);this.status='终端数据存在缺口或代次变化，输入已暂停；请返回列表重新连接，旧屏不是实时状态。';return;}
    if(raw.nextCursor>memory.cursor){memory.seq++;if(await this.webCall('window.uuTerminal.feed('+JSON.stringify(raw.base64||'')+','+memory.seq+')')!=='true'){throw new Error('terminal_render_failed');}memory.pending=raw.nextCursor;}
  }

  build(){
    Column(){
      Stack({alignContent:Alignment.Center}){
        Text(this.list?'Sessions':(this.selectedToken>=0?this.labelToken(this.selectedToken):'Terminal')).fontColor('#20242A').fontSize(17).fontWeight(FontWeight.Medium).maxLines(1).width('calc(100% - 192vp)').textOverflow({overflow:TextOverflow.Ellipsis})
        Row(){
          Button({type:ButtonType.Normal}){Image($r('app.media.terminal_back')).width(22).height(22)}.width(44).height(44).backgroundColor(Color.Transparent).id('terminalBack').accessibilityText(this.list?'退出终端':'返回会话列表').onClick(()=>{if(this.list){this.leave();}else{this.showList();}})
          Blank()
          if(this.list){
            Button('+').width(44).height(44).fontSize(27).fontColor('#20242A').backgroundColor(Color.Transparent).id('terminalCreate').accessibilityText('新建会话').enabled(this.inputActive&&!this.busy&&!this.opening&&!this.openQuarantined).onClick(()=>this.requestCreate())
          }else{
            Button({type:ButtonType.Normal}){Image($r('app.media.terminal_desktop')).width(22).height(22)}.width(44).height(44).backgroundColor(Color.Transparent).id('terminalDesktop').accessibilityText('进入远程画面').enabled(this.canTransition()).onClick(()=>this.desktop())
            Button({type:ButtonType.Normal}){Image($r('app.media.terminal_more')).width(22).height(22)}.width(44).height(44).backgroundColor(Color.Transparent).id('terminalMore').accessibilityText('终止当前会话').enabled(this.inputActive&&this.selectedSession>=0&&!this.busy).onClick(()=>this.terminate(this.selectedSession))
          }
        }.width('100%')
      }.width('100%').height(44).margin({top:this.safeTop+4}).padding({left:8,right:8})
      if(this.list){
        Column({space:8}){
          if(this.status.includes('未知')||this.status.includes('未确认')||this.openQuarantined||this.phase==='failed'||!this.inputActive){Text(this.status).fontColor('#626B76').fontSize(12).width('100%').padding({left:6,right:6})}
          if(this.listState==='pending'){Text('正在获取会话…').fontColor('#626B76').fontSize(12).width('100%')}
          if(this.listState==='failed'||this.listState==='timeout'||this.listState==='unknown'){Text('会话列表未确认，可重新连接后刷新。').fontColor('#626B76').fontSize(12).width('100%')}
          Scroll(){Column({space:8}){ForEach(this.displaySessions(),(item:TerminalItem)=>{
            Row(){
              Button({type:ButtonType.Normal}){Row(){Text(this.labelToken(item.sessionToken)).fontColor('#20242A').fontSize(16).layoutWeight(1).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis});if(item.killUncertain){Text('状态未知').fontColor('#626B76').fontSize(11)}}.width('100%')}
                .layoutWeight(1).height(56).padding({left:16,right:8}).backgroundColor(Color.Transparent).accessibilityText('进入 '+this.labelToken(item.sessionToken)).enabled(this.inputActive&&!this.busy&&terminalCanEnter(item)).onClick(()=>this.choose(item))
              Button({type:ButtonType.Normal}){Image($r('app.media.terminal_more')).width(20).height(20)}.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('终止 '+this.labelToken(item.sessionToken)).enabled(this.inputActive&&!this.busy&&terminalCanKill(item)).onClick(()=>this.terminate(item.session))
            }.width('100%').height(56).backgroundColor('#F2F4F7').borderRadius(12)
          },(item:TerminalItem)=>item.sessionToken.toString())}}.width('100%').layoutWeight(1).align(Alignment.TopStart)
        }.width('100%').layoutWeight(1).padding({left:12,right:12,top:16})
      }
      if(this.viewportMounted){
        RemoteTerminalPanel({standalone:true,draft:$draft,output:this.output,status:this.status,ready:this.viewportReady&&this.phase==='open'&&this.inputActive&&this.sessions.some((item:TerminalItem)=>item.session===this.selectedSession&&!item.killPending&&!item.killUncertain),busy:this.busy,sending:this.sending,onTerminalReady:(controller:webview.WebviewController)=>{this.web=controller;this.webReady=true;this.webToken=-1;},onSend:(text:string,line:boolean)=>this.send(text,line,true),onKey:(text:string)=>this.send(text),onClose:()=>{this.showList();}}).layoutWeight(1).visibility(this.list?Visibility.None:Visibility.Visible)
      }
    }.width('100%').height('100%').padding({bottom:this.safeBottom}).backgroundColor('#FFFFFF').expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
  }
}
