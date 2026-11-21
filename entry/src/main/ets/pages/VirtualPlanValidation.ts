// SPDX-License-Identifier: GPL-3.0-only
import { VirtualPlan, VirtualControl } from './VirtualKeyModel';
export function validateVirtualPlan(plan:VirtualPlan):boolean {
 if(!plan||plan.formatVersion!==1||typeof plan.name!=='string'||plan.name.length<1||plan.name.length>80||/[\x00-\x1f\x7f]/.test(plan.name)||plan.coordinateSpace!=='global'||!Array.isArray(plan.controls)||plan.controls.length>128||!Array.isArray(plan.issues)||plan.issues.length>32||typeof plan.source!=='string'||plan.source.length>64||typeof plan.canActivate!=='boolean'){return false;}
 if(plan.issues.some((issue:string)=>typeof issue!=='string'||issue.length>100)){return false;}
 if(plan.canActivate&&plan.issues.length){return false;}
 if(plan.camera!==undefined&&(!plan.camera||typeof plan.camera.enabled!=='boolean'||plan.camera.zone!=='full'||!Number.isFinite(plan.camera.sensitivityX)||!Number.isFinite(plan.camera.sensitivityY)||plan.camera.sensitivityX<0.1||plan.camera.sensitivityX>10||plan.camera.sensitivityY<0.1||plan.camera.sensitivityY>10)){return false;}
 const ids:Set<string>=new Set(),slots:Set<string>=new Set();
 for(const c of plan.controls){
  if(!c||typeof c.id!=='string'||!c.id||c.id.length>128||/[\x00-\x1f\x7f]/.test(c.id)||ids.has(c.id)||typeof c.name!=='string'||c.name.length>80||typeof c.label!=='string'||c.label.length>128||/[\x00-\x1f\x7f]/.test(c.name+c.label)){return false;}ids.add(c.id);
  if(!['key','mouse','combo','direction','wheel','folder_list','folder_round','visibility','unsupported'].includes(c.kind)||!Number.isFinite(c.x)||!Number.isFinite(c.y)||c.x<0||c.x>1||c.y<0||c.y>1||!Number.isFinite(c.radius)||c.radius<=0||c.radius>300||!Number.isFinite(c.opacity)||c.opacity<0||c.opacity>1||typeof c.enabled!=='boolean'||typeof c.visible!=='boolean'||typeof c.draggable!=='boolean'||c.draggable&&c.kind!=='mouse'&&c.kind!=='key'||!Array.isArray(c.actions)||c.actions.length>8||!Array.isArray(c.issues)||c.issues.length>32){return false;}
  if(c.issues.some((issue:string)=>typeof issue!=='string'||issue.length>100)){return false;}
  if(c.enabled&&c.issues.some((issue:string)=>['unknown_key','unknown_combination','invalid_combination','unverified_local_function','unknown_control','macro_unsupported','press_lock_unsupported','auto_hide_unverified','drag_semantics_unverified','deadzone_unverified'].includes(issue))){return false;}
  for(const token of c.actions){if(typeof token!=='string'||!(/^k:([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$/.test(token)||/^m:(1|2|4)$/.test(token))){return false;}}
  if(c.enabled&&(c.kind==='key'&&(c.actions.length!==1||!c.actions[0].startsWith('k:'))||c.kind==='mouse'&&(c.actions.length!==1||!c.actions[0].startsWith('m:'))||c.kind==='combo'&&(c.actions.length<2||new Set(c.actions).size!==c.actions.length)||c.kind==='direction'&&c.actions.join(',')!=='k:87,k:65,k:83,k:68')){return false;}
  if(['wheel','folder_list','folder_round','visibility','unsupported'].includes(c.kind)&&c.actions.length){return false;}
  if(typeof c.ownerId!=='string'||c.ownerId.length>128||/[\x00-\x1f\x7f]/.test(c.ownerId)||!Number.isInteger(c.order)||c.order<0||c.order>127){return false;}
  if(c.ownerId&&(c.kind==='folder_list'||c.kind==='folder_round')){return false;}
  if(c.ownerId){const slot=c.ownerId+':'+c.order;if(slots.has(slot)){return false;}slots.add(slot);}
 }
 for(const c of plan.controls){if(!c.ownerId){continue;}const parent=plan.controls.find((item:VirtualControl)=>item.id===c.ownerId);if(!parent||parent.ownerId||(parent.kind!=='folder_list'&&parent.kind!=='folder_round')||parent.id===c.id){return false;}}
 return true;
}
