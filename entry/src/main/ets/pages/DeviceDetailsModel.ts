export const DETAIL_ACTIONS:string[]=['files','watch','terminal','more'];
export const MORE_ACTIONS:string[]=['files','watch','terminal','wake','reboot','shutdown','lock_now'];
export function normalizeMoreOrder(value:string[]):string[]{const result:string[]=[];for(const id of value){if(typeof id==='string'&&MORE_ACTIONS.includes(id)&&!result.includes(id)){result.push(id);}}for(const id of MORE_ACTIONS){if(!result.includes(id)){result.push(id);}}return result;}
export function moveMoreAction(value:string[],id:string,direction:number):string[]{const result=normalizeMoreOrder(value);const index=result.indexOf(id);const target=index+direction;if(index<0||target<0||target>=result.length||Math.abs(direction)!==1){return result;}const previous=result[target];result[target]=id;result[index]=previous;return result;}
export function moreActionLabel(id:string):string{return id==='files'?'文件传输':id==='watch'?'观看模式':id==='terminal'?'终端':id==='wake'?'远程开机':id==='reboot'?'重启':id==='shutdown'?'关机':'一键锁屏';}
export function lockResultNotice(result:string):string{
  return result==='立即锁屏：指令已发送；协议没有执行确认，请观察电脑状态。'||result==='锁屏指令已发送'?'锁屏指令已发送':'';
}
