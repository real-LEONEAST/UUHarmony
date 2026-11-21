import { UiColor } from './UiFoundation';
import { toolbarStep } from './RemoteToolbarModel';

// This overlay never owns the Surface, session or model subscriptions.
@Component
export struct RemoteToolsRail {
  @Prop selectedTool:string='';
  @Prop screenLabel:string='等待屏幕信息';
  @Prop inputAvailable:boolean=false;
  @Prop compact:boolean=false;
  @Prop horizontal:boolean=false;
  @Prop availableHeight:number=440;
  @Prop availableWidth:number=296;

  onControls:()=>void=()=>{};
  onMonitors:()=>void=()=>{};
  onKeyboard:()=>void=()=>{};
  onDesktop:()=>void=()=>{};
  onWindows:()=>void=()=>{};
  @State private swiping:boolean=false;

  onBegin:()=>void=()=>{};
  onStep:(step:number)=>void=()=>{};

  @Builder
  action(icon:Resource,label:string,key:string,callback:()=>void){
    Button({type:ButtonType.Normal}){
      Column({space:4}){
        if(key==='railDesktop'){Image($r('app.media.ui_computer')).width(24).height(24).fillColor(UiColor.text).accessibilityLevel('no')}else{SymbolGlyph(icon).fontSize(this.compact?22:24).fontColor([UiColor.text]).accessibilityLevel('no')}
        Text(label).fontSize(12).minFontSize(10).maxFontSize(12).maxLines(1).fontColor(UiColor.text).textAlign(TextAlign.Center).width('100%')
      }.width('100%')
    }.id(key).width(this.horizontal?'auto':'100%').height(this.horizontal?'100%':'auto').layoutWeight(1).padding(2)
      .backgroundColor(this.selectedTool===key?UiColor.neutralSoft:Color.Transparent).borderRadius(10)
      .enabled(key==='railControls'||key==='railMonitors'||this.inputAvailable)
      .accessibilityText(label).onClick(()=>{if(!this.swiping){callback();}})
  }
  build(){
    Flex({direction:this.horizontal?FlexDirection.Row:FlexDirection.Column}){
      this.action($r('sys.symbol.gearshape'),'操作','railControls',this.onControls)
      this.action($r('sys.symbol.desktop'),'显示器','railMonitors',this.onMonitors)
      this.action($r('sys.symbol.keyboard'),'键盘','railKeyboard',this.onKeyboard)
      this.action($r('sys.symbol.display'),'显示桌面','railDesktop',this.onDesktop)
      this.action($r('sys.symbol.rectangle_on_rectangle'),'切换窗口','railWindows',this.onWindows)
    }.id('remoteToolsRail').backgroundColor(UiColor.surface).borderRadius(14).padding(4).height(this.availableHeight).width(this.availableWidth).hitTestBehavior(HitTestMode.Default)
      .accessibilityDescription(this.screenLabel+(this.horizontal?'。左右滑动切换显示器。':'。上下滑动切换显示器。'))
      .onTouch((e:TouchEvent)=>{e.stopPropagation();if(e.type===TouchType.Down){this.swiping=false;this.onBegin();}})
      .priorityGesture(PanGesture({direction:PanDirection.All,distance:12,fingers:1})
        .onActionStart(()=>{this.swiping=true;})
        .onActionEnd((e:GestureEvent)=>{const step=this.horizontal?toolbarStep(e.offsetY,e.offsetX):toolbarStep(e.offsetX,e.offsetY);if(step!==0){this.onStep(step);}})
        .onActionCancel(()=>{this.swiping=true;}))
  }
}
