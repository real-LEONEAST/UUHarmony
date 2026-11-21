// SPDX-License-Identifier: GPL-3.0-only
import { VirtualControl, VirtualPlan } from './VirtualKeyModel';
import { validateVirtualPlan } from './VirtualPlanValidation';
function clone(plan:VirtualPlan):VirtualPlan{return JSON.parse(JSON.stringify(plan)) as VirtualPlan;}
export class VirtualPlanEditor {
 private draft:VirtualPlan;private undoStack:VirtualPlan[]=[];private redoStack:VirtualPlan[]=[];private serial:number=0;
 constructor(plan:VirtualPlan){if(!validateVirtualPlan(plan)){throw Error('invalid_plan');}this.draft=clone(plan);}
 snapshot():VirtualPlan{return clone(this.draft);}
 private commit(next:VirtualPlan):boolean{if(!validateVirtualPlan(next)){return false;}this.undoStack.push(clone(this.draft));if(this.undoStack.length>50){this.undoStack.shift();}this.draft=next;this.redoStack=[];return true;}
 camera(enabled:boolean,x:number,y:number):boolean{const next=clone(this.draft);if(!next.camera){return false;}next.camera.enabled=enabled;next.camera.sensitivityX=x;next.camera.sensitivityY=y;return this.commit(next);}
 undo():boolean{const value=this.undoStack.pop();if(!value){return false;}this.redoStack.push(clone(this.draft));this.draft=value;return true;}
 redo():boolean{const value=this.redoStack.pop();if(!value){return false;}this.undoStack.push(clone(this.draft));this.draft=value;return true;}
 rename(name:string):boolean{const next=clone(this.draft);next.name=name;return this.commit(next);}
 add(control:VirtualControl):boolean{const next=clone(this.draft);if(next.controls.length>=128){return false;}next.controls.push(JSON.parse(JSON.stringify(control)) as VirtualControl);return this.commit(next);}
 remove(id:string):boolean{const next=clone(this.draft);if(!next.controls.some((c:VirtualControl)=>c.id===id)){return false;}next.controls=next.controls.filter((c:VirtualControl)=>c.id!==id&&c.ownerId!==id);return this.commit(next);}
 copy(id:string):boolean{
  const next=clone(this.draft);const original=next.controls.find((c:VirtualControl)=>c.id===id);if(!original){return false;}
  const children=next.controls.filter((c:VirtualControl)=>c.ownerId===id);if(next.controls.length+children.length+1>128){return false;}
  const makeId=():string=>{let candidate='';do{candidate='local-'+Date.now().toString(36)+'-'+(++this.serial).toString(36);}while(next.controls.some((c:VirtualControl)=>c.id===candidate));return candidate;};
  const item=JSON.parse(JSON.stringify(original)) as VirtualControl;item.id=makeId();item.x=Math.min(1,item.x+0.03);item.y=Math.min(1,item.y+0.03);
  if(item.ownerId){const sibling=next.controls.filter((c:VirtualControl)=>c.ownerId===item.ownerId).map((c:VirtualControl)=>c.order);let order=0;while(sibling.includes(order)&&order<128){order++;}if(order>=128){return false;}item.order=order;}
  next.controls.push(item);for(const child of children){const copied=JSON.parse(JSON.stringify(child)) as VirtualControl;copied.id=makeId();copied.ownerId=item.id;next.controls.push(copied);}return this.commit(next);
 }
 update(id:string,x:number,y:number,radius:number,opacity:number,name:string,actions:string[]):boolean{
  const next=clone(this.draft);const item=next.controls.find((c:VirtualControl)=>c.id===id);if(!item){return false;}
  item.x=x;item.y=y;item.radius=radius;item.opacity=opacity;item.name=name;item.actions=actions.slice();return this.commit(next);
 }
}
