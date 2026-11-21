import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { session } from './SessionClient';
import { client } from './AuthClient';
import { PickerResumeIntent, canResumePickerSession } from './PickerFileSessionModel';
import { AdvancedCommand } from './AdvancedClient';
import { RemoteFiles, FilesStatus, FilesCommand, FileEntry } from './RemoteFiles';
import { UploadListRequest, uploadListingMatches } from './FilesDestinationModel';
import { windowPolicy } from './WindowPolicy';
import { UiPalette, uiPalette } from './UiFoundation';
import { UiThemeDialog, UiDialogOptions } from './UiThemeDialog';
interface FileTransferRoute {deviceKey:string;deviceName?:string;confirmed:boolean;}
@Component
export struct SharedFileTransfer {
  @Prop borrowed:boolean=false;
  private colors():UiPalette{return uiPalette(this.borrowed);}
  private dialogOptions:UiDialogOptions={title:'',message:''};
  private dialog:CustomDialogController=new CustomDialogController({builder:UiThemeDialog({dark:this.borrowed,options:this.dialogOptions}),customStyle:true,cancel:()=>this.dialogOptions.cancel?.()});
  private showDialog(options:UiDialogOptions):void{this.dialogOptions=options;this.dialog.open();}
  @Prop embeddedName:string='远程文件';
  onClose:()=>void=()=>{};
  @StorageLink('uuSafeTop') private safeTop:number=12;
  @StorageLink('uuSafeBottom') private safeBottom:number=12;
  @State private targetName:string='电脑文件传输';
  @State private connected:boolean=false;
  @State private connectionFailed:boolean=false;
  @State private notice:string='';
  @State private message:string='正在建立安全文件连接…';
  @State private directory:string='';
  @State private entries:FileEntry[]=[];
  @State private sortedEntries:FileEntry[]=[];
  @State private sortKey:string='name';
  @State private sortAscending:boolean=true;
  private directoryScroller:Scroller=new Scroller();
  private sortStore:preferences.Preferences|undefined=undefined;
  private sortWrite:Promise<void>=Promise.resolve();
  private lastListIdentity:string='';
  @State private progress:number=0;
  @State private transfer:string='';
  @State private transferring:boolean=false;
  @State private listing:boolean=false;
  @State private requiresReconnect:boolean=false;
  @State private choiceDirectory:string='';
  @State private hasChoice:boolean=false;
  @State private choiceName:string='';
  @State private saved:string='';
  @State private sent:string[]=[];
  @State private received:string[]=[];
  @State private group:number=0;
  @Link browsing:boolean;
  @State private choosingUpload:boolean=false;
  @State private uploadDirectory:string='';
  private explicitUploadDirectory:boolean=false;private pendingUpload:UploadListRequest|undefined=undefined;
  private lastTask:string='';private deviceKey:string='';private pickerPending:boolean=false;private pickerResume:PickerResumeIntent|undefined=undefined;private resumingPicker:boolean=false;
  private live:boolean=false;private pageEpoch:number=0;private sessionEpoch:number=-1;
  private timer:number=-1;
  private off:()=>void=()=>{};
  private folders:string[]=[];private requestedDirectory:string='';private lastMetadataAt:number=0;
  private files:RemoteFiles=new RemoteFiles((command:FilesCommand)=>{const request:AdvancedCommand={op:command.op,event:command.event};if(this.borrowed&&(session.generation!==this.sessionEpoch||session.selected!==this.deviceKey||!session.busy||!session.appForeground)){return Promise.resolve('{"error":"session_changed"}');}return this.borrowed?session.advancedCommand(request):session.filesCommand(request);});
  aboutToAppear():void {
    this.live=true;this.pageEpoch++;this.loadSort();if(!this.borrowed){windowPolicy.applyRemote(false);}
    this.files.setContext(this.getUIContext().getHostContext() as common.UIAbilityContext);this.files.setForeground(true);
    this.files.observe((state:FilesStatus,text:string)=>{
      if(!this.live){return;}this.directory=state.directory;this.entries=state.entries.slice();this.sortEntries();const identity=state.generation+':'+state.task+':'+state.directory;if(state.mode==='list'&&identity!==this.lastListIdentity){this.lastListIdentity=identity;this.resetDirectoryScroll();}if(!this.explicitUploadDirectory&&state.remoteDownloadPath){this.uploadDirectory=state.remoteDownloadPath;}
      const pending=this.pendingUpload;
      if(pending&&uploadListingMatches(state,pending)){this.pendingUpload=undefined;setTimeout(()=>{if(this.live){this.files.setUploadDirectory(state.directory);}},0);}
      this.requiresReconnect=!!state.requiresReconnect;this.choiceDirectory=this.files.choice?.directory||'';
      if(['failed','canceled','disconnected'].includes(state.state)){this.pendingUpload=undefined;}
      this.listing=state.mode==='list'&&!['idle','complete','failed','canceled','disconnected'].includes(state.state);
      this.message=text;this.notice=state.state==='failed'||text.includes('已中断')||text.includes('未完成')||text.includes('需要重新连接')||text.includes('未覆盖')?text:state.state==='canceled'?'已取消传输':'';
      this.hasChoice=this.files.choice!==undefined;this.choiceName=this.files.choice?.name||'';this.saved=this.files.savedDownloadName;
      this.progress=state.total>0?Math.min(100,state.transferred/state.total*100):0;
      this.transferring=state.mode!=='list'&&!['idle','complete','failed','canceled','disconnected'].includes(state.state);
      this.transfer=state.name?state.name+' · '+this.bytes(state.transferred)+' / '+this.bytes(state.total):'';
      const key=state.generation+':'+state.task;
      if(state.mode!=='list'&&state.name&&state.state==='complete'&&key!==this.lastTask){
        this.lastTask=key;
        if(state.mode==='upload'){this.sent=[state.name+' · '+this.bytes(state.total),...this.sent].slice(0,30);}
        if(state.mode==='download'&&state.localSaved){this.received=[state.name+' · '+this.bytes(state.total),...this.received].slice(0,30);}
      }
    });
    if(this.borrowed){this.startBorrowed();}else{this.off=session.observe((text:string)=>{if(this.live&&!this.connected){this.message=text;}});this.start();}
  }
  private startBorrowed():void{
    this.targetName=this.embeddedName;this.sessionEpoch=session.generation;this.deviceKey=session.selected;
    this.timer=setInterval(()=>{if(!this.live){return;}const ready=session.generation===this.sessionEpoch&&session.busy&&!session.filesOnly&&session.filesReady&&session.appForeground;
      if(ready&&!this.connected){this.connected=true;this.connectionFailed=false;this.loadConnected();}
      else if(!ready&&this.connected&&!this.pickerPending){this.connected=false;this.connectionFailed=true;this.files.connectionLost();}
      else if(!ready&&!session.busy){this.connectionFailed=true;this.message='远程会话已断开，请返回后重新连接';}
      if(this.connected&&!this.transferring&&!this.listing&&Date.now()-this.lastMetadataAt>1500){this.lastMetadataAt=Date.now();this.files.refresh();}
    },250);
  }
  private loadSort():void{
    try{this.sortStore=preferences.getPreferencesSync(this.getUIContext().getHostContext()!,{name:'remote_files_sort_v1'});const key=this.sortStore.getSync('key','name');const ascending=this.sortStore.getSync('ascending',true);if(typeof key==='string'&&['name','type','size','modified'].includes(key)){this.sortKey=key;}if(typeof ascending==='boolean'){this.sortAscending=ascending;}}catch(_){}
  }
  private saveSort():void{const key=this.sortKey;const ascending=this.sortAscending;this.sortWrite=this.sortWrite.then(async()=>{try{const store=this.sortStore;if(store){store.putSync('key',key);store.putSync('ascending',ascending);await store.flush();}}catch(_){}});}
  private resetDirectoryScroll():void{this.directoryScroller.scrollTo({xOffset:0,yOffset:0});}
  private chooseSort(key:string):void{if(this.sortKey===key){this.sortAscending=!this.sortAscending;}else{this.sortKey=key;this.sortAscending=true;}this.sortEntries();this.resetDirectoryScroll();this.saveSort();}
  private natural(a:string,b:string):number{
    const aa=a.match(/\d+|\D+/g)||[];const bb=b.match(/\d+|\D+/g)||[];
    for(let i=0;i<Math.min(aa.length,bb.length);i++){const x=aa[i];const y=bb[i];const digits=/^\d+$/.test(x)&&/^\d+$/.test(y);let cmp:number=0;
      if(digits){const nx=x.replace(/^0+/,'')||'0';const ny=y.replace(/^0+/,'')||'0';cmp=nx.length-ny.length||(nx<ny?-1:nx>ny?1:0);}else{cmp=x.localeCompare(y,'zh-CN');}if(cmp!==0){return cmp;}
    }return aa.length-bb.length;
  }
  private fileType(entry:FileEntry):string{if(entry.kind!==4&&entry.kind!==5){return '';}const dot=entry.name.lastIndexOf('.');return dot>0?entry.name.substring(dot+1).toLowerCase():'';}
  private sortEntries():void{const key=this.sortKey;const direction=this.sortAscending?1:-1;this.sortedEntries=this.entries.slice().sort((a:FileEntry,b:FileEntry):number=>{
    const ad=a.kind!==4&&a.kind!==5;const bd=b.kind!==4&&b.kind!==5;if(ad!==bd){return ad?-1:1;}let result:number=0;
    if(key==='type'){result=this.natural(this.fileType(a),this.fileType(b));}else if(key==='size'){result=a.size-b.size;}else if(key==='modified'){result=a.modified-b.modified;}else{result=this.natural(a.name,b.name);}
    if(result!==0){return direction*result;}const byName=this.natural(a.name,b.name);if(byName!==0){return byName;}return a.path<b.path?-1:a.path>b.path?1:0;
  });}
  @Builder private sortOption(label:string,key:string){Button(label+(this.sortKey===key?(this.sortAscending?' ↑':' ↓'):'')).fontSize(12).fontColor(this.sortKey===key?this.colors().onPrimary:this.colors().text).backgroundColor(this.sortKey===key?this.colors().primary:this.colors().surface).onClick(()=>this.chooseSort(key))}
  private bytes(value:number):string{return value>=1048576?(value/1048576).toFixed(1)+' MB':value>=1024?(value/1024).toFixed(1)+' KB':value+' B';}
  private async start():Promise<void>{
    const run=this.pageEpoch;const params=this.getUIContext().getRouter().getParams() as FileTransferRoute;
    this.targetName=params?.deviceName||'电脑文件传输';this.deviceKey=params?.deviceKey||'';
    if(!params||!params.confirmed||!params.deviceKey){this.message='请从设备详情打开文件传输';return;}
    if(!await session.select(params.deviceKey,params.deviceName||'',()=>this.live&&this.pageEpoch===run)){if(this.live&&run===this.pageEpoch){this.message='设备不可用或其他会话尚未结束';this.connectionFailed=true;}return;}
    if(!this.live||run!==this.pageEpoch){return;}session.joinFilesConfirmed(params.deviceKey);this.sessionEpoch=session.generation;
    this.timer=setInterval(()=>{if(!this.live){return;}if(this.pickerResume&&!this.pickerPending&&!this.resumingPicker&&this.resumeAllowed(this.pickerResume)){this.resumePicker(this.pickerResume);}if(session.filesReady&&session.filesOnly&&!this.connected){this.connected=true;this.connectionFailed=false;this.loadConnected();}else if(this.connected&&!session.busy){this.connected=false;this.connectionFailed=true;if(!this.pickerPending){this.files.connectionLost();}}else if(!this.connected&&!session.busy&&!session.isClosing){this.connectionFailed=true;}else if(this.connected&&!this.transferring&&!this.listing&&Date.now()-this.lastMetadataAt>1500){this.lastMetadataAt=Date.now();this.files.refresh();}},250);
  }
  aboutToDisappear():void{this.dialog.close();this.live=false;this.pageEpoch++;this.pickerResume=undefined;this.off();if(this.timer>=0){clearInterval(this.timer);}if(this.borrowed){this.releaseBorrowed();}else{this.files.dispose();if(session.filesOnly&&session.generation===this.sessionEpoch){session.cancel('user_disconnect');}}}
  private async releaseBorrowed():Promise<void>{if(session.generation===this.sessionEpoch&&session.selected===this.deviceKey&&session.busy&&session.appForeground){await this.files.cancel();}await this.files.dispose();}
  private back():void{if(this.browsing){this.pendingUpload=undefined;this.choosingUpload=false;this.browsing=false;return;}if(this.borrowed){this.onClose();}else{this.getUIContext().getRouter().back();}}
  onBackPress():boolean{if(this.browsing){this.pendingUpload=undefined;this.choosingUpload=false;this.browsing=false;return true;}return false;}
  private openDirectory(path:string):void{if(this.listing||!this.connected||this.transferring||(this.hasChoice&&!this.choosingUpload)){return;}this.folders.push(this.directory);this.requestedDirectory=path;this.resetDirectoryScroll();this.files.list(path);}
  private browse(choose:boolean=false):void{this.choosingUpload=choose;this.browsing=true;this.folders=[];this.requestedDirectory='';this.resetDirectoryScroll();if(this.connected){this.files.list('');}else{this.message='正在等待安全文件通道连接';}}
  private async loadConnected():Promise<void>{await this.files.refresh();if(!this.live){return;}if(this.browsing){this.files.list(this.requestedDirectory);}else if(this.files.choice){this.prepareDestination();}}
  private parentDirectory():void{const previous=this.folders.pop();this.requestedDirectory=previous===undefined?'':previous;this.resetDirectoryScroll();this.files.list(this.requestedDirectory);}
  private async prepareDestination():Promise<void>{if(!this.connected){this.notice='文件已选择，等待文件通道连接';return;}if(!this.uploadDirectory){this.browse(true);return;}this.pendingUpload={generation:this.files.status.generation,target:this.uploadDirectory,media:false};await this.files.list(this.uploadDirectory);}
  private resumeAllowed(intent:PickerResumeIntent):boolean{return canResumePickerSession(intent,{pageEpoch:this.pageEpoch,foreground:session.appForeground,generation:session.generation,lastFailure:session.lastFailure,busy:session.busy,closing:session.isClosing,selected:session.selected,hasChoice:this.files.choice!==undefined});}
  private async resumePicker(intent:PickerResumeIntent):Promise<void>{this.resumingPicker=true;try{const deadline=Date.now()+15000;while(this.live&&this.resumeAllowed(intent)&&client.view.pending&&Date.now()<deadline){await new Promise<void>((resolve:()=>void)=>setTimeout(resolve,100));}if(this.live&&this.resumeAllowed(intent)){this.pickerResume=undefined;await this.reconnect();}}finally{this.resumingPicker=false;}}
  private async upload(media:boolean):Promise<void>{this.group=0;this.pickerPending=true;const run=this.pageEpoch;const owner=session.filesOnly&&session.generation===this.sessionEpoch;this.pickerResume=owner?{pageEpoch:run,sessionEpoch:this.sessionEpoch,deviceKey:this.deviceKey}:undefined;
    try{await this.files.selectUpload('',media);}finally{this.pickerPending=false;}
    if(!this.live||run!==this.pageEpoch||!this.files.choice){this.pickerResume=undefined;return;}
    if(this.pickerResume&&this.resumeAllowed(this.pickerResume)){await this.resumePicker(this.pickerResume);return;}
    if(session.generation===this.sessionEpoch&&session.busy&&session.appForeground&&(this.borrowed?!session.filesOnly:session.filesOnly)){this.pickerResume=undefined;await this.prepareDestination();}else if(this.borrowed){this.connected=false;this.connectionFailed=true;await this.files.connectionLost();this.notice='远程会话已中断，请返回后重新连接';}
  }

