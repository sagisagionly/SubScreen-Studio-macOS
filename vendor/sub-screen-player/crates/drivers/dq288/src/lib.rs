//! Driver for the DQ/Qscreen 2.88-inch, 480×480 USB display.
//!
//! The `V26_DQ_2.88` firmware uses the same 1024-byte HotSpot `CRT` transport
//! as the MiraBox D92, but exposes its own USB product id and square panel.
#![warn(missing_docs)]

use std::time::{Duration, Instant};

use ssp_core::{
    Candidate, Capabilities, Display, DisplayInfo, Driver, EncodedImage, Error, ImageFormat,
    PanelSpec, Result, Rotation, Transport, UsbMatch, hid,
};
use ssp_driver_d92::protocol;

const VENDOR_ID: u16 = 0x1800;
const PRODUCT_ID: u16 = 0x3006;
const USAGE_PAGE: u16 = 0xFFA0;
const WIDTH: u32 = 480;
const HEIGHT: u32 = 480;
const VERSION_TRIES: u32 = 3;
const STORE_TIME: Duration = Duration::from_millis(1500);

/// Finds DQ/Qscreen 2.88-inch displays and opens them over HID.
#[derive(Debug, Clone, Copy, Default)]
pub struct Dq288Driver;

impl Driver for Dq288Driver {
    fn id(&self) -> &'static str {
        "dq288"
    }
    fn name(&self) -> &'static str {
        "DQ/Qscreen 2.88-inch"
    }
    fn usb_matches(&self) -> &'static [UsbMatch] {
        &[UsbMatch {
            vendor_id: VENDOR_ID,
            product_id: PRODUCT_ID,
            usage_page: Some(USAGE_PAGE),
        }]
    }
    fn open(&self, candidate: &Candidate) -> Result<Box<dyn Display>> {
        let transport = hid::open(candidate)?;
        Ok(Box::new(Dq288::open(
            Box::new(transport),
            &candidate.serial,
        )?))
    }
}

/// An open 2.88-inch display.
pub struct Dq288 {
    transport: Box<dyn Transport>,
    info: DisplayInfo,
    session_ended: bool,
    busy_until: Option<Instant>,
    last_dra: Option<Instant>,
}

impl Dq288 {
    fn open(mut transport: Box<dyn Transport>, serial: &str) -> Result<Self> {
        let mut report = [0_u8; 512];
        let mut firmware = None;
        for attempt in 0..VERSION_TRIES {
            if attempt > 0 {
                std::thread::sleep(Duration::from_millis(50));
            }
            match transport.get_input_report(0, &mut report) {
                Ok(count) => firmware = protocol::parse_version(&report[..count]),
                Err(error) if error.is_fatal() => return Err(error),
                Err(_) => break,
            }
            if firmware.is_some() {
                break;
            }
        }
        let info = DisplayInfo {
            driver: "dq288",
            model: "DQ 2.88-inch".into(),
            serial: serial.into(),
            firmware,
            panel: PanelSpec {
                width: WIDTH,
                height: HEIGHT,
                rotation: Rotation::Clockwise90,
                format: ImageFormat::Jpeg,
            },
            capabilities: Capabilities {
                live_frames: true,
                saved_frames: true,
                brightness: true,
                power: true,
                clear: true,
                max_fps: 30,
                keep_alive_interval: Some(Duration::from_secs(2)),
                max_image_bytes: protocol::MAX_JPEG_LEN,
                // This firmware accepts the region command, but applies small
                // updates non-atomically. Rapidly changing text and icons then
                // visibly flash, so always present a complete 480x480 frame.
                partial_images: false,
            },
        };
        let mut display = Self {
            transport,
            info,
            session_ended: false,
            busy_until: None,
            last_dra: None,
        };
        display.send(&protocol::wake())?;
        Ok(display)
    }

