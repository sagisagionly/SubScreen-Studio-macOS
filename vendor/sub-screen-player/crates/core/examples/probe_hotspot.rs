//! Read-only diagnostic for unknown HotSpot HID displays.

use ssp_core::{Transport, hid};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    for candidate in hid::enumerate()?
        .into_iter()
        .filter(|item| item.vendor_id == 0x1800)
    {
        println!(
            "{:04x}:{:04x} serial={} usage={:04x} product={}",
            candidate.vendor_id,
            candidate.product_id,
            candidate.serial,
            candidate.usage_page,
            candidate.product
        );
        if candidate.product_id != 0x3006 || candidate.usage_page != 0xFFA0 {
            continue;
        }
        let mut transport = hid::open(&candidate)?;
        let mut report = [0_u8; 512];
        match transport.get_input_report(0, &mut report) {
            Ok(count) => {
                let end = report[..count]
                    .iter()
                    .position(|byte| *byte == 0)
                    .unwrap_or(count);
                println!("firmware={}", String::from_utf8_lossy(&report[..end]));
            }
            Err(error) => println!("firmware-read-error={error}"),
        }
    }
    Ok(())
}
