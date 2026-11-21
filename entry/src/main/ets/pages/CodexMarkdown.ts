// SPDX-License-Identifier: GPL-3.0-only
export function codexEscape(text:string):string{return text.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
export function codexMarkdown(text:string):string {
  // Small Markdown subset; remote HTML and image URLs remain text.
  const lines=text.replace(/\r\n/g,'\n').split('\n');let out='';let code:string[]=[];let language='';let fenced=false;
  for(const line of lines){
    if(/^ {0,3}(\x60{3}|~~~)/.test(line)){
      if(fenced){out+='<pre><code data-language="'+codexEscape(language)+'">'+codexEscape(code.join('\n'))+'</code></pre>';code=[];fenced=false;}
      else{fenced=true;language=line.replace(/^ {0,3}(\x60{3}|~~~)/,'').trim().slice(0,32);}continue;
    }
    if(fenced){code.push(line);continue;}
    const safe=codexEscape(line);const inline=safe.replace(/\x60([^\x60]+)\x60/g,'<code>$1</code>').replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>');
    if(/^#{1,6} /.test(line)){const n=line.indexOf(' ');out+='<h'+n+'>'+inline.slice(n+1)+'</h'+n+'>';}
    else if(/^[-*] /.test(line)){out+='<p class="bullet">• '+inline.slice(2)+'</p>';}
    else if(/^> /.test(line)){out+='<blockquote>'+inline.slice(5)+'</blockquote>';}
    else{out+='<p>'+ (inline||'<br>')+'</p>';}
  }
  if(fenced){out+='<pre><code>'+codexEscape(code.join('\n'))+'</code></pre>';}
  return out;
}
