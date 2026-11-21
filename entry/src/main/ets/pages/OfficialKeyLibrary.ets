import { asset } from '@kit.AssetStoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { util, url } from '@kit.ArkTS';
interface Identity { client_id:string; system_id:string; device_id:string; }
interface Account { user_id:string; token:string; csrf:string; }
interface RemoteRow { id:string; name:string; url:string; keymapping_type:string; updated_at:string; }
interface CatalogData { version?:string|number; keymapping?:RemoteRow[]; }
interface CatalogReply { code?:number; data?:CatalogData; }
interface WireResult { status:number; body:string; }
export interface LibraryRow { index:number; name:string; }
export interface LibraryResult { ok:boolean; message:string; rows:LibraryRow[]; version:string; }
export interface LibraryDownload { ok:boolean; message:string; raw:string; }
const ENDPOINT='/api/v1/keymapping/official/list_with_version?keymapping_types=keyboard&version=';
const SIGN_KEY='alWiSzXZTLu3WfFnw13uBru3';
export class OfficialKeyLibrary {
 private epoch:number=0;private active:http.HttpRequest|undefined=undefined;private rows:RemoteRow[]=[];
 private busy:boolean=false;private scope:string='';private currentAccount:()=>string;
 constructor(currentAccount:()=>string){this.currentAccount=currentAccount;}
 private current(run:number):boolean{return run===this.epoch&&/^[a-f0-9]{64}$/.test(this.scope)&&this.currentAccount()===this.scope;}
 cancel():void {this.epoch++;this.rows=[];this.scope='';this.busy=false;try{this.active?.destroy();}catch(_){}this.active=undefined;}
 private async read(alias:string):Promise<string>{
  const query:asset.AssetMap=new Map();query.set(asset.Tag.ALIAS,new util.TextEncoder().encodeInto(alias));query.set(asset.Tag.RETURN_TYPE,asset.ReturnType.ALL);
  const rows=await asset.query(query);if(rows.length!==1){throw Error('missing');}const bytes=rows[0].get(asset.Tag.SECRET);
  if(!(bytes instanceof Uint8Array)||!bytes.length||bytes.length>1024){throw Error('missing');}
  try{return util.TextDecoder.create('utf-8',{fatal:true}).decodeToString(bytes);}finally{bytes.fill(0);}
 }
 private contentAllowed(value:string):boolean {
  try{const authority=/^https:\/\/([^/?#]+)/.exec(value);if(!authority||authority[1].includes('@')){return false;}const u=url.URL.parseURL(value);
   return u.protocol==='https:'&&u.hostname.toLowerCase()==='nrd-file.fp.ps.netease.com'&&!u.username&&!u.password&&!u.hash&&(!u.port||u.port==='443');
  }catch(_){return false;}
 }
 private async wire(address:string,headers:Record<string,string>,run:number):Promise<WireResult>{
  const request=http.createHttp();this.active=request;request.enableAutoCookie(false);
  let size=0,oversize=false,timer=-1;const chunks:Uint8Array[]=[];
  request.on('dataReceive',(buffer:ArrayBuffer)=>{if(!this.current(run)||oversize){return;}size+=buffer.byteLength;if(size>1048576){oversize=true;try{request.destroy();}catch(_){}return;}chunks.push(new Uint8Array(buffer));});
  try{
   const pending=request.requestInStream(address,{method:http.RequestMethod.GET,header:headers,maxRedirects:0,usingCache:false,connectTimeout:12000,readTimeout:12000});
   const timeout=new Promise<number>((_resolve,reject)=>{timer=setTimeout(()=>{try{request.destroy();}catch(_){}reject(Error('timeout'));},20000);});
   const status=await Promise.race([pending,timeout]);if(!this.current(run)||oversize){throw Error('cancelled');}
   const joined=new Uint8Array(size);let offset=0;chunks.forEach((part:Uint8Array)=>{joined.set(part,offset);offset+=part.length;});
   try{return {status:status,body:util.TextDecoder.create('utf-8',{fatal:true}).decodeToString(joined)};}finally{joined.fill(0);}
  }finally{if(timer>=0){clearTimeout(timer);}try{request.destroy();}catch(_){}if(this.active===request){this.active=undefined;}chunks.forEach((part:Uint8Array)=>part.fill(0));}
 }
 async fetchDirectory():Promise<LibraryResult>{
  const result:LibraryResult={ok:false,message:'无法读取官方目录',rows:[],version:''};if(this.busy){return result;}this.cancel();this.scope=this.currentAccount();const run=this.epoch;if(!this.current(run)){result.message='请先登录后访问官方目录';return result;}this.busy=true;
  let identityText='',accountText='';let id:Identity|undefined=undefined;let account:Account|undefined=undefined;let headers:Record<string,string>={};
  try{
   identityText=await this.read('uus3c.identity.v1');if(!this.current(run)){return result;}accountText=await this.read('uus3c.account.v1');if(!this.current(run)){return result;}
   id=JSON.parse(identityText) as Identity;account=JSON.parse(accountText) as Account;identityText='';accountText='';
   const safe=(value:string):boolean=>typeof value==='string'&&value.length>0&&value.length<=2048&&!/[\x00-\x20\x7f]/.test(value);
   if(!safe(id.client_id)||!safe(id.device_id)||!safe(account.user_id)||!safe(account.token)||!safe(account.csrf)||(id.system_id&&!safe(id.system_id))){result.message='当前登录资料不可用';return result;}
   headers={'x-param-plat':'2','x-param-vn':'4.45.0','x-param-vc':'445000','x-param-pkgn':'com.netease.uuremote','x-param-chn':'nochannel','x-param-lang':'zh-CN','x-param-cnt':'CN','x-param-rel':'prod','x-param-client-id':id.client_id,'x-param-device-id':id.device_id,'x-param-user-id':account.user_id,'x-param-ts':Date.now().toString()};
   if(id.system_id){headers['x-param-system-id']=id.system_id;}
   const params=Object.keys(headers).sort().map((key:string):string=>key+'='+headers[key]).join('&');const enc=new util.TextEncoder();
   const key=await cryptoFramework.createSymKeyGenerator('HMAC').convertKey({data:enc.encodeInto(SIGN_KEY)});const mac=cryptoFramework.createMac('SHA256');await mac.init(key);await mac.update({data:enc.encodeInto('GET'+ENDPOINT+params)});const digest=await mac.doFinal();let signature='';digest.data.forEach((b:number)=>{signature+=b.toString(16).padStart(2,'0');});digest.data.fill(0);
   if(!this.current(run)){return result;}headers['X-Param-SIGN']=signature;headers['Accept']='application/json';headers['Content-Type']='application/json';headers['Authorization']='Bearer '+account.token;headers['Cookie']='nrd_access_token='+account.token+'; nrd_csrf_access_token='+account.csrf;headers['X-CSRF-TOKEN']=account.csrf;
   const response=await this.wire('https://api.nrd.nie.163.com'+ENDPOINT,headers,run);if(!this.current(run)){return result;}
   const parsed=JSON.parse(response.body) as CatalogReply;if(response.status!==200||parsed.code!==0||!Array.isArray(parsed.data?.keymapping)||parsed.data!.keymapping!.length>1000){return result;}
   const rows:RemoteRow[]=[];for(const item of parsed.data!.keymapping!){if(!item||item.keymapping_type!=='keyboard'||typeof item.name!=='string'||item.name.length>128||typeof item.url!=='string'||item.url.length>4096||!this.contentAllowed(item.url)){continue;}rows.push(item);}
   this.rows=rows;result.rows=rows.map((item:RemoteRow,index:number):LibraryRow=>({index:index,name:item.name.replace(/[\x00-\x1f\x7f]/g,'').slice(0,80)}));
   result.version=String(parsed.data!.version||'').slice(0,128);result.ok=true;result.message='已读取官方目录';return result;
  }catch(_){return result;}finally{identityText='';accountText='';Object.keys(headers).forEach((key:string)=>{headers[key]='';});headers={};if(id){id.client_id='';id.system_id='';id.device_id='';}if(account){account.user_id='';account.token='';account.csrf='';}if(run===this.epoch){this.busy=false;}}
 }
 async download(index:number):Promise<LibraryDownload>{
  const result:LibraryDownload={ok:false,message:'方案下载失败',raw:''};const run=this.epoch;
  if(this.busy||!this.current(run)||!Number.isInteger(index)||index<0||index>=this.rows.length||!this.contentAllowed(this.rows[index].url)){return result;}this.busy=true;
  try{const response=await this.wire(this.rows[index].url,{'Accept':'application/json'},run);if(!this.current(run)||response.status!==200){return result;}result.raw=response.body;result.ok=true;result.message='已获取方案';return result;}catch(_){return result;}finally{if(run===this.epoch){this.busy=false;}}
 }
}
