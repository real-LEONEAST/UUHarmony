// SPDX-License-Identifier: GPL-3.0-only
export function virtualIssueText(value:string):string {
 switch(value){
  case 'unknown_key':return '按键暂不识别';case 'unknown_combination':return '组合键暂不识别';case 'invalid_combination':return '组合键格式无效';
  case 'unverified_local_function':return '此本地功能待适配';case 'unknown_control':return '此控件待适配';case 'macro_unsupported':return '宏暂不支持';
  case 'press_lock_unsupported':return '按住锁定暂不支持';case 'auto_hide_unverified':return '自动隐藏待适配';case 'drag_semantics_unverified':return '拖动行为待适配';case 'deadzone_unverified':return '方向死区待适配';
  case 'game_view_control_unverified':return '游戏视角控制待适配';case 'scene_auto_hide_unverified':return '场景自动隐藏待适配';case 'game_touch_forbidden_unverified':return '游戏触摸限制待适配';default:return '此功能待适配';
 }
}
