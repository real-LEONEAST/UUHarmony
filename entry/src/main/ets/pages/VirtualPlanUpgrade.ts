// SPDX-License-Identifier: GPL-3.0-only
import { VirtualPlan,VirtualControl } from './VirtualKeyModel';
import { adaptUuPlan } from './UuPlanAdapter';
import { validateVirtualPlan } from './VirtualPlanValidation';
const ROCO_SHA256='047bb1e0b57691ddcf1a20c7b242861d0c1dd2571aee0a7f486dfbc29c69cd06';
// Only the observed, SHA-verified official original is upgraded. User edits win.
// The caller keeps the source bytes and saved model unchanged until explicit save.
export function upgradeKnownVirtualPlan(saved:VirtualPlan,raw:string,sha256:string):VirtualPlan {
 if(sha256!==ROCO_SHA256||!validateVirtualPlan(saved)){return saved;}
 const converted=adaptUuPlan(raw,'official');if(!converted.ok||!converted.plan?.camera){return saved;}
 const next=JSON.parse(JSON.stringify(saved)) as VirtualPlan;
 if(next.issues.includes('game_view_control_unverified')){
  next.issues=next.issues.filter((issue:string)=>issue!=='game_view_control_unverified');
  if(!next.camera){next.camera=converted.plan.camera;}next.canActivate=next.issues.length===0;
 }
 for(const old of next.controls){
  if(!old.issues.includes('drag_semantics_unverified')){continue;}
  const current=converted.plan.controls.find((item:VirtualControl)=>item.id===old.id);
  if(!current||!current.draggable||old.kind!=='key'||old.actions.length!==1||!/^k:([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$/.test(old.actions[0])){continue;}
  old.draggable=true;old.issues=old.issues.filter((issue:string)=>issue!=='drag_semantics_unverified');if(!old.issues.length){old.enabled=true;}
 }
 return validateVirtualPlan(next)?next:saved;
}
