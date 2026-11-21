// SPDX-License-Identifier: GPL-3.0-only
export interface CodexEncoding {
  encode(text:string):Uint8Array;decode(bytes:Uint8Array):string;
  toBase64(bytes:Uint8Array):string;fromBase64(text:string):Uint8Array;sha256(bytes:Uint8Array):Promise<string>;
  inflate?(bytes:Uint8Array,size:number):Promise<Uint8Array>;
}
export interface CodexDecoded {messages:string[];acks:string[];}
const CHUNK:number=96;const MAX:number=400000;
export class CodexFraming {
  private nonce:string;private codec:CodexEncoding;private buffer:string='';private sequence:number=0;
  private count:number=0;private parts:string[]=[];private complete:boolean=false;
  constructor(nonce:string,codec:CodexEncoding){if(!/^[a-f0-9]{16}$/.test(nonce)){throw new Error('codex_nonce_required');}this.nonce=nonce;this.codec=codec;}
  expect(sequence:number):void {if(!Number.isSafeInteger(sequence)||sequence<0){throw new Error('codex_sequence');}this.sequence=sequence;this.parts=[];this.count=0;this.complete=false;this.buffer='';}
  async request(sequence:number,text:string):Promise<string>{
    const b=this.codec.encode(text);if(b.length>3072){throw new Error('codex_request_limit');}
    const payload=b.length+':'+await this.codec.sha256(b)+':'+this.codec.toBase64(b);
    const count=Math.ceil(payload.length/CHUNK);let out='';
    for(let i=0;i<count;i++){out+='~UUAI1|'+this.nonce+'|I|'+sequence+'|'+i+'|'+count+'|'+payload.slice(i*CHUNK,(i+1)*CHUNK)+'~\r\n';}
    return out;
  }
  async feed(bytes:Uint8Array):Promise<CodexDecoded>{
    const result:CodexDecoded={messages:[],acks:[]};
    // ASCII framing only; never decode console UTF-8 or rewrite CR/LF.
    for(const byte of bytes){this.buffer+=String.fromCharCode(byte);}
    const prefix='~UUAI1|'+this.nonce+'|O|';
    for(;;){
      const start=this.buffer.indexOf(prefix);
      if(start<0){this.buffer=this.buffer.slice(-prefix.length);break;}
      if(start>0){this.buffer=this.buffer.slice(start);}
      const end=this.buffer.indexOf('~',1);if(end<0){if(this.buffer.length>220){throw new Error('codex_frame_corrupted');}break;}
      const frame=this.buffer.slice(1,end);this.buffer=this.buffer.slice(end+1);
      const f=frame.split('|');if(f.length!==7||!/^\d+$/.test(f[3])||!/^\d+$/.test(f[4])||!/^\d+$/.test(f[5])||!/^[A-Za-z0-9+/=:]+$/.test(f[6])){throw new Error(frame.includes('\x1b')?'codex_frame_corrupted_vt':frame.includes('\r')||frame.includes('\n')?'codex_frame_corrupted_wrap':'codex_frame_corrupted_fields');}
      const seq=Number(f[3]),part=Number(f[4]),count=Number(f[5]);
      if(seq!==this.sequence){continue;}
      if(count<1||count>18000||part<0||part>=count||f[6].length>CHUNK||this.count!==0&&this.count!==count){throw new Error('codex_fragment_limit');}
      this.count=count;
      if(part<this.parts.length){if(this.parts[part]!==f[6]){throw new Error('codex_fragment_changed');}}
      else if(part!==this.parts.length){throw new Error('codex_fragment_gap_'+this.parts.length+'_'+part);}
      else{this.parts.push(f[6]);}
      // Console renderers may coalesce several rapidly printed lines. After
      // verified READY, require acknowledgement of every output record.
      if(seq>0||(part+1)%8===0||part+1===count){result.acks.push('~UUAI1|'+this.nonce+'|A|'+seq+'|'+part+'~\r\n');}
      if(this.parts.length===count&&!this.complete){
        const all=this.parts.join('');const match=/^(G?)(\d+):([a-f0-9]{64}):([A-Za-z0-9+/=]*)$/.exec(all);
        if(!match||Number(match[2])>MAX){throw new Error('codex_envelope_limit');}
        const packed=this.codec.fromBase64(match[4]);if(packed.length>MAX){throw new Error('codex_envelope_limit');}
        if(match[1]&&!this.codec.inflate){throw new Error('codex_compression_unavailable');}
        const raw=match[1]?await this.codec.inflate!(packed,Number(match[2])):packed;if(raw.length!==Number(match[2])||await this.codec.sha256(raw)!==match[3]){throw new Error('codex_digest_failed');}
        this.complete=true;result.messages.push(this.codec.decode(raw));
      }
    }
    return result;
  }
}
