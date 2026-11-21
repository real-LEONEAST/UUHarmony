use super::*;
pub(crate) fn request(c:&Core,target:&Value,v:&Value)->Value {
    let Some(id)=target["device_id"].as_str() else{return json!({"error":"device_required"})};
    let id=id.bytes().map(|b|if b.is_ascii_alphanumeric()||b"-._~".contains(&b){(b as char).to_string()}else{format!("%{b:02X}")}).collect::<String>();
    let (method,suffix,body)=match v["action"].as_str() {
        Some("list")=>("GET","/screensaver/detail",String::new()),
        Some("select")=>{
            let Some(kind)=v["selectedType"].as_str().filter(|s|["preset","custom"].contains(s)) else{return json!({"error":"invalid_screensaver_type"})};
            let Some(preset)=v["presetId"].as_str().filter(|s|s.len()<=128&&!s.chars().any(char::is_control)) else{return json!({"error":"invalid_screensaver_preset"})};
            ("PUT","/screensaver",json!({"selected_type":kind,"selected_preset_id":preset}).to_string())
        },
        _=>return json!({"error":"invalid_screensaver_action"}),
    };
    let path=format!("/api/v1/device/{id}{suffix}");
    json!({"request":{"url":format!("{BASE}{path}"),"method":method,"headers":c.headers(method,&path,&body),"body":body}})
}
#[cfg(test)] mod tests {
    use super::*;
    #[test]fn official_read_and_selection_shapes_only(){
        let c=Core::default();let d=json!({"device_id":"owned/pc"});
        let r=request(&c,&d,&json!({"action":"list"}));assert_eq!(r["request"]["method"],"GET");assert!(r["request"]["url"].as_str().unwrap().ends_with("owned%2Fpc/screensaver/detail"));
        let r=request(&c,&d,&json!({"action":"select","selectedType":"preset","presetId":"preset-1"}));
        assert_eq!(r["request"]["method"],"PUT");assert_eq!(serde_json::from_str::<Value>(r["request"]["body"].as_str().unwrap()).unwrap(),json!({"selected_type":"preset","selected_preset_id":"preset-1"}));
        assert!(request(&c,&d,&json!({"action":"select","selectedType":"execute"}))["error"].is_string());
    }
}
