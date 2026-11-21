/* SPDX-License-Identifier: GPL-3.0-only */
/* Independent thin adapter. Dependencies are official xterm.js distributions, MIT. */
(() => {
 'use strict';
 let term,fit,serializer,generation=0,profile='ordinary',touch=null,wheelRemainder=0;
 let live=false,reading=false,input=[],pending=0,rendered=0,accepted=0,sizeVersion=0,overflow=false;
 const reader=document.getElementById('reader'),screen=document.getElementById('screen');
 function enqueue(data){if(!live||reading)return;if(input.join('').length+data.length>4096){overflow=true;return;}input.push(data);}
 function cancelWheel(event){event.preventDefault();event.stopImmediatePropagation();}
 // The Codex page controls the application's transcript, which a Windows mux
 // may redraw entirely in the normal outer screen. Its local scrollback is not
 // Codex history. Page keys also avoid entering the mux's unrelated copy mode.
 screen.addEventListener('wheel',event=>{
  if(!term||!event.deltaY)return;
  if(profile==='codex'||term.buffer.active.type==='alternate'&&term.modes.mouseTrackingMode==='none'){
   cancelWheel(event);if(!live||reading)return;enqueue(event.deltaY<0?'\u001b[5~':'\u001b[6~');return;
  }
  if(live&&!reading&&term.modes.mouseTrackingMode!=='none'&&!event.shiftKey)return;
  cancelWheel(event);const height=term.element.querySelector('.xterm-screen').getBoundingClientRect().height/term.rows||16;
  wheelRemainder+=event.deltaMode===1?event.deltaY:event.deltaMode===2?event.deltaY*term.rows:event.deltaY/height;
  const lines=Math.trunc(wheelRemainder);if(lines){term.scrollLines(Math.max(-100,Math.min(100,lines)));wheelRemainder-=lines;}
 },{capture:true,passive:false});
 screen.addEventListener('touchstart',event=>{touch=event.touches.length===1?{x:event.touches[0].clientX,y:event.touches[0].clientY,last:event.touches[0].clientY,carry:0,moved:false}:null;},{passive:true});
 screen.addEventListener('touchmove',event=>{
  if(!touch||event.touches.length!==1){touch=null;return;}const point=event.touches[0];
  if(!touch.moved&&Math.abs(point.clientY-touch.y)<8)return;
  if(!touch.moved&&Math.abs(point.clientX-touch.x)>Math.abs(point.clientY-touch.y)){touch=null;return;}
  touch.moved=true;event.preventDefault();event.stopImmediatePropagation();touch.carry+=touch.last-point.clientY;touch.last=point.clientY;
  const step=profile==='codex'?80:18;let count=Math.min(12,Math.floor(Math.abs(touch.carry)/step));const direction=Math.sign(touch.carry);touch.carry-=count*step*direction;
  const target=term.element.querySelector('.xterm-screen'),rect=target.getBoundingClientRect();
  while(count-->0)target.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,deltaMode:1,deltaY:direction*3,clientX:Math.max(rect.left+1,Math.min(rect.right-1,touch.x)),clientY:Math.max(rect.top+1,Math.min(rect.bottom-1,touch.y))}));
 },{capture:true,passive:false});
 for(const name of ['touchend','touchcancel'])screen.addEventListener(name,event=>{if(touch?.moved){event.preventDefault();event.stopImmediatePropagation();}touch=null;},{capture:true,passive:false});
 function plain(){const b=term.buffer.active,lines=[];const start=Math.max(0,b.length-1000);for(let i=start;i<b.length;i++)lines.push(b.getLine(i)?.translateToString(true)||'');return lines.join('\n').slice(-150000);}
 function refresh(){if(reading)reader.textContent=plain();}
 function measure(){if(!live||screen.clientWidth<16||screen.clientHeight<16)return;const d=fit.proposeDimensions();if(!d)return;const cols=Math.max(2,Math.min(240,d.cols)),rows=Math.max(2,Math.min(100,d.rows));if(cols!==term.cols||rows!==term.rows){term.resize(cols,rows);sizeVersion++;}}
 new ResizeObserver(()=>measure()).observe(screen);
 function create(cols,rows){
  if(term)term.dispose();generation++;document.getElementById('terminal').textContent='';
  term=new Terminal({cols,rows,scrollback:1000,fontSize:13,fontFamily:'monospace',cursorBlink:true,screenReaderMode:true,convertEol:false,allowProposedApi:false,disableStdin:true,linkHandler:{activate(){},hover(){},leave(){}},theme:{background:'#ffffff',foreground:'#252b33',cursor:'#0b57d0',black:'#252b33',red:'#b3261e',green:'#137333',yellow:'#8a6100',blue:'#174ea6',magenta:'#8e24aa',cyan:'#006974',white:'#59636e',brightBlack:'#6b7280',brightRed:'#c5221f',brightGreen:'#188038',brightYellow:'#8c6800',brightBlue:'#1967d2',brightMagenta:'#9334e6',brightCyan:'#007b83',brightWhite:'#252b33'}});
  fit=new FitAddon.FitAddon();serializer=new SerializeAddon.SerializeAddon();term.loadAddon(fit);term.loadAddon(serializer);term.open(document.getElementById('terminal'));term.textarea.setAttribute('inputmode','none');
  term.parser.registerOscHandler(52,()=>true); // Never accept remote clipboard writes/reads.
  term.onData(enqueue);
 }
 create(80,24);
 window.uuTerminal={
  open(snapshot,cols,rows,agent){profile=agent==='codex'?'codex':'ordinary';touch=null;wheelRemainder=0;live=false;input=[];pending=0;rendered=0;accepted=0;overflow=false;create(Math.max(2,Math.min(240,cols)),Math.max(2,Math.min(100,rows)));const own=generation;if(snapshot){pending=snapshot.length;term.write(snapshot,()=>{if(own===generation){pending=0;refresh();}});}else{refresh();}return true;},
  setLive(value){live=!!value;term.options.disableStdin=!live||reading;if(live){document.getElementById('terminal').style.minWidth='0';measure();}else{term.blur();input=[];document.getElementById('terminal').style.minWidth=(term.cols*8)+'px';}return true;},
  feed(base64,seq){if(!Number.isSafeInteger(seq)||seq!==accepted+1||pending>32768)return false;const binary=atob(base64),bytes=new Uint8Array(binary.length);for(let i=0;i<binary.length;i++)bytes[i]=binary.charCodeAt(i);if(bytes.length>16384)return false;const own=generation;accepted=seq;pending+=bytes.length;term.write(bytes,()=>{if(own===generation){pending-=bytes.length;rendered=seq;refresh();}});return true;},
  state(){return JSON.stringify({rendered,pending,cols:term.cols,rows:term.rows,sizeVersion,overflow,bracketedPaste:term.modes.bracketedPasteMode,appCursor:term.modes.applicationCursorKeysMode,bufferType:term.buffer.active.type,viewportY:term.buffer.active.viewportY,baseY:term.buffer.active.baseY,scrollTarget:profile==='codex'?'application':'terminal'});},
  takeInput(){const out=input.join('');input=[];return JSON.stringify({text:out});},
  snapshot(){if(pending)return '';return JSON.stringify({snapshot:serializer.serialize({scrollback:1000}),plain:plain(),cols:term.cols,rows:term.rows});},
  reader(value){reading=!!value;screen.hidden=reading;reader.hidden=!reading;term.options.disableStdin=!live||reading;if(reading){term.blur();refresh();}else if(live){measure();}return true;},
  focus(){if(live&&!reading)term.focus();return true;},
  bottom(){term.scrollToBottom();reader.scrollTop=reader.scrollHeight;return true;}
 };
})();
