// Strictly bounded, allowlisted validation metadata. Values and server messages
// are never returned or logged; unknown names/types collapse to fixed placeholders.
pub fn validation_metadata(body:&serde_json::Value)->String {
 const FIELDS:[&str;17]=["name","client_id","system_id","system_version","gaid","install_id","build_fingerprint","brand","manufacturer","model","product","rom","abi","resolution","screen_size","dpi","controllable"];
 const TYPES:[&str;20]=["missing","required","value_error.missing","string_type","int_type","bool_type","type_error.str","type_error.integer","type_error.bool","string_too_short","string_too_long","too_short","too_long","greater_than","greater_than_equal","less_than","less_than_equal","invalid","value_error","type_error"];
 fn visit(v:&serde_json::Value,depth:usize,budget:&mut usize,found:&mut Vec<&'static str>){
  if depth>8||*budget==0{return;}*budget-=1;
  match v {
   serde_json::Value::Object(map)=>{for (key,val) in map.iter().take(32){if *budget==0{break;}if matches!(key.as_str(),"msg"|"message"|"input"|"value"|"ctx"|"url"|"description"){continue;}if let Some(field)=FIELDS.iter().find(|&&x|x==key){if !found.contains(field){found.push(field);}}visit(val,depth+1,budget,found);}}
   serde_json::Value::Array(list)=>{for item in list.iter().take(32){visit(item,depth+1,budget,found);}}
   serde_json::Value::String(value)=>{if let Some(token)=FIELDS.iter().chain(TYPES.iter()).find(|&&x|x==value){if !found.contains(token){found.push(token);}}}
   _=>{}
  }
 }
 let mut found=Vec::new();let mut budget=256;visit(body,0,&mut budget,&mut found);found.sort_unstable();if found.is_empty(){"no_allowlisted_metadata".into()}else{found.join(",")}
}
#[cfg(test)] mod tests {use super::*;use serde_json::json;
 #[test]fn metadata_is_only_allowlisted_and_excludes_sensitive_values(){let body=json!({"detail":[{"loc":["body","resolution"],"type":"string_type","msg":"secret name","input":"phone"},{"loc":["body","install_id"],"type":"value_error.missing","ctx":{"name":"secret"}},{"unknown":"untrusted"}]});let out=validation_metadata(&body);assert_eq!(out,"install_id,resolution,string_type,value_error.missing");assert!(!out.contains("secret"));assert_eq!(validation_metadata(&json!({"message":"name","input":"resolution"})),"no_allowlisted_metadata");}
}
