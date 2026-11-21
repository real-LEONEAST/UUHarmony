// Dedicated protocol operations only. No executable, command line or credential fields.
export type RemoteSystemAction='lock_now'|'reboot'|'shutdown';
export function systemActionLabel(kind:RemoteSystemAction):string{return kind==='lock_now'?'立即锁屏':kind==='reboot'?'重新启动':'关机';}
export function systemActionResult(raw:string):string {
  try{const reply=JSON.parse(raw) as {sent?:boolean;sentMessages?:number;totalMessages?:number;error?:string};
    if(reply.sent===true&&reply.sentMessages===1&&reply.totalMessages===1){return '指令已发送；协议没有执行确认，请观察电脑状态。';}
    return '指令未完成发送，请检查连接后手动重试。';
  }catch(_){return '无法读取发送结果；未确认电脑状态，请勿连续重复操作。';}
}
