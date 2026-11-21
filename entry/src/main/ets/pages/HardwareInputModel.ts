import { MobileInput, RemoteInput } from './MobileInput';

// KeyCode values are from the installed API26 @ohos.multimodalInput.keyCode.d.ts.
// These are physical Windows VK positions; text/IME entry remains in TextInput.
// System Home/Back/power/media keys and ambiguous locale symbols stay local.
export function harmonyKeyToVk(code:number):number|undefined {
  if(!Number.isInteger(code)){return undefined;}
  if(code>=2000&&code<=2009){return 48+code-2000;}
  if(code>=2017&&code<=2042){return 65+code-2017;}
  if(code>=2090&&code<=2101){return 112+code-2090;}
  if(code>=2103&&code<=2112){return 96+code-2103;}
  switch(code){
    case 2012:return 38;case 2013:return 40;case 2014:return 37;case 2015:return 39;
    case 2043:return 188;case 2044:return 190;
    case 2045:return 164;case 2046:return 165;case 2047:return 160;case 2048:return 161;
    case 2049:return 9;case 2050:return 32;case 2054:return 13;case 2055:return 8;
    case 2056:return 192;case 2057:return 189;case 2058:return 187;
    case 2059:return 219;case 2060:return 221;case 2061:return 220;
    case 2062:return 186;case 2063:return 222;case 2064:return 191;
    case 2067:return 93;case 2068:return 33;case 2069:return 34;case 2070:return 27;case 2071:return 46;
    case 2072:return 162;case 2073:return 163;case 2074:return 20;case 2075:return 145;
    case 2076:return 91;case 2077:return 92;case 2079:return 44;case 2080:return 19;
    case 2081:return 36;case 2082:return 35;case 2083:return 45;
    case 2102:return 144;case 2113:return 111;case 2114:return 106;case 2115:return 109;
    case 2116:return 107;case 2117:return 110;case 2118:return 108;case 2119:return 13;
    default:return undefined;
  }
}

export type HardwareMouseKind='move'|'down'|'up';
export type HardwarePointerSource='mouse'|'touch';

// Use separate instances if mouse and keyboard capture have different switches.
// Root still calls SessionClient.releaseInputs on every reset: its native registry
// provides cleanup even if a release cannot be queued through the ordinary sink.
export class HardwareInput {
  private sink:(events:RemoteInput[])=>boolean;
  private pointer:MobileInput;
  private capture:boolean=false;private focused:boolean=false;private ready:boolean=false;
  private keys:Map<number,number>=new Map();
  private buttons:number[]=[];
  constructor(sink:(events:RemoteInput[])=>boolean){this.sink=sink;this.pointer=new MobileInput(sink);}
  private allowed():boolean{return this.capture&&this.focused&&this.ready;}
  setGate(capture:boolean,focused:boolean,ready:boolean):void {
    const next=capture&&focused&&ready;
    if(this.allowed()&&!next){this.cancel();}
    this.capture=capture;this.focused=focused;this.ready=ready;
  }
  key(code:number,down:boolean):boolean {
    if(!this.allowed()){return false;}
    const vk=harmonyKeyToVk(code);if(vk===undefined){return false;}
    const held=this.keys.get(code);
    if(down){
      // Native already suppresses duplicate presses. Consume OS auto-repeat
      // locally rather than generating artificial key-up transitions.
      if(held!==undefined){return true;}
      if(this.keys.size>=32){return false;}
      let same:boolean=false;this.keys.forEach((value:number)=>{if(value===vk){same=true;}});
      if(!same&&!this.sink([{action:'kbd_press',key:vk}])){return false;}
      this.keys.set(code,vk);return true;
    }
    if(held===undefined){return false;}
    let another:boolean=false;this.keys.forEach((value:number,other:number)=>{if(other!==code&&value===vk){another=true;}});
    if(!another&&!this.sink([{action:'kbd_release',key:vk}])){return false;}
    this.keys.delete(code);return true;
  }
  mouse(kind:HardwareMouseKind,button:number,x:number,y:number,inside:boolean,source:HardwarePointerSource='mouse'):boolean {
    if(source!=='mouse'||!this.allowed()){return false;}
    const valid=Number.isFinite(x)&&Number.isFinite(y);
    if(kind==='move'){
      if(!valid||(!inside&&this.buttons.length===0)){return false;}
      this.pointer.absolute(this.clamp(x),this.clamp(y));return true;
    }
    if(![1,2,4].includes(button)){return false;}
    const at=this.buttons.indexOf(button);
    if(kind==='down'){
      if(at>=0){return true;}
      if(!inside||!valid){return false;}
    }else if(at<0){return false;}
    this.pointer.flush();
    const events:RemoteInput[]=[];
    if(valid){events.push({action:'mouse_move_absolute',abs_x:this.clamp(x),abs_y:this.clamp(y)});}
    events.push({action:kind==='down'?'mouse_press':'mouse_release',button:button});
    if(!this.sink(events)){return false;}
    if(kind==='down'){this.buttons.push(button);}else{this.buttons.splice(at,1);}
    return true;
  }
  // Same units as the existing touch adapter: displacement in vp, positive Y
  // means wheel-up; 40vp produces one 120-unit notch. UI adapts axis direction.
  wheel(dxVp:number,dyVp:number,source:HardwarePointerSource='mouse'):boolean {
    if(source!=='mouse'||!this.allowed()||!Number.isFinite(dxVp)||!Number.isFinite(dyVp)){return false;}
    this.pointer.scroll(Math.max(-4000,Math.min(4000,dxVp)),Math.max(-4000,Math.min(4000,dyVp)));return true;
  }
  flush():boolean{return this.pointer.flush();}
  pressedCount():number{return this.keys.size+this.buttons.length;}
  hasPressedVk(vk:number):boolean {let found:boolean=false;this.keys.forEach((value:number)=>{if(value===vk){found=true;}});return found;}
  cancel():boolean {
    this.pointer.cancel();
    const keyValues:number[]=[];this.keys.forEach((vk:number)=>{if(!keyValues.includes(vk)){keyValues.push(vk);}});
    const events:RemoteInput[]=[];
    for(let i=keyValues.length-1;i>=0;i--){events.push({action:'kbd_release',key:keyValues[i]});}
    for(let i=this.buttons.length-1;i>=0;i--){events.push({action:'mouse_release',button:this.buttons[i]});}
    if(events.length===0){return true;}
    if(!this.sink(events)){return false;}
    this.keys.clear();this.buttons=[];return true;
  }
  // Only local bookkeeping: root pairs this with the native release-all path.
  // Do not call cancel from SessionClient's input-reset observer (recursion).
  resetLocal():void{this.pointer.cancel();this.keys.clear();this.buttons=[];}
  private clamp(value:number):number{return Math.max(0,Math.min(1,value));}
}
