// SPDX-License-Identifier: GPL-3.0-only
export type CameraZone='full'|'right_half';
export interface CameraSettings {zone:CameraZone; sensitivityX:number; sensitivityY:number;}
// A manually selected one-touch relative-motion primitive. It never infers
// remote pointer-lock state, clicks, hides controls, or starts itself.
export class CameraGesture {
 private activeId:number=-1;private generation:number=0;private lastX:number=0;private lastY:number=0;private residualX:number=0;private residualY:number=0;
 private settings:CameraSettings={zone:'full',sensitivityX:1,sensitivityY:1};
 private send:(dx:number,dy:number)=>boolean;private failure:()=>void;
 constructor(send:(dx:number,dy:number)=>boolean,failure:()=>void){this.send=send;this.failure=failure;}
 configure(settings:CameraSettings):boolean {
  if(this.activeId>=0||!settings||!['full','right_half'].includes(settings.zone)||!Number.isFinite(settings.sensitivityX)||!Number.isFinite(settings.sensitivityY)||settings.sensitivityX<0.1||settings.sensitivityX>10||settings.sensitivityY<0.1||settings.sensitivityY>10){return false;}
  this.settings={zone:settings.zone,sensitivityX:settings.sensitivityX,sensitivityY:settings.sensitivityY};return true;
 }
 epoch():number{return this.generation;}
 begin(id:number,x:number,y:number,width:number,height:number,epoch:number):boolean {
  if(epoch!==this.generation||this.activeId>=0||!Number.isInteger(id)||id<0||![x,y,width,height].every(Number.isFinite)||width<=0||height<=0||x<0||y<0||x>width||y>height||this.settings.zone==='right_half'&&x<width/2){return false;}
  this.activeId=id;this.lastX=x;this.lastY=y;this.residualX=0;this.residualY=0;return true;
 }
 move(id:number,x:number,y:number,epoch:number):boolean {
  if(epoch!==this.generation||id!==this.activeId){return false;}if(!Number.isFinite(x)||!Number.isFinite(y)){this.reset();try{this.failure();}catch(_){}return false;}
  const dx=Math.max(-512,Math.min(512,x-this.lastX))*this.settings.sensitivityX,dy=Math.max(-512,Math.min(512,y-this.lastY))*this.settings.sensitivityY;
  this.lastX=x;this.lastY=y;this.residualX+=dx;this.residualY+=dy;
  const outX=Math.trunc(this.residualX),outY=Math.trunc(this.residualY);this.residualX-=outX;this.residualY-=outY;
  if(!outX&&!outY){return true;}
  let accepted=false;try{accepted=this.send(outX,outY);}catch(_){accepted=false;}
  if(!accepted){this.reset();try{this.failure();}catch(_){}return false;}return true;
 }
 end(id:number):boolean{if(id!==this.activeId){return false;}this.activeId=-1;this.residualX=0;this.residualY=0;return true;}
 reset():void{this.generation++;this.activeId=-1;this.residualX=0;this.residualY=0;}
}
