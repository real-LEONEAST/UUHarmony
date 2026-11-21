// SPDX-License-Identifier: GPL-3.0-only
import { VirtualPlan } from './VirtualKeyModel';
import { validateVirtualPlan } from './VirtualPlanValidation';
class SelectedVirtualPlan {
 private selected:VirtualPlan|undefined=undefined;private scope:string='offline';private id:string='';
 setScope(scope:string):void{const next=/^[a-f0-9]{64}$/.test(scope)?scope:scope==='offline'?'offline':'unavailable';if(next!==this.scope){this.selected=undefined;this.id='';this.scope=next;}}
 set(plan:VirtualPlan,id:string=''):boolean{if(this.scope==='unavailable'||!validateVirtualPlan(plan)||!plan.canActivate){return false;}this.selected=JSON.parse(JSON.stringify(plan)) as VirtualPlan;this.id=id;return true;}
 get():VirtualPlan|undefined{return this.selected?JSON.parse(JSON.stringify(this.selected)) as VirtualPlan:undefined;}
 matches(id:string):boolean{return !!id&&id===this.id;}
 clear():void{this.selected=undefined;this.id='';}
}
export const virtualSelection:SelectedVirtualPlan=new SelectedVirtualPlan();
