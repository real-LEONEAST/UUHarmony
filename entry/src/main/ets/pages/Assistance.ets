import { AppNavigation } from '../pc/AppNavigation';
import { deviceInfo } from '@kit.BasicServicesKit';
import { phoneLandscape, compactPhoneLayout } from './DeviceLayoutModel';
import { LibraryTabs } from './LibraryTabs';
import { libraryTabState } from './LibraryTabState';
import { windowPolicy } from './WindowPolicy';
import { client } from './AuthClient';
import { session } from './SessionClient';
import { RemoteRoute } from './RemoteRoute';
import { pcHost } from '../pc/PcHostService';
import { UiColor,UiFont,UiSpace,UiActionButton,UiSecondaryButton,UiNotice } from './UiFoundation';
@Entry
@Component
struct Assistance {
  @State private partnerId:string='';
  @State private code:string='';
  @State private message:string='';
  private leaving:boolean=false;
  @StorageLink('uuWindowWidth') private windowWidth:number=0;
  @StorageLink('uuWindowHeight') private windowHeight:number=0;
  @StorageLink('uuSafeTop') private safeTop:number=12;
  @StorageLink('uuSafeBottom') private safeBottom:number=12;
  private sideNavigation():boolean{return phoneLandscape(deviceInfo.deviceType,this.windowWidth,this.windowHeight);}
  private compact():boolean{return compactPhoneLayout(deviceInfo.deviceType,this.windowWidth,this.windowHeight,this.safeTop,this.safeBottom);}
  aboutToAppear():void {libraryTabState.selected='assistance';windowPolicy.applyRemote(false);}
  private navigate(tab:string):void {
    if(tab==='assistance'){return;}
    if(tab==='share'){this.code='';this.leaving=false;session.clearAssistance();this.getUIContext().getRouter().replaceUrl({url:'pages/PcShare'}).catch(()=>{this.message='暂时无法切换页面，请重试。';});return;}
    this.code='';this.leaving=false;session.clearAssistance();libraryTabState.selected=tab==='account'?'account':'devices';
    this.getUIContext().getRouter().replaceUrl({url:'pages/Devices'}).catch(()=>{libraryTabState.selected='assistance';this.message='暂时无法切换页面，请重试。';});
  }
  onBackPress():boolean {this.navigate('devices');return true;}
  aboutToDisappear():void {this.code='';if(!this.leaving){session.clearAssistance();}}
  private connect():void {
    if(!client.view.loggedIn||session.busy||session.isClosing||pcHost.blocksOutgoing){this.message='请先登录，并结束当前远控或电脑共享。';return;}
    AlertDialog.show({title:'发起远程协助？',message:'确认对方已同意共享此电脑。连接后可以查看画面，并在对方授权后操作键鼠。',primaryButton:{value:'取消',action:()=>{}},secondaryButton:{value:'发起协助',action:()=>{
      if(!session.prepareAssistance(this.partnerId,this.code)){this.message='请填写有效的设备 ID 和临时验证码。';return;}
      this.code='';this.leaving=true;
      const params:RemoteRoute={deviceKey:'assistance',confirmed:true};
      this.getUIContext().getRouter().pushUrl({url:'pages/RemoteDesktop',params:params}).catch(()=>{this.leaving=false;session.clearAssistance();this.message='暂时无法打开远程桌面，请重试。';});
    }}});
  }
  build() {
    Row({space:this.sideNavigation()?8:20}) {
      if(!pcHost.supported&&this.sideNavigation()){LibraryTabs({selected:'assistance',vertical:true,compact:this.compact(),onSelect:(tab:string)=>this.navigate(tab)})}
      if(pcHost.supported&&this.windowWidth>=840){AppNavigation({selected:'assistance',wide:true,onSelect:(page:string)=>this.navigate(page)})}
    Column({space:this.compact()?8:18}) {
      if(pcHost.supported&&this.windowWidth<840){AppNavigation({selected:'assistance',onSelect:(page:string)=>this.navigate(page)})}
      Text('远程协助').id('assistanceTitle').fontSize(this.compact()?20:UiFont.title).fontWeight(FontWeight.Bold).fontColor(UiColor.text).width('100%')
      Scroll(){
        Column({space:this.compact()?8:20}) {
          Text('输入对方提供的设备 ID 和临时验证码。').fontSize(this.compact()?13:UiFont.body).fontColor(UiColor.secondary).width('100%')
          if(this.compact()){TextInput({text:this.partnerId,placeholder:'对方设备 ID'}).height(44).fontColor(UiColor.text).placeholderColor(UiColor.secondary).caretColor(UiColor.primary).backgroundColor(UiColor.surface).maxLength(256).onChange((value:string)=>{this.partnerId=value;}).id('assistancePartnerId')}else{TextInput({text:this.partnerId,placeholder:'对方设备 ID'}).fontColor(UiColor.text).placeholderColor(UiColor.secondary).caretColor(UiColor.primary).backgroundColor(UiColor.surface).maxLength(256).onChange((value:string)=>{this.partnerId=value;}).id('assistancePartnerId')}
          if(this.compact()){TextInput({text:this.code,placeholder:'临时验证码'}).height(44).fontColor(UiColor.text).placeholderColor(UiColor.secondary).caretColor(UiColor.primary).backgroundColor(UiColor.surface).type(InputType.Password).maxLength(1024).onChange((value:string)=>{this.code=value;}).id('assistanceCode')}else{TextInput({text:this.code,placeholder:'临时验证码'}).fontColor(UiColor.text).placeholderColor(UiColor.secondary).caretColor(UiColor.primary).backgroundColor(UiColor.surface).type(InputType.Password).maxLength(1024).onChange((value:string)=>{this.code=value;}).id('assistanceCode')}
          if(this.message){UiNotice({text:this.message})}
          UiActionButton({label:'发起远程协助',available:this.partnerId.trim().length>0&&this.code.trim().length>0&&!session.busy&&!pcHost.blocksOutgoing,onAction:()=>this.connect()}).id('assistanceConnect')
          Text('验证码仅用于本次连接，不会保存。请只协助你认识且已同意的人。').fontSize(this.compact()?12:UiFont.caption).fontColor(UiColor.secondary).width('100%')
        }.width('100%').constraintSize({maxWidth:760}).padding({bottom:16}).alignItems(HorizontalAlign.Start)
      }.id('assistanceFormScroll').layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
      if(!pcHost.supported&&!this.sideNavigation()){LibraryTabs({selected:'assistance',onSelect:(tab:string)=>this.navigate(tab)})}
    }.layoutWeight(1).height('100%')
    }.width('100%').height('100%').padding({left:this.compact()?10:UiSpace.page,right:this.compact()?10:UiSpace.page,top:this.safeTop+(this.compact()?4:12),bottom:this.safeBottom+(this.compact()?2:4)}).backgroundColor(UiColor.background)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM],[LayoutSafeAreaEdge.TOP,LayoutSafeAreaEdge.BOTTOM])
      .expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
  }
}
