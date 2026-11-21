// Vendor download-origin evidence: docs/DEVICE-WALLPAPER.md. No upload endpoints.
export const WALLPAPER_BYTES:number=8*1024*1024;
export function trustedWallpaperUrl(value:string):boolean{
  if(value.length>4096||/[^\x21-\x7e]|[\\#]/.test(value)){return false;}
  const match=/^https:\/\/([^/]+)\/([^#]+)$/.exec(value);
  if(!match){return false;}
  const host=match[1];const object=match[2].split('?')[0];
  const label='[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?';
  const nos=new RegExp('^'+label+'\\.nosdn\\.127\\.net$').test(host);
  const resources=new RegExp('^'+label+'\\.res\\.netease\\.com$').test(host);
  const publication=new RegExp('^'+label+'\\.fp\\.ps\\.netease\\.com$').test(host)&&object.startsWith('file/')&&object.length>5;
  const objects=host==='nos.netease.com'&&object.split('/').filter((part:string)=>part.length>0).length>=2;
  if(!nos&&!resources&&!publication&&!objects){return false;}
  return object.length>0&&!object.toLowerCase().includes('%2e')&&!object.split('/').some((part:string)=>part==='.'||part==='..');
}
export function wallpaperFormat(bytes:Uint8Array):string{
  if(bytes.length>=8&&bytes[0]===137&&bytes[1]===80&&bytes[2]===78&&bytes[3]===71&&bytes[4]===13&&bytes[5]===10&&bytes[6]===26&&bytes[7]===10){return 'image/png';}
  if(bytes.length>=3&&bytes[0]===255&&bytes[1]===216&&bytes[2]===255){return 'image/jpeg';}
  if(bytes.length>=12&&bytes[0]===82&&bytes[1]===73&&bytes[2]===70&&bytes[3]===70&&bytes[8]===87&&bytes[9]===69&&bytes[10]===66&&bytes[11]===80){return 'image/webp';}
  return '';
}
export function wallpaperSize(width:number,height:number):boolean{return Number.isInteger(width)&&Number.isInteger(height)&&width>0&&height>0&&width<=8192&&height<=8192&&width*height<=16777216;}
