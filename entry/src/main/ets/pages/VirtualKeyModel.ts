// SPDX-License-Identifier: GPL-3.0-only
export type VirtualControlKind='key'|'mouse'|'combo'|'direction'|'wheel'|'folder_list'|'folder_round'|'visibility'|'unsupported';
export interface VirtualControl {
 id:string; kind:VirtualControlKind; label:string; name:string; x:number; y:number;
 radius:number; opacity:number; visible:boolean; draggable:boolean; ownerId:string; order:number;
 actions:string[]; enabled:boolean; issues:string[];
}
export interface VirtualCamera {enabled:boolean; zone:'full'|'right_half'; sensitivityX:number; sensitivityY:number;}
export interface VirtualPlan {
 formatVersion:number; name:string; source:string; coordinateSpace:'global'; controls:VirtualControl[];
 issues:string[]; canActivate:boolean; camera?:VirtualCamera;
}
export interface PlanAdaptResult {ok:boolean; plan?:VirtualPlan; error:string;}
