// Local predicted pointer. The host provides no cursor-position feedback here.
export class VirtualMouse {
  x: number = 0.5; y: number = 0.5;
  private id: number = -1; private px: number = 0; private py: number = 0;
  private sx: number = 0; private sy: number = 0; private start: number = 0; private maxDistance:number=0;
  down(id: number, x: number, y: number, now: number): void {
    if (this.id >= 0) { return; }
    this.id=id; this.px=x; this.py=y; this.sx=x; this.sy=y; this.start=now; this.maxDistance=0;
  }
  move(id: number, x: number, y: number, width: number, height: number, speed: number): boolean {
    if (id!==this.id || width<=0 || height<=0) { return false; }
    this.x=Math.max(0,Math.min(1,this.x+(x-this.px)*speed/width));
    this.y=Math.max(0,Math.min(1,this.y+(y-this.py)*speed/height));
    this.px=x; this.py=y; const dx=x-this.sx,dy=y-this.sy;this.maxDistance=Math.max(this.maxDistance,dx*dx+dy*dy); return true;
  }
  up(id: number, x: number, y: number, now: number): boolean {
    if(id!==this.id){return false;}
    const dx=x-this.sx,dy=y-this.sy; this.id=-1;
    return now-this.start<=350 && this.maxDistance<=100 && dx*dx+dy*dy<=100;
  }
  cancel(): void { this.id=-1; }
}
// Contact ownership and gesture state are independent from ArkUI widgets.
export class VirtualContacts {
  canvas:number=-1; left:number=-1; right:number=-1; wheel:number=-1; wheelUp:number=-1; wheelDown:number=-1; handle:number=-1;
  private blocked:number[]=[];
  private known:number[]=[];
  reconcile(active:number[]):void {this.blocked=this.blocked.filter((id:number)=>active.includes(id));if(this.blocked.length>0){for(const id of active){if(!this.blocked.includes(id)){this.blocked.push(id);}}}this.known=active.slice();}
  cancel():void {this.blocked=this.known.slice();this.canvas=-1;this.left=-1;this.right=-1;this.wheel=-1;this.wheelUp=-1;this.wheelDown=-1;this.handle=-1;}
  ready():boolean{return this.blocked.length===0;}
  own(id:number):boolean{return id===this.left||id===this.right||id===this.wheel||id===this.wheelUp||id===this.wheelDown||id===this.handle;}
}
