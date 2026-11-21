import { UiColor, UiFont, UiSpace, UiActionButton, UiSecondaryButton } from './UiFoundation';
import { client, AuthView, emptyView } from './AuthClient';
import { windowPolicy } from './WindowPolicy';
import { deviceInfo } from '@kit.BasicServicesKit';

@Entry
@Component
struct Index {
  private phone:boolean=deviceInfo.deviceType==='phone';
  @State private view:AuthView=emptyView();
  @State private helpOpen:boolean=false;
  @State private seconds:number=0;
  @StorageLink('uuSafeTop') private safeTop:number=12;
  @StorageLink('uuSafeBottom') private safeBottom:number=12;
  private leaving:boolean=false;
  private visible:boolean=false;
  private timer:number=-1;
  private stopObserving:()=>void=()=>{};
  aboutToAppear():void {
    this.visible=true;windowPolicy.applyRemote(false);
    this.stopObserving=client.observe((v:AuthView)=>{this.view=v;if(v.loggedIn&&this.visible){this.toDevices();}});
    this.boot();this.timer=setInterval(()=>{this.seconds=Math.max(0,Math.ceil((this.view.qrExpiresAtMs-Date.now())/1000));},1000);
  }
  private async boot():Promise<void>{await client.boot();await client.resume();if(client.view.loggedIn){this.toDevices();}}
  aboutToDisappear():void {this.visible=false;this.stopObserving();if(this.timer>=0){clearInterval(this.timer);this.timer=-1;}}
  onPageShow():void{this.visible=true;windowPolicy.applyRemote(false);if(client.view.loggedIn){this.toDevices();}}
  onPageHide():void{this.visible=false;}
  private toDevices():void {if(!this.visible||this.leaving||!client.view.loggedIn){return;}this.leaving=true;this.getUIContext().getRouter().replaceUrl({url:'pages/Devices'}).catch(()=>{this.leaving=false;});}
  private refreshQr():void{if(this.view.canResume){AlertDialog.show({title:'刷新登录二维码？',message:'会替换当前未过期二维码，请勿在官方UU中继续确认旧二维码。',primaryButton:{value:'保留当前',action:()=>{}},secondaryButton:{value:'刷新',action:()=>this.newQr()}});}else{this.newQr();}}
  private async newQr():Promise<void>{await client.cancel();await client.start('begin');}
  private primaryLabel():string {
    if(this.view.state==='storage_error'){return '重试恢复登录';}
    if(this.view.pending){return this.view.qr.length>0||this.view.state==='scanned'?'正在检查授权…':'正在获取二维码…';}
    if(this.view.state==='scanned'){return '检查确认结果';}
    if(this.view.canResume){return this.view.suspended?'继续登录':'检查授权结果';}
    return this.view.qr.length>0?'重新获取二维码':'获取登录二维码';
  }
  private primaryAction():void {if(this.view.state==='storage_error'||this.view.canResume){client.resume();}else{this.refreshQr();}}
  build(){
    Scroll(){Column({space:18}){
      Row({space:12}){Text('UH').fontColor(UiColor.onPrimary).fontWeight(FontWeight.Bold).fontSize(20).width(46).height(46).textAlign(TextAlign.Center).backgroundColor(UiColor.primary).borderRadius(14);Column({space:3}){Text('UUHarmony').fontSize(19).fontWeight(FontWeight.Bold).fontColor(UiColor.text).width('100%');Text('UU远控 · 非官方客户端').fontSize(12).fontColor(UiColor.secondary).width('100%')}.layoutWeight(1)}.width('100%').margin({bottom:12})
      Text('登录账号').fontSize(UiFont.title).fontWeight(FontWeight.Bold).fontColor(UiColor.text).width('100%')
      Column({space:14}){
        Column({space:10}) {
        if(this.view.qr.length>0){
          Column({space:10}){QRCode(this.view.qr).id('authQrCode').width('100%').aspectRatio(1).constraintSize({maxWidth:236,maxHeight:236}).color('#152039').backgroundColor('#FFFFFF');Text(this.view.state==='scanned'?'已扫码，请在官方UU确认':'请使用官方UU远程扫描').fontSize(14).fontColor('#334155')}.padding(14).width('100%').constraintSize({maxWidth:264}).backgroundColor('#FFFFFF').borderRadius(16)
          if(this.view.canResume){Text('本次登录任务最多保留 '+this.seconds+' 秒').fontSize(12).fontColor(UiColor.secondary)}
        }else{Column({space:10}){if(this.view.pending){LoadingProgress().width(32).height(32).color(UiColor.primary)}
        Text(this.view.state==='storage_error'?'登录恢复':this.view.pending?'正在获取二维码':this.view.state.includes('error')||this.view.state.includes('failed')?'暂时无法获取二维码':'扫码授权').fontSize(UiFont.heading).fontWeight(FontWeight.Medium).fontColor(UiColor.text);Text(this.view.pending?'请稍候':this.view.state.includes('error')||this.view.state.includes('failed')?'点击下方按钮重试':'点击下方按钮获取有效二维码').fontSize(13).fontColor(UiColor.secondary)}.width('100%').height(264).justifyContent(FlexAlign.Center).backgroundColor(UiColor.neutralSoft).borderRadius(16)}
        }.width('100%').constraintSize({minHeight:310}).justifyContent(FlexAlign.Center)
        Text(this.view.message).id('authStatus').fontSize(UiFont.body).fontColor(UiColor.text).textAlign(TextAlign.Center).lineHeight(24).constraintSize({minHeight:48})
        UiActionButton({label:this.primaryLabel(),available:!this.view.pending,onAction:()=>this.primaryAction()}).id('loginButton')
        if(this.view.canResume){UiSecondaryButton({label:'更换二维码',available:!this.view.pending,onAction:()=>this.refreshQr()}).id('refreshLoginQr')}
      }.padding(UiSpace.card).width('100%').backgroundColor(UiColor.surface).borderRadius(UiSpace.radius)
      if(this.phone){Column({space:10}){
        UiSecondaryButton({label:this.helpOpen?'收起同机登录帮助':'同一部手机如何登录？',onAction:()=>{this.helpOpen=!this.helpOpen;}}).id('loginHelp')
        if(this.helpOpen){
        Text('1  将当前二维码截屏，通过USB显示到自己的电脑屏幕。\n2  切到本机官方UU远程，用扫一扫扫描电脑上的二维码并确认。\n3  回到本应用，继续查询授权结果。').fontSize(13).fontColor(UiColor.text).lineHeight(23).width('100%')
        Text('请仅在自己的设备短暂展示，完成后删除截图。也可使用另一部已登录官方UU的设备直接扫码。').fontSize(12).fontColor(UiColor.secondary).lineHeight(20).width('100%')
        }
      }.padding(16).width('100%').backgroundColor(UiColor.surface).borderRadius(16)}
      if(this.view.canResume){Button('取消当前授权').type(ButtonType.Normal).backgroundColor(Color.Transparent).fontColor(UiColor.secondary).height('auto').constraintSize({minHeight:48}).onClick(()=>client.cancel())}
      Text('登录信息由系统安全保存。请勿向他人分享登录二维码或授权链接。').fontSize(UiFont.caption).fontColor(UiColor.secondary).lineHeight(19).width('100%')
    }.padding({left:24,right:24,top:this.safeTop+20,bottom:this.safeBottom+20}).width('100%').constraintSize({maxWidth:560})}.width('100%').height('100%').scrollBar(BarState.Off).backgroundColor(UiColor.background)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],[LayoutSafeAreaEdge.TOP,LayoutSafeAreaEdge.BOTTOM])
      .expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
  }
}
