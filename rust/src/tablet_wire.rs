// Static Android 4.45.0 Wire adapter evidence is documented in INPUT-MODES-V32.md.
// This encoder is deliberately not connected to a channel until the transport,
// capability and screen binding have been independently established.
#[derive(Clone,Copy,Debug,PartialEq)]
pub struct Point { pub id:u32, pub x:f32, pub y:f32 }
#[derive(Clone,Copy,Debug,PartialEq)]
#[repr(u8)] pub enum Kind { Start=1, Move=2, End=3, Cancel=4 }
fn varint(mut n:u64, out:&mut Vec<u8>){while n>=128{out.push((n as u8)|128);n>>=7;}out.push(n as u8);}
fn message(tag:u32, value:&[u8],out:&mut Vec<u8>){varint(((tag<<3)|2) as u64,out);varint(value.len() as u64,out);out.extend_from_slice(value);}
fn float(tag:u8,value:f32,out:&mut Vec<u8>){if value!=0.0{out.push((tag<<3)|5);out.extend_from_slice(&value.to_le_bytes());}}
pub fn encode(seq:u64,timestamp:u64,kind:Kind,points:&[Point])->Result<Vec<u8>, &'static str>{
 if points.len()>32 || points.iter().any(|p| !p.x.is_finite()||!p.y.is_finite()||p.x<0.0||p.x>1.0||p.y<0.0||p.y>1.0) {return Err("invalid_touch_points");}
 if matches!(kind,Kind::Start|Kind::Move)&&points.is_empty(){return Err("empty_active_points");}
 if matches!(kind,Kind::End|Kind::Cancel)&&!points.is_empty(){return Err("nonempty_final_points");}
 for (i,p) in points.iter().enumerate(){if points[..i].iter().any(|q|q.id==p.id){return Err("duplicate_touch_id");}}
 let mut touch=vec![8,kind as u8];
 for p in points {let mut item=Vec::new();if p.id!=0{item.push(8);varint(p.id as u64,&mut item);}float(2,p.x,&mut item);float(3,p.y,&mut item);message(2,&item,&mut touch);}
 let mut input=Vec::new();message(1,&touch,&mut input);let mut envelope=Vec::new();if seq!=0{envelope.push(8);varint(seq,&mut envelope);}if timestamp!=0{envelope.push(16);varint(timestamp,&mut envelope);}message(20,&input,&mut envelope);Ok(envelope)
}
#[cfg(test)] mod tests {
 use super::*;
 #[test] fn encodes_official_field_nesting(){assert_eq!(encode(0,0,Kind::Start,&[Point{id:0,x:0.5,y:1.0}]).unwrap(),vec![0xa2,1,16,10,14,8,1,18,10,21,0,0,0,63,29,0,0,128,63]);}
 #[test] fn transition_requires_binding_and_permits_cancel(){assert!(validate_transition(false,None,None,Kind::Start).is_err());assert!(validate_transition(false,None,Some(9),Kind::Start).is_ok());assert!(validate_transition(true,Some(9),Some(10),Kind::Move).is_err());assert!(validate_transition(true,Some(9),Some(10),Kind::Cancel).is_ok());assert!(validate_transition(false,None,Some(9),Kind::End).is_err());}
 #[test] fn metrics_presence_and_value(){assert_eq!(support_touch(&[]),None);assert_eq!(support_touch(&[0x6a,2,0x1a,0]),Some(false));assert_eq!(support_touch(&[0x6a,4,0x1a,2,8,1]),Some(true));assert_eq!(support_touch(&[0x6a,3,0x1a,1,8]),None);}
 #[test] fn validates_lifecycle_shapes(){assert!(encode(0,0,Kind::Move,&[]).is_err());assert_eq!(encode(0,0,Kind::Cancel,&[]).unwrap(),vec![0xa2,1,4,10,2,8,4]);assert!(encode(0,0,Kind::End,&[Point{id:1,x:0.0,y:0.0}]).is_err());}
}

// Shared by the production peer and offline tests; cancellation is allowed even
// when the watch or capability gate has closed.
pub fn validate_transition(active:bool,bound:Option<u64>,current:Option<u64>,kind:Kind)->Result<(), &'static str>{
 if matches!(kind,Kind::Start)==active{return Err("invalid_touch_sequence");}
 if matches!(kind,Kind::Start)&&current.is_none(){return Err("touch_screen_unknown");}
 if active&&matches!(kind,Kind::Move)&&current!=bound{return Err("touch_screen_changed");}
 Ok(())
}
// None means no complete general metric was present, not lack of support.
pub fn support_touch(packet:&[u8])->Option<bool>{
 use crate::protocol::{decode_wire,WireValue};
 let outer=decode_wire(packet).ok()?;
 let metrics=outer.iter().find_map(|f|match(f.number,&f.value){(13,WireValue::Bytes(b))=>Some(*b),_=>None})?;
 let fields=decode_wire(metrics).ok()?;
 let general=fields.iter().find_map(|f|match(f.number,&f.value){(3,WireValue::Bytes(b))=>Some(*b),_=>None})?;
 let fields=decode_wire(general).ok()?;
 let mut support=false;
 for f in fields {if f.number==1 {match f.value{WireValue::Varint(0)=>support=false,WireValue::Varint(1)=>support=true,_=>return None}}}
 Some(support)
}
pub fn metrics_request(seq:u64)->Vec<u8>{
 let mut metrics=Vec::new(); for value in [1u8]{metrics.push(8);metrics.push(value);}
 crate::wire::envelope(seq,13,&metrics)
}
