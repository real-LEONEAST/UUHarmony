import { client,AuthView,emptyView } from './AuthClient';
import { windowPolicy } from './WindowPolicy';
import { session } from './SessionClient';
import { UiColor,UiFont,UiSpace,UiActionButton,UiSecondaryButton,UiNotice } from './UiFoundation';
import { pcHost,ShareView,emptyShare,HostDisplay } from '../pc/PcHostService';
import { hostBusy,hostDisplayName,hostStopping,inputPermissionLabel } from '../pc/PcHostModel';
import { libraryTabState } from './LibraryTabState';
import { AppNavigation } from '../pc/AppNavigation';
import { DeviceRow, deviceName } from './DeviceListModel';
import { validatedLocalName } from './LocalNameModel';
import { PcReceivedFiles } from './PcReceivedFiles';
import { PcDeviceCover } from './PcDeviceCover';

@Entry
@Component
struct PcShare {
  @State private auth:AuthView=emptyView();
  @State private share:ShareView=emptyShare();
  @State private revealCode:boolean=false;
  @State private sound:boolean=false;
  @State private editingName:boolean=false;
  @State private nameSaving:boolean=false;
  @State private nameDraft:string='';
  @State private nameMessage:string='';
  private nameEpoch:number=0;
  private nameAccount:string='';
  private nameDeviceKey:string='';
  @StorageLink('uuWindowWidth') private windowWidth:number=0;
  @StorageLink('uuSafeTop') private safeTop:number=12;
  @StorageLink('uuSafeBottom') private safeBottom:number=12;
  private offAuth:()=>void=()=>{};
  private offShare:()=>void=()=>{};
  aboutToAppear():void {
    windowPolicy.applyRemote(false);
    if(!pcHost.supported){this.navigate('devices');return;}
    this.offAuth=client.observe((value:AuthView)=>{this.auth=value;if(!value.loggedIn){this.getUIContext().getRouter().replaceUrl({url:'pages/Index'}).catch(()=>{});}});
    this.offShare=pcHost.observe((value:ShareView)=>{this.share=value;if(!value.online||!value.assistance||value.deviceId.length===0){this.revealCode=false;}});
    pcHost.syncAccount();pcHost.refreshDisplays();this.sound=pcHost.sound;client.refreshDevices(false);
  }
  aboutToDisappear():void {this.nameEpoch++;this.offAuth();this.offShare();this.revealCode=false;}
  private currentDevice():DeviceRow|undefined {const rows=this.auth.devices.filter((row:DeviceRow)=>row.current);return rows.length===1?rows[0]:undefined;}
  private beginNameEdit():void {const row=this.currentDevice();const account=this.auth.wallpaperAccountKey||'';if(!row||!account){this.nameMessage='暂时无法获取本机名称，请刷新后重试。';return;}this.nameEpoch++;this.nameAccount=account;this.nameDeviceKey=row.key;this.nameDraft=deviceName(row);this.nameMessage='';this.editingName=true;}
  private cancelNameEdit():void {if(this.nameSaving){return;}this.nameEpoch++;this.editingName=false;this.nameDraft='';this.nameMessage='';}
  private async saveName():Promise<void> {if(this.nameSaving){return;}const value=validatedLocalName(this.nameDraft);if(!value){this.nameMessage='请输入 1 至 64 个字符，名称不能包含控制字符。';return;}const row=this.currentDevice();if(!row||row.key!==this.nameDeviceKey||this.nameAccount!==(this.auth.wallpaperAccountKey||'')){this.nameMessage='账号或设备已变化，请重新打开编辑。';return;}const epoch=this.nameEpoch;const account=this.nameAccount;const key=this.nameDeviceKey;this.nameSaving=true;this.nameMessage='正在保存…';try{const result=await client.renameCurrentDevice(value,key);if(epoch!==this.nameEpoch||account!==(this.auth.wallpaperAccountKey||'')||this.currentDevice()?.key!==key){return;}if(result==='success'){this.editingName=false;this.nameDraft='';this.nameMessage='名称已保存。';}else{this.nameMessage=result==='invalid'?'名称不符合要求，请修改后重试。':result==='failed'?'保存未成功，请重试。':'暂未确认保存结果，请刷新后重试。';}}finally{if(epoch===this.nameEpoch){this.nameSaving=false;}}}
  private navigate(page:string):void {if(page==='share'){return;}if(page==='assistance'){if(session.busy||session.isClosing||pcHost.busy){return;}libraryTabState.selected='assistance';this.getUIContext().getRouter().replaceUrl({url:'pages/Assistance'}).catch(()=>{});return;}libraryTabState.selected=page==='account'?'account':'devices';this.getUIContext().getRouter().replaceUrl({url:'pages/Devices'}).catch(()=>{});}
  private stateTitle():string {
    if(this.share.phase==='waiting'){return this.share.online?'此电脑已上线':'正在上线';}
    if(this.share.phase==='sharing'){return '此电脑正在共享';}
    if(this.share.phase==='preparing'){return '等待屏幕授权';}
    if(this.share.phase==='stopping'){return '正在停止共享';}
    if(this.share.phase==='stop-pending'){return '正在结束共享服务';}
    if(this.share.phase==='stop-failed'){return '停止共享需要重试';}
    if(this.share.phase==='failed'||this.share.phase==='error'){return '共享需要处理';}
    if(!this.share.encoderKnown){return '正在检查屏幕共享能力';}
    if(!this.share.encoder){return '未检测到可用的视频编码器';}
    return '此电脑被控服务已关闭';
  }
  private stopSharing():void {
    if(this.share.phase==='stopping'){return;}
    if(hostStopping(this.share.phase)){pcHost.stop();return;}
    this.getUIContext().showAlertDialog({title:'关闭此电脑的被控服务？',message:'将断开当前远控连接，此电脑在其他设备上显示为离线。',primaryButton:{value:'保持开启',action:()=>{}},secondaryButton:{value:'关闭',action:()=>{pcHost.setEnabled(false);}}});
  }
  private stopLabel():string {
    if(this.share.phase==='stopping'){return '正在停止…';}
    if(this.share.phase==='stop-pending'){return '检查停止结果';}
    if(this.share.phase==='stop-failed'){return '重试停止共享';}
    return '停止共享';
  }
  private changeCode():void {
    this.getUIContext().showAlertDialog({title:'更换临时验证码？',message:'旧验证码将失效，请将新验证码提供给可信联系人。',primaryButton:{value:'保留当前',action:()=>{}},secondaryButton:{value:'更换验证码',action:()=>{this.revealCode=false;pcHost.resetCode();}}});
  }
  @Builder overview() {
    Column({space:18}) {
      Row({space:14}) {
        Image($r('app.media.ui_computer')).width(40).height(40).accessibilityLevel('no')
        Column({space:5}) {
          Text(this.stateTitle()).id('pcShareTitle').fontSize(UiFont.heading).fontWeight(FontWeight.Bold).fontColor(UiColor.text).width('100%')
          Text(this.share.phase==='sharing'?'正在共享屏幕':this.share.phase==='waiting'?'等待远控连接':'屏幕未共享').fontSize(UiFont.caption).fontColor(this.share.online?UiColor.success:UiColor.secondary).width('100%')
        }.layoutWeight(1)
      }.width('100%')
      Text(this.share.message).id('pcShareState').fontSize(UiFont.body).fontColor(UiColor.text).width('100%')
      if(this.share.settingsMessage){UiNotice({text:this.share.settingsMessage})}
      this.permissions()
      if(this.share.encoderKnown&&!this.share.encoder){UiNotice({text:'未检测到系统 H.264 视频编码器，当前无法向其他设备发送屏幕画面。仍可连接其他电脑。'})}
      if(this.share.soundRequested&&this.share.phase==='sharing'){Text(this.share.audioFrames>0?'已采集系统声音，远端播放待确认':'已请求系统声音，等待音频数据').fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%')}
      if(this.share.viewerBusy&&this.share.phase!=='waiting'){UiNotice({text:'请先断开当前远控连接，再启动共享。'})}
      if(!hostBusy(this.share.phase)&&this.share.phase!=='waiting'){
        Text('共享画质').fontSize(UiFont.body).fontWeight(FontWeight.Medium).fontColor(UiColor.text)
        Row({space:8}){
          Column(){
            UiSecondaryButton({label:this.share.smooth?'原画':'已选 · 原画',onAction:()=>pcHost.setSmooth(false)}).id('pcOriginalQuality')
          }.layoutWeight(1)
          Column(){
            UiSecondaryButton({label:this.share.smooth?'已选 · 流畅':'流畅',onAction:()=>pcHost.setSmooth(true)}).id('pcSmoothQuality')
          }.layoutWeight(1)
        }.width('100%')
        Text(this.share.smooth?'按屏幕比例限制在 1920 × 1080 范围内，最高 30 帧。':'申请屏幕原始分辨率，连接后可查看编码器输出尺寸。')
          .fontSize(UiFont.caption).fontColor(UiColor.secondary)
        Row({space:12}){Text('共享系统声音').fontColor(UiColor.text).layoutWeight(1);Toggle({type:ToggleType.Switch,isOn:this.sound}).onChange((value:boolean)=>{this.sound=value;pcHost.setSound(value);})}.width('100%')
        Text('仅共享系统播放声音；受系统授权与应用音频捕获策略限制。').fontColor(UiColor.secondary).fontSize(UiFont.caption)
        Row({space:12}){
          Text('离开前准备主屏').fontSize(UiFont.body).fontColor(UiColor.text).layoutWeight(1)
          Toggle({type:ToggleType.Switch,isOn:this.share.keepPrimary===true}).id('pcKeepPrimary')
            .onChange((enabled:boolean)=>pcHost.setKeepPrimary(enabled))
        }.width('100%')
        if(this.share.keepPrimary){
          Text('预授权后可连接其他电脑。收到对方的远控连接时，本机发起的远控会结束。')
            .fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%')
        }else{
          ForEach(this.share.displays,(item:HostDisplay,index:number)=>{
            UiSecondaryButton({label:(this.share.selectedDisplay===item.id?'已选择 · ':'')+hostDisplayName(item.name,index)+' · '+item.width+' × '+item.height,onAction:()=>pcHost.selectDisplay(item.id)})
          },(item:HostDisplay,index:number)=>item.id+'-'+item.name+'-'+item.width+'-'+item.height+'-'+index)
          UiSecondaryButton({label:'刷新屏幕列表',onAction:()=>pcHost.refreshDisplays()})
        }
      }
      if(hostBusy(this.share.phase)||this.share.phase==='waiting'){
        if(this.share.streamWidth>0&&this.share.streamHeight>0){
          Text((this.share.smooth?'流畅':'原画')+' · 目标 '+this.share.streamWidth+' × '+this.share.streamHeight+(this.share.smooth?' · 最高 30 帧':''))
            .id('pcStreamSize').fontSize(UiFont.caption).fontColor(UiColor.secondary)
          if((this.share.encodedWidth||0)>0&&(this.share.encodedHeight||0)>0){
            Text('实际编码 '+this.share.encodedWidth+' × '+this.share.encodedHeight).id('pcEncodedSize')
              .fontSize(UiFont.body).fontColor(UiColor.text)
          }
          Text('停止共享后可切换画质。').fontSize(UiFont.caption).fontColor(UiColor.secondary)
        }
        Row(){UiActionButton({label:this.stopLabel(),available:this.share.phase!=='stopping',onAction:()=>this.stopSharing()}).id('pcStopSharing')}.width('100%').constraintSize({maxWidth:240})
      }else{
        Row(){UiActionButton({label:'允许控制此电脑',available:this.share.canStart,onAction:()=>{pcHost.setEnabled(true);}}).id('pcStartSharing')}.width('100%').constraintSize({maxWidth:240})
      }

    }.padding(UiSpace.card).width('100%').backgroundColor(UiColor.surface).borderRadius(UiSpace.radius).alignItems(HorizontalAlign.Start)
  }
  @Builder permissions() {
    Column({space:8}) {
      Text(inputPermissionLabel(this.share.inputState)).id('pcInputState').fontSize(UiFont.body).fontColor(UiColor.text).width('100%')
      if(this.share.inputState!==2){
        Text(this.share.inputState===1?'请在鸿蒙系统弹窗中确认授权。':'若 Windows 提示「未开启被控功能」，请在这里允许键鼠控制，再从 Windows 连接。')
          .fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%')
        Row(){UiSecondaryButton({label:this.share.inputState===1?'等待系统授权':'允许键鼠控制',available:this.share.inputState!==1&&this.share.encoderKnown,onAction:()=>{pcHost.requestInput();}}).id('pcGrantInput')}.width('100%').constraintSize({maxWidth:240})
      }
      if(this.share.inputMessage){
        Text(this.share.inputMessage).fontSize(UiFont.caption).fontColor(UiColor.error).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder assistance() {
    Column({space:16}) {

      Row({space:12}) {
          Text('允许验证码连接').fontSize(UiFont.body).fontColor(UiColor.text).layoutWeight(1)
          Toggle({type:ToggleType.Switch,isOn:this.share.assistance}).enabled(this.share.online===true&&this.share.deviceId.length>0).accessibilityText('允许验证码连接').onChange((value:boolean)=>pcHost.setAssistance(value))
        }.width('100%')
        Text(this.share.assistance?'仅向可信的人提供设备 ID 和临时验证码。':'开启后，可向可信的人提供临时验证码。').fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%')
        if(this.share.online&&this.share.deviceId.length>0&&this.share.assistance){
          Text('设备 ID：'+this.share.deviceId).fontSize(UiFont.body).fontColor(UiColor.text).width('100%').wordBreak(WordBreak.BREAK_ALL)
          if(this.revealCode){Text(this.share.code).fontSize(28).fontWeight(FontWeight.Bold).fontColor(UiColor.primary).width('100%').wordBreak(WordBreak.BREAK_ALL).accessibilityText('临时验证码 '+this.share.code)}
          UiSecondaryButton({label:this.revealCode?'隐藏临时验证码':'显示临时验证码',onAction:()=>{this.revealCode=!this.revealCode;}}).id('pcRevealCode')
          UiSecondaryButton({label:'更换验证码',onAction:()=>this.changeCode()}).id('pcResetCode')
        }
      if(!this.share.online||this.share.deviceId.length===0){
        Text('被控服务上线后，可选择开启临时验证码连接。').fontSize(UiFont.body).fontColor(UiColor.secondary).width('100%')
      }
    }.padding(UiSpace.card).width('100%').backgroundColor(UiColor.surface).borderRadius(UiSpace.radius).alignItems(HorizontalAlign.Start)
  }
  @Builder primarySettings() {
      Column({space:10}){
        Row({space:12}){Text('本机名称').fontSize(UiFont.heading).fontWeight(FontWeight.Bold).fontColor(UiColor.text).layoutWeight(1);if(!this.editingName){Button('修改').id('editLocalName').height(44).enabled(!this.nameSaving).onClick(()=>this.beginNameEdit())}}.width('100%')
        if(this.editingName){
          TextInput({text:this.nameDraft,placeholder:'输入本机名称'}).id('localNameInput').maxLength(64).onChange((value:string)=>{this.nameDraft=value;this.nameMessage='';}).width('100%')
          Row({space:12}){Button('取消').id('cancelLocalName').height(44).enabled(!this.nameSaving).onClick(()=>this.cancelNameEdit());Button(this.nameSaving?'保存中':'保存').id('saveLocalName').height(44).enabled(!this.nameSaving).onClick(()=>this.saveName())}.width('100%')
        }else{Text(this.currentDevice()?deviceName(this.currentDevice()!):'正在获取本机名称').id('currentLocalName').fontSize(UiFont.body).fontColor(UiColor.text).width('100%')}
        if(this.nameMessage){Text(this.nameMessage).id('localNameMessage').fontSize(UiFont.caption).fontColor(UiColor.secondary).width('100%')}
      }.padding(UiSpace.card).width('100%').backgroundColor(UiColor.surface).borderRadius(UiSpace.radius).alignItems(HorizontalAlign.Start)
      Column({space:12}) {
        Text('共享屏幕').fontSize(UiFont.heading).fontWeight(FontWeight.Bold).fontColor(UiColor.text).width('100%')
        this.overview()
      }.width('100%')
  }
  @Builder relatedSettings() {
      PcReceivedFiles({ sharingOpen: this.share.online === true && this.share.phase !== 'stopping' })
      PcDeviceCover({online: this.share.online === true})
      Column({space:12}) {
        Text('远程协助').fontSize(UiFont.heading).fontWeight(FontWeight.Bold).fontColor(UiColor.text).width('100%')
        this.assistance()
      }.width('100%')
  }
  @Builder content() {
    Scroll(){
      Column({space:18}) {
        Column({space:8}) {
          Text('共享此电脑').fontSize(UiFont.title).fontWeight(FontWeight.Bold).fontColor(UiColor.text).width('100%')
          Text(this.auth.accountLabel||'UU 账号已登录').fontSize(UiFont.body).fontColor(UiColor.secondary).width('100%')
        }.width('100%')
        if(this.windowWidth>=1240){
          Row({space:18}){
            Column({space:18}){this.primarySettings()}.layoutWeight(1)
            Column({space:18}){this.relatedSettings()}.layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Top)
        }else{
          this.primarySettings()
          this.relatedSettings()
        }
        Text('登录后恢复普通被控服务。关闭窗口后，可从托盘恢复窗口或停止服务。')
          .fontSize(UiFont.caption).fontColor(UiColor.secondary).lineHeight(21).width('100%')
      }.width('100%').constraintSize({maxWidth:1360}).padding({bottom:24})
    }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto)
  }
  build() {
    Row({space:20}) {
      if(pcHost.supported&&this.windowWidth>=840){AppNavigation({selected:'share',wide:true,onSelect:(page:string)=>this.navigate(page)})}
      Column({space:18}) {
        if(pcHost.supported&&this.windowWidth<840){AppNavigation({selected:'share',onSelect:(page:string)=>this.navigate(page)})}
        this.content()
      }.height('100%').layoutWeight(1)
    }.width('100%').height('100%').padding({left:UiSpace.page,right:UiSpace.page,top:this.safeTop+12,bottom:this.safeBottom})
      .backgroundColor(UiColor.background).ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],[LayoutSafeAreaEdge.TOP,LayoutSafeAreaEdge.BOTTOM])
      .expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
  }
}
