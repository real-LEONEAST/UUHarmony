import { inputMethod } from '@kit.IMEKit';
import { UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { RemoteImeModel } from './RemoteImeModel';

// InputMethodController is process-wide. Serialize across old/new dock instances;
// an old detach must never unbind a newer editor. Unsubscribe only our callbacks.
let imeWork:Promise<void>=Promise.resolve();
let imeOwner:RemoteImeClient|undefined=undefined;
export class RemoteImeClient {
  private controller:inputMethod.InputMethodController=inputMethod.getController();
  readonly model:RemoteImeModel;
  private wanted:boolean=false;
  private revision:number=0;
  private bound:boolean=false;
  private attaching:boolean=false;
  private shown:boolean=false;
  private operation:string='准备';
  private ready:()=>boolean;
  private changed:()=>void;
  private status:(message:string)=>void;
  private released:()=>void;
  constructor(commit:(text:string)=>boolean,key:(vk:number,count:number)=>boolean,
    ready:()=>boolean,changed:()=>void,status:(message:string)=>void,released:()=>void){
    this.ready=ready;this.changed=changed;this.status=status;this.released=released;
    this.model=new RemoteImeModel(commit,key,()=>this.wanted&&this.bound&&this.ready());
  }
  private update(ok:boolean=true):void {
    this.changed();
    if(!ok){this.status('此次输入未发送，请检查连接或组合键；不会保存或重放。');}
    if(this.wanted&&this.bound&&this.ready()){
      this.controller.changeSelection(this.model.preview,this.model.index(),this.model.index()).catch(()=>{});
    }
  }
  private insert=(text:string):void=>{this.update(this.model.insert(text));};
  private preview=(text:string,range:inputMethod.Range):void=>{this.update(this.model.setPreview(text,range.start,range.end));};
  private finish=():void=>{this.update(this.model.finish());};
  private leftDelete=(length:number):void=>{this.update(this.model.remove(length));};
  private rightDelete=(length:number):void=>{this.update(this.model.remove(length,true));};
  private enter=(_key:inputMethod.FunctionKey):void=>{this.update(this.model.enter());};
  private leftText=(length:number):string=>this.wanted&&this.ready()?this.model.left(length):'';
  private rightText=(length:number):string=>this.wanted&&this.ready()?this.model.right(length):'';
  private index=():number=>this.wanted&&this.ready()?this.model.index():0;
  private select=(range:inputMethod.Range):void=>{this.update(this.model.select(range.start,range.end));};
  private move=(direction:inputMethod.Direction):void=>{
    const keys:number[]=[0,38,40,37,39];this.update(this.model.move(keys[direction]||0));
  };
  private keyboard=(status:inputMethod.KeyboardStatus):void=>{
    if(!this.wanted){return;}
    if(status===inputMethod.KeyboardStatus.SHOW){this.shown=true;return;}
    // A stale/initial HIDE can arrive while a new editor is attaching. It is
    // not evidence that the user dismissed this editor's keyboard.
    if(status===inputMethod.KeyboardStatus.HIDE&&!this.attaching&&this.shown){this.stop();this.released();}
  };
  visibility(visible:boolean):void {
    if(!this.wanted){return;}
    if(visible){this.shown=true;}
    else if(!this.attaching&&this.shown){this.stop();this.released();}
  }
  private listen():void {
    this.bound=true;
    this.operation='insertText';
    this.controller.on('insertText',this.insert);
    this.operation='setPreviewText';
    this.controller.on('setPreviewText',this.preview);
    this.operation='finishTextPreview';
    this.controller.on('finishTextPreview',this.finish);
    this.controller.on('deleteLeft',this.leftDelete);
    this.controller.on('deleteRight',this.rightDelete);
    this.controller.on('sendFunctionKey',this.enter);
    this.controller.on('getLeftTextOfCursor',this.leftText);
    this.controller.on('getRightTextOfCursor',this.rightText);
    this.controller.on('getTextIndexAtCursor',this.index);
    this.controller.on('selectByRange',this.select);
    this.controller.on('moveCursor',this.move);
    this.controller.on('sendKeyboardStatus',this.keyboard);
  }
  private unlisten():void {
    if(!this.bound){return;}this.bound=false;
    this.controller.off('insertText',this.insert);
    this.controller.off('setPreviewText',this.preview);
    this.controller.off('finishTextPreview',this.finish);
    this.controller.off('deleteLeft',this.leftDelete);
    this.controller.off('deleteRight',this.rightDelete);
    this.controller.off('sendFunctionKey',this.enter);
    this.controller.off('getLeftTextOfCursor',this.leftText);
    this.controller.off('getRightTextOfCursor',this.rightText);
    this.controller.off('getTextIndexAtCursor',this.index);
    this.controller.off('selectByRange',this.select);
    this.controller.off('moveCursor',this.move);
    this.controller.off('sendKeyboardStatus',this.keyboard);
  }
  private async detachOwned():Promise<void> {
    if(imeOwner!==this){return;}
    this.unlisten();imeOwner=undefined;
    try{await this.controller.detach();}catch(_){this.status('输入已停止；系统输入法解绑未确认。');}
  }
  start(context:UIContext,reason:inputMethod.RequestKeyboardReason=inputMethod.RequestKeyboardReason.TOUCH):void {
    this.stop();this.wanted=true;this.attaching=true;this.shown=false;const revision=++this.revision;
    imeWork=imeWork.then(async()=>{
      if(!this.wanted||revision!==this.revision||!this.ready()){return;}
      if(imeOwner&&imeOwner!==this){
        const old=imeOwner;old.wanted=false;old.revision++;old.model.reset();old.changed();old.unlisten();imeOwner=undefined;
        try{await old.controller.detach();}catch(_){}
        if(!this.wanted||revision!==this.revision||!this.ready()){return;}
      }
      imeOwner=this;
      try{
        // API26 on the actual phone emulator rejects insertText listeners with
        // 12800009 before attachment. Bind without opening the keyboard first,
        // install all callbacks, then enter the editing state explicitly.
        this.operation='绑定';
        await this.controller.attachWithUIContext(context,{
          inputAttribute:{textInputType:inputMethod.TextInputType.TEXT,enterKeyType:inputMethod.EnterKeyType.NEWLINE},
          selection:{start:0,end:0},newEditBox:true
        },{showKeyboard:false,requestKeyboardReason:reason});
        if(!this.wanted||revision!==this.revision||!this.ready()){await this.detachOwned();return;}
        this.listen();
        this.operation='显示';await this.controller.showTextInput(reason);
        if(this.wanted&&revision===this.revision&&this.ready()){this.attaching=false;this.status('选词即输入 · 回车单独发送');}else{await this.detachOwned();}
      }catch(error){
        if(revision===this.revision){const code=(error as BusinessError).code;this.attaching=false;this.wanted=false;this.model.reset();this.changed();this.status('输入法未打开（'+this.operation+' / '+(code||'unknown')+'），点此重试');}
        await this.detachOwned();
      }
    }).catch(()=>{this.status('输入法会话不可用，请重新打开键盘。');});
  }
  stop():void {
    this.wanted=false;this.attaching=false;this.shown=false;this.revision++;this.model.reset();this.changed();
    // Callback gate closes synchronously, before asynchronous detach can finish.
    imeWork=imeWork.then(()=>this.detachOwned()).catch(()=>{});
  }
}
