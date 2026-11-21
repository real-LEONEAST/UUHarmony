// SPDX-License-Identifier: GPL-3.0-only
import { InputOwnershipArbiter, OwnershipChange } from './InputOwnershipArbiter';
import { RemoteInput } from './MobileInput';
export class OwnedInputDispatcher {
 private arbiter:InputOwnershipArbiter;private sink:(events:RemoteInput[])=>boolean;private panic:()=>void;
 constructor(sink:(events:RemoteInput[])=>boolean,panic:()=>void){this.sink=sink;this.panic=panic;this.arbiter=new InputOwnershipArbiter((changes:OwnershipChange[])=>this.sendChanges(changes),()=>this.panic());}
 private sendChanges(changes:OwnershipChange[]):boolean {
  const events:RemoteInput[]=[];
  for(const change of changes){const key=Number(change.token.slice(2));if(change.token.startsWith('k:')){events.push({action:change.down?'kbd_press':'kbd_release',key:key});}else{events.push({action:change.down?'mouse_press':'mouse_release',button:key});}}
  return this.sink(events);
 }
 ownership():InputOwnershipArbiter{return this.arbiter;}
 resetLocal():void{this.arbiter.reset();}
 send(owner:string,events:RemoteInput[]):boolean {
  return this.arbiter.sendOwned(owner,events,this.arbiter.generation(),(batch:RemoteInput[])=>this.sink(batch));
 }
}
