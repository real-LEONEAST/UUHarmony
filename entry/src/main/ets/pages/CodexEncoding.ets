import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { zlib } from '@kit.BasicServicesKit';
import { CodexEncoding } from './CodexFraming';
export class CodexUtf8 implements CodexEncoding {
  encode(text:string):Uint8Array{return new util.TextEncoder().encodeInto(text);}
  decode(bytes:Uint8Array):string{if(bytes.length===0){return '';}return util.TextDecoder.create('utf-8',{fatal:true}).decodeToString(bytes);}
  toBase64(bytes:Uint8Array):string{if(bytes.length===0){return '';}return new util.Base64Helper().encodeToStringSync(bytes);}
  fromBase64(text:string):Uint8Array{if(text.length===0){return new Uint8Array(0);}return new util.Base64Helper().decodeSync(text);}
  async sha256(bytes:Uint8Array):Promise<string>{
    const md=cryptoFramework.createMd('SHA256');await md.update({data:bytes});const result=await md.digest();
    let value='';for(const byte of result.data){value+=byte.toString(16).padStart(2,'0');}return value;
  }
  async hash(text:string):Promise<string>{return this.sha256(this.encode(text));}
  async inflate(bytes:Uint8Array,size:number):Promise<Uint8Array>{
    if(!Number.isSafeInteger(size)||size<1||size>400000||bytes.length>400000){throw new Error('codex_compression_limit');}
    const zip=await zlib.createZip();const output=new ArrayBuffer(size+1);
    const stream:zlib.ZStream={nextIn:bytes.slice().buffer,availableIn:bytes.length,nextOut:output,availableOut:size+1};
    let initialized=false;
    try{
      if(await zip.inflateInit2(stream,31)!==zlib.ReturnStatus.OK){throw new Error('codex_compression_unavailable');}initialized=true;
      const result=await zip.inflate(stream,zlib.CompressFlushMode.FINISH);
      const state=await zip.getZStream();
      if(result!==zlib.ReturnStatus.STREAM_END||state.totalOut!==size||state.totalIn!==bytes.length){throw new Error('codex_compression_invalid');}
      // The SDK updates the caller's output ArrayBuffer. getZStream reports
      // counters, while its nextOut may be empty after consuming that buffer.
      return new Uint8Array(output,0,size).slice();
    }finally{if(initialized){await zip.inflateEnd(stream);}}
  }
}
