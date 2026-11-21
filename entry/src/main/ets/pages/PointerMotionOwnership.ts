// SPDX-License-Identifier: GPL-3.0-only
export class PointerMotionOwnership {
 private owner:string='';
 acquire(owner:string):boolean{if(!owner){return false;}if(this.owner&&this.owner!==owner){return false;}this.owner=owner;return true;}
 permits(owner:string):boolean{return !this.owner||this.owner===owner;}
 owns(owner:string):boolean{return !!owner&&this.owner===owner;}
 release(owner:string):void{if(this.owner===owner){this.owner='';}}
 reset():void{this.owner='';}
}
