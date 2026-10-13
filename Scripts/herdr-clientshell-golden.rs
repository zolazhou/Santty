// Fixture generator only; not a Santty runtime dependency.
// Wire declarations follow herdrdev/herdr 2563803 (Apache-2.0).
// Uses serde 1.0.228, bincode 2.0.1 (serde, standard), serde_json 1.0.150.
use serde::Serialize;
use serde_json::{json,Map,Value};
// Exact variant order from pinned src/protocol/wire.rs::ClientKeyCode.
#[derive(Serialize)] enum ClientKeyCode {
 Backspace, Enter, Left, Right, Up, Down, Home, End, PageUp, PageDown, Tab, BackTab,
 Delete, Insert, Esc, Char(char), F(u8), Null,
}
#[derive(Serialize)] struct Cell {symbol:String,fg:u32,bg:u32,modifier:u16,skip:bool,hyperlink:Option<u32>}
#[derive(Serialize)] struct Frame {cells:Vec<Cell>,width:u16,height:u16,cursor:Option<(u16,u16,bool,u8)>,hyperlinks:Vec<String>,graphics:Vec<u8>}
#[derive(Serialize,Clone)] enum Target {Pane{pane_id:String},Popup{terminal_id:String}}
#[derive(Serialize,Clone)] enum Source {Terminal{target:Target,image_id:u32},PaneLayer{pane_id:String,layer_id:String}}
#[derive(Serialize,Clone)] enum Format {Rgb,Rgba,Png}
#[derive(Serialize,Clone)] struct Key {source:Source,image_width:u32,image_height:u32,format:Format,data_len:u64,data_fingerprint:u64}
#[derive(Serialize)] struct Asset {key:Key,data:Vec<u8>}
#[derive(Serialize)] struct Placement {asset:Key,logical_placement_id:u32,x:u16,y:u16,cols:u32,rows:u32,source_x:u32,source_y:u32,source_width:u32,source_height:u32,x_offset:u32,y_offset:u32,z:i32,scrollback_offset:u32}
#[derive(Serialize)] struct Scene {assets:Vec<Asset>,placements:Vec<Placement>,retained_assets:Vec<Key>}
type Rect=(u16,u16,u16,u16);
type Pane=(String,u64,Rect,Rect,Option<Rect>,Option<(u64,u64,u64)>,bool,bool,bool,bool,u32,u32);
#[derive(Serialize)] struct Surface {boot_id:String,projection_revision:u64,surface_revision:u64,frame:Frame,panes:Vec<Pane>,splits:Vec<(u32,u16,Rect,Rect,Vec<bool>)>,popup:Option<(String,String,Option<(u32,u16)>,Option<(u32,u16)>,Frame,bool,bool,u32,u32)>,graphics:Scene}
fn record<T:Serialize>(out:&mut Map<String,Value>,name:&str,v:T){let b=bincode::serde::encode_to_vec(&v,bincode::config::standard()).unwrap();out.insert(name.into(),json!(b.iter().map(|n|format!("{n:02x}")).collect::<String>()));}
fn main(){
 let mut out=Map::new();record(&mut out,"control_empty",(20u32,"",""));record(&mut out,"resize",(12u32,8u32,16u32,289u16,77u16,true));record(&mut out,"request",(15u32,"boot","{}"));record(&mut out,"focus",(18u32,true));record(&mut out,"appearance",(17u32,2u32,0u32));record(&mut out,"detach",4u32);
 record(&mut out,"host_foreground",(17u32,0u32,0u32,(255u8,251u8,254u8)));
 record(&mut out,"host_background",(17u32,0u32,1u32,(1u8,2u8,3u8)));
 record(&mut out,"host_palette",(17u32,1u32,vec![(0u8,(255u8,251u8,254u8)),(255u8,(0u8,1u8,2u8))]));
 record(&mut out,"text",(13u32,"w5:pA",vec![(1u32,"你好")]));record(&mut out,"paste",(13u32,"w5:pA",vec![(3u32,"x\ny")]));
 record(&mut out,"key_char",(13u32,"w5:pA",vec![(0u32,ClientKeyCode::Char('é'),4u8,0u32,1u16,Some('É' as u32),Some("é"),true,Some(12u32),None::<u8>)]));
 record(&mut out,"key_enter",(13u32,"w5:pA",vec![(0u32,ClientKeyCode::Enter,0u8,2u32,1u16,None::<u32>,None::<String>,true,Some(36u32),None::<u8>)]));
 let keys = [ClientKeyCode::Backspace,ClientKeyCode::Enter,ClientKeyCode::Left,ClientKeyCode::Right,
 ClientKeyCode::Up,ClientKeyCode::Down,ClientKeyCode::Home,ClientKeyCode::End,ClientKeyCode::PageUp,
 ClientKeyCode::PageDown,ClientKeyCode::Tab,ClientKeyCode::BackTab,ClientKeyCode::Delete,ClientKeyCode::Insert,
 ClientKeyCode::Esc,ClientKeyCode::Char('界'),ClientKeyCode::F(12),ClientKeyCode::Null];
 record(&mut out,"all_keys",(13u32,"w5:pA",keys.into_iter().map(|code|
 (0u32,code,0u8,0u32,1u16,None::<u32>,None::<String>,false,None::<u32>,None::<u8>)).collect::<Vec<_>>()));
 record(&mut out,"mouse",(13u32,"w5:pA",vec![(2u32,(0u32,0u32),(1u32,16u32,32u32,2u16,2u16),Some((80u16,24u16,640u32,384u32)),4u8,1u16)]));
 record(&mut out,"response",(18u32,"boot","r1",true,b"{\"id\":\"r1\"}".to_vec()));record(&mut out,"shutdown",(3u32,Some("bye")));record(&mut out,"clipboard",(5u32,"aGk="));record(&mut out,"notification",(14u32,0u32,"done",Some("body"),Some(1u32),Some("agent"),Some("w5"),Some("w5:t4"),Some("w5:pA"),Some(3u32)));
 let key=Key{source:Source::Terminal{target:Target::Pane{pane_id:"w5:pA".into()},image_id:7},image_width:1,image_height:1,format:Format::Rgba,data_len:4,data_fingerprint:1234};
 let frame=Frame{cells:vec![Cell{symbol:"界".into(),fg:0x02112233,bg:0,modifier:1,skip:false,hyperlink:Some(0)},Cell{symbol:"".into(),fg:0,bg:0,modifier:0,skip:true,hyperlink:None}],width:2,height:1,cursor:Some((0,0,true,2)),hyperlinks:vec!["https://example.com".into()],graphics:vec![]};
 let pane:Pane=("w5:pA".into(),9,(0,0,2,1),(0,0,2,1),None,Some((0,10,1)),true,true,false,false,16,16);
 let scene=Scene{assets:vec![Asset{key:key.clone(),data:vec![255,0,0,255]}],placements:vec![Placement{asset:key.clone(),logical_placement_id:3,x:0,y:0,cols:1,rows:1,source_x:0,source_y:0,source_width:1,source_height:1,x_offset:0,y_offset:0,z:-1,scrollback_offset:0}],retained_assets:vec![key]};
 record(&mut out,"surface_image",(13u32,Surface{boot_id:"boot".into(),projection_revision:251,surface_revision:65536,frame,panes:vec![pane],splits:vec![],popup:None,graphics:scene}));
 record(&mut out,"patch",(19u32,"boot",251u64,65536u64,65537u64,vec![(0u16,0u16,vec![Cell{symbol:"x".into(),fg:0,bg:0,modifier:0,skip:false,hyperlink:None}])],Vec::<Pane>::new(),Some((0u16,0u16,true,2u8))));
 println!("{}",serde_json::to_string_pretty(&json!({"source_revision":"2563803dca97c040beaf3dc3acdcb5a3221b4238","serializer":"bincode 2.0.1 serde standard","payloads":out})).unwrap());
}
