import { UiColor } from './UiFoundation';
import { RemoteImeClient } from './RemoteImeClient';
import { inputMethod } from '@kit.IMEKit';
import { ComputerKey, COMPUTER_ROWS, FUNCTION_KEYS, NAVIGATION_KEYS, NUMBER_ROWS } from './RemoteKeyboardKeys';
class DockCombo {
  label:string;modifiers:number[];code:number;
  constructor(label:string,modifiers:number[],code:number){this.label=label;this.modifiers=modifiers;this.code=code;}
}
@Component
export struct RemoteKeyboardDock {
  @Link composing:boolean;
  @Prop @Watch('gateChanged') available:boolean=false;
  @Prop @Watch('resetChanged') resetToken:number=0;
  @Prop nativeOnly:boolean=false;
  @Prop modifiers:string='';
  @Prop hint:string='手机选词后即时上屏；外接键盘原生转发。';
  @Prop maxHeight:number=280;
  @Prop @Watch('imeVisibilityChanged') imeVisible:boolean=false;
  onModifier:(key:number)=>void=()=>{};
  onKey:(key:number,label:string)=>void=()=>{};
  onCombo:(modifiers:number[],key:number,label:string)=>void=()=>{};
  onClear:()=>void=()=>{};
  onCommit:(text:string)=>boolean=()=>false;
  onImeKey:(key:number,count:number)=>boolean=()=>false;
  onPhysicalKey:(event:KeyEvent)=>boolean=()=>false;
  canInput:()=>boolean=()=>false;
  inputEpoch:()=>number=()=>0;
  onReset:()=>void=()=>{};
  onClose:()=>void=()=>{};
  onFocusChange:(focused:boolean)=>void=()=>{};
  @State private page:number=0;
  @State private previewText:string='';
  @State private imeStatus:string='点此使用手机输入法，选词后即时上屏';
  @State private nativeInput:boolean=false;
  @State private numberPad:boolean=false;
  private pendingActivation:boolean=false;
  private imeEpoch:number=-1;
  private focused:boolean=false;
  private visible:boolean=false;
  private ime:RemoteImeClient|undefined=undefined;
  private focusTimer:number=-1;
  private focusRetries:number=0;
  private keyboardReason:inputMethod.RequestKeyboardReason=inputMethod.RequestKeyboardReason.TOUCH;
  aboutToAppear():void {this.visible=true;this.nativeInput=this.nativeOnly;this.page=this.nativeOnly?1:0;this.focusTimer=setTimeout(()=>this.activate(false),150);}
  aboutToDisappear():void {this.visible=false;if(this.focusTimer>=0){clearTimeout(this.focusTimer);this.focusTimer=-1;}this.stopIme();this.onFocusChange(false);this.onReset();}
  private stopIme():void {this.pendingActivation=false;const old=this.ime;this.ime=undefined;old?.stop();this.previewText='';this.composing=false;}
  private gateChanged():void {if(!this.available){this.stopIme();this.onReset();this.imeStatus='输入已暂停，恢复后点此继续';}else if(this.visible&&this.page===0&&!this.nativeInput){this.activate(false);}}
  private imeVisibilityChanged():void {this.ime?.visibility(this.imeVisible);}
  private resetChanged():void {if(this.imeEpoch!==this.inputEpoch()){this.stopIme();this.imeStatus='输入已重置，点此继续；不重放旧输入。';}}
  private activate(touched:boolean=true):void {
    if(!this.visible){return;}
    this.stopIme();this.onReset();
    // ArkUI delivers @Watch(resetToken) before the asynchronous focus callback.
    // Mark the reset we just requested as current before requesting focus, or
    // the watch cancels pendingActivation and no IME attachment is ever made.
    this.imeEpoch=this.inputEpoch();this.nativeInput=this.nativeOnly;this.page=this.nativeOnly?1:0;this.pendingActivation=true;
    this.keyboardReason=touched?inputMethod.RequestKeyboardReason.TOUCH:inputMethod.RequestKeyboardReason.OTHER;this.focusRetries=0;this.focusReceiver();
  }
  private focusReceiver():void {
    if(!this.visible){return;}
    // UIContext.FocusController.requestFocus returns void; the actual focus
    // callback, not a synthetic return value, is the source of truth.
    try{this.getUIContext().getFocusController().requestFocus('remoteText');}catch(_){this.imeStatus='未能获得输入焦点，点此重试';}
    if(!this.focused){if(this.focusRetries++<1){this.focusTimer=setTimeout(()=>this.focusReceiver(),40);}else{this.pendingActivation=false;this.imeStatus='未能获得输入焦点，点此重试';}return;}
    if(this.focused){this.attachIme();}
  }
  private attachIme():void {
    if(!this.pendingActivation){return;}this.pendingActivation=false;
    if(this.nativeOnly||this.page!==0||!this.canInput()){return;}
    const epoch=this.inputEpoch();this.imeEpoch=epoch;
    const client=new RemoteImeClient((text:string)=>this.onCommit(text),(key:number,count:number)=>this.onImeKey(key,count),
      ()=>this.visible&&this.focused&&this.page===0&&!this.nativeInput&&epoch===this.inputEpoch()&&this.canInput(),
      ()=>{if(this.ime===client){this.previewText=client.model.preview;this.composing=client.model.composing;}},
      (status:string)=>{if(this.ime===client){this.imeStatus=status;}},()=>this.onReset());
    this.ime=client;client.start(this.getUIContext(),this.keyboardReason);
  }
  private editorBlur():void {this.focused=false;this.stopIme();this.onFocusChange(false);this.onReset();}
  private physical(event:KeyEvent):boolean {
    if(event.keySource!==KeySource.Keyboard||(event.type!==KeyType.Down&&event.type!==KeyType.Up)){return false;}
    if(!this.nativeInput){this.nativeInput=true;this.stopIme();this.onReset();this.imeStatus='外接键盘原生转发；点此返回手机输入法。';}
    // Pre-IME consumption prevents the same physical key from also committing
    // text through the local IME. Unknown/system keys never become local text.
    this.onPhysicalKey(event);return true;
  }
  private rows:ComputerKey[][]=COMPUTER_ROWS;
  private functions:ComputerKey[]=FUNCTION_KEYS;
  private navigation:ComputerKey[]=NAVIGATION_KEYS;
  private numbers:ComputerKey[][]=NUMBER_ROWS;
  private essentials:ComputerKey[]=[new ComputerKey('Esc',27),new ComputerKey('Tab',9),new ComputerKey('Ctrl',162,1,'Ctrl'),new ComputerKey('Alt',164,1,'Alt'),new ComputerKey('Shift',160,1,'Shift'),new ComputerKey('Win',91,1,'Win'),new ComputerKey('←',37),new ComputerKey('↑',38),new ComputerKey('↓',40),new ComputerKey('→',39),new ComputerKey('Enter',13),new ComputerKey('⌫',8)];
  private combos:DockCombo[]=[new DockCombo('全选 Ctrl+A',[162],65),new DockCombo('复制 Ctrl+C',[162],67),new DockCombo('粘贴 Ctrl+V',[162],86),new DockCombo('撤销 Ctrl+Z',[162],90),new DockCombo('重做 Ctrl+Y',[162],89),new DockCombo('切换窗口 Alt+Tab',[164],9),new DockCombo('显示桌面 Win+D',[91],68)];
  private close():void {this.stopIme();this.onReset();this.onClose();}
  private choose(page:number):void {this.stopIme();this.onReset();this.page=page;if(page===0){this.activate();}else{this.pendingActivation=false;this.focusReceiver();}}
  private pressKey(key:ComputerKey):void {
    // Both sides select the same single-use soft modifier. Physical keyboard
    // left/right VK forwarding remains in the existing hardware path.
    if(key.modifier.length){this.onModifier(key.code===161?160:key.code===163?162:key.code===165?164:key.code);}else{this.onKey(key.code,key.label);}
  }
  private selected(key:ComputerKey):boolean {return key.modifier.length>0&&this.modifiers.includes(key.modifier);}
  @Builder
  tab(label:string,index:number){
    Button(label,{type:ButtonType.Normal}).focusOnTouch(false).id('keyboardTab'+index).fontSize(13).height(34).padding({left:12,right:12})
      .backgroundColor(this.page===index?UiColor.surface:Color.Transparent).fontColor(this.page===index?UiColor.primary:UiColor.secondary).fontWeight(this.page===index?FontWeight.Medium:FontWeight.Regular).borderRadius(8).accessibilityText(label+(this.page===index?'，已选择':'')).onClick(()=>this.choose(index))
  }
  @Builder
  keyCap(key:ComputerKey,compact:boolean=false){
    Button(key.label,{type:ButtonType.Normal}).focusOnTouch(false).id('computerKey'+key.code).width(compact?undefined:'100%').height(this.page===1?28:34).fontSize(key.label.length>=4?10:12).fontWeight(FontWeight.Medium)
      .padding({left:compact?12:1,right:compact?12:1}).borderRadius(7)
      .backgroundColor(this.selected(key)?UiColor.primary:UiColor.neutralSoft).fontColor(this.selected(key)?UiColor.onPrimary:UiColor.text)
      .border({width:1,color:this.selected(key)?UiColor.primary:UiColor.divider,radius:7})
      .accessibilityText(key.label+(this.selected(key)?' 已选择':'')).enabled(this.available&&!this.composing).onClick(()=>this.pressKey(key))
  }
  @Builder
  keyStrip(keys:ComputerKey[]){
    Scroll(){Row({space:5}){ForEach(keys,(key:ComputerKey)=>{this.keyCap(key,true)},(key:ComputerKey)=>key.code.toString())}.padding({right:2})}
      .width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
  }
  @Builder
  matrix(rows:ComputerKey[][]){
    Column({space:4}){ForEach(rows,(row:ComputerKey[],index:number)=>{
      Row({space:4}){ForEach(row,(key:ComputerKey)=>{Row(){this.keyCap(key)}.layoutWeight(key.weight)},(key:ComputerKey)=>key.code.toString())}.width('100%')
    },(_row:ComputerKey[],index:number)=>index.toString())}.width('100%')
  }
  build(){
    Column({space:8}){
      Row({space:8}){
        Scroll(){Row({space:2}){this.tab('输入法',0);this.tab('电脑键盘',1);this.tab('快捷键',2)}.padding(3).backgroundColor(UiColor.neutralSoft).borderRadius(10)}.layoutWeight(1).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        Button({type:ButtonType.Normal}){Text('×').fontSize(22).fontColor(UiColor.secondary).textAlign(TextAlign.Center).width('100%')}.focusOnTouch(false).id('closeKeyboard').accessibilityText('关闭键盘').padding(0).backgroundColor(UiColor.neutralSoft).width(38).height(38).borderRadius(10).onClick(()=>this.close())
      }.width('100%')
      Scroll(){Column({space:this.page===1?5:9}){
        Row({space:8}){
          Text(this.composing?this.previewText:this.page!==0?'点此切回手机输入法':this.nativeOnly?'使用电脑输入法组词':this.nativeInput?'外接键盘模式 · 点此使用手机输入法':this.imeStatus)
            .id('remoteText').focusable(true).focusOnTouch(true).layoutWeight(1).height(this.page===0?42:this.page===1?20:28).maxLines(1).fontSize(this.page===0?14:11)
            .fontColor(this.composing?UiColor.text:UiColor.secondary).backgroundColor(this.page===0?UiColor.neutralSoft:Color.Transparent).borderRadius(9).padding({left:10,right:10})
            .onClick(()=>this.activate()).onFocus(()=>{this.focused=true;this.onFocusChange(true);this.attachIme();}).onBlur(()=>this.editorBlur())
            .onKeyPreIme((event:KeyEvent)=>this.physical(event))
        }.width('100%')
        if(this.page===0){this.keyStrip(this.essentials)}
        if(this.page===1){
          this.keyStrip(this.functions)
          Row(){Text(this.numberPad?'数字键盘':'标准键盘').fontSize(11).fontColor(UiColor.secondary);Blank();Button(this.numberPad?'字母区':'数字区',{type:ButtonType.Normal}).focusOnTouch(false).id('toggleNumberPad').fontSize(11).fontColor(UiColor.primary).backgroundColor(Color.Transparent).height(20).padding({left:8,right:8}).onClick(()=>{this.numberPad=!this.numberPad;})}.width('100%')
          if(this.numberPad){this.matrix(this.numbers)}else{this.matrix(this.rows)}
          this.keyStrip(this.navigation)
        }
        if(this.page===2){
          Flex({wrap:FlexWrap.Wrap}){ForEach(this.combos,(combo:DockCombo)=>{
            Button(combo.label,{type:ButtonType.Normal}).focusOnTouch(false).id('combo'+combo.modifiers[0]+'_'+combo.code).fontSize(12).fontColor(UiColor.text).backgroundColor(UiColor.neutralSoft).border({width:1,color:UiColor.divider}).borderRadius(9)
              .height(40).padding({left:14,right:14}).margin({right:7,bottom:7}).enabled(this.available&&!this.composing).onClick(()=>this.onCombo(combo.modifiers,combo.code,combo.label))
          },(combo:DockCombo)=>combo.label)}.width('100%')
        }
        if(!this.available){Text('远程输入已暂停').fontSize(11).fontColor(UiColor.warning).width('100%')}
        if(this.modifiers.length>0){Row(){Text(this.modifiers+' · 下一键生效').fontSize(11).fontColor(UiColor.primary);Blank();Button('清除',{type:ButtonType.Normal}).focusOnTouch(false).id('clearModifiers').fontSize(11).height(26).padding({left:8,right:8}).fontColor(UiColor.primary).backgroundColor(UiColor.primarySoft).onClick(()=>this.onClear())}.width('100%')}
      }.width('100%')}.constraintSize({maxHeight:Math.max(44,this.maxHeight-66)}).width('100%').scrollBar(BarState.Off)
    }.id('remoteKeyboardDock').padding(10).width('100%').constraintSize({maxHeight:this.maxHeight}).backgroundColor(UiColor.surface).foregroundColor(UiColor.text).borderRadius(16).border({width:1,color:UiColor.divider}).clip(true)
      .onTouch((e:TouchEvent)=>e.stopPropagation())
  }
}
