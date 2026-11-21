export function validatedLocalName(value:string):string {
  const name=value.trim();
  if(!name||Array.from(name).length>64||/[\u0000-\u001f\u007f-\u009f]/.test(value)){return '';}
  return name;
}
