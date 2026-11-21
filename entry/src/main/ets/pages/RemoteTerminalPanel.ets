import { webview } from '@kit.ArkWeb';
import { UiColor } from './UiFoundation';
// Plain terminal transcript: no HTML, links, persistence or command history.
@Component
export struct RemoteTerminalPanel {
  @Link draft:string;
  @Prop output:string='';
  @Prop status:string='';
  @Prop ready:boolean=false;
  @Prop busy:boolean=false;
  @Prop standalone:boolean=false;
  @Prop closeLabel:string='关闭终端';
  @Prop description:string='复用当前已授权会话；仅手动提交输入。此处显示文本记录，不支持全屏终端排版。';
  onSend:(text:string,line:boolean)=>void=()=>{};
  onKey:(text:string)=>void=()=>{};
  onClose:()=>void=()=>{};
  private scroll:Scroller=new Scroller();
  private terminalWeb:webview.WebviewController=new webview.WebviewController();
  onTerminalReady:(controller:webview.WebviewController)=>void=()=>{};
  @Prop sending:boolean=false;
  @State private composing:boolean=false;

  @Builder private compactKey(label:string,value:string){
    Button(label).fontColor('#252B33').fontSize(13).backgroundColor('#E9ECF0').height(36).padding({left:9,right:9}).onClick(()=>this.onKey(value))
  }
  @Builder private standaloneView(){
    Column(){
      if(!this.ready||this.status.includes('未知')||this.status.includes('未确认')){
        Text(this.status).fontSize(11).fontColor('#626B76').width('100%').padding({left:12,right:12,bottom:4})
      }
      Web({src:$rawfile('terminal/index.html'),controller:this.terminalWeb}).id('terminalViewport').backgroundColor('#FFFFFF').javaScriptAccess(true).onlineImageAccess(false).domStorageAccess(false).databaseAccess(false).fileAccess(false).mixedMode(MixedMode.None).onPageEnd(()=>this.onTerminalReady(this.terminalWeb)).layoutWeight(1).width('100%')
      Row({space:4}){
        TextArea({text:this.draft,placeholder:'输入命令或指令'}).id('terminalStandaloneInput').fontColor('#20242A').placeholderColor('#7B838C').caretColor('#20242A').backgroundColor('#FFFFFF').height(36).layoutWeight(1).fontSize(13).onChange((text:string,preview:PreviewText)=>{this.draft=text;this.composing=preview!==undefined&&preview.value.length>0;}).key('terminalStandaloneInput').maxLength(2048).enabled(this.ready&&!this.busy)
        Button('发送并回车').fontColor('#252B33').fontSize(13).backgroundColor('#FFFFFF').height(36).padding({left:9,right:9}).enabled(this.ready&&!this.busy&&!this.sending&&!this.composing&&this.draft.length>0).accessibilityText('发送并回车').onClick(()=>this.onSend(this.draft,true))
      }.width('100%').padding({left:12,right:12})
      Scroll(){
        Row({space:2}){
          this.compactKey('↑','\u001b[A');this.compactKey('↓','\u001b[B');this.compactKey('←','\u001b[D');this.compactKey('→','\u001b[C');this.compactKey('Ctrl+C','\u0003');this.compactKey('Tab','\t')
          Button('Enter').fontColor('#252B33').fontSize(13).backgroundColor('#E9ECF0').height(36).padding({left:9,right:9}).accessibilityText('回车').onClick(()=>this.onKey('\r'))
          Button({type:ButtonType.Normal}){Image($r('app.media.terminal_keyboard')).width(20).height(20)}.backgroundColor('#E9ECF0').width(44).height(36).padding(0).accessibilityText('打开键盘').onClick(()=>{try{this.getUIContext().getFocusController().requestFocus('terminalStandaloneInput');}catch(_){}})
          this.compactKey('Esc','\u001b')
        }.padding(3).backgroundColor('#E9ECF0').borderRadius(22).clip(true).enabled(this.ready&&!this.busy)
      }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).padding({left:8,right:8,bottom:8,top:4})
    }.width('100%').height('100%').backgroundColor('#FFFFFF')
  }
  build(){
    if(this.standalone){this.standaloneView()}else{
      Column({space:10}){
        Row(){Text('交互终端').fontSize(22).fontColor(UiColor.text).layoutWeight(1);Button(this.closeLabel).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).id('closeTerminal').onClick(this.onClose)}.width('100%')
        Text(this.status).id('terminalStatus').fontSize(12).fontColor(UiColor.secondary).width('100%')
        Text(this.description).fontSize(11).fontColor(UiColor.secondary).width('100%')
        Scroll(this.scroll){Text(this.output||'等待电脑输出…').id('terminalOutput').fontSize(13).fontFamily('monospace').fontColor('#D5E8DC').width('100%').copyOption(CopyOptions.None)}.layoutWeight(1).width('100%').scrollBar(BarState.Off).backgroundColor('#09100E').padding(12).borderRadius(10)
        TextInput({text:this.draft,placeholder:'手动输入，不保存历史'}).id('terminalDraft').fontColor(UiColor.text).placeholderColor(UiColor.secondary).caretColor(UiColor.primary).backgroundColor(UiColor.neutralSoft).border({width:1,color:UiColor.divider}).onChange((text:string)=>{this.draft=text;}).maxLength(2048).enabled(this.ready&&!this.busy)
        Row({space:8}){Button('发送').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).id('terminalSend').layoutWeight(1).onClick(()=>this.onSend(this.draft,false));Button('发送并回车').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).id('terminalSendLine').layoutWeight(1).onClick(()=>this.onSend(this.draft,true))}.width('100%').enabled(this.ready&&!this.busy&&this.draft.length>0)
        Flex({wrap:FlexWrap.Wrap}){
          Button('回车').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).onClick(()=>this.onKey('\r'));Button('Tab').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).onClick(()=>this.onKey('\t'));Button('Ctrl+C').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).onClick(()=>this.onKey('\u0003'));Button('↑').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).onClick(()=>this.onKey('\u001b[A'));Button('↓').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).onClick(()=>this.onKey('\u001b[B'));Button('←').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).onClick(()=>this.onKey('\u001b[D'));Button('→').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).onClick(()=>this.onKey('\u001b[C'))
        }.width('100%').enabled(this.ready&&!this.busy)
        Button('滚动到末尾').fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).fontSize(12).onClick(()=>this.scroll.scrollEdge(Edge.Bottom))
      }.width('100%').height('100%').padding(18).backgroundColor(UiColor.surface)
    }
  }
}
