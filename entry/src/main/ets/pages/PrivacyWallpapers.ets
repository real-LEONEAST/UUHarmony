import { http } from '@kit.NetworkKit';
import { session } from './SessionClient';

interface SignedRequest {url:string;method:string;headers:Record<string,string>;body:string;}
interface Envelope {request?:SignedRequest;error?:string;}
interface PrivacyImage {url:string;md5?:string;}
interface PrivacyLocale {image?:PrivacyImage;}
interface PrivacyLocales {default?:PrivacyLocale;}
interface PrivacyPreset {preset_id:string;locales?:PrivacyLocales;}
interface PrivacyData {selected_type?:string;selected_preset_id?:string;selected_image_url?:string;custom_image?:string;preset_config?:PrivacyPreset[];}
interface ApiReply {code:number;data?:PrivacyData;}
export interface PrivacyChoice {key:string;type:string;presetId:string;title:string;url:string;selected:boolean;}
export interface PrivacyWallpaperResult {choices:PrivacyChoice[];message:string;}

function imageUrl(url:string):string {
  // Official first-party image origins, no local file or arbitrary website previews.
  return url.length<=4096&&/^https:\/\/([a-z0-9-]+\.)?(nosdn\.127\.net|res\.netease\.com|nos\.netease\.com|fp\.ps\.netease\.com)\//.test(url)?url:'';
}
export function privacyChoices(data:PrivacyData):PrivacyChoice[]{
  const result:PrivacyChoice[]=[];
  for(const item of (data.preset_config||[]).slice(0,24)){
    if(!item.preset_id||item.preset_id.length>128){continue;}
    const image=item.locales?.default?.image;
    result.push({key:item.preset_id,type:'preset',presetId:item.preset_id,title:'隐私壁纸 '+(result.length+1),url:image?imageUrl(image.url):'',selected:data.selected_type==='preset'&&data.selected_preset_id===item.preset_id});
  }
  if(data.custom_image){result.push({key:'custom',type:'custom',presetId:'',title:'电脑已保存的自定义壁纸',url:imageUrl(data.custom_image),selected:data.selected_type==='custom'});}
  if(!result.length&&data.selected_image_url){result.push({key:'current',type:data.selected_type||'preset',presetId:data.selected_preset_id||'',title:'电脑当前隐私壁纸',url:imageUrl(data.selected_image_url),selected:true});}
  return result;
}
export async function privacyWallpaperApi(action:string,choice?:PrivacyChoice):Promise<PrivacyWallpaperResult>{
  const generation=session.generation;const key=session.selected;
  const raw=await session.privacyWallpaperRequest(action,choice?.type||'',choice?.presetId||'');
  const envelope=JSON.parse(raw) as Envelope;
  if(!envelope.request||envelope.error){return {choices:[],message:'当前连接无法读取这台电脑的隐私壁纸'};}
  const request=envelope.request;const task=http.createHttp();
  try{
    if(generation!==session.generation||key!==session.selected||!session.windowsUnlockAllowed()){return {choices:[],message:'连接已变化，请重新打开防窥设置'};}
    const options:http.HttpRequestOptions={method:request.method==='PUT'?http.RequestMethod.PUT:http.RequestMethod.GET,header:request.headers,connectTimeout:10000,readTimeout:12000,expectDataType:http.HttpDataType.STRING,usingCache:false};
    if(request.body){options.extraData=request.body;}
    const response=await task.request(request.url,options);
    if(generation!==session.generation||key!==session.selected||!session.windowsUnlockAllowed()){return {choices:[],message:'连接已变化，请重新打开防窥设置'};}
    if(response.responseCode!==200||typeof response.result!=='string'||response.result.length>1048576){return {choices:[],message:'隐私壁纸请求未完成，请重试'};}
    const result=JSON.parse(response.result) as ApiReply;
    if(result.code!==0){return {choices:[],message:'电脑隐私壁纸暂不可用，请重试'};}
    return {choices:result.data?privacyChoices(result.data):[],message:action==='select'?'壁纸设置已保存，正在通知电脑更新':'请选择电脑防窥时显示的壁纸'};
  }catch(_){return {choices:[],message:'读取隐私壁纸失败，请重试'};}
  finally{task.destroy();request.headers={};request.body='';}
}
