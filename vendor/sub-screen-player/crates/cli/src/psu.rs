//! darkFlash VD1200P read-only USB telemetry bridge.

use std::io::Write;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use hidapi::{HidApi, HidDevice};
use serde::Serialize;

const VENDOR_ID: u16 = 0x2100;
const PRODUCT_ID: u16 = 0x0022;

#[derive(Serialize)]
struct Telemetry<'a> {
    connected: bool,
    model: &'a str,
    firmware: &'a str,
    rail_3v3_volts: f64,
    rail_3v3_amps: f64,
    rail_5v_volts: f64,
    rail_5v_amps: f64,
    rail_12v_a_volts: f64,
    rail_12v_a_amps: f64,
    rail_12v_b_volts: f64,
    rail_12v_b_amps: f64,
    temperature_celsius: f64,
    fan_rpm: f64,
    input_volts: f64,
    input_power_watts: f64,
}

pub fn run(watch: bool) -> Result<()> {
    loop {
        match open() {
            Ok((device, firmware)) => {
                if let Err(error) = read_session(&device, &firmware, watch) {
                    if !watch {
                        return Err(error);
                    }
                    emit_disconnected(&error.to_string())?;
                }
            }
            Err(error) => {
                if !watch {
                    return Err(error);
                }
                emit_disconnected(&error.to_string())?;
            }
        }

        if !watch {
            return Ok(());
        }
        std::thread::sleep(Duration::from_secs(2));
    }
}

fn open() -> Result<(HidDevice, String)> {
    let api = HidApi::new().context("cannot start USB HID access")?;
    let info = api
        .device_list()
        .find(|info| {
            info.vendor_id() == VENDOR_ID
                && info.product_id() == PRODUCT_ID
                && info.usage_page() == 0xffa0
        })
        .context("darkFlash VD1200P USB telemetry is not connected")?;
    let path = info.path().to_owned();
    let primer = api
        .open_path(&path)
        .context("macOS did not allow access to VD1200P telemetry")?;

    let mut report = [0_u8; 65];
    let mut count = 0;
    // The Windows controller performs a short series of read-only identity
    // requests before listening. The device queues its first status frames as
    // part of this handshake, so reproduce it without sending an output report.
    for report_id in 0_u8..=15 {
        report.fill(0);
        report[0] = report_id;
        count = primer
            .get_input_report(&mut report)
            .context("cannot read VD1200P firmware identity")?;
    }
    let bytes = if count > 1 && report[0] == 0 {
        &report[1..count]
    } else {
        &report[..count]
    };
    let end = bytes.iter().position(|byte| *byte == 0).unwrap_or(bytes.len());
    let firmware = String::from_utf8_lossy(&bytes[..end]).to_string();
    drop(primer);

    let device = api
        .open_path(&path)
        .context("cannot open the VD1200P telemetry stream")?;
    device.set_blocking_mode(false)?;
    Ok((device, firmware))
}

fn read_session(device: &HidDevice, firmware: &str, watch: bool) -> Result<()> {
    loop {
        // GET_REPORT is read-only. Besides returning the firmware identity, it asks
        // this controller to publish its next live status report.
        let mut identity = [0_u8; 65];
        identity[0] = 0;
        let _ = device.get_input_report(&mut identity);

        let deadline = Instant::now() + Duration::from_secs(5);
        let report = loop {
            let mut report = [0_u8; 65];
            match device.read_timeout(&mut report, 500) {
                Ok(count) if count >= 53 && &report[..3] == b"ACK" => break report,
                Ok(_) => {}
                Err(error) => return Err(error.into()),
            }
            if Instant::now() >= deadline {
                anyhow::bail!("VD1200P did not return telemetry within five seconds");
            }
        };

        emit(&decode(&report, firmware))?;
        if !watch {
            return Ok(());
        }
    }
}

fn decode<'a>(report: &[u8], firmware: &'a str) -> Telemetry<'a> {
    let values = report[5..53]
        .chunks_exact(4)
        .map(|chunk| decimal([chunk[1], chunk[2], chunk[3]]))
        .collect::<Vec<_>>();
    Telemetry {
        connected: true,
        model: "darkFlash VD1200P",
        firmware,
        rail_3v3_volts: values[0],
        rail_3v3_amps: values[1],
        rail_5v_volts: values[2],
        rail_5v_amps: values[3],
        rail_12v_a_volts: values[4],
        rail_12v_a_amps: values[5],
        rail_12v_b_volts: values[6],
        rail_12v_b_amps: values[7],
        temperature_celsius: values[8],
        fan_rpm: values[9],
        input_volts: values[10],
        // The controller sends input power as a whole-number watt field.
        input_power_watts: raw_integer(&report[49..53]),
    }
}

/// The controller stores two decimal digits in each byte instead of a normal
/// binary integer: `[4, 65, 41]` means `465.41`.
fn decimal(bytes: [u8; 3]) -> f64 {
    f64::from(bytes[0]) * 100.0 + f64::from(bytes[1]) + f64::from(bytes[2]) / 100.0
}

fn raw_integer(chunk: &[u8]) -> f64 {
    let bytes = [chunk[1], chunk[2], chunk[3]];
    f64::from(bytes[0]) * 10_000.0 + f64::from(bytes[1]) * 100.0 + f64::from(bytes[2])
}

fn emit(value: &impl Serialize) -> Result<()> {
    let mut stdout = std::io::stdout().lock();
    serde_json::to_writer(&mut stdout, value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
}

fn emit_disconnected(message: &str) -> Result<()> {
    emit(&serde_json::json!({
        "connected": false,
        "model": "darkFlash VD1200P",
        "error": message,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_controller_decimal_bytes() {
        assert_eq!(decimal([0, 3, 32]), 3.32);
        assert_eq!(decimal([0, 228, 44]), 228.44);
        assert_eq!(decimal([4, 65, 41]), 465.41);
    }

    #[test]
    fn decodes_whole_watts() {
        assert_eq!(raw_integer(&[0xee, 0, 0, 43]), 43.0);
    }

    #[test]
    fn decodes_captured_vd1200p_packet() {
        let report = [
            0x41, 0x43, 0x4b, 0x00, 0x00, 0xee, 0x00, 0x03, 0x20, 0xee, 0x00, 0x00,
            0x01, 0xee, 0x00, 0x05, 0x0d, 0xee, 0x00, 0x00, 0x02, 0xee, 0x00, 0x0c,
            0x03, 0xee, 0x00, 0x00, 0x03, 0xee, 0x00, 0x0c, 0x0a, 0xee, 0x00, 0x00,
            0x03, 0xee, 0x00, 0x1e, 0x30, 0xee, 0x04, 0x41, 0x29, 0xee, 0x00, 0xe4,
            0x2c, 0xee, 0x00, 0x00, 0x2b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ];
        let telemetry = decode(&report, "PSC_01.001");
        assert_eq!(telemetry.rail_3v3_volts, 3.32);
        assert_eq!(telemetry.rail_5v_volts, 5.13);
        assert_eq!(telemetry.rail_12v_a_volts, 12.03);
        assert_eq!(telemetry.rail_12v_b_volts, 12.10);
        assert_eq!(telemetry.temperature_celsius, 30.48);
        assert_eq!(telemetry.fan_rpm, 465.41);
        assert_eq!(telemetry.input_volts, 228.44);
        assert_eq!(telemetry.input_power_watts, 43.0);
    }
}
