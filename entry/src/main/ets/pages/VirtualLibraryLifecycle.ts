// SPDX-License-Identifier: GPL-3.0-only
class VirtualLibraryLifecycle {
 private listeners:Map<number,()=>void>=new Map();private serial:number=0;
 register(callback:()=>void):()=>void {const id=++this.serial;this.listeners.set(id,callback);return ()=>{this.listeners.delete(id);};}
 suspend():void {this.listeners.forEach((callback:()=>void)=>{try{callback();}catch(_){}});}
}
export const virtualLibraryLifecycle:VirtualLibraryLifecycle=new VirtualLibraryLifecycle();