    fn send(&mut self, reports: &[u8]) -> Result<()> {
        debug_assert_eq!(reports.len() % protocol::REPORT_LEN, 0);
        reports
            .chunks(protocol::REPORT_LEN)
            .try_for_each(|report| self.transport.write_report(report))
    }

    fn check(&self, image: &EncodedImage) -> Result<()> {
        let (width, height) = self.info.panel.encoded_size();
        if image.format != ImageFormat::Jpeg
            || !image.is_whole(&self.info.panel)
            || !image.data.starts_with(&[0xFF, 0xD8])
        {
            return Err(Error::InvalidArgument(format!(
                "the DQ 2.88 takes full-frame JPEGs of {width}x{height}"
            )));
        }
        if image.data.len() > protocol::MAX_JPEG_LEN {
            return Err(Error::InvalidArgument(format!(
                "JPEG is {} bytes, maximum is {}",
                image.data.len(),
                protocol::MAX_JPEG_LEN
            )));
        }
        Ok(())
    }

    fn before_image(&mut self) -> Result<()> {
        if let Some(until) = self.busy_until.take() {
            std::thread::sleep(until.saturating_duration_since(Instant::now()));
        }
        if self.session_ended {
            self.send(&protocol::wake())?;
            self.session_ended = false;
        }
        Ok(())
    }
}

impl Display for Dq288 {
    fn info(&self) -> &DisplayInfo {
        &self.info
    }

    fn show(&mut self, image: &EncodedImage) -> Result<()> {
        self.check(image)?;
        self.before_image()?;
        if let Some(last) = self.last_dra {
            std::thread::sleep(
                (last + protocol::DRA_GAP).saturating_duration_since(Instant::now()),
            );
        }
        let reports = protocol::live_frame(&image.data);
        let sent = self.send(&reports);
        self.last_dra = Some(Instant::now());
        sent
    }

    fn save(&mut self, image: &EncodedImage) -> Result<()> {
        self.check(image)?;
        self.before_image()?;
        self.send(&protocol::stored_image(
            &image.data,
            protocol::StoreMode::Saved,
        ))?;
        self.busy_until = Some(Instant::now() + STORE_TIME);
        Ok(())
    }

    fn set_brightness(&mut self, percent: u8) -> Result<()> {
        self.send(&protocol::brightness(percent))
    }
    fn wake(&mut self) -> Result<()> {
        self.session_ended = false;
        self.send(&protocol::wake())
    }
    fn sleep(&mut self) -> Result<()> {
        self.send(&protocol::sleep())
    }
    fn clear(&mut self) -> Result<()> {
        self.send(&protocol::clear())?;
        self.session_ended = true;
        Ok(())
    }
    fn keep_alive(&mut self) -> Result<()> {
        self.send(&protocol::keep_alive())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ssp_core::testing::RecordingTransport;
    use ssp_core::{Encoder, Frame};

    fn open() -> Dq288 {
        let transport = RecordingTransport::new().with_input_report(b"V26_DQ_2.88_02.003\0\0");
        Dq288::open(Box::new(transport), "4250D278163C").unwrap()
    }

    #[test]
    fn matches_the_connected_revision() {
        let matches = Dq288Driver.usb_matches();
        assert_eq!(matches.len(), 1);
        assert_eq!(
            (matches[0].vendor_id, matches[0].product_id),
            (0x1800, 0x3006)
        );
        assert_eq!(matches[0].usage_page, Some(0xFFA0));
    }

    #[test]
    fn uses_whole_frames_to_avoid_region_flicker() {
        let mut display = open();
        assert!(!display.info().capabilities.partial_images);

        let frame = Frame::blank(WIDTH, HEIGHT);
        let mut image = Encoder::default()
            .encode(&frame, &display.info().panel, protocol::MAX_JPEG_LEN)
            .unwrap();
        image.x = 8;
        image.y = 8;
        image.width = 32;
        image.height = 32;

        assert!(matches!(
            display.show(&image),
            Err(Error::InvalidArgument(_))
        ));
    }
}
