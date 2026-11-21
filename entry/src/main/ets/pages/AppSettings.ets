import { bundleManager, common } from '@kit.AbilityKit';
import { appAppearance } from './AppAppearance';
import { RemotePreferences } from './RemotePreferences';
import { session } from './SessionClient';
import { UiColor } from './UiFoundation';

@Entry
@Component
struct AppSettings {
  @State private page:string='home';
  @State private appearance:number=appAppearance.value();
  @State private codec:number=0;
  @State private version:string='读取中';
  @State private saving:boolean=false;
  @State private connected:boolean=false;
  @StorageLink('uuSafeTop') private safeTop:number=12;
  @StorageLink('uuSafeBottom') private safeBottom:number=12;
  private prefs:RemotePreferences|undefined=undefined;
  private offSession:()=>void=()=>{};
  aboutToAppear():void {
    this.prefs=new RemotePreferences(this.getUIContext().getHostContext() as common.UIAbilityContext);this.codec=this.prefs.loadVideoCodec();
    this.offSession=session.observe(()=>{this.connected=session.busy;});this.connected=session.busy;
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).then((info:bundleManager.BundleInfo)=>{this.version=info.versionName;},()=>{this.version='未知';});
  }
  aboutToDisappear():void{this.offSession();}
  onBackPress():boolean{if(this.page!=='home'){this.page='home';return true;}return false;}
  private back():void{if(!this.onBackPress()){this.getUIContext().getRouter().back();}}
  private appearanceLabel():string{return ['跟随系统','浅色','深色'][this.appearance];}
  private rowSelected(key:string):boolean{if(key==='appearanceSystem'){return this.appearance===0;}if(key==='appearanceLight'){return this.appearance===1;}if(key==='appearanceDark'){return this.appearance===2;}if(key==='settingsCodecAuto'){return this.codec===0;}if(key==='settingsCodecH264'){return this.codec===1;}return false;}
  private rowDescription(key:string,fallback:string):string{if(key==='settingsAppearance'){return this.appearanceLabel();}if(key==='settingsVideo'){return this.codec===0?'H.265 优先':'H.264 兼容';}if(key==='settingsAbout'){return '版本 '+this.version;}return fallback;}
  private async chooseAppearance(value:number):Promise<void>{if(this.saving){return;}const old=this.appearance;this.saving=true;this.appearance=value;try{if(!await appAppearance.choose(value)){this.appearance=old;this.getUIContext().getPromptAction().showToast({message:'外观设置未保存，请重试'});}}finally{this.saving=false;}}
  private async chooseCodec(value:number):Promise<void>{if(this.saving||this.connected||!this.prefs){return;}this.saving=true;try{if(await this.prefs.saveVideoCodec(value)){this.codec=value;}else{this.getUIContext().getPromptAction().showToast({message:'视频设置未保存，请重试'});}}finally{this.saving=false;}}
  @Builder
  row(title:string,description:string,key:string,action:()=>void){
    Button({type:ButtonType.Normal}){
      Row({space:12}){Column({space:5}){Text(title).fontSize(17).fontColor(UiColor.text).width('100%');if(description.length){Text(this.rowDescription(key,description)).fontSize(13).fontColor(UiColor.secondary).width('100%')}}.layoutWeight(1);Text(this.rowSelected(key)?'✓':this.page==='home'?'›':'○').fontSize(22).fontColor(this.rowSelected(key)?UiColor.primary:UiColor.secondary)}.width('100%')
    }.id(key).width('100%').height('auto').constraintSize({minHeight:64}).padding(18).borderRadius(12).backgroundColor(this.rowSelected(key)?UiColor.primarySoft:UiColor.surface).enabled((!key.startsWith('settingsCodec')||!this.connected)&&!this.saving).onClick(action)
  }
  build(){
    Column({space:18}){
      Row({space:12}){Button('‹',{type:ButtonType.Normal}).id('settingsBack').width(48).height(48).fontSize(28).fontColor(UiColor.text).backgroundColor(UiColor.surface).borderRadius(12).accessibilityText('返回').onClick(()=>this.back());Text(this.page==='appearance'?'外观':this.page==='codec'?'视频编码':this.page==='about'?'关于':'设置').fontSize(26).fontColor(UiColor.text).fontWeight(FontWeight.Bold).layoutWeight(1)}.width('100%')
      Scroll(){Column({space:12}){
        if(this.page==='home'){
          this.row('外观',this.appearanceLabel(),'settingsAppearance',()=>{this.page='appearance';})
          this.row('视频编码',this.codec===0?'H.265 优先':'H.264 兼容','settingsVideo',()=>{this.page='codec';})
          this.row('操控方案','管理虚拟按键布局','settingsVirtualPlans',()=>{this.getUIContext().getRouter().pushUrl({url:'pages/VirtualPlanPage'}).catch(()=>{});})
          this.row('关于','版本 '+this.version,'settingsAbout',()=>{this.page='about';})
        }else if(this.page==='appearance'){
          this.row('跟随系统','与鸿蒙系统的浅色、深色模式同步','appearanceSystem',()=>this.chooseAppearance(0))
          this.row('浅色','白色标题栏和菜单','appearanceLight',()=>this.chooseAppearance(1))
          this.row('深色','深色标题栏和菜单','appearanceDark',()=>this.chooseAppearance(2))
        }else if(this.page==='codec'){
          this.row('H.265 优先','不支持时自动回退 H.264','settingsCodecAuto',()=>this.chooseCodec(0))
          this.row('H.264 兼容','优先兼容性','settingsCodecH264',()=>this.chooseCodec(1))
          Text(this.connected?'请结束当前远控后更改编码设置。':'下次连接生效。').fontSize(14).fontColor(UiColor.secondary).width('100%').padding(6)
        }else{
          Column({space:16}){Text('UUHarmony').fontSize(24).fontColor(UiColor.text);Text('版本 '+this.version).id('settingsVersion').fontSize(17).fontColor(UiColor.text);Text('非官方客户端').fontSize(14).fontColor(UiColor.secondary)}.padding(24).width('100%').backgroundColor(UiColor.surface).borderRadius(18)
        }
      }.width('100%').constraintSize({maxWidth:720})}.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Off)
    }.width('100%').height('100%').padding({left:18,right:18,top:this.safeTop+12,bottom:this.safeBottom+12}).backgroundColor(UiColor.background).expandSafeArea([SafeAreaType.SYSTEM],[SafeAreaEdge.TOP,SafeAreaEdge.BOTTOM])
  }
}
