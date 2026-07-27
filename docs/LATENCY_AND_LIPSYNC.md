# Latency and Lip-Sync Calibration

AutoMix reports two different kinds of latency:

- **DSP latency** is fixed and exact. The master true-peak limiter contributes 1.5 ms
  (144 frames at 96 kHz), verified with an impulse test.
- **Estimated audio-path latency** adds the input/output Core Audio buffer sizes,
  device-reported latency and safety offsets, the DSP delay, and—when separate input
  and output devices are used—the prebuffer in the cross-device output ring.

The estimate does not include every Dante network, encoder, camera, switcher, or
distribution delay. A real end-to-end A/V measurement is required for go-live.

## Measurement procedure

1. Use the exact production Dante route, Mac, buffer sizes, output device, encoder,
   cameras, switcher, frame rate, and streaming profile.
2. Record a sync source visible and audible to the camera, such as a clapper or a
   frame-accurate flash/beep generator, at the final program output.
3. Measure source event to encoded audio and source event to encoded video separately.
   Repeat at least ten times after the system has run for 30 minutes.
4. Enter the median audio and video path measurements in the Stream Mix panel.
5. Apply the displayed recommendation at the encoder:
   - if video is slower, delay audio by `video latency - audio latency`;
   - if audio is slower, delay video by `audio latency - video latency`.
6. Record the configured compensation and run the test again. The residual median
   offset must be within the venue's acceptance limit; use ±20 ms as the initial gate
   and tighten it when the video chain permits.
7. Repeat the test after changing sample rate, Core Audio buffers, DVS latency, output
   device, camera/switcher/encoder settings, or separate-device routing.

## Clock-drift test

A one-time offset is not enough when input and output use independent clocks. Run a
multi-hour recording with sync events near the beginning and end:

- calculate offset change in milliseconds per hour;
- any monotonic change is clock drift, not a fixed latency error;
- use one Aggregate Device/shared clock with drift correction, or implement and prove
  a bounded asynchronous sample-rate converter before production;
- do not compensate clock drift with a larger static ring buffer.

Hardware proof should preserve the two raw measurements, the final compensation,
residual offsets, duration, clock topology, Core Audio buffer sizes, device latency
frames, separate-output prebuffer frames, and the test recording.
