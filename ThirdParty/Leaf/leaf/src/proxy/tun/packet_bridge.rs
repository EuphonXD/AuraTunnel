use std::ffi::c_void;
use std::sync::Mutex;

use lazy_static::lazy_static;
use tokio::sync::mpsc::Sender;

pub type PacketOutputCallback =
    unsafe extern "C" fn(data: *const u8, len: usize, context: *mut c_void);

#[derive(Clone, Copy)]
struct OutputRegistration {
    callback: PacketOutputCallback,
    context: usize,
}

lazy_static! {
    static ref INPUT_SENDER: Mutex<Option<Sender<Vec<u8>>>> = Mutex::new(None);
    static ref OUTPUT_REGISTRATION: Mutex<Option<OutputRegistration>> = Mutex::new(None);
}

pub fn install_input_sender(sender: Sender<Vec<u8>>) {
    if let Ok(mut slot) = INPUT_SENDER.lock() {
        slot.replace(sender);
    }
}

pub fn clear_input_sender() {
    if let Ok(mut slot) = INPUT_SENDER.lock() {
        slot.take();
    }
}

pub fn register_output(callback: PacketOutputCallback, context: *mut c_void) {
    if let Ok(mut slot) = OUTPUT_REGISTRATION.lock() {
        slot.replace(OutputRegistration {
            callback,
            context: context as usize,
        });
    }
}

pub fn clear_output() {
    if let Ok(mut slot) = OUTPUT_REGISTRATION.lock() {
        slot.take();
    }
}

/// Copies one packet into Leaf's bounded input channel. The copy is required
/// because NEPacketTunnelFlow owns the source Data lifetime after the FFI call.
pub fn input_packet(packet: &[u8]) -> bool {
    input_packets(std::iter::once(packet)) == 1
}

/// Clones the bounded channel sender once for a whole PacketFlow batch instead
/// of taking the global mutex for every packet.
pub fn input_packets<'a>(packets: impl IntoIterator<Item = &'a [u8]>) -> usize {
    let sender = INPUT_SENDER.lock().ok().and_then(|slot| slot.clone());
    let Some(sender) = sender else { return 0 };
    let mut accepted = 0;
    for packet in packets {
        if sender.try_send(packet.to_vec()).is_err() {
            break;
        }
        accepted += 1;
    }
    accepted
}

pub fn emit_packet(packet: &[u8]) {
    let registration = OUTPUT_REGISTRATION.lock().ok().and_then(|slot| *slot);
    if let Some(registration) = registration {
        // The pointer is valid only for this synchronous callback. The Swift
        // bridge copies it into a bounded write batch before returning.
        unsafe {
            (registration.callback)(
                packet.as_ptr(),
                packet.len(),
                registration.context as *mut c_void,
            );
        }
    }
}
