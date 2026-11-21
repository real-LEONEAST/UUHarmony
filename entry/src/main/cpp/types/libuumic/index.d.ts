// Call start only after runtime microphone consent and remote negotiation success.
export const start:(generation:number,stereo:boolean,packetMs:number)=>string;
export const read:()=>string;
export const stop:()=>void;
export const status:()=>string;
