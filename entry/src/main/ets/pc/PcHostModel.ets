// Sharing transitions are independent of page lifetime and window visibility.
export function pcPlatform(type:string):boolean { return type==='2in1'||type==='pc'; }
export function hostStopping(phase:string):boolean {return phase==='stopping'||phase==='stop-pending'||phase==='stop-failed';}
export function hostBusy(phase:string):boolean {return phase==='preparing'||phase==='sharing'||hostStopping(phase);}
export function hostDisplayName(name:string,index:number):string {
  const trimmed=name.trim();
  return trimmed&&trimmed.toUpperCase()!=='UNKNOWN'?trimmed:'显示屏 '+(index+1);
}
export function captureEnded(state:number):boolean {return [-2,1,2,3,4,10].includes(state);}
export function canShare(loggedIn:boolean,encoder:boolean,phase:string,viewerBusy:boolean):boolean {
  return loggedIn&&encoder&&!hostBusy(phase)&&!viewerBusy;
}
export function inputPermissionLabel(state:number):string {
  return state===2?'已允许键鼠控制':state===1?'等待系统授权':'尚未允许键鼠控制';
}
