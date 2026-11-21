// SPDX-License-Identifier: GPL-3.0-only
export function validCommittedText(text:string):boolean {
  if(text.length===0||text.length>4096||text.includes('\u0000')){return false;}
  for(let i=0;i<text.length;i++){
    const n=text.charCodeAt(i);
    if(n>=0xD800&&n<=0xDBFF){const low=text.charCodeAt(++i);if(!(low>=0xDC00&&low<=0xDFFF)){return false;}}
    else if(n>=0xDC00&&n<=0xDFFF){return false;}
  }
  return true;
}
export interface RemoteInput {
  action?: string; button?: number; abs_x?: number; abs_y?: number;
  delta_x?: number; delta_y?: number; key?: number; content?: string; heartbeat?: string;
  index?: number; buttons?: number; left_trigger?: number; right_trigger?: number;
  left_thumb_x?: number; left_thumb_y?: number; right_thumb_x?: number; right_thumb_y?: number;
}
export class MobileInput {
  private sink: (events: RemoteInput[]) => boolean;
  private motion: RemoteInput | undefined = undefined;
  private timer: number = -1;
  private residualX: number = 0; private residualY: number = 0;
  private wheelX: number = 0; private wheelY: number = 0;
  private modifiers: number[] = [];
  constructor(sink: (events: RemoteInput[]) => boolean) { this.sink = sink; }
  absolute(x: number, y: number): void { this.merge({action:'mouse_move_absolute',abs_x:x,abs_y:y}); }
  relative(dx: number, dy: number): void {
    this.residualX += dx; this.residualY += dy;
    const x = Math.trunc(this.residualX); const y = Math.trunc(this.residualY);
    this.residualX -= x; this.residualY -= y;
    if(x !== 0 || y !== 0) { this.merge({action:'mouse_move_relative',delta_x:x,delta_y:y}); }
  }
  scroll(dx: number, dy: number): void {
    this.wheelX += dx * 3; this.wheelY += dy * 3;
    const x = Math.trunc(this.wheelX); const y = Math.trunc(this.wheelY);
    this.wheelX -= x; this.wheelY -= y;
    if(x !== 0 || y !== 0) { this.merge({action:'mouse_scroll',delta_x:x,delta_y:y}); }
  }
  private merge(e: RemoteInput): void {
    if(this.motion && this.motion.action !== e.action) { this.flush(); }
    if(this.motion && e.action !== 'mouse_move_absolute') {
      this.motion.delta_x = Math.max(-12000, Math.min(12000, (this.motion.delta_x || 0) + (e.delta_x || 0)));
      this.motion.delta_y = Math.max(-12000, Math.min(12000, (this.motion.delta_y || 0) + (e.delta_y || 0)));
    } else { this.motion = e; }
    if(this.timer < 0) { this.timer = setTimeout(() => { this.timer = -1; this.flush(); }, 16); }
  }
  flush(): boolean {
    if(this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    if(this.motion) { const e = this.motion; this.motion = undefined; return this.sink([e]); }
    return true;
  }
  button(button: number, down: boolean): boolean {
    this.flush(); return this.sink([{action:down?'mouse_press':'mouse_release',button:button}]);
  }
  // Soft modifiers are local, single-use choices. Opening/closing a keyboard
  // cannot leave a remote Ctrl/Alt/Shift/Win pressed while the user composes.
  toggleModifier(key: number): boolean {
    if(!this.isModifier(key)) { return false; }
    const i = this.modifiers.indexOf(key);
    if(i >= 0) { this.modifiers.splice(i,1); return false; }
    this.modifiers.push(key); return true;
  }
  modifierKeys(): number[] { return this.modifiers.slice(); }
  key(key: number): boolean { return this.combo(this.modifiers,key); }
  shortcut(key: number): boolean { return this.combo([162],key); }
  combo(modifiers: number[], key: number): boolean {
    const chosen: number[] = [];
    for(const modifier of modifiers) {
      if(!this.isModifier(modifier)) { this.modifiers=[]; return false; }
      if(!chosen.includes(modifier)) { chosen.push(modifier); }
    }
    this.modifiers=[];
    if(!Number.isInteger(key)||key<1||key>254||chosen.includes(key)||!this.flush()) { return false; }
    const events: RemoteInput[] = [];
    for(const modifier of chosen) { events.push({action:'kbd_press',key:modifier}); }
    events.push({action:'kbd_press',key:key},{action:'kbd_release',key:key});
    for(let i=chosen.length-1;i>=0;i--) { events.push({action:'kbd_release',key:chosen[i]}); }
    return this.sink(events);
  }
  private isModifier(key: number): boolean { return key===91||key===92||(Number.isInteger(key)&&key>=160&&key<=165); }
  // IME commit is one protocol operation, never UTF-16 sliced. At most 4096
  // code units => <=12288 UTF-8 bytes, below native MAX_TEXT_BYTES (16KiB).
  commitText(value:string):boolean {
    if(!validCommittedText(value)){return false;}
    if(this.modifiers.length>0){if(!/^[A-Za-z0-9]$/.test(value)){return false;}return this.key(value.toUpperCase().charCodeAt(0));}
    if(!this.flush()){return false;}
    return this.sink([{action:'text_input',content:value}]);
  }
  repeatKey(key:number,count:number):boolean {
    if(!Number.isInteger(count)||count<1||count>64||![8,46].includes(key)||!this.flush()){return false;}
    const events:RemoteInput[]=[];
    // A held soft modifier is consumed by the first deliberate key only.
    if(this.modifiers.length>0){if(!this.key(key)){return false;}count--;}
    for(let i=0;i<count;i++){events.push({action:'kbd_press',key:key},{action:'kbd_release',key:key});}
    return events.length===0||this.sink(events);
  }
  submit(value: string): boolean {
    if(value.length === 0 || value.length > 64 || value.indexOf('\u0000') >= 0) { return false; }
    if(this.modifiers.length>0){if(!/^[A-Za-z0-9]$/.test(value)){return false;}return this.key(value.toUpperCase().charCodeAt(0));}
    if(!this.flush()){return false;}
    // A committed draft is text, including ASCII; preserve the exact characters.
    return this.sink([{action:'text_input',content:value}]);
  }
  cancel(): void {
    if(this.timer>=0) { clearTimeout(this.timer); this.timer=-1; }
    this.motion=undefined; this.modifiers=[];
    this.residualX=0;this.residualY=0;this.wheelX=0;this.wheelY=0;
  }
}
