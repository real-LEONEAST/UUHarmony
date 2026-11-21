export const createExclusive: (directoryFd:number, name:string)=>number;
export const finishTemporary: (directoryFd:number, temporaryName:string, destinationName?:string)=>string;
export const removeReceived: (directoryFd:number, name:string, fingerprint:string)=>number;
export const inspectReceived: (directoryFd:number, name:string)=>string;
export interface LocalDirectoryEntry { name:string; kind:number; size:number; modified:number; }
export const listDirectory: (directoryFd:number)=>LocalDirectoryEntry[];
