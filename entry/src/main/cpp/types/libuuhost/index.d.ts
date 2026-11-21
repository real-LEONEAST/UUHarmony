export interface HostState {
  message:string; loggedIn:boolean; serverRunning:boolean; encoderAvailable:boolean;
  captureState:number; inputState:number; frames:number;audioFrames?:number;
  online?:boolean;captureRequests?:number;streamWidth?:number;streamHeight?:number;encodedWidth?:number;encodedHeight?:number;
  assistanceDeviceId:string; assistanceCode:string; assistanceEnabled:boolean;
}
export const initialize:(path:string,width:number,height:number,language:string)=>number;
export const adoptLegacyAccount:()=>number;
export const bindSharedAccount:()=>number;
export const clearSharedAccount:()=>number;
export const getState:()=>HostState;
export const startCapture:(width:number,height:number,displayId:number,sound?:boolean,primary?:boolean)=>number;
export const startHost:()=>number;
export const configureDisplay:(width:number,height:number,displayId:number,smooth?:boolean)=>number;
export const stopCapture:()=>number;
export const stopCaptureAsync:()=>Promise<number>;
export const stop:()=>number;
export const stopAsync:()=>Promise<number>;
export const requestInput:()=>number;
export const setAssistanceEnabled:(enabled:boolean)=>number;
export const resetAssistanceCode:()=>number;
export const isReceivingFiles:()=>boolean;
export const setReceivingFiles:(enabled:boolean,directoryFd?:number,root?:string)=>Promise<number>;
export const publishDeviceCover:(data:ArrayBuffer)=>Promise<number>;
