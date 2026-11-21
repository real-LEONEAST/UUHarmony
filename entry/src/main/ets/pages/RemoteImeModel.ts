// SPDX-License-Identifier: GPL-3.0-only
// A write-through IME client, NOT a local mirror of the remote document.
// Only uncommitted preview exists here. No timer, draft, retry or remote history.
import { validCommittedText } from './MobileInput';
function boundary(text:string,index:number):boolean {
  if(index<0||index>text.length||!Number.isInteger(index)){return false;}
  const n=text.charCodeAt(index);return !(n>=0xDC00&&n<=0xDFFF);
}
// Local preview boundaries for combining marks and emoji (VS, skin tone, ZWJ,
// keycaps, flag pairs, tag sequences). Remote deletion is NEVER computed here.
function previewCuts(text:string):number[] {
  const cuts:number[]=[0];let offset=0,previous=-1,regional=0;
  for(const ch of Array.from(text)){
    const cp=ch.codePointAt(0)||0;
    const flag=cp>=0x1F1E6&&cp<=0x1F1FF;
    const extend=/\p{M}/u.test(ch)||(cp>=0xFE00&&cp<=0xFE0F)||(cp>=0xE0100&&cp<=0xE01EF)||
      (cp>=0x1F3FB&&cp<=0x1F3FF)||(cp>=0xE0020&&cp<=0xE007F);
    const joined=extend||cp===0x200D||previous===0x200D||(flag&&regional%2===1)||(previous===13&&cp===10);
    if(offset>0&&!joined){cuts.push(offset);}
    regional=flag?regional+1:0;previous=cp;offset+=ch.length;
  }
  cuts.push(text.length);return cuts;
}
export class RemoteImeModel {
  preview:string='';
  composing:boolean=false;
  private cursor:number=0;
  private anchor:number=0;
  constructor(private commit:(text:string)=>boolean,private key:(vk:number,count:number)=>boolean,
    private allowed:()=>boolean){}
  reset():void {this.preview='';this.composing=false;this.cursor=0;this.anchor=0;}
  setPreview(text:string,start:number=-1,end:number=-1):boolean {
    if(!this.allowed()||text.length>4096||(text.length>0&&!validCommittedText(text))){return false;}
    let from=start,to=end;
    if(start===-1&&end===-1){from=0;to=this.preview.length;}
    if(from>to||!boundary(this.preview,from)||!boundary(this.preview,to)){return false;}
    const next=this.preview.slice(0,from)+text+this.preview.slice(to);
    if(next.length>4096){return false;}
    this.preview=next;this.composing=true;this.cursor=from+text.length;this.anchor=this.cursor;return true;
  }
  // insertText replaces a live preview; finishTextPreview formally commits it.
  // These are two alternative SDK commit paths, not two copies of the text.
  insert(text:string):boolean {
    if(!this.allowed()){this.reset();return false;}
    // Some IMEs use insertText for a standalone newline rather than FunctionKey.
    // It is still a confirmation-only action if a preview is live; never turn
    // candidate confirmation into an extra remote Enter.
    if(text==='\n'||text==='\r'||text==='\r\n'){return this.enter();}
    this.reset();
    if(!validCommittedText(text)){return false;}
    return this.commit(text);
  }
  finish():boolean {
    if(!this.allowed()){this.reset();return false;}
    const value=this.preview,active=this.composing;this.reset();
    return !active||value.length===0||this.commit(value);
  }
  select(start:number,end:number):boolean {
    if(!this.allowed()||!this.composing||start>end||!boundary(this.preview,start)||!boundary(this.preview,end)){return false;}
    this.anchor=start;this.cursor=end;return true;
  }
  left(length:number):string {
    if(!Number.isInteger(length)||length<1){return '';}
    let from=Math.max(0,this.cursor-Math.min(length,4096));if(!boundary(this.preview,from)){from++;}
    return this.preview.slice(from,this.cursor);
  }
  right(length:number):string {
    if(!Number.isInteger(length)||length<1){return '';}
    let to=Math.min(this.preview.length,this.cursor+Math.min(length,4096));if(!boundary(this.preview,to)){to--;}
    return this.preview.slice(this.cursor,to);
  }
  index():number {return this.cursor;}
  remove(length:number,forward:boolean=false):boolean {
    if(!this.allowed()||!Number.isInteger(length)||length<1||length>64){return false;}
    if(this.composing){
      let from=Math.min(this.anchor,this.cursor),to=Math.max(this.anchor,this.cursor);
      if(from===to){if(forward){to=Math.min(this.preview.length,to+length);}else{from=Math.max(0,from-length);}}
      // IME offsets are UTF-16. Expand a local delete to whole preview
      // characters; one deletion cannot leave half an emoji or a ZWJ tail.
      const cuts=previewCuts(this.preview);
      for(let i=cuts.length-1;i>=0;i--){if(cuts[i]<=from){from=cuts[i];break;}}
      for(const cut of cuts){if(cut>=to){to=cut;break;}}
      this.preview=this.preview.slice(0,from)+this.preview.slice(to);this.cursor=from;this.anchor=from;
      // Even if a delete empties the preview, the SAME operation never spills
      // into the remote document. finish/insert ends the composition explicitly.
      return true;
    }
    // Do not infer remote UTF-16 length from the last commit (focus may move).
    // Remote applications own Backspace/Delete semantics, including graphemes.
    return this.key(forward?46:8,length);
  }
  enter():boolean {
    if(!this.allowed()){return false;}
    // Confirmation belongs to the IME. insert/finish is the sole text path.
    if(this.composing){return true;}
    return this.key(13,1);
  }
  move(vk:number):boolean {return this.allowed()&&!this.composing&&[37,38,39,40].includes(vk)&&this.key(vk,1);}
}
