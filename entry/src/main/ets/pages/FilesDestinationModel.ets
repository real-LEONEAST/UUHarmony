import { FilesStatus } from './RemoteFiles';
export interface UploadListRequest {generation:number;target:string;media:boolean;}
export function sameRemoteDirectory(a:string,b:string):boolean{
  const normalize=(value:string):string=>value.replace(/\\/g,'/').replace(/\/+$/,'');
  const left=normalize(a),right=normalize(b);
  return left.length>0&&right.length>0&&((/^[A-Za-z]:/.test(left)||/^[A-Za-z]:/.test(right))?left.toLowerCase()===right.toLowerCase():left===right);
}
export function uploadListingMatches(state:FilesStatus,request:UploadListRequest):boolean{
  return state.generation>request.generation&&state.mode==='list'&&state.state==='complete'&&sameRemoteDirectory(state.directory,request.target);
}