  private async reconnect():Promise<void>{if(this.borrowed){this.onClose();return;}if(this.timer>=0){clearInterval(this.timer);this.timer=-1;}this.pendingUpload=undefined;await this.files.connectionLost();if(session.filesOnly&&session.generation===this.sessionEpoch){await session.cancel('user_disconnect');}this.connected=false;this.connectionFailed=false;this.files.setForeground(true);await this.start();}

  private confirmUpload():void{this.showDialog({title:'确认发送文件',message:this.choiceName+'\n发送到电脑目录：'+this.choiceDirectory+'\n同名文件不会覆盖。',primaryButton:{value:'取消',action:()=>{this.pickerResume=undefined;this.files.cancel();}},secondaryButton:{value:'发送',action:()=>this.files.confirmUpload()}});}
  private download(entry:FileEntry):void{
    const save=(inApp:boolean):void=>{this.browsing=false;this.group=0;this.files.download(entry,inApp);};
    const actions:AlertDialogButtonOptions[]=[{value:'存到应用接收区',action:()=>save(true)}];
    if(canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection')){actions.push({value:'选择手机目录',action:()=>save(false)});}
    actions.push({value:'取消',action:()=>{}});
    this.showDialog({title:'下载到手机',message:entry.name+' · '+this.bytes(entry.size)+'\n接收完成后可通过系统分享另存。同名文件不会覆盖。',buttons:actions});
  }

  @Builder private header(){
    Row({space:12}){
      Button('‹').fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).fontSize(30).fontColor(this.colors().text).backgroundColor(Color.Transparent).width(40).height(44).id('filesBack').onClick(()=>this.back())
      Text(this.browsing?(this.choosingUpload?'选择电脑接收目录':'从电脑下载文件到手机'):this.targetName).fontSize(this.browsing?17:21).fontWeight(FontWeight.Bold).fontColor(this.colors().text).layoutWeight(1).maxLines(2)
      Text(this.connected?'已连接':this.connectionFailed?'未连接':'连接中').fontSize(12).fontColor(this.connected?this.colors().primary:this.colors().secondary)
    }.width('100%')
  }
  @Builder private action(title:string,symbol:string,media:boolean){
    Button(){Column({space:12}){Text(symbol).fontSize(32).fontColor(this.colors().primary);Text(title).fontSize(13).fontColor(this.colors().text).textAlign(TextAlign.Center)}.width('100%')}
      .backgroundColor(this.colors().surface).borderRadius(16).layoutWeight(1).height(114).id(media?'filesPhotos':'filesUpload').enabled(!this.transferring&&!this.hasChoice).onClick(()=>this.upload(media))
  }
  @Builder private groupHeader(label:string,index:number){
    Button(){Row(){Text(label+' ('+(index===0?(this.transferring?1:0):index===1?this.received.length:this.sent.length)+')').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.colors().text).layoutWeight(1).textAlign(TextAlign.Start);Text(this.group===index?'⌃':'⌄').fontSize(20).fontColor(this.colors().secondary)}.padding({top:16,bottom:16})}.width('100%').backgroundColor(Color.Transparent).id('filesGroup'+index).onClick(()=>{this.group=this.group===index?-1:index;})
  }
  @Builder private home(){
    Column({space:8}){
      Row({space:12}){
        this.action('传照片/视频','▧',true)
        this.action('传文件','▤',false)
        Button(){Column({space:12}){Text('↓').fontSize(32).fontColor(this.colors().primary);Text('从电脑下载').fontSize(13).fontColor(this.colors().text)}.width('100%')}.layoutWeight(1).height(114).backgroundColor(this.colors().surface).borderRadius(16).id('filesBrowse').enabled(!this.transferring&&!this.hasChoice).onClick(()=>this.browse())
      }.width('100%').margin({top:8,bottom:20})
      if(this.hasChoice){Column({space:8}){Text('已选择：'+this.choiceName).fontSize(14).fontColor(this.colors().text).width('100%');Text('发送到：'+(this.choiceDirectory||'请选择电脑接收目录')).fontSize(12).fontColor(this.colors().secondary).width('100%');Row({space:10}){Button('取消').fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).onClick(()=>{this.pickerResume=undefined;this.files.cancel();});Button(this.choiceDirectory?'确认发送':'选择电脑接收目录').fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).enabled(!this.listing&&!this.requiresReconnect&&this.connected).onClick(()=>{if(this.choiceDirectory){this.confirmUpload();}else{this.browse(true);}})}}.padding(14).width('100%').backgroundColor(this.colors().surface).borderRadius(12)}
      this.groupHeader('传输中',0)
      if(this.group===0){
        if(this.transferring){Column({space:12}){Text(this.transfer).fontSize(14).fontColor(this.colors().text).width('100%');Progress({value:this.progress,total:100,type:ProgressType.Linear}).color(this.colors().primary).backgroundColor(this.colors().neutralSoft).width('100%');Row(){Text(Math.round(this.progress)+'%').fontSize(12).fontColor(this.colors().secondary).layoutWeight(1);Button('取消传输').fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).id('filesCancel').fontSize(13).onClick(()=>this.files.cancel())}}.padding(16).width('100%').backgroundColor(this.colors().surface).borderRadius(14)}else{this.empty('暂无进行中的传输','')}
      }
      Divider().color(this.colors().divider)
      this.groupHeader('已接收',1)
      if(this.group===1){if(this.received.length===0){this.empty('暂无已接收文件','')}else{ForEach(this.received,(row:string)=>{this.record(row)});if(this.saved){Button('保存 / 分享最近接收文件').fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).fontSize(13).onClick(()=>this.files.shareSavedDownload())}}}
      Divider().color(this.colors().divider)
      this.groupHeader('已发送',2)
      if(this.group===2){if(this.sent.length===0){this.empty('暂无已发送文件','')}else{ForEach(this.sent,(row:string)=>{this.record(row)})}}
      Divider().color(this.colors().divider)
      if(this.requiresReconnect||this.connectionFailed){Button(this.borrowed?'返回并重新连接远程桌面':'重新连接文件通道').fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).onClick(()=>this.reconnect())}
      if(this.notice){Text(this.notice).fontSize(13).fontColor(this.colors().warning).width('100%').maxLines(3)}
      if(!this.connected){Text(this.message).fontSize(13).fontColor(this.colors().secondary).width('100%').maxLines(3)}
    }.width('100%')
  }
  @Builder private empty(title:string,subtitle:string){Column({space:8}){Text(title).fontSize(15).fontColor(this.colors().secondary);if(subtitle){Text(subtitle).fontSize(12).fontColor(this.colors().secondary)}}.width('100%').padding({top:30,bottom:30})}
  @Builder private record(row:string){Text(row).fontSize(14).fontColor(this.colors().text).width('100%').padding(16).backgroundColor(this.colors().surface).borderRadius(10)}
  @Builder private directoryPage(){
    Column({space:8}){
      Scroll(){Row({space:8}){Button('接收目录').fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).fontSize(13).enabled(this.connected&&!this.listing&&this.uploadDirectory.length>0).onClick(()=>this.openDirectory(this.uploadDirectory));Button('磁盘').fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).fontSize(13).id('filesDrives').enabled(this.connected&&!this.listing).onClick(()=>this.openDirectory(''));Button('上一级').fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).fontSize(13).enabled(this.connected&&!this.listing).onClick(()=>this.parentDirectory());ForEach(this.entries.filter((entry:FileEntry)=>[0,2,3].includes(entry.kind)&&['desktop','downloads','documents','pictures','videos','桌面','下载','文档','图片','视频'].includes(entry.name.toLowerCase())),(entry:FileEntry)=>{Button(entry.name).fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).fontSize(12).enabled(this.connected&&!this.listing).onClick(()=>this.openDirectory(entry.path))},(entry:FileEntry)=>entry.path)}}.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
      Text(this.directory||'电脑磁盘').fontSize(12).fontColor(this.colors().secondary).width('100%').maxLines(2)
      Scroll(){Row({space:8}){this.sortOption('名称','name');this.sortOption('类型','type');this.sortOption('大小','size');this.sortOption('修改时间','modified')}}.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
      List({space:8,scroller:this.directoryScroller}){
        if(!this.connected){ListItem(){Text(this.message).fontSize(13).fontColor(this.colors().secondary).width('100%')}}
        if(this.listing){ListItem(){Text('正在读取电脑目录…').fontSize(13).fontColor(this.colors().secondary).width('100%')}}
        if(this.connected&&!this.listing&&this.entries.length===0){ListItem(){Text('当前目录暂无文件').fontSize(13).fontColor(this.colors().secondary).width('100%')}}
        if(this.requiresReconnect||this.connectionFailed){ListItem(){Button(this.borrowed?'返回并重新连接远程桌面':'重新连接文件通道').fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).onClick(()=>this.reconnect())}}
        if(this.notice){ListItem(){Column({space:8}){Text(this.notice).fontSize(13).fontColor(this.colors().warning).width('100%');Button('重试读取目录').fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).enabled(this.connected&&!this.listing).onClick(()=>{this.resetDirectoryScroll();this.files.list(this.requestedDirectory);})}.width('100%')}}
        ForEach(this.sortedEntries,(entry:FileEntry)=>{ListItem(){Row({space:12}){Text((entry.kind===4||entry.kind===5)?'▤':'▰').fontSize(24).fontColor(this.colors().primary).width(32);Column({space:4}){Text(entry.name).fontSize(15).fontColor(this.colors().text).width('100%').maxLines(2);if(entry.kind===4||entry.kind===5){Text(this.bytes(entry.size)).fontSize(12).fontColor(this.colors().secondary).width('100%')}}.layoutWeight(1);Button((entry.kind===4||entry.kind===5)?'下载':'打开').fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).fontSize(12).enabled(this.connected&&!this.listing&&!this.transferring&&(!this.hasChoice||(this.choosingUpload&&entry.kind!==4&&entry.kind!==5))).onClick(()=>{if(entry.kind===4||entry.kind===5){this.download(entry);}else{this.openDirectory(entry.path);}})}.padding(14).width('100%').backgroundColor(this.colors().surface).borderRadius(12)}},(entry:FileEntry)=>entry.path)
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off).padding({bottom:12})
      if(this.choosingUpload){Button('使用此目录接收文件').width('100%').fontColor(this.colors().onPrimary).backgroundColor(this.colors().primary).enabled(!this.listing&&this.directory.length>0&&this.files.status.state==='complete').onClick(()=>{this.uploadDirectory=this.directory;this.explicitUploadDirectory=true;this.files.setUploadDirectory(this.directory);this.choosingUpload=false;this.browsing=false;})}
    }.width('100%').layoutWeight(1)
  }
  build(){
    Column({space:16}){
      this.header()
      if(this.browsing){this.directoryPage()}else{Scroll(){this.home()}.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Off)}
      if(!this.browsing){Button(){Column({space:5}){Text('电脑接收目录').fontSize(12).fontColor(this.colors().secondary).width('100%');Text(this.uploadDirectory||'尚未上报，点击选择接收目录').fontSize(12).fontColor(this.colors().secondary).width('100%').maxLines(2)}.padding(8)}.width('100%').backgroundColor(Color.Transparent).onClick(()=>this.browse(true))}
    }.padding({left:20,right:20,top:this.borrowed?16:this.safeTop,bottom:this.borrowed?16:this.safeBottom}).width('100%').height('100%').backgroundColor(this.colors().background)
  }
}
