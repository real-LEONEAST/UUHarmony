// SPDX-License-Identifier: GPL-3.0-only
import { VirtualPlan,VirtualControl } from './VirtualKeyModel';
import { validateVirtualPlan } from './VirtualPlanValidation';
const PLAN_ISSUES:string[]=['game_view_control_unverified','scene_auto_hide_unverified','game_touch_forbidden_unverified'];
const CONTROL_ISSUES:string[]=['unknown_key','unknown_combination','invalid_combination','unverified_local_function','unknown_control','macro_unsupported','press_lock_unsupported','auto_hide_unverified','drag_semantics_unverified','deadzone_unverified'];
export function publicVirtualPlan(input:VirtualPlan):VirtualPlan|undefined {
 if(!validateVirtualPlan(input)){return undefined;}
 const issues=input.issues.filter((value:string)=>PLAN_ISSUES.includes(value));
 const controls=input.controls.map((item:VirtualControl):VirtualControl=>{
  const warnings=item.issues.filter((value:string)=>CONTROL_ISSUES.includes(value));
  return {id:item.id,kind:item.kind,label:item.label,name:item.name,x:item.x,y:item.y,radius:item.radius,opacity:item.opacity,visible:item.visible,draggable:item.draggable,ownerId:item.ownerId,order:item.order,actions:item.actions.slice(),enabled:item.enabled&&warnings.length===item.issues.length,issues:warnings};
 });
 const source=['builtin','official','import','local'].includes(input.source)?input.source:'import';
 const output:VirtualPlan={formatVersion:1,name:input.name,source:source,coordinateSpace:'global',controls:controls,issues:issues,canActivate:input.canActivate&&issues.length===input.issues.length,camera:input.camera?{enabled:input.camera.enabled,zone:input.camera.zone,sensitivityX:input.camera.sensitivityX,sensitivityY:input.camera.sensitivityY}:undefined};
 return validateVirtualPlan(output)?output:undefined;
}
