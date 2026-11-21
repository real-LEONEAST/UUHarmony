import { UiColor } from './UiFoundation';
import { AdvancedClient, AdvancedView } from './AdvancedClient';
import { ScreenRow } from './DisplayModel';
import { SharedFileTransfer } from './SharedFileTransfer';
import { common } from '@kit.AbilityKit';

@Component
export struct AdvancedPanel {
  @Require @Prop client:AdvancedClient;
  @Prop initialPage:number=0;
  @Link fileBrowsing:boolean;
  onClose:()=>void=()=>{};
  onPrivacy:()=>void=()=>{};
  @State private view:AdvancedView=new AdvancedView();
  @State private page:number=0;
  @State private volume:number=0.8;
  private timer:number=-1;
  aboutToAppear():void {
    this.page=this.initialPage;
    this.client.setForeground(true);this.client.files.setForeground(true);
    const context=this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.client.files.setContext(context);
    this.client.observe((v:AdvancedView)=>{this.view=v;this.volume=v.volume;});
    this.client.refresh();this.timer=setInterval(()=>this.client.refresh(),1000);
  }
  aboutToDisappear():void {if(this.timer>=0){clearInterval(this.timer);this.timer=-1;}this.client.observe(undefined);}
  @Builder
  screenTools(){
    Text('远程显示器').fontSize(18).fontColor(UiColor.text).width('100%')
    Text(this.view.screenText).fontSize(13).fontColor(UiColor.secondary).width('100%')
    if(this.view.controls){
      ForEach(this.view.controls.screens,(screen:ScreenRow)=>{
        Column({space:10}){
          Text(screen.name||('显示器 '+(screen.id+1))).fontSize(17).fontColor(UiColor.text).fontWeight(FontWeight.Medium).width('100%')
          Text(`${screen.native.width}×${screen.native.height} · ${screen.native.height>screen.native.width?'竖屏':'横屏'}${screen.primary?' · 主屏幕':''}${this.view.controls?.selectedScreen===screen.id?' · 当前选择':''}`).fontSize(13).fontColor(UiColor.secondary).width('100%')
          Button(this.view.controls?.requestedScreen===screen.id&&!!this.view.controls?.displayError?'重试该屏幕':'显示此屏幕')
            .id('switchScreen'+screen.id).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).constraintSize({minHeight:48}).width('100%')
            .enabled(!!this.view.controls?.switchCommandSupported&&!this.view.screenBusy&&!this.view.controls?.displayPending)
            .onClick(()=>this.client.switchScreen(screen.id))
        }.padding(14).width('100%').borderRadius(14).backgroundColor(UiColor.neutralSoft)
      },(screen:ScreenRow)=>screen.id.toString())
    }
    Divider().color(UiColor.divider)
    Button('防窥模式与壁纸',{type:ButtonType.Normal}).id('advancedPrivacy').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).constraintSize({minHeight:48}).width('100%').borderRadius(12).backgroundColor(UiColor.neutralSoft).fontColor(UiColor.text).onClick(this.onPrivacy)
  }
  @Builder
  audioTools(){
    Text('本地远程音频').fontSize(18).fontColor(UiColor.text).width('100%')
    Flex({wrap:FlexWrap.Wrap}){
      Button(this.view.audioEnabled?'停止播放':'启用播放',{type:ButtonType.Normal}).borderRadius(12).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).constraintSize({minHeight:48}).id('audioEnable').onClick(()=>this.client.configureAudio(!this.view.audioEnabled,this.view.audioMuted,this.volume))
      Button(this.view.audioMuted?'取消本地静音':'本地静音',{type:ButtonType.Normal}).borderRadius(12).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).constraintSize({minHeight:48}).id('audioMute').onClick(()=>this.client.configureAudio(this.view.audioEnabled,!this.view.audioMuted,this.volume))
    }
    Text(`本地音量 ${Math.round(this.volume*100)}%`).fontSize(13).fontColor(UiColor.text).width('100%')
    Slider({value:this.volume,min:0,max:1,step:0.05}).selectedColor(UiColor.primary).trackColor(UiColor.neutralSoft).blockColor(UiColor.text).onChange((value:number,mode:SliderChangeMode)=>{this.volume=value;if(mode===SliderChangeMode.End||mode===SliderChangeMode.Click){this.client.configureAudio(this.view.audioEnabled,this.view.audioMuted,value);}})
    Text(this.view.audioText).id('audioStatus').fontSize(12).fontColor(UiColor.text).width('100%')
  }
  @Builder
  clipboardTools(){
    Text('手动文本剪贴板').fontSize(18).fontColor(UiColor.text).width('100%')
    Text('鸿蒙 → Windows').fontSize(15).fontColor(UiColor.text).width('100%')
    Flex({wrap:FlexWrap.Wrap}){
      PasteButton().padding({top:12,bottom:12,left:24,right:24}).onClick((event:ClickEvent,result:PasteButtonOnClickResult)=>{if(result===PasteButtonOnClickResult.SUCCESS){this.client.captureLocalClipboard();}})
      Button('确认发送本机文本',{type:ButtonType.Normal}).borderRadius(12).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).constraintSize({minHeight:48}).id('sendLocalClipboard').enabled(this.view.clipHasDraft).onClick(()=>this.client.sendLocalClipboard())
    }
    Text('Windows → 鸿蒙').fontSize(15).fontColor(UiColor.text).width('100%')
    Button('开启60秒接收窗口',{type:ButtonType.Normal}).borderRadius(12).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).constraintSize({minHeight:48}).id('listenClipboard').onClick(()=>this.client.listenClipboard())
    Button('获取远端文本到本机剪贴板',{type:ButtonType.Normal}).borderRadius(12).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).constraintSize({minHeight:48}).id('applyRemoteClipboard').onClick(()=>this.client.applyRemoteClipboard())
    Button('关闭并清除缓存',{type:ButtonType.Normal}).borderRadius(12).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).constraintSize({minHeight:48}).onClick(()=>this.client.disableClipboard())
    Text(this.view.clipText).id('clipboardStatus').fontSize(13).fontColor(UiColor.text).width('100%')
  }
  @Builder
  tab(title:string,index:number){
    Button(title,{type:ButtonType.Normal}).id('advancedTab'+index).fontSize(14).height('auto').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).constraintSize({minHeight:48}).padding(12)
      .fontColor(this.page===index?UiColor.primary:UiColor.secondary).backgroundColor(this.page===index?UiColor.primarySoft:UiColor.neutralSoft).borderRadius(12)
      .accessibilityText(title+(this.page===index?'，已选择':'')).onClick(()=>this.page=index)
  }
  build(){
    Column({space:12}){
      if(this.page===3){SharedFileTransfer({browsing:$fileBrowsing,borrowed:true,embeddedName:'远程文件',onClose:()=>this.onClose()})}else{
      Row({space:8}){Text(this.page===0?'多显示器':this.page===1?'远程声音':this.page===2?'剪贴板':'远程文件').fontSize(22).fontColor(UiColor.text).fontWeight(FontWeight.Bold).layoutWeight(1);Button('返回',{type:ButtonType.Normal}).borderRadius(12).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).constraintSize({minHeight:48}).onClick(()=>this.onClose())}.width('100%')
      Scroll(){Column({space:16}){
        if(this.page===0){this.screenTools()}
        if(this.page===1){this.audioTools()}
        if(this.page===2){this.clipboardTools()}
      }.width('100%')}.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      }
    }.padding(16).width('100%').height('100%').backgroundColor(UiColor.surface).foregroundColor(UiColor.text).onTouch((event:TouchEvent)=>event.stopPropagation())
  }
}
