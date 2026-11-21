// SPDX-License-Identifier: GPL-3.0-only
import { VirtualControl, VirtualControlKind, VirtualPlan, PlanAdaptResult, VirtualCamera } from './VirtualKeyModel';
interface Position { layout?:string; rel_x?:number; rel_y?:number; }
interface Icon { position?:Position; visibility?:boolean; radius?:number; alpha?:number; }
interface Extra { press_can_be_dragged?:boolean; press_and_lock?:boolean; auto_hide?:boolean; deadzone_percent?:number; }
interface Collection { owner_id?:string; index?:number; }
interface UuControl {id?:string; type?:string; label?:string; display_name?:string; icon?:Icon; extra?:Extra; collection_info?:Collection; macro_sequence?:Object;}
interface UuConfig {name?:string; source?:string;}
interface UuDrag {enable?:boolean; type?:string; move_to_click?:boolean; mouse_move?:string;}
interface UuScene {drag?:UuDrag;}
interface UuViewConfig {zone?:string; sensitivity_x?:number; sensitivity_y?:number;}
interface UuView {is_open?:boolean; auto_hide_open?:boolean; game_touch_forbidden?:boolean; config?:UuViewConfig; in_scene?:UuScene;}
interface UuRoot {config_info?:UuConfig; game_view_control?:UuView; virtual_keys?:UuControl[];}
export function isBoundedVirtualJson(text:string):boolean {
 let size=0,depth=0,quote=false,escape=false;
 for(let i=0;i<text.length;i++){
  const c=text.charCodeAt(i);if(c<0x80){size++;}else if(c<0x800){size+=2;}else if(c>=0xD800&&c<=0xDBFF){const low=text.charCodeAt(++i);if(!(low>=0xDC00&&low<=0xDFFF)){return false;}size+=4;}else if(c>=0xDC00&&c<=0xDFFF){return false;}else{size+=3;}
  if(size>1048576){return false;}const ch=text.charAt(i);
  if(quote){if(escape){escape=false;}else if(ch==='\\'){escape=true;}else if(ch==='"'){quote=false;}}
  else if(ch==='"'){quote=true;}else if(ch==='{'||ch==='['){if(++depth>32){return false;}}else if(ch==='}'||ch===']'){if(--depth<0){return false;}}
 }
 return !quote&&depth===0;
}
function text(value:string|undefined,max:number):string {return typeof value==='string'?value.slice(0,max).replace(/[\x00-\x1f\x7f]/g,''):'';}
function keyToken(label:string):string {
 if(/^[A-Z0-9]$/.test(label)){return 'k:'+label.charCodeAt(0);}
 if(/^F([1-9]|1[0-2])$/.test(label)){return 'k:'+(111+Number(label.slice(1)));}
 switch(label){
  case 'CTRL_LEFT':return 'k:162';case 'CTRL_RIGHT':return 'k:163';case 'SHIFT_LEFT':return 'k:160';case 'SHIFT_RIGHT':return 'k:161';
  case 'ALT_LEFT':return 'k:164';case 'ALT_RIGHT':return 'k:165';case 'WINDOW':return 'k:91';
  case 'ESCAPE':return 'k:27';case 'SPACE':return 'k:32';case 'ENTER':return 'k:13';case 'TAB':return 'k:9';
  case 'DEL':return 'k:8';case 'FORWARD_DEL':return 'k:46';case 'PAGE_UP':return 'k:33';case 'PAGE_DOWN':return 'k:34';
  case 'DPAD_UP':return 'k:38';case 'DPAD_DOWN':return 'k:40';case 'DPAD_LEFT':return 'k:37';case 'DPAD_RIGHT':return 'k:39';
  case 'MOUSE_PRIMARY':return 'm:1';case 'MOUSE_SECONDARY':return 'm:2';case 'MOUSE_TERTIARY':return 'm:4';default:return '';
 }
}
function hasOnly(value:Object|undefined,keys:string[]):boolean {return !!value&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).every((key:string)=>keys.includes(key));}
function supportedCamera(view:UuView):VirtualCamera|undefined {
 if(!hasOnly(view,['is_open','auto_hide_open','game_touch_forbidden','config','in_scene'])||view.is_open!==true||view.auto_hide_open!==false||view.game_touch_forbidden!==false){return undefined;}
 const config=view.config,scene=view.in_scene,drag=scene?.drag;
 if(!hasOnly(config,['zone','sensitivity_x','sensitivity_y'])||!hasOnly(scene,['drag'])||!hasOnly(drag,['enable','type','move_to_click','mouse_move'])||!config||!drag){return undefined;}
 if(config.zone!=='full'||typeof config.sensitivity_x!=='number'||typeof config.sensitivity_y!=='number'||!Number.isFinite(config.sensitivity_x)||!Number.isFinite(config.sensitivity_y)||config.sensitivity_x<0.4||config.sensitivity_x>40||config.sensitivity_y<0.3||config.sensitivity_y>30){return undefined;}
 if(drag.enable!==true||drag.type!=='mouse'||drag.move_to_click!==false||(drag.mouse_move!==undefined&&drag.mouse_move!=='relative')){return undefined;}
 return {enabled:true,zone:'full',sensitivityX:config.sensitivity_x/4,sensitivityY:config.sensitivity_y/3};
}
export function adaptUuPlan(raw:string,source:string):PlanAdaptResult {
 const fail=(error:string):PlanAdaptResult=>({ok:false,error:error});
 if(typeof raw!=='string'||!isBoundedVirtualJson(raw)){return fail('size_or_depth');}
 let parsed:UuRoot|UuRoot[];try{parsed=JSON.parse(raw) as UuRoot|UuRoot[];}catch(_){return fail('invalid_json');}
 if(Array.isArray(parsed)){if(parsed.length!==1){return fail('root_count');}parsed=parsed[0];}
 if(!parsed||typeof parsed!=='object'||!Array.isArray(parsed.virtual_keys)||parsed.virtual_keys.length>128){return fail('invalid_controls');}
 const controls:VirtualControl[]=[];const ids:Set<string>=new Set();const issues:string[]=[];
 for(let i=0;i<parsed.virtual_keys.length;i++){
  const u=parsed.virtual_keys[i];if(!u||typeof u!=='object'||!u.icon||!u.icon.position){return fail('invalid_control');}
  const pos=u.icon.position;if(pos.layout!=='global'||typeof pos.rel_x!=='number'||typeof pos.rel_y!=='number'||!Number.isFinite(pos.rel_x)||!Number.isFinite(pos.rel_y)||pos.rel_x<0||pos.rel_x>100||pos.rel_y<0||pos.rel_y>100){return fail('invalid_position');}
  const radius=u.icon.radius;if(typeof radius!=='number'||!Number.isFinite(radius)||radius<=0||radius>300){return fail('invalid_radius');}
  const alpha=u.icon.alpha===undefined?1:u.icon.alpha;if(typeof alpha!=='number'||!Number.isFinite(alpha)||alpha<0||alpha>1){return fail('invalid_alpha');}
  if(u.id!==undefined&&(typeof u.id!=='string'||u.id.length>128||/[\x00-\x1f\x7f]/.test(u.id))){return fail('invalid_id');}
  const id=typeof u.id==='string'&&u.id.length>0?u.id:(u.id===undefined&&(source==='builtin'||source==='import')?source+'-'+i:'');
  if(!id||ids.has(id)){return fail('invalid_id');}ids.add(id);
  if(typeof u.label !== 'string'||u.label.length>128||/[\x00-\x1f\x7f]/.test(u.label)){return fail('invalid_binding');}
  const label=u.label,name=text(u.display_name,80)||label;
  let kind:VirtualControlKind='unsupported';let actions:string[]=[];let enabled=true;const warnings:string[]=[];
  if(u.type==='single_key'&&label==='visibility_switch'){kind='visibility';}
  else if(u.type==='single_key'){const token=keyToken(label);kind=token.startsWith('m:')?'mouse':'key';if(token){actions=[token];}else{enabled=false;warnings.push('unknown_key');}}
  else if(u.type==='combination_key'){kind='combo';const pieces=label.split('+');if(pieces.length<2||pieces.length>8){enabled=false;warnings.push('invalid_combination');}else{for(const part of pieces){const token=keyToken(part);if(!token||actions.includes(token)){enabled=false;warnings.push('unknown_combination');break;}actions.push(token);}}}
  else if(u.type==='direction_swipehold'&&label==='W+A+S+D'){kind='direction';actions=['k:87','k:65','k:83','k:68'];}
  else if(u.type==='directional_mouse_scroll'){kind='wheel';}
  else if(u.type==='collection_table'){kind='folder_list';}
  else if(u.type==='collection_round'){kind='folder_round';}
  else{enabled=false;warnings.push(u.type==='function_key'?'unverified_local_function':'unknown_control');}
  if(u.macro_sequence!==undefined&&u.macro_sequence!==null){enabled=false;warnings.push('macro_unsupported');}
  if(u.extra?.press_and_lock){enabled=false;warnings.push('press_lock_unsupported');}
  if(kind==='direction'&&u.extra?.deadzone_percent!==undefined){const deadzone=u.extra.deadzone_percent;if(typeof deadzone!=='number'||!Number.isFinite(deadzone)||deadzone<0||deadzone>100){return fail('invalid_deadzone');}if(deadzone!==0){enabled=false;warnings.push('deadzone_unverified');}}
  if(u.extra?.auto_hide){enabled=false;warnings.push('auto_hide_unverified');}
  if(u.extra?.press_can_be_dragged&&kind!=='mouse'&&kind!=='key'){enabled=false;warnings.push('drag_semantics_unverified');}
  const rawOwner=u.collection_info?.owner_id;if(rawOwner!==undefined&&(typeof rawOwner!=='string'||rawOwner.length>128||/[\x00-\x1f\x7f]/.test(rawOwner))){return fail('invalid_folder_owner');}
  const ownerId=rawOwner||'';const order=u.collection_info?.index===undefined?0:u.collection_info.index;
  if(!Number.isInteger(order)||order<0||order>127){return fail('invalid_folder_order');}
  controls.push({id:id,kind:kind,label:label,name:name,x:pos.rel_x/100,y:pos.rel_y/100,radius:radius,opacity:alpha,visible:u.icon.visibility!==false,draggable:(kind==='mouse'||kind==='key')&&u.extra?.press_can_be_dragged===true,ownerId:ownerId,order:order,actions:actions,enabled:enabled,issues:warnings});
 }
 for(const control of controls){if(control.ownerId&&(control.kind==='folder_list'||control.kind==='folder_round')){return fail('nested_folder_unsupported');}}
 const slots:Set<string>=new Set();
 for(const control of controls){if(!control.ownerId){continue;}if(control.kind==='folder_list'||control.kind==='folder_round'){return fail('nested_folder_unsupported');}const slot=control.ownerId+':'+control.order;if(slots.has(slot)){return fail('duplicate_folder_order');}slots.add(slot);const parent=controls.find((c:VirtualControl)=>c.id===control.ownerId);if(!parent||(parent.kind!=='folder_list'&&parent.kind!=='folder_round')||parent.ownerId||control.id===control.ownerId){return fail('invalid_folder_owner');}}
 let camera:VirtualCamera|undefined=undefined;if(parsed.game_view_control?.is_open){camera=supportedCamera(parsed.game_view_control);if(!camera){issues.push('game_view_control_unverified');}}
 if(parsed.game_view_control?.auto_hide_open){issues.push('scene_auto_hide_unverified');}
 if(parsed.game_view_control?.game_touch_forbidden){issues.push('game_touch_forbidden_unverified');}
 const plan:VirtualPlan={formatVersion:1,name:text(parsed.config_info?.name,80)||'未命名方案',source:source,coordinateSpace:'global',controls:controls,issues:issues,canActivate:issues.length===0};if(camera){plan.camera=camera;}
 return {ok:true,plan:plan,error:''};
}
