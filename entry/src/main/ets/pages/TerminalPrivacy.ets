// SPDX-License-Identifier: GPL-3.0-only
export interface TerminalPrivacy {privacyProtected?:boolean;privacyState?:string;error?:string;}
export function terminalPrivacyText(p:TerminalPrivacy):string {
 return p.privacyProtected?'电脑已回报隐私屏开启':p.privacyState==='requested'?'已请求隐私屏，尚未确认保护':p.privacyState==='unsupported'?'电脑不支持此隐私屏请求，未保护':p.privacyState==='failed'?'隐私屏请求失败，未保护':'隐私屏状态未知，未确认保护';
}
