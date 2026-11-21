// Event snapshots follow the official Android active-contact collection semantics.
// This model is not connected to a transport until capability and channel are proven.
export interface TabletPoint { id: number; x: number; y: number; }
export enum TabletEventType { Start=1, Move=2, End=3, Cancel=4 }
export class TabletEvent {
  type: TabletEventType; points: TabletPoint[];
  constructor(type:TabletEventType,points:TabletPoint[]){this.type=type;this.points=points;}
}
export class TabletTouch {
  private active:TabletPoint[]=[]; private localIds:number[]=[]; private nextId:number=0;
  private blocked:boolean=false;
  private valid(p:TabletPoint):boolean{return Number.isInteger(p.id)&&p.id>=0&&Number.isFinite(p.x)&&Number.isFinite(p.y)&&p.x>=0&&p.x<=1&&p.y>=0&&p.y<=1;}
  private index(id:number):number{return this.localIds.indexOf(id);}
  private snapshot():TabletPoint[]{return this.active.map((p:TabletPoint)=>({id:p.id,x:p.x,y:p.y}));}
  down(point:TabletPoint):TabletEvent|undefined {
    if(this.blocked||!this.valid(point)||this.index(point.id)>=0){return undefined;}
    const start=this.active.length===0;this.localIds.push(point.id);
    this.active.push({id:this.nextId++,x:point.x,y:point.y});
    return new TabletEvent(start?TabletEventType.Start:TabletEventType.Move,this.snapshot());
  }
  move(points:TabletPoint[]):TabletEvent|undefined {
    if(this.blocked||points.length!==this.active.length||points.length===0){return undefined;}
    const seen:number[]=[];
    for(const p of points){const i=this.index(p.id);if(!this.valid(p)||i<0||seen.includes(p.id)){return undefined;}seen.push(p.id);}
    for(const p of points){const i=this.index(p.id);this.active[i].x=p.x;this.active[i].y=p.y;}
    return new TabletEvent(TabletEventType.Move,this.snapshot());
  }
  up(id:number):TabletEvent|undefined {
    const i=this.index(id);if(i<0){return undefined;}this.localIds.splice(i,1);this.active.splice(i,1);
    if(this.blocked){if(this.active.length===0){this.blocked=false;}return undefined;}
    return new TabletEvent(this.active.length?TabletEventType.Move:TabletEventType.End,this.snapshot());
  }
  cancel():TabletEvent|undefined {
    if(this.blocked||this.active.length===0){return undefined;}this.blocked=true;return new TabletEvent(TabletEventType.Cancel,[]);
  }
  // A platform-wide cancellation proves the old contact sequence has ended.
  reconcileBlocked(ids:number[]):void {if(!this.blocked){return;}for(let i=this.localIds.length-1;i>=0;i--){if(!ids.includes(this.localIds[i])){this.localIds.splice(i,1);this.active.splice(i,1);}}if(this.active.length===0){this.blocked=false;}}
  isBlocked():boolean{return this.blocked;}
  platformCancel():void{this.active=[];this.localIds=[];this.blocked=false;}
}
