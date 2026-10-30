# ECG Polar Recording System

Native Apple Silicon macOS software for recording and exploring cardiac signals from a Polar H10.

## Features

- Connects to a Polar H10 over Bluetooth and shows connection state, contact, battery, heart rate, latest R–R interval, and a live ECG preview.
- Records ECG at the H10 ECG stream rate, received heart-rate notifications, and R–R intervals to separate, hourly-rotated CSV files.
- Exports five-minute HRV windows with raw and heuristic-candidate time-domain metrics, quality fields, and an explicit `nn_verified=false` flag.
- Saves session metadata, clock anchors, and connection/acquisition events alongside the signal CSVs.
- Browses saved sessions with selectable ECG, R–R, Pulse Rate, and HRV trend plots, plus event and file views.
- Creates a shifted copy of a completed session by applying one timestamp offset; original files remain unchanged.
- Keeps recordings local to the Mac; no account or cloud service is used.

In a saved session, drag across a chart to select and zoom a time range. Use
**◀** and **▶** or the position slider to move the current window. Right-click
a chart and choose **Whole session** or **Back to previous zoom**. The same
window is retained when switching signals. ECG windows of 30 seconds or less
load the original samples; longer views are downsampled and do not show
individual beats faithfully. Loading a late ECG window may take time because
the CSV files are scanned locally. Missing HRV candidate windows remain gaps.

## Platform

macOS 14 or later on Apple Silicon. The app is built with Apple's Swift toolchain; `build.command` builds the app and `test.command` runs the core tests.

HRV candidate values are exploratory: normal-to-normal beats are not verified and this software is not for diagnosis or treatment decisions.
