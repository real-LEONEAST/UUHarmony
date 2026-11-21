import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import settings from '@ohos.settings';
import { display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

export interface LocalDeviceProfile {name:string;nameAuthoritative:boolean;os:string;cpu:string;model:string;screen:string;deviceType:string;brand:string;manufacturer:string;product:string;rom:string;screenSize:string;dpi:number;}
export function localDeviceProfile(context:common.UIAbilityContext):LocalDeviceProfile {
  let shared:string='';let standard:string='';let userProperty:string='';let source:string='fallback';let sharedError:boolean=false;let defaultError:boolean=false;let userError:boolean=false;
  try{shared=settings.getValueSync(context,settings.general.DEVICE_NAME,'',settings.domainName.DEVICE_SHARED).trim();}catch(_){sharedError=true;}
  try{standard=settings.getValueSync(context,settings.general.DEVICE_NAME,'').trim();}catch(_){defaultError=true;}
  try{userProperty=settings.getValueSync(context,settings.general.DEVICE_NAME,'',settings.domainName.USER_PROPERTY).trim();}catch(_){userError=true;}
  let name:string=shared||standard;if(name){source=shared?'shared':'default';}
  const fallback=deviceInfo.marketName||deviceInfo.productModel||'鸿蒙设备';
  hilog.info(0x0303,'UUS3C','device_name_source=%{public}s shared_error=%{public}d default_error=%{public}d shared_present=%{public}d default_present=%{public}d domains_equal=%{public}d shared_fallback=%{public}d default_fallback=%{public}d',source,sharedError?1:0,defaultError?1:0,shared?1:0,standard?1:0,shared&&standard&&shared===standard?1:0,shared&&shared===fallback?1:0,standard&&standard===fallback?1:0);
  hilog.info(0x0303,'UUS3C','device_name_user_error=%{public}d user_present=%{public}d user_shared_equal=%{public}d user_fallback=%{public}d',userError?1:0,userProperty?1:0,userProperty&&shared&&userProperty===shared?1:0,userProperty&&userProperty===fallback?1:0);
  const nameAuthoritative=source!=='fallback';
  if(!name){name=fallback;}
  let screen:string='';let screenSize:string='';let dpi:number=0;
  try{const item=display.getDefaultDisplaySync();screen=item.width+'x'+item.height;dpi=Number.isFinite(item.densityDPI)?Math.max(0,Math.round(item.densityDPI)):0;if(dpi>0){const w=Math.round(item.width/dpi),h=Math.round(item.height/dpi);screenSize=Math.max(w,h)+'x'+Math.min(w,h);}}catch(_){} 
  return {name:name.slice(0,64),nameAuthoritative:nameAuthoritative,os:deviceInfo.osFullName,cpu:deviceInfo.abiList,model:deviceInfo.productModel,screen:screen,deviceType:deviceInfo.deviceType,brand:deviceInfo.brand||'',manufacturer:deviceInfo.manufacture||'',product:deviceInfo.productSeries||'',rom:deviceInfo.osFullName||'',screenSize:screenSize,dpi:dpi};
}
