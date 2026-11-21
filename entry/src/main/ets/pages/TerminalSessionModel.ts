export interface TerminalItem {createdAt?:number;session:number;sessionToken:number;listed:boolean;name:string;phase:string;attached:boolean;killPending:boolean;killUncertain:boolean;}
export function terminalCanEnter(item:TerminalItem):boolean {
  return item.phase!=='exited'&&item.phase!=='failed'&&!item.killPending&&!item.killUncertain&&(item.attached||item.listed);
}
export function terminalCanKill(item:TerminalItem):boolean {
  return item.phase!=='exited'&&item.phase!=='failed'&&!item.killPending&&!item.killUncertain&&(item.attached||item.listed);
}

export class TerminalNames {
  private names:Map<number,string>=new Map<number,string>();
  private next:number=1;
  name(token:number):string {
    let value=this.names.get(token);
    if(!value){value='session'+this.next;this.next++;this.names.set(token,value);}
    return value;
  }
}
