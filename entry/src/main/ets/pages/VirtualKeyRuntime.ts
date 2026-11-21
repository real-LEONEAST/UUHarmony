// SPDX-License-Identifier: GPL-3.0-only
import { VirtualControl } from './VirtualKeyModel';
import { InputOwnershipArbiter, TouchEpochGuard } from './InputOwnershipArbiter';
interface Contact {controlId:string; kind:string; actions:string[]; epoch:number;}
export class VirtualKeyRuntime {
 private guard:TouchEpochGuard=new TouchEpochGuard();
 private contacts:Map<number,Contact>=new Map();
 private arbiter:InputOwnershipArbiter;private local:(kind:string,id:string)=>void;private wheel:(delta:number)=>boolean;private drag:(id:number,dx:number,dy:number,end:boolean)=>boolean;private round:(id:number,controlId:string,dx:number,dy:number,end:boolean,commit:boolean)=>void;
 constructor(arbiter:InputOwnershipArbiter,local:(kind:string,id:string)=>void,wheel:(delta:number)=>boolean,drag:(id:number,dx:number,dy:number,end:boolean)=>boolean,round:(id:number,controlId:string,dx:number,dy:number,end:boolean,commit:boolean)=>void=()=>{}){this.arbiter=arbiter;this.local=local;this.wheel=wheel;this.drag=drag;this.round=round;}
 down(id:number,control:VirtualControl,wheelDelta:number=120):boolean {
  if(!this.guard.down(id)){return false;}if(!control.enabled){return false;}
  if(control.kind==='folder_list'||control.kind==='visibility'){this.local(control.kind,control.id);return true;}
  if(control.kind==='folder_round'){this.contacts.set(id,{controlId:control.id,kind:control.kind,actions:[],epoch:this.arbiter.generation()});this.local('folder_round_start',control.id);return true;}
  const epoch=this.arbiter.generation();const owner='overlay:'+id;let actions:string[]=[];
  if(control.kind==='key'||control.kind==='mouse'||control.kind==='combo'){actions=control.actions.slice();if(!this.arbiter.acquire(owner,actions,epoch)){return false;}}
  else if(control.kind==='wheel'){if(wheelDelta!==120&&wheelDelta!==-120||!this.wheel(wheelDelta)){return false;}}
  else if(control.kind!=='direction'){return false;}
  this.contacts.set(id,{controlId:control.id,kind:control.kind,actions:actions,epoch:epoch});return true;
 }
 move(id:number,control:VirtualControl,dx:number,dy:number,deltaX:number=0,deltaY:number=0):boolean {
  const contact=this.contacts.get(id);if(!contact||contact.controlId!==control.id||contact.epoch!==this.arbiter.generation()||!Number.isFinite(dx)||!Number.isFinite(dy)){return false;}
  if(control.kind==='folder_round'){this.round(id,control.id,dx,dy,false,false);return true;}
  if((control.kind==='mouse'||control.kind==='key')&&control.draggable){return Number.isFinite(deltaX)&&Number.isFinite(deltaY)&&this.drag(id,deltaX,deltaY,false);}
  if(control.kind!=='direction'){return false;}
  const next:string[]=[];if(dy < -0.2){next.push('k:87');}if(dx < -0.2){next.push('k:65');}if(dy > 0.2){next.push('k:83');}if(dx > 0.2){next.push('k:68');}
  const removed=contact.actions.filter((value:string)=>!next.includes(value));const added=next.filter((value:string)=>!contact.actions.includes(value));
  if(removed.length&&!this.arbiter.release('overlay:'+id,removed,contact.epoch)){this.contacts.delete(id);return false;}
  if(added.length&&!this.arbiter.acquire('overlay:'+id,added,contact.epoch)){this.contacts.delete(id);return false;}
  contact.actions=next;return true;
 }
 up(id:number,commit:boolean=true):void {this.drag(id,0,0,true);const contact=this.contacts.get(id);this.contacts.delete(id);this.guard.up(id);if(contact&&contact.kind==='folder_round'){this.round(id,contact.controlId,0,0,true,commit&&contact.epoch===this.arbiter.generation());}if(contact&&contact.actions.length){this.arbiter.releaseOwner('overlay:'+id,contact.epoch);}}
 suspend():void {this.guard.suspend();this.contacts.forEach((contact:Contact,id:number)=>{this.drag(id,0,0,true);if(contact.kind==='folder_round'){this.round(id,contact.controlId,0,0,true,false);}if(contact.actions.length){this.arbiter.releaseOwner('overlay:'+id,contact.epoch);}});this.contacts.clear();}
 resetLocal():void {this.guard.suspend();this.contacts.clear();}
 beginExternal(id:number):boolean{return this.guard.down(id);}
 endExternal(id:number):void{this.guard.up(id);}
 owns(id:number):boolean{return this.guard.owns(id);}
 observeContacts(ids:number[]):void {this.guard.observe(ids);}
 resume():void {this.guard.resume();}
 canStart():boolean{return this.guard.canStart();}
}
