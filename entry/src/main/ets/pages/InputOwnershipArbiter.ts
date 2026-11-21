// SPDX-License-Identifier: GPL-3.0-only
import { RemoteInput } from './MobileInput';
// Each token is scoped to a session/window epoch; a batch is queued atomically.
export type OwnedInput = string;
export interface OwnershipChange { token: OwnedInput; down: boolean; }
export type OwnershipSink = (events: OwnershipChange[]) => boolean;
export class InputOwnershipArbiter {
  private owners: Map<string,OwnedInput[]> = new Map();
  private counts: Map<OwnedInput,number> = new Map();
  private epoch: number = 0;
  private sink:OwnershipSink; private failed:()=>void;
  constructor(sink:OwnershipSink,failed:()=>void) {this.sink=sink;this.failed=failed;}
  generation():number{return this.epoch;}
  private submit(changes:OwnershipChange[]):boolean {try{return this.sink(changes);}catch(_){return false;}}
  private validToken(token:OwnedInput):boolean {
    if(/^k:([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$/.test(token)){return true;}
    return token==='m:1'||token==='m:2'||token==='m:4';
  }
  acquire(owner:string,tokens:OwnedInput[],epoch:number):boolean {
    if(epoch!==this.epoch||!owner||owner.length>128||tokens.length===0||tokens.length>16||this.owners.size>=128&&!this.owners.has(owner)){return false;}
    const old=this.owners.get(owner)||[];const next=old.slice();const transitions:OwnershipChange[]=[];
    for(const token of tokens){if(!this.validToken(token)){return false;}if(!next.includes(token)){next.push(token);if(!this.counts.has(token)){transitions.push({token:token,down:true});}}}
    if(next.length>32||this.counts.size+transitions.length>128){return false;}
    if(transitions.length&&!this.submit(transitions)){this.failClosed();return false;}
    for(const token of next){if(!old.includes(token)){this.counts.set(token,(this.counts.get(token)||0)+1);}}
    this.owners.set(owner,next);return true;
  }
  release(owner:string,tokens:OwnedInput[],epoch:number):boolean {
    if(epoch!==this.epoch){return false;}const old=this.owners.get(owner);if(!old){return false;}
    const removing:OwnedInput[]=[];for(let i=old.length-1;i>=0;i--){if(tokens.includes(old[i])){removing.push(old[i]);}}
    if(!removing.length){return false;}
    const transitions:OwnershipChange[]=[];for(const token of removing){if(this.counts.get(token)===1){transitions.push({token:token,down:false});}}
    if(transitions.length&&!this.submit(transitions)){this.failClosed();return false;}
    for(const token of removing){const count=this.counts.get(token)||0;if(count<=1){this.counts.delete(token);}else{this.counts.set(token,count-1);}}
    const next=old.filter((token:OwnedInput)=>!removing.includes(token));if(next.length){this.owners.set(owner,next);}else{this.owners.delete(owner);}return true;
  }
  // Project every source transition in a temporary state, then submit exactly one batch.
  sendOwned(owner:string,events:RemoteInput[],epoch:number,sink:(events:RemoteInput[])=>boolean):boolean {
    if(epoch!==this.epoch||!owner||owner.length>128||!events.length||events.length>256||this.owners.size>=128&&!this.owners.has(owner)){return false;}
    const initial=this.owners.get(owner)||[];const owned=initial.slice();const counts=new Map<OwnedInput,number>(this.counts);const output:RemoteInput[]=[];
    for(const event of events){
      let token='';let down=false;
      if(event.action==='kbd_press'||event.action==='kbd_release'){
        if(!Number.isInteger(event.key)||!event.key||event.key<1||event.key>254){this.failClosed();return false;}
        token='k:'+event.key;down=event.action==='kbd_press';
      }else if(event.action==='mouse_press'||event.action==='mouse_release'){
        if(event.button!==1&&event.button!==2&&event.button!==4){this.failClosed();return false;}
        token='m:'+event.button;down=event.action==='mouse_press';
      }
      if(!token){output.push(event);continue;}
      const index=owned.indexOf(token);const count=counts.get(token)||0;
      if(down){if(index>=0){continue;}if(owned.length>=32||counts.size>=128&&!counts.has(token)){return false;}owned.push(token);counts.set(token,count+1);if(count===0){output.push(event);}}
      else{if(index<0||count<1){return false;}owned.splice(index,1);if(count===1){counts.delete(token);output.push(event);}else{counts.set(token,count-1);}}
    }
    if(output.length){let accepted=false;try{accepted=sink(output);}catch(_){accepted=false;}if(!accepted){this.failClosed();return false;}}
    this.counts=counts;if(owned.length){this.owners.set(owner,owned);}else{this.owners.delete(owner);}return true;
  }
  releaseOwner(owner:string,epoch:number):boolean {const old=this.owners.get(owner);return old?this.release(owner,old,epoch):false;}
  // Caller invokes the native release-all path after reset. No stale source can re-enter.
  reset():void {this.epoch++;this.owners.clear();this.counts.clear();}
  held(token:OwnedInput):number{return this.counts.get(token)||0;}
  ownerCount():number{return this.owners.size;}
  private failClosed():void{this.reset();try{this.failed();}catch(_){}}
}
// Suspension captures contacts still physically down; resume requires all to leave.
export class TouchEpochGuard {
  private contacts:Set<number>=new Set();private waiting:Set<number>=new Set();private paused:boolean=false;
  down(id:number):boolean{if(!Number.isInteger(id)||id<0||this.contacts.has(id)||this.contacts.size>=16){return false;}this.contacts.add(id);if(this.paused||this.waiting.size){this.waiting.add(id);return false;}return true;}
  up(id:number):void{this.contacts.delete(id);this.waiting.delete(id);}
  suspend():void{this.paused=true;this.contacts.forEach((id:number)=>this.waiting.add(id));}
  resume():void{this.paused=false;}
  owns(id:number):boolean{return this.contacts.has(id);}
  observe(ids:number[]):void{this.waiting.forEach((id:number)=>{if(!ids.includes(id)){this.waiting.delete(id);this.contacts.delete(id);}});}
  canStart():boolean{return !this.paused&&this.waiting.size===0;}
  reset():void{this.contacts.clear();this.waiting.clear();this.paused=true;}
}
