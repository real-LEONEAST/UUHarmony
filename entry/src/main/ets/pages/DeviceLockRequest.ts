// One-use authorization created by the device-details confirmation, never by route data alone.
export class DeviceLockRequest {
  private serial:number=0;private token:string='';private key:string='';private generation:number=-1;private used:boolean=false;
  private resultKey:string='';private result:string='';
  create(key:string):string{this.cancel();this.key=key;this.token=Date.now().toString(36)+'-'+(++this.serial);return this.token;}
  bind(token:string,key:string,generation:number):boolean{if(!token||this.token!==token||this.key!==key||this.used||this.generation!==-1){return false;}this.generation=generation;return true;}
  consume(token:string,key:string,generation:number):boolean{if(this.token!==token||this.key!==key||this.generation!==generation||this.used||!token){return false;}this.used=true;return true;}
  finish(key:string,result:string):void{this.resultKey=key;this.result=result;this.cancel();}
  takeResult(key:string):string{if(this.resultKey!==key){return '';}const value=this.result;this.result='';this.resultKey='';return value;}
  cancelToken(token:string):void{if(token&&this.token===token){this.cancel();}}
  cancel():void{this.token='';this.key='';this.generation=-1;this.used=false;}
}
export const deviceLockRequest:DeviceLockRequest=new DeviceLockRequest();
