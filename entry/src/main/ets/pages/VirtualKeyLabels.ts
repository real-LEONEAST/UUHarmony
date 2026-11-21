// SPDX-License-Identifier: GPL-3.0-only
function label(token:string):string {
 if(token==='m:1')return '鼠标左键';if(token==='m:2')return '鼠标右键';if(token==='m:4')return '鼠标中键';
 if(!token.startsWith('k:'))return '未知';const key=Number(token.slice(2));
 if(key>=65&&key<=90||key>=48&&key<=57)return String.fromCharCode(key);
 if(key>=112&&key<=123)return 'F'+(key-111);
 switch(key){case 162:return 'Ctrl';case 163:return '右Ctrl';case 160:return 'Shift';case 161:return '右Shift';case 164:return 'Alt';case 165:return '右Alt';case 91:return 'Win';case 92:return '右Win';case 27:return 'Esc';case 32:return '空格';case 13:return '回车';case 9:return 'Tab';case 8:return '退格';case 46:return 'Delete';case 33:return 'PageUp';case 34:return 'PageDown';case 37:return '左方向';case 38:return '上方向';case 39:return '右方向';case 40:return '下方向';default:return '未知';}
}
export function formatVirtualBinding(actions:string[]):string{return actions.map(label).join(' + ');}
export function parseVirtualBinding(value:string):string[] {
 const parts=value.split('+').map((v:string)=>v.trim());if(parts.length<1||parts.length>8||parts.some((v:string)=>!v)){return [];}
 const tokens:string[]=[];for(const part of parts){let token='';const upper=part.toUpperCase();
  if(/^[A-Z0-9]$/.test(upper)){token='k:'+upper.charCodeAt(0);}
  else if(/^F([1-9]|1[0-2])$/.test(upper)){token='k:'+(111+Number(upper.slice(1)));}
  else{switch(upper){case 'CTRL':token='k:162';break;case '右CTRL':token='k:163';break;case 'SHIFT':token='k:160';break;case '右SHIFT':token='k:161';break;case 'ALT':token='k:164';break;case '右ALT':token='k:165';break;case 'WIN':token='k:91';break;case '右WIN':token='k:92';break;case 'ESC':token='k:27';break;case '空格':token='k:32';break;case '回车':token='k:13';break;case 'TAB':token='k:9';break;case '退格':token='k:8';break;case 'DELETE':token='k:46';break;case 'PAGEUP':token='k:33';break;case 'PAGEDOWN':token='k:34';break;case '左方向':token='k:37';break;case '上方向':token='k:38';break;case '右方向':token='k:39';break;case '下方向':token='k:40';break;case '鼠标左键':token='m:1';break;case '鼠标右键':token='m:2';break;case '鼠标中键':token='m:4';break;}}
  if(!token||tokens.includes(token)){return [];}tokens.push(token);
 }return tokens;
}
