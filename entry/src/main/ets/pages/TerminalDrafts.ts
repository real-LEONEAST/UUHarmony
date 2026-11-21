export class TerminalDrafts {
  private values:Map<number,string>=new Map<number,string>();
  private current:number=-1;
  switchTo(id:number,draft:string):string {
    if(this.current>=0){this.values.set(this.current,draft);}
    this.current=id;
    return this.values.get(id)||'';
  }
  remember(draft:string):void {if(this.current>=0){this.values.set(this.current,draft);}}
  forget(id:number):void {this.values.delete(id);if(this.current===id){this.current=-1;}}
}
