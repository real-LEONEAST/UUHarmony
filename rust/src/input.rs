// SPDX-License-Identifier: GPL-3.0-only
//! CONTROL input for the Windows target. Upstream @ 6bf05a6361e58dbeec5846f044d234bed04fcf02:
//! src/viewer/input.rs:4-17,70-102 (VK, buttons, scroll, releases, heartbeat),
//! src/viewer/sdl.rs:369 (left=1/right=2/middle=4),
//! src/control_protocol.rs:18,30-70 (relative deltas and text_input.content).
//! UTF-8 JSON is carried by a binary SCTP message on CONTROL_DATA_CHANNEL.
//! Bounds below are local viewer policy, not inferred Windows protocol limits.
use serde_json::{json, Value};
use std::collections::BTreeSet;

pub const MAX_RELATIVE_DELTA: i64 = 65_535;
pub const MAX_SCROLL_DELTA: i64 = 12_000;
pub const MAX_TEXT_BYTES: usize = 16 * 1024;
pub const MAX_HELD_KEYS: usize = 32;

// One attached controller over the existing authorized Windows CONTROL channel.
// Field names and ranges follow the pinned viewer's native_gamepad.rs.
#[derive(Default, serde::Deserialize, serde::Serialize, Clone)]
pub struct PadState {
    buttons: u16,
    left_trigger: u8,
    right_trigger: u8,
    left_thumb_x: i16,
    left_thumb_y: i16,
    right_thumb_x: i16,
    right_thumb_y: i16,
}

pub enum InputEvent {
    Absolute { x: f64, y: f64 },
    Relative { x: i64, y: i64 },
    Scroll { x: i64, y: i64 },
    Button { button: u8, down: bool },
    Key { key: u8, down: bool },
    Text(String),
    PadConnect,
    PadUpdate(PadState),
    PadDisconnect,
    Heartbeat,
}

fn coordinate(v: &Value, name: &str, error: &'static str) -> Result<f64, &'static str> {
    v[name].as_f64().filter(|n| n.is_finite() && (0.0..=1.0).contains(n)).ok_or(error)
}
fn delta(v: &Value, name: &str, limit: i64) -> Result<i64, &'static str> {
    v[name].as_i64().filter(|n| (-limit..=limit).contains(n)).ok_or("invalid_input_delta")
}
impl InputEvent {
    /// Project only known fields. Never forward arbitrary JSON or log text content.
    pub fn parse(v: &Value) -> Result<Self, &'static str> {
        if !v.is_object() { return Err("invalid_input_event"); }
        if v.get("heartbeat").is_some() {
            return if v.get("action").is_none() && v["heartbeat"] == "kbd_heartbeat" {
                Ok(Self::Heartbeat)
            } else { Err("invalid_input_heartbeat") };
        }
        match v["action"].as_str() {
            Some(action @ ("gpd_connect" | "gpd_update" | "gpd_disconnect")) => {
                if v["index"].as_u64() != Some(0) { return Err("invalid_controller_index"); }
                match action {
                    "gpd_connect" => Ok(Self::PadConnect),
                    "gpd_disconnect" => Ok(Self::PadDisconnect),
                    _ => serde_json::from_value(v.clone()).map(Self::PadUpdate)
                        .map_err(|_| "invalid_controller_state"),
                }
            }
            Some("mouse_move_absolute") => Ok(Self::Absolute {
                x: coordinate(v, "abs_x", "invalid_mouse_x")?,
                y: coordinate(v, "abs_y", "invalid_mouse_y")?,
            }),
            Some("mouse_move_relative") => Ok(Self::Relative {
                x: delta(v, "delta_x", MAX_RELATIVE_DELTA)?,
                y: delta(v, "delta_y", MAX_RELATIVE_DELTA)?,
            }),
            Some("mouse_scroll") => Ok(Self::Scroll {
                x: delta(v, "delta_x", MAX_SCROLL_DELTA)?,
                y: delta(v, "delta_y", MAX_SCROLL_DELTA)?,
            }),
            Some(action @ ("mouse_press" | "mouse_release")) => {
                let button = v["button"].as_u64().filter(|n| matches!(*n, 1 | 2 | 4))
                    .ok_or("invalid_mouse_button")? as u8;
                Ok(Self::Button { button, down: action == "mouse_press" })
            }
            Some(action @ ("kbd_press" | "kbd_release")) => {
                // Windows VK, not SDL/HID scancode, Unicode scalar or Harmony keyCode.
                let key = v["key"].as_u64().filter(|n| (1..=254).contains(n))
                    .ok_or("invalid_windows_vk")? as u8;
                Ok(Self::Key { key, down: action == "kbd_press" })
            }
            Some("text_input") => {
                let text = v["content"].as_str().filter(|s| !s.is_empty()
                    && s.len() <= MAX_TEXT_BYTES && !s.contains('\0'))
                    .ok_or("invalid_text_content")?;
                Ok(Self::Text(text.into()))
            }
            _ => Err("unsupported_input"),
        }
    }
    pub fn wire(&self) -> Value {
        match self {
            Self::PadConnect => json!({"action":"gpd_connect","index":0}),
            Self::PadDisconnect => json!({"action":"gpd_disconnect","index":0}),
            Self::PadUpdate(state) => {
                let mut out = json!(state);
                out["action"] = json!("gpd_update");
                out["index"] = json!(0);
                out
            }
            Self::Absolute { x, y } => json!({"action":"mouse_move_absolute","abs_x":x,"abs_y":y}),
            Self::Relative { x, y } => json!({"action":"mouse_move_relative","delta_x":x,"delta_y":y}),
            // Already wire units: one wheel notch is 120; positive y is wheel-up.
            Self::Scroll { x, y } => json!({"action":"mouse_scroll","delta_x":x,"delta_y":y}),
            Self::Button { button, down } => json!({"action":if *down {"mouse_press"} else {"mouse_release"},"button":button}),
            Self::Key { key, down } => json!({"action":if *down {"kbd_press"} else {"kbd_release"},"key":key}),
            Self::Text(text) => json!({"action":"text_input","content":text}),
            Self::Heartbeat => json!({"heartbeat":"kbd_heartbeat"}),
        }
    }
    pub fn is_input(&self) -> bool { !matches!(self, Self::Heartbeat) }
    /// Screen ID comes from the peer's confirmed inventory, never caller JSON or a list index.
    pub fn wire_for_screen(&self,screen:Option<u64>)->Value {
        let mut value=self.wire();
        if matches!(self,Self::Absolute{..}) {if let Some(id)=screen.filter(|id|*id<=i32::MAX as u64){value["screen_id"]=json!(id);}}
        value
    }
}

