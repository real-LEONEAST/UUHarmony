export function compactPhoneLayout(deviceType:string,width:number,height:number,top:number,bottom:number):boolean {
  return deviceType==='phone' && width>height && height>0 && height-Math.max(0,top)-Math.max(0,bottom)<500;
}

export function compactDeviceCoverHeight(height:number,top:number,bottom:number):number {
  return Math.max(96,Math.min(128,(height-Math.max(0,top)-Math.max(0,bottom))*0.34));
}

export function phoneLandscape(deviceType:string,width:number,height:number):boolean {
  return deviceType==='phone' && height>0 && width>height;
}
