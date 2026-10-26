//! Passive, read-only capture for the RC12 USB HID device.
//!
//! This deliberately sends no output or feature reports. It only listens for
//! interrupt input reports that the device publishes on its own.

use std::time::{Duration, Instant};

use hidapi::HidApi;

const VENDOR_ID: u16 = 0x2100;
const PRODUCT_ID: u16 = 0x0022;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let api = HidApi::new()?;
    let candidates: Vec<_> = api
        .device_list()
        .filter(|info| info.vendor_id() == VENDOR_ID && info.product_id() == PRODUCT_ID)
        .collect();

    if candidates.is_empty() {
        println!("RC12_IAP (2100:0022) is not connected");
        return Ok(());
    }

    for info in candidates {
        println!(
            "device={:04x}:{:04x} interface={} usage_page=0x{:04x} usage=0x{:04x} product={} serial={}",
            info.vendor_id(),
            info.product_id(),
            info.interface_number(),
            info.usage_page(),
            info.usage(),
            info.product_string().unwrap_or(""),
            info.serial_number().unwrap_or("")
        );

        let device = info.open_device(&api)?;
        device.set_blocking_mode(false)?;
        let started = Instant::now();
        let mut report_count = 0_u64;

        let listen_seconds = if info.usage_page() == 0xffa0 && info.usage() == 2 {
            32
        } else {
            1
        };
        while started.elapsed() < Duration::from_secs(listen_seconds) {
            let mut report = [0_u8; 65];
            match device.read_timeout(&mut report, 100) {
                Ok(0) => {}
                Ok(count) => {
                    report_count += 1;
                    let hex = report[..count]
                        .iter()
                        .map(|byte| format!("{byte:02x}"))
                        .collect::<Vec<_>>()
                        .join(" ");
                    println!(
                        "  t={:>7.3}s bytes={count:>2} data={hex}",
                        started.elapsed().as_secs_f64()
                    );
                    if count >= 53 && &report[..3] == b"ACK" {
                        let values = report[5..53]
                            .chunks_exact(4)
                            .map(|chunk| {
                                u32::from_be_bytes([0, chunk[1], chunk[2], chunk[3]])
                            })
                            .collect::<Vec<_>>();
                        println!("    fields={values:?}");
                    }
                }
                Err(error) => {
                    println!("  passive-read-error={error}");
                    break;
                }
            }
        }

        println!("  passive_reports={report_count}\n");

        println!("  read-only input report queries:");
        for report_id in 0_u8..=15 {
            let mut report = [0_u8; 65];
            report[0] = report_id;
            match device.get_input_report(&mut report) {
                Ok(count) => {
                    let hex = report[..count]
                        .iter()
                        .map(|byte| format!("{byte:02x}"))
                        .collect::<Vec<_>>()
                        .join(" ");
                    println!("    id={report_id:02x} bytes={count:>2} data={hex}");
                }
                Err(error) => println!("    id={report_id:02x} error={error}"),
            }
        }
        println!();
    }

    Ok(())
}