#[derive(Default)]
pub struct InputState { keys: BTreeSet<u8>, buttons: BTreeSet<u8>, pad_attached: bool }
impl InputState {
    /// Register a press BEFORE awaiting transport: a cancelled/failed send may have
    /// enqueued bytes. Keep it until a release succeeds. Repeated downs are suppressed,
    /// as in upstream Input::key/button; unmatched ups are allowed for recovery.
    pub fn before_send(&mut self, event: &InputEvent) -> Result<bool, &'static str> {
        match event {
            InputEvent::PadConnect => {
                if self.pad_attached { return Ok(false); }
                self.pad_attached = true;
            }
            InputEvent::PadUpdate(_) if !self.pad_attached => return Err("controller_not_attached"),
            InputEvent::Key { key, down: true } => {
                if self.keys.contains(key) { return Ok(false); }
                if self.keys.len() >= MAX_HELD_KEYS { return Err("held_key_limit"); }
                self.keys.insert(*key);
            }
            InputEvent::Button { button, down: true } => {
                if !self.buttons.insert(*button) { return Ok(false); }
            }
            _ => (),
        }
        Ok(true)
    }
    /// Call only after RTCDataChannel::send succeeds. This proves submission, not
    /// delivery/Windows execution; a release timeout must leave its key tracked.
    pub fn sent(&mut self, event: &InputEvent) {
        match event {
            InputEvent::PadDisconnect => self.pad_attached = false,
            InputEvent::Key { key, down: false } => { self.keys.remove(key); }
            InputEvent::Button { button, down: false } => { self.buttons.remove(button); }
            _ => (),
        }
    }
    pub fn releases(&self) -> Vec<InputEvent> {
        self.keys.iter().map(|key| InputEvent::Key { key: *key, down: false })
            .chain(self.buttons.iter().map(|button| InputEvent::Button { button: *button, down: false }))
            .chain(self.pad_attached.then(|| InputEvent::PadUpdate(PadState::default())))
            .chain(self.pad_attached.then_some(InputEvent::PadDisconnect))
            .collect()
    }
    pub fn key_count(&self) -> usize { self.keys.len() }
    pub fn button_count(&self) -> usize { self.buttons.len() }
    pub fn held_count(&self) -> usize { self.keys.len() + self.buttons.len() + usize::from(self.pad_attached) }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn gamepad_validation_order_and_release() {
        let mut state = InputState::default();
        let mut packet = InputEvent::PadUpdate(PadState::default()).wire();
        let neutral = packet.clone();
        assert!(state.before_send(&InputEvent::parse(&packet).unwrap()).is_err());
        sent(&mut state, InputEvent::PadConnect.wire());
        packet["buttons"] = json!(4096);
        packet["left_thumb_x"] = json!(-32768);
        sent(&mut state, packet.clone());
        assert_eq!(InputEvent::parse(&packet).unwrap().wire(), packet);
        packet["right_trigger"] = json!(256);
        assert!(InputEvent::parse(&packet).is_err());
        assert!(InputEvent::parse(&json!({"action":"gpd_connect","index":1})).is_err());
        let releases: Vec<_> = state.releases().iter().map(InputEvent::wire).collect();
        assert_eq!(releases, vec![neutral, InputEvent::PadDisconnect.wire()]);
        sent(&mut state, InputEvent::PadDisconnect.wire());
        assert!(state.releases().is_empty());
    }
    #[test]fn display_absolute_targets_confirmed_screen_only(){let e=InputEvent::parse(&json!({"action":"mouse_move_absolute","abs_x":0.25,"abs_y":0.75,"screen_id":999})).unwrap();assert_eq!(e.wire_for_screen(Some(7))["screen_id"],7);assert_eq!(e.wire_for_screen(Some(0))["screen_id"],0);assert!(e.wire_for_screen(None).get("screen_id").is_none());let key=InputEvent::Key{key:65,down:true};assert_eq!(key.wire_for_screen(Some(7)),key.wire());let relative=InputEvent::Relative{x:10,y:-8};assert_eq!(relative.wire_for_screen(Some(7)),relative.wire());}
    fn sent(state: &mut InputState, value: Value) {
        let event = InputEvent::parse(&value).unwrap();
        assert!(state.before_send(&event).unwrap());
        state.sent(&event);
    }
    #[test]
    fn exact_control_fields_and_numeric_conventions() {
        for value in [
            json!({"action":"mouse_move_absolute","abs_x":0.0,"abs_y":1.0}),
            json!({"action":"mouse_move_relative","delta_x":-4,"delta_y":5}),
            json!({"action":"mouse_scroll","delta_x":0,"delta_y":120}),
            json!({"action":"mouse_scroll","delta_x":30,"delta_y":-12}),
            json!({"action":"mouse_press","button":2}),
            json!({"action":"mouse_release","button":4}),
            json!({"action":"kbd_press","key":65}),
            json!({"action":"kbd_release","key":162}),
            json!({"action":"text_input","content":"Hello 你好\n\"\\🙂"}),
            json!({"heartbeat":"kbd_heartbeat"}),
        ] {
            assert_eq!(InputEvent::parse(&value).unwrap().wire(), value);
        }
        let event = InputEvent::parse(&json!({"action":"kbd_press","key":13,"arbitrary":"discard"})).unwrap();
        assert_eq!(event.wire(), json!({"action":"kbd_press","key":13}));
        assert!(!InputEvent::parse(&json!({"heartbeat":"kbd_heartbeat"})).unwrap().is_input());
        assert!(event.is_input());
    }
    #[test]
    fn rejects_invalid_or_ambiguous_payloads_without_coercing() {
        for value in [
            Value::Null, json!([]), json!({}),
            json!({"action":"kbd_press"}), json!({"action":"kbd_press","key":"65"}),
            json!({"action":"kbd_press","key":65.0}), json!({"action":"kbd_press","key":0}),
            json!({"action":"kbd_release","key":255}), json!({"action":"kbd_press","key":-1}),
            json!({"action":"mouse_press","button":3}), json!({"action":"mouse_press","button":1.0}),
            json!({"action":"mouse_scroll","delta_x":0}),
            json!({"action":"mouse_move_relative","delta_x":0.5,"delta_y":0}),
            json!({"action":"mouse_move_relative","delta_x":i64::MAX,"delta_y":0}),
            json!({"action":"mouse_move_absolute","abs_x":-0.01,"abs_y":0.5}),
            json!({"action":"mouse_move_absolute","abs_x":0.5,"abs_y":1.01}),
            json!({"action":"mouse_move_absolute","abs_x":null,"abs_y":0.5}),
            json!({"action":"text_input","text":"wrong field"}),
            json!({"action":"text_input","content":""}), json!({"action":"text_input","content":"a\0b"}),
            json!({"heartbeat":"wrong"}),
            json!({"heartbeat":"kbd_heartbeat","action":"kbd_press","key":65}),
            json!({"heartbeat":"kbd_heartbeat","action":"unknown"}),
            json!({"action":"mouse_click","button":1}), json!({"action":"release_all"}),
        ] { assert!(InputEvent::parse(&value).is_err(), "accepted {value}"); }
    }
    #[test]
    fn applies_finite_delta_vk_and_utf8_byte_limits() {
        for (action, limit) in [("mouse_move_relative", MAX_RELATIVE_DELTA), ("mouse_scroll", MAX_SCROLL_DELTA)] {
            for value in [-limit, limit] {
                assert!(InputEvent::parse(&json!({"action":action,"delta_x":value,"delta_y":-value})).is_ok());
            }
            for value in [-limit-1, limit+1] {
                assert!(InputEvent::parse(&json!({"action":action,"delta_x":value,"delta_y":0})).is_err());
            }
        }
        for key in [1, 13, 65, 160, 162, 164, 254] {
            assert!(InputEvent::parse(&json!({"action":"kbd_press","key":key})).is_ok());
        }
        assert!(InputEvent::parse(&json!({"action":"text_input","content":"x".repeat(MAX_TEXT_BYTES)})).is_ok());
        assert!(InputEvent::parse(&json!({"action":"text_input","content":"x".repeat(MAX_TEXT_BYTES+1)})).is_err());
        assert!(InputEvent::parse(&json!({"action":"text_input","content":"你".repeat(MAX_TEXT_BYTES/3)})).is_ok());
        assert!(InputEvent::parse(&json!({"action":"text_input","content":"你".repeat(MAX_TEXT_BYTES/3+1)})).is_err());
    }
    #[test]
    fn release_snapshot_covers_every_key_and_button_once() {
        let mut state = InputState::default();
        for key in [65, 162, 160] { sent(&mut state, json!({"action":"kbd_press","key":key})); }
        for button in [4, 2, 1] { sent(&mut state, json!({"action":"mouse_press","button":button})); }
        let duplicate = InputEvent::parse(&json!({"action":"kbd_press","key":65})).unwrap();
        assert!(!state.before_send(&duplicate).unwrap());
        let duplicate = InputEvent::parse(&json!({"action":"mouse_press","button":2})).unwrap();
        assert!(!state.before_send(&duplicate).unwrap());
        sent(&mut state, json!({"action":"kbd_release","key":160}));
        sent(&mut state, json!({"action":"mouse_release","button":1}));
        let releases = state.releases();
        assert_eq!(releases.iter().map(InputEvent::wire).collect::<Vec<_>>(), vec![
            json!({"action":"kbd_release","key":65}), json!({"action":"kbd_release","key":162}),
            json!({"action":"mouse_release","button":2}), json!({"action":"mouse_release","button":4}),
        ]);
        // Snapshot must not erase tracked state ahead of successful submission.
        assert_eq!((state.key_count(), state.button_count()), (2, 2));
        for release in releases { state.sent(&release); }
        assert_eq!(state.held_count(), 0);
        assert!(state.releases().is_empty());
        sent(&mut state, json!({"action":"kbd_release","key":65}));
        sent(&mut state, json!({"action":"mouse_release","button":2}));
        assert!(state.releases().is_empty());
    }
    #[test]
    fn failed_or_cancelled_send_cannot_forget_a_possible_press() {
        let mut state = InputState::default();
        let press = InputEvent::parse(&json!({"action":"kbd_press","key":65})).unwrap();
        assert!(state.before_send(&press).unwrap()); // transport fails/cancels here
        let release = state.releases().pop().unwrap();
        assert!(state.before_send(&release).unwrap()); // release send also fails
        assert_eq!(state.held_count(), 1);
        assert_eq!(state.releases()[0].wire(), json!({"action":"kbd_release","key":65}));
        state.sent(&release);
        assert_eq!(state.held_count(), 0);
    }
    #[test]
    fn partial_release_keeps_failed_item_and_clears_other_keys_and_buttons() {
        let mut state = InputState::default();
        sent(&mut state, json!({"action":"kbd_press","key":65}));
        sent(&mut state, json!({"action":"kbd_press","key":162}));
        sent(&mut state, json!({"action":"mouse_press","button":2}));
        for (index, release) in state.releases().into_iter().enumerate() {
            assert!(state.before_send(&release).unwrap());
            if index != 0 { state.sent(&release); } // First send fails; others proceed.
        }
        assert_eq!((state.key_count(), state.button_count()), (1, 0));
        assert_eq!(state.releases()[0].wire(), json!({"action":"kbd_release","key":65}));
    }
    #[test]
    fn bounds_simultaneous_keys_and_never_blocks_existing_key_release() {
        let mut state = InputState::default();
        for key in 1..=MAX_HELD_KEYS {
            sent(&mut state, json!({"action":"kbd_press","key":key}));
        }
        let extra = InputEvent::parse(&json!({"action":"kbd_press","key":200})).unwrap();
        assert_eq!(state.before_send(&extra), Err("held_key_limit"));
        assert_eq!(state.key_count(), MAX_HELD_KEYS);
        for button in [1, 2, 4] { sent(&mut state, json!({"action":"mouse_press","button":button})); }
        assert_eq!(state.releases().len(), MAX_HELD_KEYS + 3);
        sent(&mut state, json!({"action":"kbd_release","key":1}));
        assert!(state.before_send(&extra).unwrap());
    }
}
